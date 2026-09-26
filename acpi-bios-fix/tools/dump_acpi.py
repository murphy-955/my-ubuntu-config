#!/usr/bin/env python3
# 导出本机全部 ACPI 表（含 DSDT 和全部 SSDT），并反编译为 .dsl
# 用法: sudo python3 dump_acpi.py [输出目录]
# 优先从 /sys/firmware/acpi/tables 读取；当系统以 acpi=off 启动时，
# 回退到 /dev/mem 物理内存方式（RSDP 地址从 /sys/firmware/efi/systab 获取）。
import struct, os, subprocess, sys

OUT = sys.argv[1] if len(sys.argv) > 1 else os.path.abspath('acpi_tables')
os.makedirs(OUT, exist_ok=True)

def dump_from_sysfs():
    src = '/sys/firmware/acpi/tables'
    if not os.path.isdir(src):
        return False
    n = 0
    for f in sorted(os.listdir(src)):
        p = os.path.join(src, f)
        if not os.path.isfile(p):
            continue
        data = open(p, 'rb').read()
        if len(data) < 36:
            continue
        oemid = data[10:16].decode('latin1', 'replace').strip().replace(' ', '_')
        out = os.path.join(OUT, f'{n:02d}_{f}_{oemid}.aml')
        open(out, 'wb').write(data)
        n += 1
    print(f'从 sysfs 导出 {n} 张表')
    return n > 0

def rd_mem(addr, n):
    with open('/dev/mem', 'rb') as f:
        f.seek(addr)
        return f.read(n)

def find_rsdp():
    # EFI systab 里找 ACPI 2.0 表地址
    try:
        for line in open('/sys/firmware/efi/systab'):
            if line.startswith('ACPI20='):
                return int(line.strip().split('=')[1], 16)
    except FileNotFoundError:
        pass
    raise SystemExit('找不到 RSDP 地址（非 EFI 系统？）；也可手动指定物理地址修改本脚本')

def dump_from_mem():
    rsdp_addr = find_rsdp()
    print(f'RSDP @ {rsdp_addr:#x}')
    rsdp = rd_mem(rsdp_addr, 36)
    assert rsdp[:8] == b'RSD PTR ', 'RSDP 签名不匹配'
    xsdt_addr = struct.unpack('<Q', rsdp[24:32])[0]
    hdr = rd_mem(xsdt_addr, 36)
    length = struct.unpack('<I', hdr[4:8])[0]
    data = rd_mem(xsdt_addr, length)
    n = (length - 36) // 8
    entries = [struct.unpack('<Q', data[36+i*8:44+i*8])[0] for i in range(n)]

    fadt_addr = None
    count = 0
    for idx, addr in enumerate(entries):
        h = rd_mem(addr, 36)
        sig = h[:4].decode('latin1').strip()
        tlen = struct.unpack('<I', h[4:8])[0]
        if sig == 'FACP':
            fadt_addr = addr
        if tlen == 0 or tlen > 16*1024*1024:
            continue
        body = rd_mem(addr, tlen)
        oemid = ''.join(c if 32 <= ord(c) < 127 else '_' for c in h[10:16].decode('latin1')).strip()
        fn = os.path.join(OUT, f'{idx:02d}_{sig}_{oemid}.aml')
        open(fn, 'wb').write(body)
        count += 1

    if fadt_addr:
        fadt = rd_mem(fadt_addr, struct.unpack('<I', rd_mem(fadt_addr, 8)[4:8])[0])
        dsdt_addr = struct.unpack('<Q', fadt[140:148])[0]
        h = rd_mem(dsdt_addr, 36)
        tlen = struct.unpack('<I', h[4:8])[0]
        open(os.path.join(OUT, 'DSDT.aml'), 'wb').write(rd_mem(dsdt_addr, tlen))
        print('DSDT len:', hex(tlen))
    print(f'从 /dev/mem 导出 {count} 张表')

if not dump_from_sysfs():
    dump_from_mem()

# 反编译（需要 iasl: sudo apt install acpica-tools）
for f in sorted(os.listdir(OUT)):
    if f.endswith('.aml'):
        r = subprocess.run(['iasl', '-d', os.path.join(OUT, f)],
                           capture_output=True, cwd=OUT)
        if r.returncode != 0:
            print(f'反编译失败（可忽略）: {f}')
print('完成，文件在', OUT)
