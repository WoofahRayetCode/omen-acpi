# Windows dual-boot clock setup

This repository's ACPI transformation is Linux-only and does not require this
configuration. The optional PowerShell helper in
[`scripts/windows/dual-boot-time.ps1`](../scripts/windows/dual-boot-time.ps1)
addresses a separate dual-boot problem: Linux normally treats the motherboard
real-time clock (RTC) as UTC, while Windows traditionally treats it as local
time.

Keeping the RTC in UTC is the preferred arrangement because it avoids daylight-
saving and timezone-transition errors. The helper changes Windows to use that
same convention. It does not change the Windows timezone, disable Windows Time,
or modify Linux.

## Use

Open PowerShell as Administrator and run from the repository directory:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\scripts\windows\dual-boot-time.ps1 -Action Status
.\scripts\windows\dual-boot-time.ps1 -Action Enable
```

Reboot Windows after enabling it. Check that Windows has the correct timezone
and displayed time. Linux should report `RTC in local TZ: no` in:

```bash
timedatectl
```

To restore the Windows registry state that existed before Enable:

```powershell
.\scripts\windows\dual-boot-time.ps1 -Action Disable
```

The helper stores that prior state in
`%ProgramData%\OMEN-ACPI\dual-boot-time-backup.json`. Do not copy that file
between computers; it is only a local rollback record.

## What it changes

Enable creates or sets this Windows registry value:

```text
HKLM\SYSTEM\CurrentControlSet\Control\TimeZoneInformation
  RealTimeIsUniversal = DWORD 1
```

The value is a Windows-side interoperability setting, not an ACPI override.
Windows Time/NTP remains enabled so the system clock can synchronize normally.

## References and limits

- [ArchWiki: System time](https://wiki.archlinux.org/title/System_time)
- [ArchWiki: Dual boot with Windows](https://wiki.archlinux.org/title/Dual_boot_with_Windows)
- [systemd timedate1 documentation](https://github.com/systemd/systemd/blob/main/man/org.freedesktop.timedate1.xml)

This helper has not been tested on every Windows release or enterprise policy
configuration. Registry policy, domain management, hibernation, or firmware
RTC behavior may override or interfere with the setting.

## Testing the ACPI patch on Nobara

The main Linux installer targets CachyOS/Arch, `mkinitcpio`, and Limine. It
should not be run unchanged on Nobara. The separate
[`scripts/nobara/test-acpi-override.sh`](../scripts/nobara/test-acpi-override.sh)
helper provides a deliberately limited test path for an existing verified
`s5` or `combined` build archive.

On Nobara, install `acpica-tools` if `iasl` is not already available, then run
from the repository:

```bash
sudo dnf install acpica-tools cpio
bash ./scripts/nobara/test-nobara.sh preflight
sudo bash ./scripts/nobara/test-acpi-override.sh install s5 /path/to/omen-dsdt-s5-build.tar.gz
```

The helper checks `CONFIG_ACPI_TABLE_UPGRADE=y`, creates an early ACPI CPIO,
prepends it to a copy of the currently running kernel's initramfs, and writes a
separate GRUB Boot Loader Specification entry. It does not alter the stock
entry or make the test entry the default. Select the test entry manually after
rebooting.

Verify the result with:

```bash
bash ./scripts/nobara/test-nobara.sh verify s5
```

Remove the test entry and its owned payload with:

```bash
sudo bash ./scripts/nobara/test-acpi-override.sh remove s5
```

This is a one-kernel test harness, not yet a complete Nobara integration. A
successful test should be followed by a Nobara-specific kernel-update hook so
the override is rebuilt whenever the kernel or initramfs changes.
