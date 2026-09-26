#!/bin/bash
# 华硕 a豆14 Air 2026 (M5451GA, BIOS 314) ACPI 修复一键应用脚本
# 作用：安装修补版 SSDT(AOD) 表 + 配置 GRUB（去掉 acpi=off、关闭 PSR/PR/DSC）
# 用法：sudo bash install.sh
set -e

if [ "$(id -u)" != "0" ]; then
    echo "请用 sudo 运行: sudo bash $0" >&2
    exit 1
fi

DIR=$(cd "$(dirname "$0")" && pwd)

echo "[1/3] 安装修补版 ACPI 表到 /boot/acpi/"
install -Dm644 "$DIR/ssdt22_aod_fix.cpio" /boot/acpi/ssdt22_aod_fix.cpio

echo "[2/3] 更新 /etc/default/grub"
cp -a /etc/default/grub /etc/default/grub.bak.$(date +%Y%m%d%H%M%S)
python3 - <<'PYEOF'
import re
p = '/etc/default/grub'
s = open(p).read()

# 去掉 acpi=off（无论它在哪个 GRUB_CMDLINE 变量里）
s = re.sub(r' ?acpi=off', '', s)

# 确保 GRUB_CMDLINE_LINUX_DEFAULT 含 amdgpu.dcdebugmask=0x414
def fix_default(m):
    val = m.group(1)
    if 'amdgpu.dcdebugmask' not in val:
        val = (val + ' amdgpu.dcdebugmask=0x414').strip()
    return 'GRUB_CMDLINE_LINUX_DEFAULT="%s"' % val
s = re.sub(r'GRUB_CMDLINE_LINUX_DEFAULT="([^"]*)"', fix_default, s)

# 确保 early initrd 覆盖配置存在
if 'GRUB_EARLY_INITRD_LINUX_CUSTOM' in s:
    s = re.sub(r'GRUB_EARLY_INITRD_LINUX_CUSTOM="[^"]*"',
               'GRUB_EARLY_INITRD_LINUX_CUSTOM="acpi/ssdt22_aod_fix.cpio"', s)
else:
    s = s.rstrip() + '\n\n# 华硕 M5451GA BIOS 314 的 SSDT(AMD AOD 表)有 bug 会导致内核 panic，用修补表覆盖\nGRUB_EARLY_INITRD_LINUX_CUSTOM="acpi/ssdt22_aod_fix.cpio"\n'

# 留 3 秒 GRUB 菜单时间，方便异常时进旧内核
s = re.sub(r'GRUB_TIMEOUT=\d+', 'GRUB_TIMEOUT=3', s)

open(p, 'w').write(s)
print('grub 配置已更新（原文件已备份为 /etc/default/grub.bak.*）')
PYEOF

echo "[3/3] 重新生成 GRUB 配置"
update-grub

echo
echo "完成！验证 GRUB 配置："
grep -m1 '^	initrd' /boot/grub/grub.cfg | grep -q ssdt22_aod_fix \
    && echo "  ✓ initrd 行已含修补表" || echo "  ✗ 警告：initrd 行未见修补表，请检查"
grep -c 'acpi=off' /boot/grub/grub.cfg | grep -q '^0$' \
    && echo "  ✓ acpi=off 已移除" || echo "  ✗ 警告：grub.cfg 中仍有 acpi=off"
echo
echo "请重启验证：sudo reboot"
