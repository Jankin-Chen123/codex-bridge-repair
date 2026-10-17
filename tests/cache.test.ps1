$ErrorActionPreference = 'Stop'
$root = Join-Path ([IO.Path]::GetTempPath()) ('bridge 中文 ' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($root) | Out-Null
$passed = 0
function Assert($Condition, $Message) { if (!$Condition) { throw $Message } }
function Write-Fixture($Path, $Text) {
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path)) | Out-Null
    [IO.File]::WriteAllText($Path, $Text)
}
try {
    # Import function ASTs only: no top-level discovery, reports, registry or real caches.
    $source = Join-Path $PSScriptRoot '../scripts/repair.ps1'
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($source,[ref]$tokens,[ref]$errors)
    Assert ($errors.Count -eq 0) 'Source has parse errors'
    foreach ($name in @('Get-RepairFileHash','Test-OfficialDirectory','Move-RepairDirectory','Restore-OfficialDirectory')) {
        $definition = $ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name}, $true)
        . ([scriptblock]::Create($definition.Extent.Text))
    }
    $official = Join-Path $root 'official'
    Write-Fixture (Join-Path $official 'nested/file.txt') 'new bytes'
    foreach ($scenario in @('normal','replace-fails','missing-fails','backup-fails','rollback-fails','stage-fails')) {
        $destination = Join-Path $root $scenario
        $missing = $scenario -eq 'missing-fails'
        if (!$missing) { Write-Fixture (Join-Path $destination 'old.txt') 'old bytes' }
        function Move-RepairDirectory([string]$Source,[string]$Destination) {
            if ($scenario -in @('replace-fails','missing-fails','rollback-fails') -and $Source -like '*.content-staging-*') { throw 'injected install failure' }
            if ($scenario -eq 'rollback-fails' -and $Source -like '*.backup-*') { throw 'injected rollback failure' }
            if ($scenario -eq 'backup-fails' -and $Destination -like '*.backup-*') { throw 'injected backup failure' }
            [IO.Directory]::Move($Source,$Destination)
        }
        $inspection = Test-OfficialDirectory $official $destination
        if ($scenario -eq 'stage-fails') {
            $inspection.files = @([pscustomobject]@{FullName=(Join-Path $official 'missing.txt')})
        }
        $failure = $null
        try { $result = Restore-OfficialDirectory $official $destination $inspection }
        catch { $failure = $_.Exception.Message }
        $backups = @(Get-ChildItem -LiteralPath $root -Directory | Where-Object Name -like "$scenario.backup-*")
        if ($scenario -eq 'normal') {
            Assert (!$failure) 'Normal repair failed'
            Assert ((Test-OfficialDirectory $official $destination).complete) 'New directory mismatch'
            Assert ($backups.Count -eq 1) 'Old cache backup missing'
            Assert ([IO.File]::ReadAllText((Join-Path $backups[0].FullName 'old.txt')) -eq 'old bytes') 'Old backup changed'
            $again = Restore-OfficialDirectory $official $destination (Test-OfficialDirectory $official $destination)
            Assert ($again -eq '正常') 'Repeated run should be a no-op'
            Assert (@(Get-ChildItem -LiteralPath $root -Directory | Where-Object Name -like "$scenario.backup-*").Count -eq 1) 'Repeated run made a backup'
        } elseif ($scenario -eq 'rollback-fails') {
            Assert ($failure -like '*自动回滚失败*') 'Rollback failure not reported'
            Assert ($backups.Count -eq 1) 'Recovery backup missing'
            Assert ($failure.Contains($backups[0].FullName)) 'Recovery path not reported'
            Assert ([IO.File]::ReadAllText((Join-Path $backups[0].FullName 'old.txt')) -eq 'old bytes') 'Recovery backup changed'
        } else {
            Assert ($null -ne $failure) 'Expected injected failure'
            if ($missing) { Assert (!(Test-Path -LiteralPath $destination)) 'Originally absent directory should stay absent' }
            else { Assert ([IO.File]::ReadAllText((Join-Path $destination 'old.txt')) -eq 'old bytes') 'Old cache not restored' }
            Assert ($backups.Count -eq 0) 'Unexpected backup after rollback'
        }
        Assert (@(Get-ChildItem -LiteralPath $root -Directory | Where-Object Name -like '*.content-staging-*').Count -eq 0) 'Staging leaked'
        $passed++; Write-Output "PASS cache: $scenario"
    }
    # Successful first install, then repeated no-op.
    $destination = Join-Path $root 'first-install'
    $scenario = 'normal'
    $null = Restore-OfficialDirectory $official $destination (Test-OfficialDirectory $official $destination)
    Assert ((Test-OfficialDirectory $official $destination).complete) 'First installation failed'
    Assert ((Restore-OfficialDirectory $official $destination (Test-OfficialDirectory $official $destination)) -eq '正常') 'First installation repeat failed'
    $passed++; Write-Output 'PASS cache: first install and repeat'
    Write-Output "$passed cache cases passed"
} finally {
    # root is an absolute, GUID-named directory created by this test, never a user cache.
    if ([IO.Path]::GetDirectoryName($root) -ne [IO.Path]::GetTempPath().TrimEnd('\')) { throw 'Unsafe test cleanup path' }
    Remove-Item -LiteralPath $root -Recurse -Force
}
