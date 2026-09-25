# fcitx5 输入法配置（GNOME Wayland + 166% 分数缩放）

环境：Ubuntu 26.04 / GNOME Shell 50.1 / Wayland / 2880×1800 @ 166.67% 分数缩放 / fcitx5 5.1.19

本目录记录了让 fcitx5 候选框在所有应用中「像 Windows 一样紧贴光标」的完整排查结论与配置。
运行 `install.sh` 可一键部署，**注销重登后生效**。

## 最终效果

| 应用 | 输入法通道 | 候选框 |
|---|---|---|
| GTK3/4、Qt（终端、文件管理器等） | Wayland text-input-v3 → GNOME ibus 桥 → fcitx5 | ✅ 贴合光标 |
| Edge | X11（`--ozone-platform=x11`）→ GTK ibus 模块 | ✅ 贴合光标 |
| VSCode (Electron) | X11 + `--force-device-scale-factor=2` + 扩展补丁 | ✅ 贴合光标 |
| X11/Xwayland 老应用 | XIM（`XMODIFIERS=@im=fcitx`） | ✅ |

## 问题与根因（排查过程）

### 1. 环境变量被 gnome-session 强制指向 ibus

Ubuntu 的 `gnome-session` 二进制在启动时**无条件**把
`QT_IM_MODULE=ibus`、`QT_IM_MODULES=wayland;ibus`、`XMODIFIERS=@im=ibus`
写进 systemd user manager 环境（即使 im-config 已选择 fcitx5）。
应用因此走 fcitx5 的 ibus 兼容前端，在 Wayland + 分数缩放下光标坐标换算错误——
这就是最初「候选框跟随光标但偏移很大」的根因。

**对策**：
- `config/90-fcitx5.conf` → `~/.config/environment.d/`（会话早期生效）
- `config/fcitx5-im-env.service` → systemd user 服务，在 `graphical-session.target`
  之后把变量重新改回 fcitx（gnome-session 每次登录都会篡改，必须兜底）

关键取舍：**不设置 `GTK_IM_MODULE`**，让 GTK 走原生 Wayland text-input；
`QT_IM_MODULES=wayland;fcitx` 让 Qt6 优先走 text-input，XCB 时回退 fcitx 模块。

### 2. GNOME 不支持 input-method-v2 → waylandim 前端不可用

用自写工具枚举 Wayland globals（见下方「调试方法」）确认 mutter 只暴露
`zwp_text_input_manager_v3`，**没有** `zwp_input_method_manager_v2`。
fcitx5 日志中 `Using Wayland native input method protocol: 0` 印证。
因此在 GNOME 上所有 Wayland 应用只能经 **gnome-shell 内置的 ibus 桥**
（`org.freedesktop.IBus` 由 fcitx5 的 ibusfrontend 接管）输入，
候选框需要 **kimpanel GNOME 扩展**在 Shell 内原生渲染。
fcitx5 每次启动弹出的 wiki 提示框（#GNOME）就是在建议装这个扩展，装上后不再弹。

**对策**：`desktop/org.fcitx.Fcitx5.desktop` 开机自启 + 安装启用
[Input Method Panel (kimpanel)](https://extensions.gnome.org/extension/261/kimpanel/) 扩展。

### 3. Chromium/Electron 的光标坐标缩放混乱（分数缩放重灾区）

实测（dbus-monitor 抓取 `SetSpotRect` + 字符步进分析）：

- **Chromium Wayland 原生**：不用 fractional-scale-v1，按 buffer scale 2 上报，
  坐标是实际值的 0.833 倍 → 候选框遮挡光标（屏幕上半部分）。
- **强制 `--force-device-scale-factor=1.6667`**：坐标变成 1.2 倍，且 UI 尺寸错乱。❌
- **Chromium X11**（Edge）：GTK ibus 模块按 X11 像素上报，扩展
  `protocol_to_stage_rect` 正确换算 → **完全正常**。✅
- **Electron X11**（VSCode）：上报的是**自己的 DIP 坐标、不做像素换算**
  （字符步进 8.5 ≈ 编辑器字宽证实），扩展把 DIP 当 X11 像素再 ÷2 → 偏移一半。❌

**对策**：
- Edge：`--ozone-platform=x11`（见 `desktop/com.microsoft.Edge.desktop`、`microsoft-edge.desktop`）
- VSCode：`--ozone-platform=x11 --force-device-scale-factor=2`（整数缩放是 Electron
  坐标最可靠的路径）+ `extension/kimpanel-electron-fix.patch`：
  kimpanel 扩展对 Electron 类 X11 窗口先把坐标 ×2 还原再转换。
  补丁按 `get_wm_class()` 匹配，可自行往 `ELECTRON_WM_CLASSES` 列表里加应用。
- 注意：GNOME Shell 会缓存扩展代码，**补丁/修改扩展后必须注销重登才生效**，
  用 disable/enable 热重载无效（本次排查踩过的坑）。
- DSF=2 使 VSCode 界面大 20%，用 `vscode/settings.json` 的
  `"window.zoomLevel": -1` 正好抵消（1.2⁻¹ × 2 = 1.667）。

## 文件清单

```
fcitx5/
├── install.sh                          # 一键部署脚本
├── config/
│   ├── 90-fcitx5.conf                  # → ~/.config/environment.d/
│   └── fcitx5-im-env.service           # → ~/.config/systemd/user/（对抗 gnome-session 篡改）
├── desktop/
│   ├── org.fcitx.Fcitx5.desktop        # → ~/.config/autostart/（开机自启）
│   ├── com.microsoft.Edge.desktop      # → ~/.local/share/applications/（X11 模式）
│   ├── microsoft-edge.desktop          #    同上（Edge 有两个桌面文件，都要覆盖）
│   ├── code_code.desktop               # → 同上（X11 + DSF=2）
│   └── code_code-url-handler.desktop   # → 同上
├── extension/
│   └── kimpanel-electron-fix.patch     # kimpanel 扩展的 Electron 坐标修正补丁
└── vscode/
    └── settings.json                   # window.zoomLevel: -1（UI 缩放补偿）
```

## 调试方法（本次用到的手段，备查）

```bash
# 1. 枚举 compositor 支持的 Wayland 协议（无需 root/编译器）
python3 wlglobals.py   # 见下，ctypes 调 libwayland-client 列 registry globals

# 2. 抓取输入法上报的光标坐标
dbus-monitor "interface='org.kde.impanel2'" > /tmp/spotrect.log
# 在目标应用打字，对比 SetSpotRect 值与字符步进，判断坐标系

# 3. 判断应用是 Wayland 还是 X11
xlsclients             # 有名字 = X11 客户端
xwininfo -root -tree   # 查 X11 窗口几何（本机 X11 根屏 3456×2160 = 逻辑屏×2）

# 4. fcitx5 运行状态
fcitx5-diagnose
journalctl --user -b 0 | grep org.fcitx.Fcitx5.desktop
# 关注 "Using Wayland native input method protocol: 0" 和 "Failed to open xim"
```

## 已知限制

- GNOME 活动概览搜索框走 gnome-shell 自己的 ibus 通道，由 kimpanel 扩展渲染，位置正常。
- 其他 Electron 应用（Obsidian、QQ 等）有同样的坐标 bug：启动加
  `--ozone-platform=x11 --force-device-scale-factor=2`，并把其 wm_class 加进补丁列表。
- 如果修改了系统缩放比例（如 166% → 150%），VSCode 的 zoomLevel 补偿需重新计算
  （zoomLevel z 满足 1.2^z = 缩放比/2）。
