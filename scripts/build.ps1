$ErrorActionPreference = 'Stop'
$folder = Split-Path -Parent $MyInvocation.MyCommand.Path
$source = Join-Path $folder 'repair.ps1'
$target = Join-Path $folder 'Codex工具一键诊断修复.cmd'
$body = [IO.File]::ReadAllText($source, [Text.Encoding]::UTF8).TrimStart([char]0xFEFF)
$loader = @'
$raw=[IO.File]::ReadAllText($env:CODEX_BRIDGE_REPAIR_SELF,[Text.Encoding]::UTF8)
$marker='# POWERSHELL_PAYLOAD_START'
$offset=$raw.LastIndexOf($marker)
if($offset -lt 0){throw 'Repair payload is missing.'}
& ([ScriptBlock]::Create($raw.Substring($offset+$marker.Length)))
'@
$encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($loader))
$header = @(
    '@echo off'
    'setlocal'
    'set "CODEX_BRIDGE_REPAIR_SELF=%~f0"'
    'set "CODEX_BRIDGE_REPAIR_MODE=repair"'
    'if /I "%~1"=="--scan" set "CODEX_BRIDGE_REPAIR_MODE=scan"'
    'if /I "%~2"=="--scan" set "CODEX_BRIDGE_REPAIR_MODE=scan"'
    'set "CODEX_BRIDGE_REPAIR_PAUSE=1"'
    'if /I "%~1"=="--no-pause" set "CODEX_BRIDGE_REPAIR_PAUSE=0"'
    'if /I "%~2"=="--no-pause" set "CODEX_BRIDGE_REPAIR_PAUSE=0"'
    ('"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -OutputFormat Text -EncodedCommand ' + $encoded)
    'set "CODEX_BRIDGE_REPAIR_EXIT=%errorlevel%"'
    'if "%CODEX_BRIDGE_REPAIR_PAUSE%"=="1" pause'
    'exit /b %CODEX_BRIDGE_REPAIR_EXIT%'
    '# POWERSHELL_PAYLOAD_START'
) -join "`r`n"
$content = ($header + "`r`n" + $body) -replace "`r?`n", "`r`n"
[IO.File]::WriteAllText($target, $content, [Text.UTF8Encoding]::new($false))
[Console]::WriteLine($target)

