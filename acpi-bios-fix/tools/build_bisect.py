#!/usr/bin/env python3
# 用法: sudo python3 build_bisect.py <输出cpio路径> <要禁用的表序号,逗号分隔> [表目录]
# 生成含"空表覆盖"的 early cpio：用同 OEMID/OEMTID、修订号+1 的空 SSDT
# 顶替指定序号（XSDT 中的顺序号）的固件表，用于二分定位坏表。
import struct, subprocess, sys, os, tempfile, shutil

out_cpio = sys.argv[1]
ids = sys.argv[2].split(',')
srcdir = sys.argv[3] if len(sys.argv) > 3 else os.path.abspath('acpi_tables')
work = tempfile.mkdtemp()
initrd = os.path.join(work, 'initrd', 'kernel', 'firmware', 'acpi')
os.makedirs(initrd)

for tid in ids:
    matches = [f for f in os.listdir(srcdir) if f.startswith(tid + '_SSDT_') and f.endswith('.aml')]
    assert matches, f'表 {tid} 不存在'
    f = os.path.join(srcdir, matches[0])
    h = open(f, 'rb').read(36)
    oemid, oemtid, rev = h[10:16], h[16:24], struct.unpack('<I', h[24:28])[0]
    print(f'stub {matches[0]}: OEMID={oemid!r} OEMTID={oemtid!r} REV={rev}')
    # 先用占位符编译空表
    asl = os.path.join(work, f'{tid}.asl')
    open(asl, 'w').write('DefinitionBlock ("", "SSDT", 2, "AAAAAA", "BBBBBBBB", 0x1)\n{\n}\n')
    subprocess.run(['iasl', '-tc', asl], check=True, capture_output=True)
    aml = bytearray(open(os.path.join(work, f'{tid}.aml'), 'rb').read())
    aml[10:16] = oemid
    aml[16:24] = oemtid
    new_rev = rev + 1 if rev < 0xFFFFFFFE else rev
    aml[24:28] = struct.pack('<I', new_rev)  # 覆盖要求新表修订号 > 原表
    aml[9] = 0
    aml[9] = (-sum(aml)) % 256   # 修正校验和
    open(os.path.join(initrd, f'ssdt_{tid}.aml'), 'wb').write(bytes(aml))

cpio = subprocess.run(['sh', '-c', f'cd {work}/initrd && find . | cpio -H newc -o --quiet'],
                      check=True, capture_output=True)
open(out_cpio, 'wb').write(cpio.stdout)
print('built', out_cpio, os.path.getsize(out_cpio), 'bytes')
shutil.rmtree(work)
