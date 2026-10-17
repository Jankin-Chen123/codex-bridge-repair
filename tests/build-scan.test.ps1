$ErrorActionPreference = 'Stop'
$root = Join-Path ([IO.Path]::GetTempPath()) ('bridge 独立 CMD ' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($root) | Out-Null
function Assert($Condition,$Message) { if (!$Condition) { throw $Message } }
function Write-Fixture($Path,$Text) {
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path)) | Out-Null
    [IO.File]::WriteAllText($Path,$Text)
}
function Snapshot($Fixture) {
    @(Get-ChildItem -LiteralPath $Fixture -File -Recurse | Where-Object FullName -notlike '*\CodexBridgeRepair\runs\*' | ForEach-Object {
        $_.FullName + ':' + [Convert]::ToBase64String([IO.File]::ReadAllBytes($_.FullName)) + ':' + $_.LastWriteTimeUtc.Ticks
    } | Sort-Object) -join "`n"
}
try {
    $repo = Split-Path -Parent $PSScriptRoot
    $build = Join-Path $root 'build'
    [IO.Directory]::CreateDirectory($build) | Out-Null
    Copy-Item -LiteralPath (Join-Path $repo 'scripts/build.ps1'),(Join-Path $repo 'scripts/repair.ps1') -Destination $build
    & (Join-Path $build 'build.ps1') | Out-Null
    $cmd = Join-Path $build 'Codex工具一键诊断修复.cmd'
    $expected = [IO.File]::ReadAllBytes((Join-Path $repo 'scripts/Codex工具一键诊断修复.cmd'))
    Assert ([Convert]::ToBase64String([IO.File]::ReadAllBytes($cmd)) -eq [Convert]::ToBase64String($expected)) 'Tracked CMD is stale: run scripts/build.ps1'
    $raw = [IO.File]::ReadAllText($cmd,[Text.Encoding]::UTF8)
    $marker = "# POWERSHELL_PAYLOAD_START`r`n"
    $body = $raw.Substring($raw.LastIndexOf($marker)+$marker.Length)
    $source = [IO.File]::ReadAllText((Join-Path $repo 'scripts/repair.ps1'),[Text.Encoding]::UTF8).TrimStart([char]0xFEFF) -replace "`r?`n","`r`n"
    Assert ($body -ceq $source) 'Embedded source differs'
    Assert ($raw.Contains('exit /b %CODEX_BRIDGE_REPAIR_EXIT%')) 'CMD exit propagation missing'
    & (Join-Path $build 'build.ps1') -Check
    [IO.File]::AppendAllText($cmd,'stale')
    $staleDetected = $false
    try { & (Join-Path $build 'build.ps1') -Check } catch { $staleDetected = $true }
    Assert $staleDetected 'Check mode failed to detect stale CMD'
    Assert ([IO.File]::ReadAllText($cmd).EndsWith('stale')) 'Check mode modified CMD'
    & (Join-Path $build 'build.ps1') | Out-Null
    foreach ($n in 1,2) {
        Assert ($raw.Contains(('if /I "%~{0}"=="--scan" set "CODEX_BRIDGE_REPAIR_MODE=scan"' -f $n))) 'Scan argument handling missing'
    }
    Write-Output 'PASS build: deterministic CMD, exact payload, header flags and exit propagation'
    # Copy only CMD to a separate Chinese/space path; test the real encoded loader with mocked discovery.
    $standalone = Join-Path $root '只有 CMD 文件'
    [IO.Directory]::CreateDirectory($standalone) | Out-Null
    Copy-Item -LiteralPath $cmd -Destination $standalone
    Assert (@(Get-ChildItem -LiteralPath $standalone).Count -eq 1) 'Standalone folder contains companions'
    foreach ($mode in @('source','loader')) {
        $fixture = Join-Path $root $mode
        $resources = Join-Path $fixture 'package/app/resources'
        $market = Join-Path $resources 'plugins/openai-bundled'
        foreach ($name in @('browser','computer-use')) {
            Write-Fixture (Join-Path $market "plugins/$name/.codex-plugin/plugin.json") '{"version":"1.0"}'
        }
        Write-Fixture (Join-Path $market 'plugins/browser/scripts/browser-client.mjs') 'fixture'
        Write-Fixture (Join-Path $market 'plugins/chrome/scripts/extension-ids.json') '{"extensionHostName":"com.openai.fixture","browserExtensions":[]}'
        foreach ($file in @('cua_node/bin/node.exe','cua_node/bin/node_repl.exe')) { Write-Fixture (Join-Path $resources $file) 'must not execute' }
        foreach ($rel in @('local/OpenAI/Codex/chrome-native-hosts-v2.json','home/chrome-native-hosts-v2.json')) {
            Write-Fixture (Join-Path $fixture $rel) '{"schemaVersion":2,"entries":[]}'
        }
        Write-Fixture (Join-Path $fixture 'local/OpenAI/extension/com.openai.fixture.json') 'keep original'
        Write-Fixture (Join-Path $fixture 'home/plugins/cache/openai-bundled/browser/1.0/old.txt') 'old cache'
        $before = Snapshot $fixture
        $engine = (Get-Process -Id $PID).Path
        $payload = if ($mode -eq 'loader') { Join-Path $standalone 'Codex工具一键诊断修复.cmd' } else { Join-Path $repo 'scripts/repair.ps1' }
        $arguments = @('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $PSScriptRoot 'scan-runner.ps1'),'-Payload',$payload,'-Root',$fixture)
        if ($mode -eq 'loader') { $arguments += '-Loader' }
        $output = & $engine @arguments 2>&1
        Assert ($LASTEXITCODE -eq 0) "Scan failed: $output"
        Assert ((Snapshot $fixture) -ceq $before) "Scan modified target files: $mode"
        Assert (!(Test-Path -LiteralPath (Join-Path $fixture 'home/.tmp'))) 'Scan created marketplace cache'
        $reports = @(Get-ChildItem -LiteralPath (Join-Path $fixture 'local/OpenAI/CodexBridgeRepair/runs') -Filter report.json -Recurse)
        Assert ($reports.Count -eq 1) 'Scan report missing'
        $report = Get-Content -Raw -Encoding UTF8 -LiteralPath $reports[0].FullName | ConvertFrom-Json
        Assert ($report.mode -eq 'scan') 'Wrong scan mode'
        Assert (@($report.results | Where-Object state -eq '需修复').Count -ge 3) 'Scan did not inspect fake cache/registry'
        Write-Output "PASS scan: $mode (target bytes/timestamps unchanged, reports allowed)"
    }
    # Execute the actual CMD header and encoded loader against a harmless substitute payload.
    # Real repair payload was tested above with mocked discovery, never against the current PC.
    $probe = Join-Path $standalone '启动器测试.cmd'
    $probePayload = @'
if ($env:CODEX_BRIDGE_REPAIR_MODE -ne 'scan') { exit 8 }
if ($env:CODEX_BRIDGE_REPAIR_PAUSE -ne '0') { exit 9 }
exit 7
'@
    [IO.File]::WriteAllText($probe,$raw.Substring(0,$raw.LastIndexOf($marker)+$marker.Length)+$probePayload,[Text.UTF8Encoding]::new($false))
    $startInfo = New-Object Diagnostics.ProcessStartInfo
    $startInfo.FileName = $env:ComSpec
    $startInfo.Arguments = '/d /s /c ""{0}" --scan --no-pause"' -f $probe
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $process = [Diagnostics.Process]::Start($startInfo)
    $process.WaitForExit()
    Assert ($process.ExitCode -eq 7) 'CMD launcher failed to pass flags or propagate exit code'
    $process.Dispose()
    Write-Output 'PASS CMD launcher: Chinese/space path, scan/no-pause flags, exit code (harmless payload)'
} finally {
    if ([IO.Path]::GetDirectoryName($root) -ne [IO.Path]::GetTempPath().TrimEnd('\')) { throw 'Unsafe test cleanup path' }
    Remove-Item -LiteralPath $root -Recurse -Force
}
