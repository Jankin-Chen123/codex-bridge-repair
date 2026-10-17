$ErrorActionPreference = 'Stop'
& (Join-Path $PSScriptRoot 'cache.test.ps1')
& (Join-Path $PSScriptRoot 'build-scan.test.ps1')
& node --test (Join-Path $PSScriptRoot 'config.test.cjs')
if ($LASTEXITCODE -ne 0) { throw 'Node tests failed' }
Write-Output 'All isolated tests passed.'
