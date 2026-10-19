# 实战案例：WorkBuddy 国内版 + 国际版更新后双双打不开（2026-10-18）

本 skill 的来源。所有命令与输出都是当时在这台机器上真实跑出来的，
Windows 10 build 19045，用户 `zt`，两个版本共存。

## 现象

- 国内版 `WorkBuddy 5.8.3`、国际版 `WorkBuddy AI 5.8.4`，"更新完之后全都打不开"
- 双击 → 无窗口；任务管理器里进程起来几秒后消失
- 桌面/开始菜单快捷方式看着正常

## 调查路径（按顺序，每一步的证据）

### 第 1 步：别信快捷方式，先问注册表"真正装在哪"

```powershell
Get-ItemProperty "HKLM:\...\Uninstall\*","HKCU:\...\Uninstall\*" |
  Where-Object { $_.DisplayName -match 'WorkBuddy' } |
  Select-Object DisplayName,DisplayVersion,DisplayIcon,UninstallString
```

```
DisplayName     : WorkBuddy 5.8.3      (HKLM, /allusers  -> perMachine)
DisplayIcon     : C:\Program Files\WorkBuddy\WorkBuddy.exe,0
DisplayName     : WorkBuddy AI 5.8.4   (HKCU, /currentuser -> perUser)
DisplayIcon     : C:\Program Files\WorkBuddy\WorkBuddyAI.exe,0
```

两个产品**都指向 `C:\Program Files\WorkBuddy`**，这是后面一切混乱的起点。

### 第 2 步：看安装目录里还剩什么

```
C:\Program Files\WorkBuddy        8154 项，有 WorkBuddy.exe，没有 WorkBuddyAI.exe
C:\Users\zt\AppData\Local\Programs\WorkBuddy     仅剩 version / debug.log / .update-installing  ← 空了
C:\Users\zt\AppData\Local\Programs\WorkBuddyAI   仅剩 version / debug.log                        ← 空了
```

`.update-installing` 的内容直接点名了那次更新：

```json
{"pid":24984,"processName":"WorkBuddy-win32-x64-user-5.8.3.41334564-db0e9b51.exe"}
```

### 第 3 步：Windows 事件给出"哪个 exe 挂了"

```powershell
Get-WinEvent -FilterHashtable @{LogName='Application';StartTime=(Get-Date).AddHours(-8)}
```

```
Id=1002 Application Hang
  程序 WorkBuddyAI.exe 版本 5.8.4.0 已停止与 Windows 交互并关闭
  应用程序路径: C:\Users\zt\AppData\Local\Programs\WorkBuddy\WorkBuddyAI.exe
  挂起类型: Top level window is idle
Id=1001 WER  AppHangB1  P1: WorkBuddyAI.exe  P2: 5.8.4.0
```

关键：**国际版当时跑在 `...\Programs\WorkBuddy\WorkBuddyAI.exe`**（和国内版同一个目录），
不是 `...\Programs\WorkBuddyAI\`。

### 第 4 步：应用自己的日志说出"为什么不出窗口"

`C:\Users\zt\.workbuddy\logs\`：

- `startup\2026-10-18\14872-012242.log` 最后一行：
  `Phase: early silent startup update triggered, skipping window bootstrap`
- `main.log`：
  `[early-silent-startup-update] ready update restored before window, quitting to install version=5.8.4.41366630`
- `update\update-20261018.log`：
  `Launching installer: ...\Temp\workbuddy-update-x64\WorkBuddy-Setup-5.8.4.41366630.exe`
  `Using NSIS silent mode (/S --updated /UPDATE=1 /D=C:\Program Files\WorkBuddy)`
  `Calling app.quit() now`

→ **模式 A 成立**：每次启动都去装一个装不上的包，窗口永远不创建。

### 第 5 步：找到那个"装不上的包"

```powershell
(Get-Item "$env:LOCALAPPDATA\@genieworkbuddy-desktop-updater\installer.exe").VersionInfo
```

```
FileVersion  = 5.8.4
ProductName  = WorkBuddy AI      ← 国际版的包
Size         = 497735912
Modified     = 2026/10/16 06:17  ← 已经卡了两天
```

国内版（5.8.3）和国际版（5.8.4）共用同一个 updater 缓存目录，
于是国内版启动时捡到了国际版的待装包 —— 这是死循环的根因。

### 第 6 步：谁删掉了 WorkBuddyAI.exe —— 安装日志说了

`C:\Users\zt\.workbuddy\logs\installer.log`：

```
[install-68122968] INFO install target dir: C:\Users\zt\AppData\Local\Programs\WorkBuddy
[install-68122968] INFO wrote update install mark: ...\Programs\WorkBuddy\.update-installing
[install-68122968] INFO install directory confirmed: C:\Program Files\WorkBuddy (access=yes)
[install-68122968] INFO extraction sentinel OK: C:\Program Files\WorkBuddy\WorkBuddy.exe present
[install-68122968] INFO [WinShareTarget] register script exit=1
```

先写标记到旧目录 → 最终却装到 `C:\Program Files\WorkBuddy`，旧目录（里面同时放着
`WorkBuddy.exe` 和 `WorkBuddyAI.exe`）被连带卸载。而
`C:\Program Files\WorkBuddy\resources\install-manifest.json` 的 `files` 列表里
**只有 `WorkBuddy.exe`** —— 5.8.3 这个包压根不发货国际版 exe，所以它就再也没回来。

→ **模式 B 成立**。

### 第 7 步：顺带发现的次要故障

`register.log` / `%TEMP%\wb-installer-register.log`：

```
register FAILED: 0x80131500 ... HRESULT: 0x80073D06
Windows 无法安装程序包 WorkBuddyShareTarget_5.8.3.0，因为已安装了此程序的更高版本 5.8.4.0
```

→ **模式 C**（不阻断启动，只影响"分享到 WorkBuddy"）。

## 根因（两条，互相独立）

1. **静默更新死循环**：国内版和国际版共享 updater 缓存，国内版启动就去装国际版的 5.8.4；
   该包要写 `C:\Program Files` 而静默安装未提权，且安装预检 `QmProtector suspend failed`；
   失败后状态仍是 ready，下次启动再来一遍 → 窗口永不创建。
2. **共用安装目录**：5.8.3 安装包把目标从用户级目录改到 `C:\Program Files\WorkBuddy` 并卸载旧目录，
   而它不发货 `WorkBuddyAI.exe` → 国际版主程序消失，快捷方式失效。

## 实际执行的修复

```powershell
# 1. 用卡住的那个包（它本身就是 WorkBuddy AI 5.8.4 完整安装包）重装国际版到独立目录
$p    = "C:\Users\zt\AppData\Local\@genieworkbuddy-desktop-updater\installer.exe"
$dir  = "C:\Users\zt\AppData\Local\Programs\WorkBuddyAI"
Start-Process -FilePath $p -ArgumentList "/S","/D=$dir"
# 轮询 WorkBuddyAI.exe 出现 + installer 进程退出 → 7629 个文件，Uninstall WorkBuddyAI.exe 生成

# 2. 打破死循环
Remove-Item $p -Force
Remove-Item "$env:TEMP\workbuddy-update-x64","$env:TEMP\workbuddy-update-x64-workbuddy-ai" -Recurse -Force
Remove-Item "C:\Users\zt\AppData\Local\Programs\WorkBuddy" -Recurse -Force   # 已空

# 3. 重注册分享目标（必须用 Windows PowerShell 5.1，pwsh 7 加载不了 Appx 模块）
$env:WB_SHT_INSTDIR = $dir
$env:WB_SHT_LOG     = "C:\Users\zt\.workbuddy\logs\register.log"
powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass `
  -File "$dir\share-target\scripts\register.ps1"    # exit=0, register ok
```

## 验证

- `WorkBuddy.exe`：进程存在，主窗口标题 `WorkBuddy`，
  启动日志 `bootstrap complete - STARTUP COMPLETE`
- `WorkBuddyAI.exe`：主窗口标题 `WorkBuddy AI`
- 三个快捷方式（桌面 + 开始菜单 ×2）TargetPath 全部存在
- `@genieworkbuddy-desktop-updater` 缓存为空
- `WorkBuddyShareTarget 5.8.4.0` 状态 `Ok`，外部位置指向新的国际版目录

## 经验教训

- **快捷方式路径会骗人**：本例快捷方式指向 `C:\Program Files\WorkBuddy\WorkBuddyAI.exe`，
  但国际版实际一直跑在 `AppData\Local\Programs\WorkBuddy\` 下。永远以注册表 `DisplayIcon`
  和事件日志里的"应用程序路径"为准。
- **"双击没反应"最可能是启动被更新劫持**，不是程序损坏：先查日志里的
  `skipping window bootstrap`，能省掉重装的一小时。
- **多版本共存时，安装目录必须分开**，且要知道它们仍共享 `~/.<app>` 和 updater 缓存，
  死循环理论上还能再犯一次；复发速效就是删掉那个 pending `installer.exe`。
- **NSIS 保留打包时的文件时间戳**：重装后 `WorkBuddyAI.exe` 的 mtime 显示 10/15，
  不要拿 mtime 判断"有没有装成功"，要看文件是否存在、进程能否起来。
