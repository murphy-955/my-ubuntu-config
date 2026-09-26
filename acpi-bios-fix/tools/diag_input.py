#!/usr/bin/env python3
# 诊断 v3：动态重扫 evdev、事件级时间戳、2s 中断采样、停顿检测
# 只在测试启动（内核 cmdline 含 acpidiag）时运行，避免污染正常启动
import os, glob, time, select, threading, subprocess, traceback

OUT = os.path.expanduser('~/diag_report.txt')
DURATION = 300

def rf(p):
    try:
        with open(p) as f:
            return f.read()
    except Exception as e:
        return '<err %s>' % e

if 'acpidiag' not in rf('/proc/cmdline'):
    raise SystemExit(0)

t0 = time.monotonic()
stalls = []
events_ts = []   # (时刻, 设备名, 简述)
irq_snap = []    # (时刻, {irq: (count,label)})
gpe_snap = []    # (时刻, gpe0B原文, gpe_all原文)
stop = False

EV = {0: 'SYN', 1: 'KEY', 2: 'REL', 3: 'ABS', 4: 'MSC'}

def stall_watcher():
    while not stop:
        t1 = time.monotonic()
        time.sleep(0.1)
        t2 = time.monotonic()
        over = (t2 - t1 - 0.1) * 1000
        if over > 400:
            stalls.append((t2 - t0, over))

def evdev_watcher():
    import struct
    fds = {}
    while not stop:
        # 每秒重扫，处理设备重建
        for e in sorted(glob.glob('/dev/input/event*')):
            if e not in fds.values():
                try:
                    fd = os.open(e, os.O_RDONLY | os.O_NONBLOCK)
                    fds[fd] = e
                except Exception:
                    pass
        if not fds:
            time.sleep(1)
            continue
        try:
            r, _, _ = select.select(list(fds), [], [], 1)
        except Exception:
            continue
        dead = []
        for fd in r:
            try:
                data = os.read(fd, 65536)
            except OSError:
                dead.append(fd)
                continue
            off = 0
            while off + 24 <= len(data):
                sec, usec, etype, ecode, eval_ = struct.unpack_from('qqHHi', data, off)
                off += 24
                if etype == 0:
                    continue
                events_ts.append((time.monotonic() - t0, os.path.basename(fds[fd]),
                                  '%s code=%d val=%d' % (EV.get(etype, str(etype)), ecode, eval_)))
        for fd in dead:
            try:
                os.close(fd)
            except Exception:
                pass
            del fds[fd]

def parse_irq(txt):
    d = {}
    for line in txt.splitlines():
        if ':' not in line:
            continue
        irq, rest = line.split(':', 1)
        irq = irq.strip()
        if not irq.isdigit():
            continue
        toks = rest.split()
        nums = [int(x) for x in toks if x.isdigit()]
        label = ' '.join(toks[-2:]) if toks else ''
        d[irq] = (sum(nums), label)
    return d

def sampler():
    while not stop:
        irq_snap.append((time.monotonic() - t0, parse_irq(rf('/proc/interrupts'))))
        gpe_snap.append((time.monotonic() - t0,
                         rf('/sys/firmware/acpi/interrupts/gpe0B').strip().replace('\n', ' | '),
                         rf('/sys/firmware/acpi/interrupts/gpe_all').strip().replace('\n', ' | ')))
        time.sleep(2)

report = []
try:
    report.append('=== cmdline ===\n' + rf('/proc/cmdline'))

    ths = [threading.Thread(target=f) for f in (stall_watcher, evdev_watcher, sampler)]
    for t in ths:
        t.daemon = True
        t.start()
    time.sleep(DURATION)
    stop = True
    for t in ths:
        t.join(timeout=3)

    report.append('=== 停顿检测（>400ms）===\n' + (
        '\n'.join('T+%.1fs 停顿 %.0fms' % s for s in stalls[:300]) if stalls else '无停顿')
        + '\n停顿总数: %d' % len(stalls))

    report.append('=== 输入事件（非SYN，共%d条，显示前600条）===\n' % len(events_ts) + (
        '\n'.join('T+%.2fs %s %s' % e for e in events_ts[:600]) if events_ts else '【零事件】'))

    if len(irq_snap) >= 2:
        first, last = irq_snap[0][1], irq_snap[-1][1]
        lines = []
        for k in last:
            if k in first:
                d = last[k][0] - first[k][0]
                if d > 0:
                    lines.append('irq%s (%s): +%d' % (k, last[k][1], d))
        report.append('=== IRQ 全程增量 ===\n' + (
            '\n'.join(sorted(lines, key=lambda l: -int(l.rsplit('+', 1)[1]))) or '无'))

    # 关注 irq1 / 触摸板 / xhci 的时间序列
    def series(pred):
        out = []
        for ts, d in irq_snap[::15]:
            for k, (c, lb) in d.items():
                if pred(k, lb):
                    out.append('T+%.0fs irq%s(%s)=%d' % (ts, k, lb, c))
        return out
    report.append('=== 关键IRQ时间序列 ===\n' + '\n'.join(series(
        lambda k, lb: k == '1' or 'xhci' in lb or 'BLTP' in lb or 'AMDI0010' in lb)))

    report.append('=== GPE 采样（每30条取1）===\n' + '\n'.join(
        'T+%.0fs 0B:[%s] all:[%s]' % s for s in gpe_snap[::30]))

    report.append('=== loadavg ===\n' + rf('/proc/loadavg'))
    report.append('=== 进程CPU ===\n' + subprocess.run(
        ['ps', 'aux', '--sort=-%cpu'], capture_output=True, text=True).stdout[:2000])
    report.append('=== dmesg尾部 ===\n' + subprocess.run(
        ['journalctl', '-k', '-b', '--no-pager'], capture_output=True, text=True).stdout[-3000:])
except Exception:
    report.append('脚本异常:\n' + traceback.format_exc())

with open(OUT, 'w') as f:
    f.write('\n\n'.join(report))
