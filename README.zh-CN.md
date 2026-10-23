# win-gui-guard

**Windows GUI 自动化的 fail-closed 安全层。**

让 AI 代理（或任何脚本）在你自己的桌面上动鼠标、打字、点界面时，需要三样东西：开工要显式授权、出事能立刻停、事后有记录。`win-gui-guard` 就是这三样：约 600 行 PowerShell + 一个 C# 文件。

它不替代你的自动化库（pyautogui、Playwright、AutoHotkey、SendInput 封装……），而是包在外面——保护不可验证时，**拒绝执行**。

## 特性

- **显式授权**：`Start-Guard` 成功前什么都不跑；存在停止标志时守候拒绝启动。
- **物理急停**：按物理 **ESC** 键 → 写停止标志 → 杀掉所有登记的自动化进程。
- **注入免疫**：合成按键带 `LLKHF_INJECTED` 标志，一律忽略——自动化程序触发不了（也伪造不了）自己的急停。
- **fail-closed 闸门**：每个动作前先校验：无停止标志、守候进程在、心跳 < 15 秒、守候规格等于已授权规格；否则带不同退出码直接中止。
- **规格指纹**：守候发布 `guard.spec`，被替换或降级的守候会导致规格不符，动作被拒。
- **停止时白名单**：只杀守候启动之后出现的解释器 / 自动化宿主进程，回收复用的 PID 绝不误杀。
- **审计**：`audit.log`（会话事件）+ `guard-actions.log`（每动作的 tag、PID、退出码）。
- **无界面、零依赖**：隐藏 PowerShell 宿主 + 一个由 `Add-Type` 现场编译的 C# 文件。

## 状态码

| 码 | 名称    | 含义                          | 处理        |
|----|---------|-------------------------------|-------------|
| 0  | CLEAR   | 守候在场、心跳新鲜、规格一致  | 允许动作    |
| 9  | STOPPED | 停止标志生效                  | 全部中止    |
| 8  | NOGUARD | 守候进程没运行                | 中止        |
| 7  | STALE   | 心跳超过 15 秒                | 中止        |
| 6  | BADSPEC | 守候规格与已授权规格不符      | 中止        |

## 快速开始

```powershell
.\scripts\arm.ps1 -Minutes 120 -Tag my-session                     # 武装
.\scripts\run-guarded.ps1 -Command "python .\click.py" -Tag click-1 # 动作过闸
.\scripts\status.ps1                                                # 只读查状态
.\scripts\disarm.ps1 -Confirm                                       # 收工
```

运行时目录默认 `.\runtime`，可用 `$env:WIN_GUI_GUARD_HOME` 改。

## 设计

- **构造上 fail-closed**：文件缺失、心跳不可读、进程死亡——每一种都意味着中止，绝不放行。
- **急停是物理的**：只认纯 ESC 的 keydown、只认真硬件输入；`Alt+ESC` 的 SYSKEYDOWN 不触发，避免与系统快捷键冲突。
- **停下不算完，守候要继续武器化**：触发后保持武装（默认 5 秒冷却），第二次按 ESC 仍然有效。
- **陈旧停止标志自愈**：守候进程已退出且无存活自动化进程的停止标志会被自动归档，一次崩溃不会永久堵死后续会话。

## 限制

- 仅 Windows（WinForms 消息循环 + `WH_KEYBOARD_LL`）。
- 需要交互式桌面会话（不是服务、不是 session 0）。
- ESC 是物理键：没有键盘的 headless 环境用不了急停（闸门本身仍有效）。
- 守候保护的是经闸门启动的进程；绕过闸门的程序在设计上不在它的视野内——把它当作纵深防御的一层，而不是唯一防线。

## 许可

MIT，见 [LICENSE](LICENSE)。
