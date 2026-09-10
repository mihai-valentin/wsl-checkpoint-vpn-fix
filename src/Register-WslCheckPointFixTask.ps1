#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Installs, updates or removes a scheduled task that runs Fix-WslCheckPointRoutes.ps1
    every time the VPN connects.

.DESCRIPTION
    The task runs as SYSTEM whenever Windows reports a newly connected network
    (Microsoft-Windows-NetworkProfile/Operational, event 10000). That event fires when the
    Check Point virtual adapter comes up, including reconnects after sleep. It also fires
    for ordinary Wi-Fi or Ethernet changes; the fix script then finds nothing to do.

    The fix script is copied to C:\ProgramData\WslCheckPointFix, and that folder is locked
    down so only administrators and SYSTEM can change it: a task that runs as SYSTEM must
    never execute a file a standard user can edit. Run this again after updating the fix
    script to install the new version.

.PARAMETER Uninstall
    Removes the task and C:\ProgramData\WslCheckPointFix.

.EXAMPLE
    .\Register-WslCheckPointFixTask.ps1

.EXAMPLE
    .\Register-WslCheckPointFixTask.ps1 -Uninstall
#>
param([switch]$Uninstall)

$ErrorActionPreference = 'Stop'
$taskName = 'WSL Check Point route fix'
$dir      = Join-Path $env:ProgramData 'WslCheckPointFix'
$script   = Join-Path $dir 'Fix-WslCheckPointRoutes.ps1'
$log      = Join-Path $dir 'fix.log'

if ($Uninstall) {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    Remove-Item -Path $dir -Recurse -Force -ErrorAction SilentlyContinue
    "Removed the '$taskName' task and $dir."
    return
}

$source = Join-Path $PSScriptRoot 'Fix-WslCheckPointRoutes.ps1'
if (-not (Test-Path $source)) { throw "Fix-WslCheckPointRoutes.ps1 was not found next to this script ($PSScriptRoot)." }

New-Item -ItemType Directory -Force -Path $dir | Out-Null
Copy-Item -Path $source -Destination $script -Force
# SIDs instead of names so this also works on non-English Windows:
# SYSTEM and Administrators get full control, Users can only read (and so read the log).
icacls $dir /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-32-545:(OI)(CI)RX' | Out-Null
if ($LASTEXITCODE -ne 0) { throw "icacls could not lock down $dir (exit code $LASTEXITCODE)." }

$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$script`" -WaitSeconds 60 -RecheckSeconds 30 -LogFile `"$log`""

$trigger = New-CimInstance -ClientOnly -CimClass (Get-CimClass -Namespace 'ROOT\Microsoft\Windows\TaskScheduler' -ClassName 'MSFT_TaskEventTrigger')
$trigger.Enabled = $true
$trigger.Subscription = '<QueryList><Query Id="0" Path="Microsoft-Windows-NetworkProfile/Operational"><Select Path="Microsoft-Windows-NetworkProfile/Operational">*[System[(EventID=10000)]]</Select></Query></QueryList>'

$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 5) -MultipleInstances Queue

Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings `
    -Description 'Removes Check Point hub-mode routes that cut off the WSL NAT subnet after the VPN connects.' -Force | Out-Null
"Installed the '$taskName' task. Log: $log"
