# 异常恢复改造与验证

## 基线

审查日期：2026-10-17。远端默认分支是 `main`，没有 `master`。
基线提交：`f0bb843ec926e9486a35472b00028fbffbac38e8`。
交付包含可直接替换的 `scripts/repair.ps1`、`scripts/build.ps1`、重新生成的独立 CMD 和隔离测试。

## PowerShell：缓存目录替换

`Restore-OfficialDirectory` 的顺序为：

1. 在目标旁创建唯一 staging 目录，逐文件复制并验证 SHA-256。
2. 校验旧目标不是目录链接，将旧目录改名到唯一 backup 路径。
3. 使用 `Directory.Move` 提交新目录。它会拒绝已存在的目标，避免 `Move-Item` 在目标被其他进程重新创建时把 staging 嵌套到其中。
4. 提交失败时，将 backup 移回原路径；原来不存在目标时，保留不存在的状态。
5. 回滚失败时，错误同时包含安装错误、回滚错误、旧备份和目标路径。旧备份不会被删除。
6. `finally` 只清理本次创建的 staging；清理错误独立输出，不覆盖主要错误。成功替换后保留旧缓存备份。

每个缓存目录分别处理；后一个组件失败不会撤销已经成功修复的前一个组件。

## Node.js：三个配置文件组成一个恢复单元

嵌入程序中的 `writeConfigurationTransaction` 处理两份 `chrome-native-hosts-v2.json` 和 Native Messaging manifest：

- 所有内容先生成并校验已有清单格式，再开始备份和暂存。
- 每次事务独立使用 `backups/<UUID>/`，按序号保存原始字节。`index.json` 记录目标路径、备份路径和原文件存在状态，避免同名文件覆盖。
- 所有备份、临时文件及索引写完，才依次通过 rename 提交。
- 任意提交失败，逆序恢复已提交文件。原有文件通过“备份 → 目标旁临时文件 → rename”恢复；原先不存在的文件删除本次创建的目标。
- 一处回滚失败仍继续恢复其他文件，最后报告全部失败路径及备份目录；清理临时文件，始终保留备份。
- 重复执行不会重复追加相同 runtime entry；保留无关 entry。时间和 presence 字段会更新，因此成功的重复执行不保证字节完全不变。

这些是可捕获异常的补偿回滚，不是文件系统的多文件原子事务。消费者可能在提交窗口看到混合状态。强制终止进程、断电、并发修复或 Codex 同时重写配置，不在自动恢复保证内。未增加启动时重放恢复日志；应避免并发运行。

事务在三份文件提交成功时结束；后续握手失败保留新配置供诊断。现有 HKCU 注册表修改仍独立执行，仅有原脚本的文本备份，没有加入这三个文件的事务。文件回滚恢复原始字节和存在状态，不承诺恢复时间戳、ACL 或其他 NTFS 元数据；新建空父目录可以保留。上述限制不能解释为“整个电脑环境已恢复”。

## 执行自动测试

在交付的仓库根目录运行，要求 Windows PowerShell 5.1 或 PowerShell 7，以及 PATH 中的 Node.js 22+；无需 Pester、npm 安装或管理员权限：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\run.ps1
```

分开执行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\cache.test.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\build-scan.test.ps1
node --test .\tests\config.test.cjs
```

测试只创建自己的 GUID 临时目录，并在结束时清理。缓存测试用 AST 加载生产函数，替换目录移动依赖注入故障；不运行生产脚本的顶层发现逻辑。配置测试直接提取并执行生产脚本内完整 Node 程序，使用真实临时文件和代理 fs 注入错误，本机握手由模拟进程应答。

扫描测试通过独立 PowerShell 子进程运行完整源码和独立 CMD 内的真实编码加载器。AppX、桌面进程和注册表探测均模拟，LOCALAPPDATA、CODEX_HOME、USERPROFILE 均指向临时目录；注册表写操作设为立即失败。比较所有目标文件的字节与时间戳；允许扫描创建自身报告。CMD 启动头另以无害替代 payload 实际执行，检查中文空格路径、参数及退出码。

| 自动覆盖 | 验证内容 |
| --- | --- |
| 缓存正常修复、首次安装、重复运行 | 新文件哈希一致，旧备份完整，重复执行不再备份 |
| staging、备份、提交失败 | 原缓存字节保留或自动恢复；不存在的目标仍不存在；无 staging 遗留 |
| 缓存回滚再次失败 | 错误标明恢复路径，旧备份存在且完整 |
| 配置正常修复与重复运行 | 三份配置有效，无关 entry 保留，同一 entry 不重复 |
| 第 1/2/3 次 rename 失败 | 已有文件逐字节恢复，原先不存在的文件恢复不存在状态 |
| 备份失败、临时写入失败 | 提交尚未开始，目标不变 |
| 配置回滚失败 | 仍恢复其余文件，错误与可用备份均保留 |
| 同名父目录、未知 schema | 备份互不覆盖，未知格式拒绝修改 |
| 扫描、构建与独立加载器 | 目标不变；生成结果可重复；CMD payload 与源码一致；过期 CMD 检查失败且不改文件 |

## 构建与一致性

原始基线的 CMD payload 与源码在换行规范化后相同。本次修改后已经重新构建 CMD。
另修复了 `build.ps1` 缺失 UTF-8 BOM 导致 Windows PowerShell 5.1 错误解码中文目标文件名的问题。

```powershell
# 重新生成可单独分享的 CMD
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\build.ps1

# 只读验证完整 CMD（启动器和源码）；不一致时非零退出
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\build.ps1 -Check
```

`-Check` 按构建器相同的去 BOM、CRLF 规则计算预期字节，再与 CMD 完整字节比较。
PowerShell 源文件及测试含中文，保留 UTF-8 BOM；CMD 本身为无 BOM 的 UTF-8，内部加载器显式按 UTF-8 读取 payload。

## 本次验证结果与实机边界

已在 Windows PowerShell 5.1 和 PowerShell 7 上运行全套隔离测试：7 项缓存场景、12 项 Node.js 场景，以及构建一致性、源码扫描、独立加载器扫描和无害 CMD 启动检查，均通过。包含真实 Windows 临时目录 rename；Node.js 配置测试使用模拟 native host。
`outputs/rollback.patch` 另在基线提交的干净本地克隆中通过 `git apply --check`、实际应用和 `build.ps1 -Check` 验证。
没有运行真实修复，没有修改当前 Codex 缓存或 HKCU 注册表。

仍需在专用 Windows 测试账户或虚拟机验证：

- 真实 AppX/WindowsApps 布局、权限及受保护文件的读取。
- 用独占文件句柄、ACL 拒绝写入、杀毒软件占用等真实 Windows 错误触发提交及回滚；与函数注入错误区分。
- 真实 Edge/Chrome Native Messaging 注册、App Execution Alias、hello/ensure 握手。
- Edge/Chrome 扩展和侧边栏、内置浏览器实际打开页面并读取内容、Computer Use 返回真实应用列表。
- 关闭 Codex 后运行，以及需要重启后复测的状态。测试并发写入或进程终止前先做虚拟机快照；本实现不保证自动恢复此类中断。

不要把隔离测试通过等同于三条真实通道已经恢复。
