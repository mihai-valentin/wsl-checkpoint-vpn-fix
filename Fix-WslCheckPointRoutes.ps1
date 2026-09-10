<#
.SYNOPSIS
    Restores WSL 2 networking (NAT mode) after the Check Point Endpoint Security VPN
    connects in hub mode.

.DESCRIPTION
    In hub mode, the Check Point client adds routes on its virtual adapter that are more
    specific than the WSL vEthernet subnet (for a /20 it adds two /21s), plus host routes
    for the Windows side of the WSL link and the subnet broadcast address. Windows then
    sends WSL's return traffic into the tunnel and WSL loses all connectivity.

    This script removes ONLY the Check Point routes that lie inside the WSL subnet.
    WSL's internet traffic still leaves through the VPN, because Windows NATs it out of
    the tunnel. Nothing is persistent: the client adds the routes again on its next
    connect.

    Changing routes needs an elevated PowerShell. -WhatIf previews without admin rights.

.PARAMETER WaitSeconds
    Wait up to this many seconds for the Check Point routes to appear. Useful when the
    script runs at the moment the VPN connects.

.PARAMETER RecheckSeconds
    After fixing, look again after this many seconds and fix again if routes came back.

.PARAMETER LogFile
    Also append every message to this file.

.EXAMPLE
    .\Fix-WslCheckPointRoutes.ps1 -WhatIf

    Lists the routes that would be removed, without changing anything.

.EXAMPLE
    .\Fix-WslCheckPointRoutes.ps1 -RecheckSeconds 30

    Removes the routes, then reports whether the client added any back 30 seconds later.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [int]$WaitSeconds = 0,
    [int]$RecheckSeconds = 0,
    [string]$LogFile
)

function Write-Log([string]$Message) {
    $line = '{0:yyyy-MM-dd HH:mm:ss} {1}' -f (Get-Date), $Message
    Write-Output $line
    # -WhatIf must not suppress the log: a preview is exactly what you want recorded.
    if ($LogFile) { Add-Content -Path $LogFile -Value $line -WhatIf:$false }
}

function ConvertTo-UInt32([string]$Ip) {
    $b = ([ipaddress]$Ip).GetAddressBytes()
    [array]::Reverse($b)
    [BitConverter]::ToUInt32($b, 0)
}

function ConvertTo-IPString([uint32]$Value) {
    $b = [BitConverter]::GetBytes($Value)
    [array]::Reverse($b)
    ([System.Net.IPAddress]::new($b)).ToString()
}

function Get-NetworkMask([int]$Length) {
    # uint64 so that a shift by 32 (a /0) yields 0 instead of wrapping around.
    [uint32](([uint64]4294967295 -shl (32 - $Length)) -band [uint64]4294967295)
}

# True when a route prefix such as '172.23.160.0/21' lies entirely inside $Network/$Length.
function Test-PrefixInNetwork([string]$Prefix, [uint32]$Network, [int]$Length) {
    $addr, $plen = $Prefix.Split('/')
    ([int]$plen -ge $Length) -and (((ConvertTo-UInt32 $addr) -band (Get-NetworkMask $Length)) -eq $Network)
}

# The WSL and VPN adapters, and the Check Point routes that lie inside the WSL subnet.
function Get-State {
    $wsl = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object InterfaceAlias -like 'vEthernet (WSL*' | Select-Object -First 1
    $vpn = Get-NetAdapter -ErrorAction SilentlyContinue |
        Where-Object InterfaceDescription -like 'Check Point Virtual Network Adapter*' | Select-Object -First 1
    $state = [pscustomobject]@{ Wsl = $wsl; Vpn = $vpn; Length = 0; Network = [uint32]0; Routes = @() }
    if (-not $wsl -or -not $vpn -or $vpn.Status -ne 'Up') { return $state }

    $state.Length  = [int]$wsl.PrefixLength
    $state.Network = [uint32]((ConvertTo-UInt32 $wsl.IPAddress) -band (Get-NetworkMask $state.Length))
    $state.Routes  = @(Get-NetRoute -AddressFamily IPv4 -InterfaceIndex $vpn.ifIndex -ErrorAction SilentlyContinue |
        Where-Object { Test-PrefixInNetwork $_.DestinationPrefix $state.Network $state.Length })
    $state
}

# Load the networking modules with -WhatIf switched off. Otherwise PowerShell carries the
# preference into the module import and prints bogus "New Alias" previews for their aliases.
$whatIf = $WhatIfPreference
$WhatIfPreference = $false
Import-Module NetTCPIP, NetAdapter
$WhatIfPreference = $whatIf

$principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $WhatIfPreference -and -not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Changing routes needs an elevated PowerShell. Run it as administrator, or add -WhatIf to preview.'
}

$deadline = (Get-Date).AddSeconds($WaitSeconds)
$state = Get-State
while (-not $state.Routes -and (Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 2
    $state = Get-State
}

if (-not $state.Wsl) {
    Write-Log 'No WSL vEthernet adapter found (WSL is not running, or not in NAT mode). Nothing to do.'
    return
}
if (-not $state.Vpn -or $state.Vpn.Status -ne 'Up') {
    Write-Log 'The Check Point VPN adapter is not connected. Nothing to do.'
    return
}

$passes = if ($RecheckSeconds -gt 0) { 2 } else { 1 }
for ($pass = 1; $pass -le $passes; $pass++) {
    if ($pass -gt 1) {
        Start-Sleep -Seconds $RecheckSeconds
        $state = Get-State
        if (-not $state.Wsl -or -not $state.Vpn -or $state.Vpn.Status -ne 'Up') {
            Write-Log 'WSL or the VPN went away before the recheck. Stopping.'
            break
        }
        $found = if ($state.Routes) { "RE-ADDED $($state.Routes.Count) route(s)" } else { 'did not re-add any routes' }
        Write-Log "Recheck after ${RecheckSeconds}s: Check Point $found."
    }
    if (-not $state.Routes) {
        Write-Log "No Check Point routes overlap the WSL subnet $(ConvertTo-IPString $state.Network)/$($state.Length)."
    }
    foreach ($route in $state.Routes) {
        if ($PSCmdlet.ShouldProcess("$($route.DestinationPrefix) on '$($state.Vpn.Name)'", 'Remove route')) {
            $route | Remove-NetRoute -Confirm:$false
            Write-Log "Removed $($route.DestinationPrefix) from '$($state.Vpn.Name)'."
        }
    }
    # The client also takes over the host route for the Windows end of the WSL link; put it back if it is gone.
    $hostRoute = "$($state.Wsl.IPAddress)/32"
    if (-not (Get-NetRoute -DestinationPrefix $hostRoute -InterfaceIndex $state.Wsl.ifIndex -ErrorAction SilentlyContinue)) {
        if ($PSCmdlet.ShouldProcess("$hostRoute on '$($state.Wsl.InterfaceAlias)'", 'Add route')) {
            New-NetRoute -DestinationPrefix $hostRoute -InterfaceIndex $state.Wsl.ifIndex -NextHop 0.0.0.0 -RouteMetric 256 -PolicyStore ActiveStore | Out-Null
            Write-Log "Restored $hostRoute on '$($state.Wsl.InterfaceAlias)'."
        }
    }
}

# Any address inside the subnet shows which route Windows now uses to reach the WSL VM.
$probe = ConvertTo-IPString ([uint32]($state.Network + 2))
$chosen = Find-NetRoute -RemoteIPAddress $probe -ErrorAction SilentlyContinue | Select-Object -Last 1
Write-Log "Windows routes the WSL subnet via '$($chosen.InterfaceAlias)' ($($chosen.DestinationPrefix))."
