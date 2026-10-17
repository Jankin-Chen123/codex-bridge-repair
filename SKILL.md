---
name: codex-windows-bridge-repair
description: Diagnose and repair Windows Codex desktop bridges for the Edge/Chrome sidebar, built-in Browser, and Computer Use, especially after an app update. Use for connection failures, missing native host manifests, stale bundled plugin caches, or unavailable local control tools.
---

# Codex Windows 连接修复

用于 Windows 版 Codex 桌面应用的三条独立连接：浏览器扩展的本机通信、内置浏览器、Computer Use。不要把其中一条的成功当成另外两条的证明。

## 运行

优先运行 [一键脚本](scripts/Codex工具一键诊断修复.cmd) 的 `--scan --no-pause` 模式，阅读输出的 `report.json`。用户要求修复时，直接运行默认修复模式并读取新报告；双击脚本会自动修复并暂停显示结果。脚本是单文件，复制 CMD 给其他 Windows 用户也能运行。源文件为 [repair.ps1](scripts/repair.ps1)，修改源文件后运行 [build.ps1](scripts/build.ps1) 重新生成 CMD。

脚本自动发现当前用户的 OpenAI.Codex AppX 安装、组件版本和用户目录，按哈希校验并用官方安装包的文件修复匹配版本缓存；检查 Edge/Chrome 本机通信注册和 Edge 默认配置文件中的扩展文件；备份旧配置后修复已知的 v2 通信清单；最后测试本机通信程序与 Codex 本地服务。它不会自动重启桌面应用或浏览器。只支持脚本已识别的 Windows x64 AppX 布局及 v2 清单；遇到未知格式应停止修改并报告。

## 继续诊断

- Edge 侧边栏：本机通信测试通过后，还要在用户当前 Edge 配置文件里确认扩展已启用，并实际打开侧边栏或点击 **Try again**。扩展文件存在不代表已启用。必要时使用已安装的 Browser 插件和它当前版本的使用说明做行为验证。
- 内置浏览器：缓存和运行程序存在只说明依赖完整。用当前 Browser 插件的官方客户端尝试取得 `iab`，打开一个安全页面并读取页面内容；失败时检查当前聊天的工具连接和 Codex 进程，避免凭旧路径或旧运行时版本推断原因。
- Computer Use：用当前版本的 Computer Use 技能说明，在受信任的 Node 工具里导入 `@oai/sky` 并执行 `sky.list_apps()`；真实应用列表才证明控制通道可用。不要把旧版本的脚本路径当成新版本必须存在的文件。
- 若工具启动时报工作目录无效，先核实该聊天绑定的实际工作目录及用户现有的迁移目标。仅在目标目录确实存在且路径对应关系明确时修复该工作目录或链接；不要自动创建猜测出的旧目录，也不要写死用户目录或动态管道 ID。修复后让 Codex 重新初始化工具连接，并分别重测三条通道。

报告要区分“已修复并验证”“仅校验文件”“需用户在浏览器中确认”“需要重启后再测”。保留报告和备份路径；不要打印令牌、本地服务 URL 或完整用户配置。不要删除整个插件缓存或改动 WindowsApps 安装目录。若问题涉及未知新版本协议、扩展缺失或应用本体损坏，说明当前自动修复的边界，并建议通过官方更新或修复安装处理。

