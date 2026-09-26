#!/bin/bash
# 华硕 a豆14 Air 2026 (M5451GA) 有线耳机麦克风修复一键应用脚本
# 作用：配置 model=alc233-asus + 安装 CTIA 寄存器强制脚本（开机/唤醒自动执行）
# 用法：sudo bash install.sh
set -e

if [ "$(id -u)" != "0" ]; then
    echo "请用 sudo 运行: sudo bash $0" >&2
    exit 1
fi

DIR=$(cd "$(dirname "$0")" && pwd)

echo "[1/5] 安装 alsa-tools（提供 hda-verb）"
apt-get install -y alsa-tools

echo "[2/5] 写入声卡 model 参数 /etc/modprobe.d/hda-model.conf"
echo "options snd-hda-intel model=alc233-asus" > /etc/modprobe.d/hda-model.conf

echo "[3/5] 安装 CTIA 强制脚本、systemd 服务和睡眠唤醒钩子"
install -Dm755 "$DIR/alc235-force-ctia.sh" /usr/local/bin/alc235-force-ctia.sh
install -Dm644 "$DIR/alc235-ctia.service" /etc/systemd/system/alc235-ctia.service
install -Dm755 "$DIR/alc235-ctia-resume" /usr/lib/systemd/system-sleep/alc235-ctia-resume
systemctl daemon-reload
systemctl enable alc235-ctia.service

echo "[4/5] 尝试热重载声卡模块（立即生效，免重启）"
USERNAME=$(logname 2>/dev/null || echo "$SUDO_USER")
USERCTL() { sudo -u "$USERNAME" XDG_RUNTIME_DIR=/run/user/$(id -u "$USERNAME") systemctl --user "$@"; }
if USERCTL stop pipewire.socket pipewire-pulse.socket pipewire pipewire-pulse wireplumber 2>/dev/null \
   && sleep 1 && modprobe -r snd_hda_intel 2>/dev/null && modprobe snd_hda_intel; then
    sleep 2
    USERCTL start wireplumber pipewire pipewire-pulse 2>/dev/null || true
    sleep 1
    /usr/local/bin/alc235-force-ctia.sh
    echo "  ✓ 已热重载并应用 CTIA 设置"
else
    echo "  ! 声卡模块正被占用，无法热重载。配置已写入，重启后自动生效。"
fi

echo "[5/5] 设置合理的录音增益"
amixer -c 1 sset 'Mic Boost' 1 >/dev/null 2>&1 || true
amixer -c 1 sset 'Capture' 50 cap >/dev/null 2>&1 || true

echo
echo "完成！验证方法：插上耳机后运行"
echo "  arecord -D plughw:1,0 -f S16_LE -r 48000 -c 1 -d 5 /tmp/t.wav && aplay /tmp/t.wav"
echo "能回放出自己说的话即修复成功。若热重载失败过，请先重启。"
