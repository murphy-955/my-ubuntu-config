#!/bin/bash
# ALC235 耳麦 CTIA 强制脚本
# 内核驱动漏掉了 0x10ec0235 的 CTIA/OMTP 制式切换，这里直接写寄存器补上
D=/dev/snd/hwC1D0
for i in $(seq 1 30); do
    [ -e "$D" ] && break
    sleep 1
done
[ -e "$D" ] || exit 1

w() { hda-verb $D 0x20 0x500 "$1" >/dev/null; hda-verb $D 0x20 0x400 "$2" >/dev/null; }
w 0x45 0xd489   # Set to CTIA type
w 0x1b 0x0c2b
