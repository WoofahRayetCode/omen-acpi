#requires -Version 5.1
<#
.SYNOPSIS
    Configure Windows to interpret the motherboard RTC as UTC for dual boot.

.DESCRIPTION
    Linux normally keeps the RTC in UTC while Windows traditionally interprets
    it as local time.  This script changes only Windows' interpretation of the
    RTC; it does not disable Windows Time or change the Windows time zone.

    Enable stores the previous registry state in ProgramData so Disable can
    restore it.  A reboot is required after Enable or Disable.
#>
[CmdletBinding()]
param(
    [ValidateSet('Status', 'Enable', 'Disable')]
    [string] $Action = 'Status'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RegistryPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\TimeZoneInformation'
$RegistrySubKey = 'SYSTEM\CurrentControlSet\Control\TimeZoneInformation'
$ValueName = 'RealTimeIsUniversal'
$BackupDirectory = Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'OMEN-ACPI'
$BackupPath = Join-Path $BackupDirectory 'dual-boot-time-backup.json'

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-RtcValueState {
    $baseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
        [Microsoft.Win32.RegistryHive]::LocalMachine,
        [Microsoft.Win32.RegistryView]::Default
    )
    try {
        $key = $baseKey.OpenSubKey($RegistrySubKey, $false)
        if ($null -eq $key) {
            return [pscustomobject]@{ Exists = $false; Kind = $null; Value = $null }
        }
        try {
            $valueNames = $key.GetValueNames()
            if ($valueNames -notcontains $ValueName) {
                return [pscustomobject]@{ Exists = $false; Kind = $null; Value = $null }
            }
            return [pscustomobject]@{
                Exists = $true
                Kind = $key.GetValueKind($ValueName).ToString()
                Value = $key.GetValue($ValueName, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
            }
        }
        finally {
            $key.Dispose()
        }
    }
    finally {
        $baseKey.Dispose()
    }
}

function Convert-ToRegistryPropertyType([string] $Kind) {
    switch ($Kind) {
        'String' { return 'String' }
        'ExpandString' { return 'ExpandString' }
        'Binary' { return 'Binary' }
        'DWord' { return 'DWord' }
        'QWord' { return 'QWord' }
        'MultiString' { return 'MultiString' }
        default { throw "Unsupported registry value type in backup: $Kind" }
    }
}

function Save-PreviousState($State) {
    if (Test-Path -LiteralPath $BackupPath) {
        return
    }
    New-Item -ItemType Directory -Path $BackupDirectory -Force | Out-Null
    $State | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $BackupPath -Encoding UTF8
}

function Restore-PreviousState {
    if (-not (Test-Path -LiteralPath $BackupPath)) {
        Remove-ItemProperty -LiteralPath $RegistryPath -Name $ValueName -ErrorAction SilentlyContinue
        return 'removed (no previous value was recorded)'
    }

    $backup = Get-Content -LiteralPath $BackupPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ([bool] $backup.Exists) {
        $type = Convert-ToRegistryPropertyType ([string] $backup.Kind)
        New-ItemProperty -LiteralPath $RegistryPath -Name $ValueName -PropertyType $type -Value $backup.Value -Force | Out-Null
        return "restored $($backup.Kind) value"
    }

    Remove-ItemProperty -LiteralPath $RegistryPath -Name $ValueName -ErrorAction SilentlyContinue
    return 'removed (the value was absent before Enable)'
}

function Show-Status {
    $state = Get-RtcValueState
    if ($state.Exists) {
        Write-Output "${ValueName}: $($state.Value) ($($state.Kind))"
        if ([string] $state.Kind -ne 'DWord' -or [int64] $state.Value -ne 1) {
            Write-Output 'Windows is not configured by this script to interpret the RTC as UTC.'
        }
        else {
            Write-Output 'Windows is configured to interpret the RTC as UTC.'
        }
    }
    else {
        Write-Output "${ValueName}: absent"
        Write-Output 'Windows is using its default RTC interpretation (normally local time).'
    }
}

if ($Action -eq 'Status') {
    Show-Status
    exit 0
}

if (-not (Test-IsAdministrator)) {
    throw "Enable and Disable must be run from an elevated PowerShell window."
}

if ($Action -eq 'Enable') {
    $state = Get-RtcValueState
    if ($state.Exists -and [string] $state.Kind -eq 'DWord' -and [int64] $state.Value -eq 1) {
        Write-Output 'Windows is already configured to interpret the RTC as UTC.'
        exit 0
    }

    Save-PreviousState $state
    New-ItemProperty -LiteralPath $RegistryPath -Name $ValueName -PropertyType DWord -Value 1 -Force | Out-Null
    Write-Output 'Configured Windows to interpret the motherboard RTC as UTC.'
    Write-Output "Backup: $BackupPath"
    Write-Output 'Reboot Windows for the change to take effect. The Windows Time service remains enabled.'
    exit 0
}

$result = Restore-PreviousState
Write-Output "Restored Windows RTC configuration: $result."
if (Test-Path -LiteralPath $BackupPath) {
    Remove-Item -LiteralPath $BackupPath -Force
}
Write-Output 'Reboot Windows for the change to take effect.'
