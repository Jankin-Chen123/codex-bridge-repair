param([string]$Payload,[string]$Root,[switch]$Loader)
$ErrorActionPreference = 'Stop'
$env:LOCALAPPDATA = Join-Path $Root 'local'
$env:CODEX_HOME = Join-Path $Root 'home'
$env:USERPROFILE = Join-Path $Root 'profile'
$env:CODEX_BRIDGE_REPAIR_MODE = 'scan'
$script:FixtureRoot = $Root
function Get-AppxPackage {
    param($Name)
    [pscustomobject]@{InstallLocation=(Join-Path $script:FixtureRoot 'package');Architecture='X64';Version='1.0';PackageFamilyName='Fixture'}
}
function Get-CimInstance { param($ClassName,$Filter) return $null }
function Test-Path {
    param([string]$LiteralPath,[string]$PathType)
    if ($LiteralPath -like 'HKCU:*') { return $false }
    $arguments = @{LiteralPath=$LiteralPath}
    if ($PathType) { $arguments.PathType=$PathType }
    Microsoft.PowerShell.Management\Test-Path @arguments
}
function New-Item { throw 'Scan attempted a forbidden write via New-Item' }
function Set-ItemProperty { throw 'Scan attempted registry mutation' }
function Restore-OfficialDirectory { throw 'Scan attempted cache repair' }
if ($Loader) {
    $env:CODEX_BRIDGE_REPAIR_SELF = $Payload
    $raw = [IO.File]::ReadAllText($Payload,[Text.Encoding]::UTF8)
    $encoded = [regex]::Match($raw,'-EncodedCommand ([A-Za-z0-9+/=]+)').Groups[1].Value
    & ([scriptblock]::Create([Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($encoded))))
} else {
    & ([scriptblock]::Create([IO.File]::ReadAllText($Payload,[Text.Encoding]::UTF8)))
}
