<#
    Dependency-free tests for the route-matching logic in Fix-WslCheckPointRoutes.ps1.
    Loads the script's functions without running it, so it needs neither admin rights nor a VPN.

    powershell -ExecutionPolicy Bypass -File .\tests\Test-FixWslCheckPointRoutes.ps1
#>
$ErrorActionPreference = 'Stop'

# ProviderPath, not Path: on a UNC share Path is provider-qualified, which the parser cannot open.
$path = (Resolve-Path (Join-Path $PSScriptRoot '..\src\Fix-WslCheckPointRoutes.ps1')).ProviderPath
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$parseErrors)
if ($parseErrors) { throw "Parse errors in ${path}: $($parseErrors -join '; ')" }
foreach ($fn in $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
    . ([scriptblock]::Create($fn.Extent.Text))
}

$script:failures = 0
function Assert-Equal($Actual, $Expected, [string]$Name) {
    if ($Actual -eq $Expected) {
        Write-Output "PASS  $Name"
    } else {
        Write-Output "FAIL  $Name - expected '$Expected', got '$Actual'"
        $script:failures++
    }
}

Assert-Equal (ConvertTo-IPString (ConvertTo-UInt32 '172.23.160.1')) '172.23.160.1' 'IPv4 round trip'
Assert-Equal (ConvertTo-IPString (Get-NetworkMask 20)) '255.255.240.0' 'mask /20'
Assert-Equal (ConvertTo-IPString (Get-NetworkMask 21)) '255.255.248.0' 'mask /21'
Assert-Equal (ConvertTo-IPString (Get-NetworkMask 32)) '255.255.255.255' 'mask /32'
Assert-Equal (ConvertTo-IPString (Get-NetworkMask 0)) '0.0.0.0' 'mask /0'

# A WSL vEthernet subnet of 172.23.160.0/20 (Windows side 172.23.160.1), as seen with the VPN up.
$network = [uint32]((ConvertTo-UInt32 '172.23.160.1') -band (Get-NetworkMask 20))
Assert-Equal (ConvertTo-IPString $network) '172.23.160.0' 'network of 172.23.160.1/20'

$cases = [ordered]@{
    # What the Check Point client adds on connect: must be removed.
    '172.23.160.0/21'   = $true
    '172.23.168.0/21'   = $true
    '172.23.160.1/32'   = $true
    '172.23.175.255/32' = $true
    '172.23.160.0/20'   = $true
    # Hub-mode and Office Mode routes, other networks and neighbours: must be kept.
    '0.0.0.0/2'         = $false
    '128.0.0.0/2'       = $false
    '172.16.0.0/12'     = $false
    '172.23.159.255/32' = $false
    '172.23.176.0/21'   = $false
    '10.0.0.0/24'       = $false
    '10.0.0.25/32'      = $false
    '192.168.1.0/25'    = $false
}
foreach ($prefix in $cases.Keys) {
    $verb = if ($cases[$prefix]) { 'removes' } else { 'keeps' }
    Assert-Equal (Test-PrefixInNetwork $prefix $network 20) $cases[$prefix] "$verb $prefix"
}

if ($script:failures) {
    Write-Output "$($script:failures) test(s) failed."
    exit 1
}
Write-Output 'All tests passed.'
