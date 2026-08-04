# Technical references

The sources below have different evidentiary roles. Standards and official
documentation define interfaces. Community reports show that the symptom has
occurred on other machines. Prior art informed the investigation method. None
of them proves this patch correct or extends support beyond the documented
reference machine.

## Standards and official documentation

- [ACPI Specification 6.4: OEM-supplied system-level control methods](https://uefi.org/htmlspecs/ACPI_Spec_6_4_html/07_Power_and_Performance_Mgmt/oem-supplied-system-level-control-methods.html)
  defines `_PTS` and `_WAK`, including the S5 argument passed to `_PTS` during
  orderly shutdown.
- [ACPI Specification 6.4: device power management objects](https://uefi.org/htmlspecs/ACPI_Spec_6_4_html/07_Power_and_Performance_Mgmt/device-power-management-objects.html)
  defines `_PS3`; the related
  [power-resource object](https://uefi.org/htmlspecs/ACPI_Spec_6_4_html/07_Power_and_Performance_Mgmt/power-resource-object.html)
  defines `_ON` and `_OFF`.
- [Linux initrd ACPI table override](https://docs.kernel.org/admin-guide/acpi/initrd_table_override.html)
  documents the mechanism used to load a locally rebuilt DSDT.
- [Linux PCI power management](https://docs.kernel.org/power/pci.html)
  distinguishes D3hot from D3cold.
- [Linux ACPI WMI interface](https://docs.kernel.org/next/wmi/acpi-interface.html)
  documents proprietary WMI data and `WQxx` query methods including `WQBZ` and
  `WQBE`.
- [NVIDIA PCI-Express Runtime D3 power management](https://download.nvidia.com/XFree86/Linux-x86_64/570.124.04/README/dynamicpowermanagement.html)
  describes firmware and ACPI dependencies of NVIDIA RTD3 support, including
  `_PR0` and `_PR3`.
- [Limine configuration reference](https://github.com/Limine-Bootloader/Limine/blob/v12.x/CONFIG.md)
  documents entries, paths and configuration syntax.
- [CachyOS boot manager documentation](https://wiki.cachyos.org/configuration/boot_manager_configuration/)
  describes the distribution integration used by the toolkit.
- [Arch Linux Pacman manual](https://man.archlinux.org/man/pacman.8.en)
  documents the package-management interface used for dependencies.

## Related reports

- [Fedora Discussion: incomplete shutdown on HP OMEN 16-ap0038ns](https://discussion.fedoraproject.org/t/technical-issue-incomplete-shutdown-on-hp-omen-16-ap0038ns/184041)
  reports residual heat, battery drain and a powered NVIDIA GPU across several
  distributions and kernels.
- [HP Support Community: Linux shutdown on HP OMEN 16-ap0xxx](https://h30434.www3.hp.com/t5/Gaming-Notebooks/After-shuting-down-from-a-Linux-distribution-HP-OMEN-16/td-p/9624996)
  records incomplete shutdown and `AE_AML_BUFFER_LIMIT`, `WQBZ` and `WQBE`
  findings, including a report from the reference 16-ap0006sl with BIOS F.13.
- [HP Support Community: additional HP OMEN 16-ap0xxx reports](https://h30434.www3.hp.com/t5/Gaming-Notebooks/HP-omen-did-not-shut-down/td-p/9623383)
  includes other family members with residual heat and powered-off battery
  drain.

These reports are independent evidence that the symptom is not isolated. They
are not evidence that this firmware-specific transformation is correct for
those systems.

## Related projects and prior art

- [OmenLinux: ACPI Fix for HP OMEN 16-u0000sl](https://github.com/OmenLinux/ACPI-Fix-for-HP-Omen-16-u0000sl)
  was an early reference for loading a modified HP OMEN DSDT through initramfs.
  It targets a different model, board and BIOS. This toolkit neither distributes
  nor reuses that project's DSDT.

## Project-specific investigation

- [`../patches/README.md`](../patches/README.md) specifies the normalized S5
  and `WQBZ` transformations and their structural verification rules.
- [`nvde-analysis.md`](nvde-analysis.md) records the DSDT plus 23-SSDT analysis,
  reconstructs the `_PTS -> PEGP._PS3 -> PG00._OFF` chain, and documents the
  measured post-resume re-arming of `NVDE`.
- [`nvde-audit.py`](nvde-audit.py) is the read-only tool used to classify symbol
  access and expose unresolved or ambiguous AML call paths.
- The implementation identifies the two affected loops in `WQBZ`, rebuilds each
  AML variant independently, and compares reconstructed AML hashes with
  installed state before reporting or removal.

The NVDE notes are background research, not a guarantee. They separate what is
provable from AML, what the maintainer observed on the reference machine, and
what depends on proprietary driver behaviour. Neither implemented variant
writes `NVDE`.

The actual transformations derive from ACPI tables collected locally on HP
OMEN MAX 16-ap0006sl, board `8E35`, BIOS `F.13`. Firmware tables and private
machine artifacts are not distributed.
