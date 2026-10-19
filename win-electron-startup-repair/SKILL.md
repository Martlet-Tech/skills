---
name: win-electron-startup-repair
description: >
  Diagnose and repair a Windows Electron desktop app that stopped opening after a
  self-update — WorkBuddy / CodeBuddy 或任何 electron-updater + NSIS 打包的桌面应用出现
  「双击没反应 / 进程闪一下就退 / 快捷方式失效 / 更新完就打不开」。覆盖四种故障模式：静默更新
  死循环（启动即跳过窗口去装更新）、多版本共用安装目录导致 exe 被卸载、Appx 稀疏包版本冲突、
  快捷方式指向已删除的 exe。附带 `scripts/triage.ps1` 一次性采集安装目录、快捷方式、更新缓存、
  应用日志和 Windows 事件日志。
whenToUse: >
  Use when a Windows desktop app — especially WorkBuddy / CodeBuddy, or any Electron app
  packaged with electron-updater + NSIS — no longer opens after an update: double-click
  produces nothing or a process that exits immediately, a shortcut reports a missing target,
  the app quits during startup, or a self-update appears stuck. Also use for 更新后打不开 /
  闪退 / 打不开 / 无窗口 / 快捷方式失效 on Windows desktop apps.
---

# Windows Electron 应用「更新后打不开」排障

## 什么时候用

- 应用更新完就打不开：双击无反应、进程起来又立刻消失、任务管理器里一闪而过
- 桌面/开始菜单快捷方式报「目标不存在」
- 同一台机器装了同一产品的两个版本（国内版 / 国际版），其中一个或两个都起不来
- 自更新卡住：反复提示安装更新但装不上

## 核心认知：别从 exe 开始猜，从「写下来的证据」开始

Windows 上 Electron 应用的每次启动和更新都会留下记录。真正的根因几乎总能在这六处之一读到，
而不是靠猜。按可信度排序：

| 证据源 | 在哪 | 能读出什么 |
|---|---|---|
| 应用启动日志 | `%USERPROFILE%\.<app>\logs\startup\<date>\<pid>-<time>.log` | 启动卡在哪一步，有没有走到 `STARTUP COMPLETE` |
| 更新日志 | `%USERPROFILE%\.<app>\logs\update\update-<date>.log`，`installer.log` | 是不是在装更新、装到谁、有没有失败 |
| Windows 事件日志 | Application 日志 1002(挂起) / 1000(崩溃) / 1001(WER) | 哪个 exe、什么版本、为什么退出 |
| 更新缓存 | `%LOCALAPPDATA%\@<app>-*-updater\installer.exe`、`%TEMP%\<app>-update-*` | 卡住的待装安装包（读它的 `ProductName`/`FileVersion`） |
| 注册表卸载项 | HKLM/HKCU `...\Uninstall\*` | 真实安装目录、`/allusers`(perMachine) vs `/currentuser`(perUser) |
| NSIS 安装清单 | `<INSTDIR>\resources\install-manifest.json` | 这个包到底发货哪些 exe（能证明某个 exe 被"卸没了"） |

一次性采集这些，直接跑：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts/triage.ps1 -AppName WorkBuddy
```

## 四种故障模式（按出现频率）

### 模式 A —— 静默更新死循环（最常见，症状最像"完全打不开"）

**判据**

- 启动日志最后几行是：`Phase: early silent startup update triggered, skipping window bootstrap`
- 更新日志出现：`ready update restored before window, quitting to install version=X.Y.Z`
- 进程在任务管理器里出现几秒后消失，永远不出窗口

**根因**：electron-updater 把下载好的安装包留在 updater 缓存里（`<...>-updater\installer.exe`）。
应用每次启动都优先去装它，装完才建窗口。若安装失败（目标目录在 `C:\Program Files` 而静默安装
没提权；或安装前预检失败，例如安全驱动挂起失败 `QmProtector suspend failed`），状态仍是 "ready"，
下次启动再来一遍 —— 窗口永远不会创建。

**修法**

先确认**日志里确实出现了上面那两句**再动手。注意：`%LOCALAPPDATA%\@*-updater\installer.exe`
是 electron-updater 的通用缓存位，很多机器上一台就有十几个长期躺着的 `installer.exe`，
它们本身无害 —— 只有当启动日志证明应用在"启动时就去装它"时，它才是阻塞项。

```powershell
# 1. 确认是它（看 ProductName / FileVersion，和日志里 quitting to install 的版本对得上）
Get-ChildItem "$env:LOCALAPPDATA" -Directory -Filter "*updater*" |
  Where-Object { $_.Name -like "*<AppName>*" } |
  Get-ChildItem -Filter installer.exe |
  ForEach-Object { $_.VersionInfo | Select-Object ProductName, FileVersion; $_.FullName }

# 2. 打破死循环
Remove-Item "$env:LOCALAPPDATA\@<app>-<...>-updater\installer.exe" -Force
Remove-Item "$env:TEMP\<app>-update-*" -Recurse -Force
```

若想保留这次更新：不要删，改成**右键 → 以管理员身份运行**该 `installer.exe`，装完循环自然结束。

### 模式 B —— 多版本共用安装目录，旧 exe 被卸载

**判据**

- 注册表里两个产品（如 `WorkBuddy 5.8.3` 与 `WorkBuddy AI 5.8.4`）指向**同一个** `INSTDIR`
- 其中一个 exe 全盘搜不到
- `<INSTDIR>\resources\install-manifest.json` 的 `files` 列表里**没有**那个 exe →
  证明这个安装包压根不发货它，是旧安装被卸载后没被补回来
- `installer.log` 里写入 `.update-installing` 的路径（旧目录）和最终
  `install directory confirmed`（新目录）**不一致** → 安装目标被改了，旧目录被连带卸载

**修法**：把缺失的版本重装到**独立目录**，绝不再共用同一个目录：

```powershell
Start-Process "<installer>.exe" -ArgumentList "/S","/D=C:\Users\<user>\AppData\Local\Programs\<AppName>Edition"
# 轮询等待 <INSTDIR>\<AppName>.exe 出现，并以 installer 进程退出为完成标志
```

安装包来源优先级：updater 缓存里那个 pending 包（先核对 `ProductName` 是不是缺失的那个版本）
> 官方下载页（本例 `D:\Downloads\` 就有一份）> 卸载重装。

### 模式 C —— Appx 稀疏包（ShareTarget）版本冲突

**判据**：`%USERPROFILE%\.<app>\logs\register.log` 或 `%TEMP%\wb-installer-register.log` 出现

- `0x80073D06`「已安装了此程序的更高版本」—— 两个版本抢同一个稀疏包
- `0x80073D0B`「外部位置不支持」—— 外部位置目录已被删除或不被支持

**影响**：不阻断启动，但「分享到该应用」失效。**修法**：用产品自带的注册脚本重注册。
注意 `Appx` 模块在 PowerShell 7 里加载不了（`Operation is not supported on this platform`），
必须走 Windows PowerShell 5.1：

```powershell
$env:WB_SHT_INSTDIR = "<INSTDIR>"
$env:WB_SHT_LOG     = "$env:USERPROFILE\.workbuddy\logs\register.log"
powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass `
  -File "<INSTDIR>\share-target\scripts\register.ps1"
# 退出码：0 成功 / 2 缺文件 / 3 注册后仍看不到 / 4 超时（应用自愈会重试）
```

### 模式 D —— 快捷方式指向已删除的 exe

重装后安装器通常会重建快捷方式；少数情况需要手工修。判据是 `TargetPath` 不存在：

```powershell
$s = New-Object -ComObject WScript.Shell
$l = $s.CreateShortcut("<path>.lnk"); $l.TargetPath = "<新 exe 路径>"; $l.Save()
```

## 标准处理顺序

1. **确认现象**：进程有没有起来？事件日志 1002/1000 报的是哪个 exe？
2. **跑 `triage.ps1`** 一次采全证据，不要凭感觉删文件
3. **按 A → B → D → C 匹配判据**（A 阻断启动最致命，C 只影响分享功能）
4. **先解除启动阻塞（A），再补缺失组件（B/D），最后修次要集成（C）**
5. **验证**：进程存在 + 主窗口有标题 + 启动日志出现 `bootstrap complete - STARTUP COMPLETE`
   + updater 缓存目录为空

## 预防与复发速效

- 同一台机器不要给两个共享 updater 缓存的同类产品（国内版/国际版）用同一个安装目录；
  它们共用 `~/.<app>` 用户数据和同一个 `<...>-updater` 缓存，会互相捡到对方的更新包
- 目标是 `C:\Program Files` 的静默更新需要提权，一旦没提权就会退化成模式 A 的死循环
- 复发速效（先恢复可用，再慢慢查）：

```powershell
Remove-Item "$env:LOCALAPPDATA\@<app>-*-updater\installer.exe" -Force
```

## 附：本 skill 的真实来源

完整时间线、每一条证据的原始输出和当时执行的命令，见
`references/workbuddy-case.md`（WorkBuddy 国内版 5.8.3 + 国际版 5.8.4，2026-10-18 实测）。
