#!/bin/bash
# 一键部署 fcitx5 输入法配置（GNOME Wayland + 分数缩放）
# 适用于 Ubuntu 26.04 / GNOME Shell 50，其他版本请先核对扩展版本号
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
KIMPANEL_UUID="kimpanel@kde.org"
KIMPANEL_VERSION_TAG="75158"   # 适配 GNOME Shell 49/50 的扩展版本

echo "==> 1. 安装 fcitx5 及中文组件"
sudo apt update
sudo apt install -y fcitx5 fcitx5-chinese-addons fcitx5-config-qt \
    fcitx5-frontend-all fcitx5-module-cloudpinyin fcitx5-module-chttrans \
    fcitx5-module-punctuation fcitx5-pinyin

echo "==> 2. 卸载 ibus（可选但推荐，避免 gnome-session 把应用引到 ibus）"
sudo apt remove -y ibus || true

echo "==> 3. 部署环境变量配置"
mkdir -p ~/.config/environment.d ~/.config/systemd/user
cp "$DIR/config/90-fcitx5.conf" ~/.config/environment.d/
cp "$DIR/config/fcitx5-im-env.service" ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable fcitx5-im-env.service

echo "==> 4. 部署 fcitx5 开机自启"
mkdir -p ~/.config/autostart
cp "$DIR/desktop/org.fcitx.Fcitx5.desktop" ~/.config/autostart/

echo "==> 5. 安装并启用 kimpanel GNOME 扩展（原生渲染候选框）"
if [ ! -d ~/.local/share/gnome-shell/extensions/$KIMPANEL_UUID ]; then
    curl -sL -o /tmp/kimpanel.zip \
        "https://extensions.gnome.org/download-extension/kimpanel@kde.org.shell-extension.zip?version_tag=$KIMPANEL_VERSION_TAG"
    gnome-extensions install --force /tmp/kimpanel.zip
fi
# 给扩展打 Electron 坐标修正补丁
patch -d ~/.local/share/gnome-shell/extensions/$KIMPANEL_UUID -p1 \
    < "$DIR/extension/kimpanel-electron-fix.patch"
# 加入启用列表（下次登录生效）
cur=$(gsettings get org.gnome.shell enabled-extensions)
if [[ "$cur" != *"$KIMPANEL_UUID"* ]]; then
    gsettings set org.gnome.shell enabled-extensions \
        "$(python3 -c "import ast; l=ast.literal_eval('''$cur'''); l.append('$KIMPANEL_UUID'); print(l)")"
fi

echo "==> 6. 部署 Edge / VSCode 启动参数覆盖"
mkdir -p ~/.local/share/applications
cp "$DIR"/desktop/com.microsoft.Edge.desktop \
   "$DIR"/desktop/microsoft-edge.desktop \
   "$DIR"/desktop/code_code.desktop \
   "$DIR"/desktop/code_code-url-handler.desktop \
   ~/.local/share/applications/
update-desktop-database ~/.local/share/applications 2>/dev/null || true

echo "==> 7. VSCode 设置（缩放补偿）"
if [ -f ~/.config/Code/User/settings.json ]; then
    echo "    ~/.config/Code/User/settings.json 已存在，请手动合并："
    cat "$DIR/vscode/settings.json"
else
    mkdir -p ~/.config/Code/User
    cp "$DIR/vscode/settings.json" ~/.config/Code/User/settings.json
fi

echo
echo "完成。请注销并重新登录一次，然后："
echo "  - fcitx5 应自动启动，不再弹出 wiki 提示框"
echo "  - 候选框在所有应用中贴合光标（GTK/Qt 走 GNOME ibus 桥，Edge/VSCode 走 X11）"
echo "  - 用 fcitx5-diagnose 检查仍有异常的应用"
