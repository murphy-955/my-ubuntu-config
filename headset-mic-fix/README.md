# 有线耳机麦克风修复（华硕 a豆14 Air 2026 · M5451GA · Realtek ALC235）

这台机器全新安装 Ubuntu 后，**3.5mm 有线耳机的麦克风完全收不到声音**（耳机出声正常，系统也能"检测到"麦克风插入，但录音一直是纯静音）。按本目录的 `install.sh` 一键修复即可。

## 问题一句话概括

声卡是 Realtek **ALC235**（PCI 子系统 `1043:1814`）。Linux 内核 `patch_realtek.c` 中的耳麦制式检测函数 `alc_determine_headset_type()` **漏掉了 `0x10ec0235` 这个型号**（同族的 0255/0233/0236 等都有，唯独没有 0235），导致：

1. 耳麦二合一插孔插入后，驱动从不执行 CTIA/OMTP 制式切换；
2. 麦克风信号一直被接在插孔错误的触点上 → 偏置电压正常、插孔检测正常、录音链路全通，但**收到的永远是静音**。

这与耳机无关（同一耳机在手机上完全正常）。

## 全新装机步骤

```bash
cd my-ubuntu-config/headset-mic-fix
sudo bash install.sh
```

脚本会：

1. 安装 `alsa-tools`（提供 `hda-verb`）；
2. 写入 `/etc/modprobe.d/hda-model.conf`（`options snd-hda-intel model=alc233-asus`，把 0x19 针脚声明为耳麦麦克风）；
3. 安装 `/usr/local/bin/alc235-force-ctia.sh`（强制写 CTIA 寄存器）+ 开机 systemd 服务 + 睡眠唤醒钩子；
4. 热重载声卡模块并立即应用 CTIA 设置（若热重载失败则重启后生效）。

## 修复后验证

插上耳机，任选其一：

```bash
# 方法1：录音 10 秒看电平（说话时峰值应达到几千以上）
arecord -D plughw:1,0 -f S16_LE -r 48000 -c 1 -d 10 /tmp/t.wav
python3 -c "
import wave, array
a = array.array('h', wave.open('/tmp/t.wav','rb').readframes(480000))
print('峰值:', max(abs(x) for x in a))"

# 方法2：系统设置 → 声音 → 输入，对着麦克风说话看电平条
```

如果音量太小/爆音，用 `alsamixer -c 1` 调 `Mic Boost`（0~3 档，每档 10dB）和 `Capture`。

## 日常使用注意事项

- 修复由开机服务和睡眠唤醒钩子自动维持，**重启、合盖休眠后均无需手动操作**；
- 若某次插拔后麦克风突然又没声（极少数情况），手动执行一次：`sudo /usr/local/bin/alc235-force-ctia.sh`；
- 此配置下插着耳机时内置麦克风不可用（耳麦自动切换，属正常现象）；
- **升级内核后**如果麦克风失效，先检查 `/etc/modprobe.d/hda-model.conf` 仍在；若上游内核已修复 ALC235 检测，可删除该文件和本服务，用原生支持：
  ```bash
  sudo rm /etc/modprobe.d/hda-model.conf
  sudo systemctl disable alc235-ctia.service
  sudo rm /usr/local/bin/alc235-force-ctia.sh /etc/systemd/system/alc235-ctia.service /usr/lib/systemd/system-sleep/alc235-ctia-resume
  ```

## 排查过程记录（2026-09-26）

完整的推理链，供理解原理：

1. **定位声卡**：`arecord -l` 显示 ALC233 采集设备存在；`lspci`/`/proc/asound/cards` 确认为 AMD Ryzen 平台 + Realtek 编解码器（实际芯片 ID `0x10ec0235` = ALC235，ALSA 显示名 ALC233）。
2. **排除软件层**：PipeWire/WirePlumber 正常运行；`arecord` 直连硬件（绕过 PipeWire）录音依然静音 → 问题在驱动/硬件层。
3. **插孔检测**：`amixer -c 1 cget numid=16`（Mic Jack）初始为 `off`，重新插拔后变 `on` → 检测电路正常。codec dump（`/proc/asound/card1/codec#0`）显示 0x21(HP) 与 0x19(Mic) 同在 "Ext Right"，是耳麦二合一插孔。
4. **信号链验证**：录音混音器 0x23 中 0x19 输入已打开、0x19 已加 VREF_80 偏置电压、Mic Boost 拉满 30dB，录音仍是 ~70 的噪音底 → 通道全通但麦克风信号没进芯片。
5. **排除耳机**：同一耳机在手机上通话/录音正常 → 排除 OMTP 制式和耳机损坏。
6. **试 model 参数**：`dell-headset-multi`、`headset-mode`、`headset-mic`、`alc233-asus` 均无效 → 说明不是针脚布局问题。
7. **读内核源码定位根因**：`patch_realtek.c` 中 `alc_determine_headset_type()`、`alc_headset_mode_ctia()`、`alc_headset_mode_omtp()` 的 switch 语句都没有 `case 0x10ec0235` → **制式切换逻辑对该芯片从未执行**。
8. **修复**：用 `hda-verb` 直接写 ALC255 家族通用的 CTIA 寄存器（`COEF 0x45=0xd489`、`0x1b=0x0c2b`），麦克风立刻收到清晰信号。

**上游修复方向**：在内核 `sound/pci/hda/patch_realtek.c` 的上述三个函数中为 `0x10ec0235` 补上 case（复用 `0x10ec0255` 的处理即可），并为该机型（`1043:1814`）添加 quirk 条目。
