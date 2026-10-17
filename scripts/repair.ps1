$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$env:PSModulePath = "$PSHOME\Modules;$env:PSModulePath"
$env:PATH = "$env:SystemRoot\System32;$env:PATH"
$repairMode = if ($env:CODEX_BRIDGE_REPAIR_MODE -eq 'scan') { 'scan' } else { 'repair' }
$runDirectory = Join-Path $env:LOCALAPPDATA "OpenAI\CodexBridgeRepair\runs\$(Get-Date -Format 'yyyyMMdd-HHmmss')-$([guid]::NewGuid().ToString('N').Substring(0,8))"
[IO.Directory]::CreateDirectory($runDirectory) | Out-Null
$results = New-Object System.Collections.ArrayList
function Add-Result([string]$Area, [string]$State, [string]$Detail) {
    [void]$results.Add([pscustomobject]@{area=$Area;state=$State;detail=$Detail})
    [Console]::WriteLine("[$State] $Area：$Detail")
}
function Save-Report {
    $report = [pscustomobject]@{time=(Get-Date).ToString('o');mode=$repairMode;results=@($results.ToArray())}
    [IO.File]::WriteAllText((Join-Path $runDirectory 'report.json'),($report | ConvertTo-Json -Depth 5),[Text.UTF8Encoding]::new($false))
    [Console]::WriteLine("诊断报告：$(Join-Path $runDirectory 'report.json')")
}
function Get-RepairFileHash([string]$LiteralPath) {
    $stream = [IO.File]::OpenRead($LiteralPath)
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try { [pscustomobject]@{Hash=[BitConverter]::ToString($algorithm.ComputeHash($stream)).Replace('-','')} }
    finally { $algorithm.Dispose(); $stream.Dispose() }
}
function Test-OfficialDirectory([string]$Source, [string]$Destination) {
    if (!(Test-Path -LiteralPath $Source -PathType Container)) { throw "官方组件目录不存在：$Source" }
    $files = @(Get-ChildItem -LiteralPath $Source -File -Recurse -Force)
    if (!$files.Count) { throw "官方组件目录为空：$Source" }
    $complete = Test-Path -LiteralPath $Destination -PathType Container
    if ($complete -and ((Get-Item -LiteralPath $Destination).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw "组件目标目录是链接，已停止替换：$Destination" }
    foreach ($file in $files) {
        if ($file.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "不支持的组件链接文件：$($file.FullName)" }
        $relative = $file.FullName.Substring($Source.Length).TrimStart('\')
        $target = Join-Path $Destination $relative
        if (!(Test-Path -LiteralPath $target -PathType Leaf)) { $complete = $false; continue }
        if ((Get-RepairFileHash -LiteralPath $target).Hash -ne (Get-RepairFileHash -LiteralPath $file.FullName).Hash) { $complete = $false }
    }
    [pscustomobject]@{files=$files;complete=$complete}
}
function Move-RepairDirectory([string]$Source, [string]$Destination) {
    # Directory.Move refuses an occupied destination (Move-Item can nest directories).
    [IO.Directory]::Move($Source, $Destination)
}
function Restore-OfficialDirectory([string]$Source, [string]$Destination, $Inspection) {
    if ($Inspection.complete) { return '正常' }
    $Destination = [IO.Path]::GetFullPath($Destination)
    $staging = "$Destination.content-staging-$([guid]::NewGuid().ToString('N'))"
    $backup = "$Destination.backup-$([guid]::NewGuid().ToString('N'))"
    $backedUp = $false
    try {
        [IO.Directory]::CreateDirectory($staging) | Out-Null
        foreach ($file in $Inspection.files) {
            $relative = $file.FullName.Substring($Source.Length).TrimStart('\')
            $target = Join-Path $staging $relative
            [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target)) | Out-Null
            # Read/write contents so WindowsApps encryption attributes are not copied.
            [IO.File]::WriteAllBytes($target, [IO.File]::ReadAllBytes($file.FullName))
            if ((Get-RepairFileHash -LiteralPath $target).Hash -ne (Get-RepairFileHash -LiteralPath $file.FullName).Hash) { throw "组件文件校验失败：$relative" }
        }
        if (Test-Path -LiteralPath $Destination) {
            $resolved = (Resolve-Path -LiteralPath $Destination).Path
            if ($resolved -ne $Destination) { throw '组件备份路径校验失败。' }
            if ((Get-Item -LiteralPath $resolved).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw '组件目标目录是链接，已停止替换。' }
            Move-RepairDirectory $resolved $backup
            $backedUp = $true
        }
        try {
            Move-RepairDirectory $staging $Destination
        } catch {
            $installError = $_.Exception.Message
            if ($backedUp) {
                try { Move-RepairDirectory $backup $Destination }
                catch { throw "缓存替换失败：$installError；自动回滚失败：$($_.Exception.Message)；旧目录保留于：$backup；目标：$Destination" }
            }
            throw "缓存替换失败，原状态已恢复：$installError"
        }
    } finally {
        # Only our unique, absolute staging path may be deleted. Never delete the destination/backup.
        if ([IO.Directory]::Exists($staging)) {
            try { Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction Stop }
            catch { [Console]::Error.WriteLine("临时目录清理失败，保留于：$staging；$($_.Exception.Message)") }
        }
    }
    return '已修复'
}
try {
    $package = Get-AppxPackage -Name OpenAI.Codex | Sort-Object Version -Descending | Select-Object -First 1
    if (!$package) { throw '未找到当前用户安装的 Codex 桌面应用；请通过官方渠道安装后重试。' }
    if ($package.Architecture -ne 'X64') { throw "暂不支持此架构：$($package.Architecture)；未修改私有配置。" }
    $resources = Join-Path $package.InstallLocation 'app\resources'
    $nodeExe = Join-Path $resources 'cua_node\bin\node.exe'
    if (!(Test-Path -LiteralPath $nodeExe -PathType Leaf)) { throw 'Codex 内置运行程序不存在，请先修复应用安装。' }
    Add-Result 'Codex 安装' '正常' "检测到版本 $($package.Version)；架构 X64"
    $appPath = Join-Path $package.InstallLocation 'app\ChatGPT.exe'
    $desktop = Get-CimInstance Win32_Process -Filter "name='ChatGPT.exe'" | Where-Object {
        $_.ExecutablePath -eq $appPath -and $_.CommandLine -notmatch '--type='
    } | Select-Object -First 1
    if (!$desktop) { Add-Result '桌面进程' '需操作' '请打开当前版本的 Codex 桌面应用；本次仍会校验组件缓存。' }
    else { Add-Result '桌面进程' '正常' '当前版本的桌面应用正在运行。' }
    $cacheHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE '.codex' }
    $officialMarketplace = Join-Path $resources 'plugins\openai-bundled'
    [Console]::WriteLine("正在诊断 Codex $($package.Version)；模式：$repairMode")
    $marketDestination = Join-Path $cacheHome '.tmp\bundled-marketplaces\openai-bundled'
    $marketInspection = Test-OfficialDirectory $officialMarketplace $marketDestination
    if ($repairMode -eq 'repair') {
        $marketAction = Restore-OfficialDirectory $officialMarketplace $marketDestination $marketInspection
        Add-Result '官方组件市场缓存' $marketAction "$($marketInspection.files.Count) 个文件已校验。"
    } else { Add-Result '官方组件市场缓存' $(if($marketInspection.complete){'正常'}else{'需修复'}) "$($marketInspection.files.Count) 个文件已检查。" }
    foreach ($pluginName in @('browser', 'computer-use')) {
        $source = Join-Path $officialMarketplace "plugins\$pluginName"
        $version = [string](Get-Content -Raw -LiteralPath (Join-Path $source '.codex-plugin\plugin.json') | ConvertFrom-Json).version
        if ($version -notmatch '^[0-9][0-9A-Za-z.+_-]*$') { throw "组件版本格式异常：$pluginName" }
        $destination = Join-Path $cacheHome "plugins\cache\openai-bundled\$pluginName\$version"
        $inspection = Test-OfficialDirectory $source $destination
        $label = if ($pluginName -eq 'browser') { '内置浏览器组件' } else { 'Computer Use 组件' }
        if ($repairMode -eq 'repair') {
            $action = Restore-OfficialDirectory $source $destination $inspection
            Add-Result $label $action "匹配版本 $version；$($inspection.files.Count) 个文件。"
        } else { Add-Result $label $(if($inspection.complete){'正常'}else{'需修复'}) "匹配版本 $version；$($inspection.files.Count) 个文件。" }
    }
    $browserClient = Join-Path $officialMarketplace 'plugins\browser\scripts\browser-client.mjs'
    $nodeRepl = Join-Path $resources 'cua_node\bin\node_repl.exe'
    if (!(Test-Path -LiteralPath $browserClient -PathType Leaf) -or !(Test-Path -LiteralPath $nodeRepl -PathType Leaf)) { throw '内置浏览器运行依赖缺失，请修复或重新安装 Codex。' }
    Add-Result '内置浏览器运行依赖' '正常' '浏览器客户端及 Codex 内置 Node 运行程序存在；实际浏览器会话需在 Codex 中验证。'
    $chromeSource = Join-Path $officialMarketplace 'plugins\chrome'
    $ids = Get-Content -Raw -LiteralPath (Join-Path $chromeSource 'scripts\extension-ids.json') | ConvertFrom-Json
    $hostName = [string]$ids.extensionHostName
    if ($hostName -notmatch '^com\.openai\.[a-zA-Z0-9_.-]+$') { throw '官方浏览器通信程序名称格式异常；未修改浏览器注册。' }
    $manifestPath = Join-Path $env:LOCALAPPDATA "OpenAI\extension\$hostName.json"
    foreach ($nativeList in @((Join-Path $env:LOCALAPPDATA 'OpenAI\Codex\chrome-native-hosts-v2.json'), (Join-Path $cacheHome 'chrome-native-hosts-v2.json'))) {
        if (Test-Path -LiteralPath $nativeList -PathType Leaf) {
            $existingList = Get-Content -Raw -LiteralPath $nativeList | ConvertFrom-Json
            if ($existingList.schemaVersion -ne 2 -or $null -eq $existingList.entries -or $existingList.entries -isnot [array]) {
                throw "发现不认识的本机通信配置格式，已停止修改：$nativeList"
            }
        }
    }
    $registryPaths = @("HKCU:\Software\Microsoft\Edge\NativeMessagingHosts\$hostName", "HKCU:\Software\Google\Chrome\NativeMessagingHosts\$hostName")
    foreach ($registryPath in $registryPaths) {
        $previous = if (Test-Path -LiteralPath $registryPath) { (Get-Item -LiteralPath $registryPath).GetValue('') } else { $null }
        if ($previous -eq $manifestPath) { Add-Result '浏览器通信注册' '正常' "$registryPath 已指向当前清单。" }
        elseif ($repairMode -eq 'repair') {
            [IO.File]::AppendAllText((Join-Path $runDirectory 'registry-backup.txt'), "$registryPath = $previous`r`n",[Text.UTF8Encoding]::new($false))
            if (!(Test-Path -LiteralPath $registryPath)) { New-Item -Path $registryPath -Force | Out-Null }
            (Get-Item -LiteralPath $registryPath).SetValue('', $manifestPath)
            Add-Result '浏览器通信注册' '已修复' "$registryPath 已指向当前清单；旧值已备份。"
        } else { Add-Result '浏览器通信注册' '需修复' "$registryPath 未指向当前清单。" }
    }
    $edgeData = Join-Path $env:LOCALAPPDATA 'Microsoft\Edge\User Data'
    $edgeIds = @($ids.browserExtensions | Where-Object browserFamily -eq 'edge' | ForEach-Object { $_.extensionIds })
    $extensionFound = $false
    if (Test-Path -LiteralPath $edgeData -PathType Container) {
        foreach ($profile in @(Get-ChildItem -LiteralPath $edgeData -Directory -ErrorAction SilentlyContinue)) {
            if ($profile.Name -ne 'Default' -and $profile.Name -notlike 'Profile *') { continue }
            foreach ($extensionId in $edgeIds) {
                if (Test-Path -LiteralPath (Join-Path $profile.FullName "Extensions\$extensionId") -PathType Container) { $extensionFound = $true }
            }
        }
    }
    if ($extensionFound) { Add-Result 'Edge 扩展' '发现文件' '默认数据目录存在扩展文件；请在 edge://extensions 确认当前配置文件中已启用。' }
    else { Add-Result 'Edge 扩展' '需核实' '默认数据目录未找到扩展；请核对 Edge 当前配置文件与扩展安装状态。' }
    if ($repairMode -eq 'scan' -or !$desktop) {
        Add-Result 'Edge 通信' '待验证' '修复模式且桌面应用运行时才会测试本机通信。'
        Save-Report
        if (!$desktop -and $repairMode -eq 'repair') { exit 2 }
        exit 0
    }
    $repairProgram = Join-Path $runDirectory 'repair.cjs'
    $program = @'
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const {spawn} = require('child_process');
const [resources, home, desktopPID, desktopStartedAt, family, runDirectory] = process.argv.slice(2);
const local = process.env.LOCALAPPDATA;
const plugin = path.join(resources, 'plugins/openai-bundled/plugins/chrome');
const ids = JSON.parse(fs.readFileSync(path.join(plugin, 'scripts/extension-ids.json'), 'utf8'));
const hostName = ids.extensionHostName;
if (!hostName || !Array.isArray(ids.extensionIds) || !ids.extensionIds.length) throw Error('Official native host definition is invalid');
const version = JSON.parse(fs.readFileSync(path.join(plugin, '.codex-plugin/plugin.json'), 'utf8')).version;
const paths = {
  browserClientPath:path.join(plugin,'scripts/browser-client.mjs'),
  browserServicePath:path.join(plugin,'scripts/browser-service.mjs'),
  codexCliPath:path.join(resources,'codex.exe'), codexHome:home,
  extensionHostPath:path.join(plugin,'extension-host/windows/x64/extension-host.exe'),
  nodePath:path.join(resources,'cua_node/bin/node.exe'),
  nodeModuleDirs:[path.join(resources,'cua_node/bin/node_modules')],
  nodeReplPath:path.join(resources,'cua_node/bin/node_repl.exe'), resourcesPath:resources
};
for (const p of Object.values(paths).flat()) if (!fs.existsSync(p)) throw Error('Missing current runtime: '+p);
function hash(parts) { const h=crypto.createHash('sha256');for(const p of parts){h.update(p);h.update('\0');}return h.digest('hex').slice(0,32); }
const now=new Date().toISOString();
const entry={schemaVersion:2,appServerProtocolVersion:2,appVersion:version,channel:'prod',cliVersion:version,
  entryId:'codex-runtime-'+hash([hostName,...ids.extensionIds,'prod',version,paths.extensionHostPath,paths.codexCliPath,home,resources]),
  extensionBuildChannels:['prod'],extensionIds:ids.extensionIds,
  installId:'codex-install-'+hash([hostName,resources,home]),nativeHostNames:[hostName],
  nativeHostProtocolVersion:2,nativeHostVersion:version,paths,
  presence:{lastSeenAt:now,pid:Number(desktopPID),startedAt:desktopStartedAt},
  proxyHost:'127.0.0.1',proxyPort:0,updatedAt:now};
if (!entry.presence.pid || !desktopStartedAt) throw Error('Desktop process presence is required');
const manifestPath=path.join(local,'OpenAI/extension',hostName+'.json');
const destinations=[path.join(local,'OpenAI/Codex/chrome-native-hosts-v2.json'),path.join(home,'chrome-native-hosts-v2.json')];
const pending=destinations.map(p=>{
  let entries=[];
  if(fs.existsSync(p)){
    const old=JSON.parse(fs.readFileSync(p,'utf8'));
    if(old.schemaVersion!==2 || !Array.isArray(old.entries)) throw Error('Unexpected existing native manifest schema: '+p);
    entries=old.entries.filter(e=>e.entryId!==entry.entryId && !(e.nativeHostNames?.includes(hostName) && (!fs.existsSync(e.paths?.extensionHostPath||'') || e.paths?.resourcesPath===resources)));
  }
  return [p,{schemaVersion:2,entries:[...entries,entry]}];
});
const alias=path.join(local,'Microsoft/WindowsApps',family,'codex-chrome-native-host.exe');
pending.push([manifestPath,{allowed_origins:ids.extensionIds.map(id=>'chrome-extension://'+id+'/'),description:'ChatGPT browser native messaging host',name:hostName,path:alias,type:'stdio'}]);
function writeConfigurationTransaction(pending, runDirectory) {
  // A unique backup set avoids collisions between equal basenames and repeated runs.
  const backup=path.join(runDirectory,'backups',crypto.randomUUID());
  fs.mkdirSync(backup,{recursive:true});
  const records=[];
  const committed=[];
  try {
    for (const [index,[p,value]] of pending.entries()) {
      const original=fs.existsSync(p) ? fs.readFileSync(p) : null;
      const record={path:p,existed:original!==null,backup:path.join(backup,index+'.bin'),
        temp:p+'.tmp-'+crypto.randomUUID()};
      records.push(record);
      if (original!==null) fs.writeFileSync(record.backup,original,{flag:'wx'});
      fs.mkdirSync(path.dirname(p),{recursive:true});
      fs.writeFileSync(record.temp,JSON.stringify(value,null,2)+'\n',{flag:'wx'});
    }
    // Persist the mapping before replacing anything; absence is part of the snapshot.
    fs.writeFileSync(path.join(backup,'index.json'),JSON.stringify(records,null,2)+'\n',{flag:'wx'});
    for (const record of records) {
      fs.renameSync(record.temp,record.path);
      committed.push(record);
    }
  } catch (error) {
    const failures=[];
    for (const record of committed.reverse()) {
      try {
        if (record.existed) {
          fs.writeFileSync(record.temp,fs.readFileSync(record.backup),{flag:'wx'});
          fs.renameSync(record.temp,record.path);
        } else fs.unlinkSync(record.path);
      } catch (rollbackError) {
        failures.push(record.path+': '+rollbackError.message);
      }
    }
    throw new Error('Native configuration transaction failed: '+error.message+
      (failures.length ? '; rollback incomplete: '+failures.join('; ') : '; original files restored')+
      '; backup: '+backup, {cause:error});
  } finally {
    for (const record of records) {
      try { if(fs.existsSync(record.temp)) fs.unlinkSync(record.temp); }
      catch (error) { console.error('Temporary file retained: '+record.temp+': '+error.message); }
    }
  }
  return backup;
}
const backup=writeConfigurationTransaction(pending,runDirectory);
console.log('Native configuration updated. Backup: '+backup);
const edge=ids.browserExtensions?.find(b=>b.browserFamily==='edge');
const extensionId=edge?.storeExtensionId || ids.extensionIds[0];
const constraints={extensionBuildChannel:'prod',extensionId,extensionVersion:'1.0.0',nativeHostName:hostName,requiredAppServerProtocolVersion:2,requiredNativeHostProtocolVersion:2};
const child=spawn(alias,['chrome-extension://'+extensionId+'/'],{windowsHide:true,stdio:['pipe','pipe','pipe']});
let buffer=Buffer.alloc(0),finished=false;
function finish(error){
  if(finished)return;finished=true;clearTimeout(timer);
  if(error){console.error(error);process.exitCode=1;}else console.log('Native host and local app-server connection verified.');
  child.stdin.end();child.kill();
}
const timer=setTimeout(()=>finish('Native connection verification timed out.'),45000);
function send(id,method){const body=Buffer.from(JSON.stringify({jsonrpc:'2.0',id,method,params:{constraints}}));const head=Buffer.alloc(4);head.writeUInt32LE(body.length);child.stdin.write(Buffer.concat([head,body]));}
child.stdout.on('data',data=>{
  buffer=Buffer.concat([buffer,data]);
  while(buffer.length>=4){
    const size=buffer.readUInt32LE(0);if(size>8388608){finish('Invalid native frame size.');return;}if(buffer.length<size+4)return;
    let message;try{message=JSON.parse(buffer.subarray(4,4+size));}catch{finish('Invalid native response.');return;}
    buffer=buffer.subarray(4+size);if(finished)return;
    if(message.id!==1 && message.id!==2)continue;
    if(message.error){finish('Native connection error: '+String(message.error.message||'unknown'));return;}
    if(message.id===1)send(2,'codexRuntime/ensure');else finish();
  }
});
child.stderr.on('data',()=>{});
child.stdin.on('error',e=>{if(!finished)finish('Native input error: '+e.message);});
child.on('error',e=>finish('Unable to start native host: '+e.message));
child.on('exit',()=>{if(!finished)finish('Native host exited before verification completed.');});
send(1,'codexRuntime/hello');
'@
    [IO.File]::WriteAllText($repairProgram, $program, [Text.UTF8Encoding]::new($false))
    & $nodeExe $repairProgram $resources $cacheHome $desktop.ProcessId $desktop.CreationDate.ToUniversalTime().ToString('o') $package.PackageFamilyName $runDirectory
    if ($LASTEXITCODE -ne 0) { throw '通信验证失败，请保留上方错误信息。' }
    Add-Result 'Edge 本机通信' '已验证' '本机通信程序及 Codex 本地服务应答正常。'
    Add-Result 'Computer Use 与内置浏览器' '待验证' '组件已校验；请在新的 Codex 对话中分别测试应用列表和内置浏览器。'
    [Console]::WriteLine('修复阶段完成。请在 Edge 侧边栏点击 Try again；如 Codex 内置浏览器或 Computer Use 仍失败，请先完全重启 Codex 再测试。')
    Save-Report
    exit 0
} catch {
    Add-Result '修复流程' '失败' $_.Exception.Message
    Save-Report
    exit 1
}

