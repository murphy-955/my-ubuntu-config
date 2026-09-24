# 华硕 a豆14 Air 2026（M5451GA）ACPI 启动崩溃修复全记录

> 日期：2026-09-23/24
> 机型：ASUS Adol 14 M5451GA（Ryzen AI 9 H 465，Gorgon Point 平台）
> BIOS：M5451GA.314（2026-07-30，当时最新）
> 系统：Ubuntu 26.04，内核 7.0.0-34-generic / 主线 7.2.6-070206-generic

---

## 一、问题现象

1. 不加工内核参数无法启动：开机约 60-90 秒后屏幕卡住不动（实际是内核 panic）。
2. 只有加 `acpi=off` 才能进系统，但代价是：只剩 1 个 CPU 核心、自带键盘/触摸板失效、无电源管理。
3. 即便侥幸进入登录界面，也出现"画面定格、时钟不走、键鼠看似全部失灵"的假死现象。

## 二、根因（两个相互独立的 bug 叠加）

### Bug 1：BIOS 的 SSDT 第 22 号表（AMD AOD 表）导致内核 panic

- DSDT 主表在根作用域 `Scope (\)` 定义了两个**方法**：`Method (ASMI, 1)` 和 `Method (ISMI, 1)`（SMI 触发接口，IO 端口 0xB2）。
- 第 22 号 SSDT（OEM Table ID = `AOD`，AMD OverDrive 超频接口表）又在根作用域定义了**同名整数**：`Name (ASMI, 0xB2)` / `Name (ISMI, 0xB9)`。
- 内核加载该表时名称冲突（AE_ALREADY_EXISTS），导致表内 `OperationRegion (PSMI, SystemIO, ASMI, 0x02)` 的地址求值失败，该区域节点没有附着对象；紧接着创建 `Field (PSMI)` 时，ACPICA 的 `acpi_ex_prep_field_value()` 未做空指针检查，直接崩溃：

```
RIP: acpi_ex_prep_field_value+0x10f/0x5c0   CR2: 0xd（NULL+0xd 读取）
调用链: acpi_init → acpi_load_tables → acpi_ns_load_table → acpi_ds_create_field
      → acpi_ds_get_field_names → 💥
Kernel panic - not syncing: Attempted to kill init!
```

- 这是**华硕固件 bug**（表写得不对）+ **内核 ACPICA 缺容错**（未判空）双重问题，Windows/Linux 都会中招，与内核版本无关（7.0 和 7.2.6 同样崩）。

### Bug 2：AMD 显卡驱动的 PSR/Panel Replay 与这块新面板不兼容

- 画面停止刷新（时钟不走、打字无回显、登录界面加载不全），但**系统和输入其实在正常工作**——后台取证证实按键事件有送达、系统无中断风暴、无 CPU 停顿。
- 属于 AMD DC（Display Core）在 2026 新款高分高刷面板上的已知类问题，症状即"画面定格，切换终端/黑屏唤醒后恢复"。

## 三、排查过程（方法论）

### 1. 让 panic 现场可见

默认 `quiet splash` 会把崩溃信息藏起来。测试启动项加：

```
loglevel=7 ignore_loglevel earlycon=efifb keep_bootcon
```

效果：开机全程滚字，panic 调用栈得以拍照留存。**这是整个排查的关键第一步**——此前一直以为只是"卡死"。

### 2. 导出全部 ACPI 表

从 `/dev/mem` 按 RSDP 物理地址（本机 0x6fe7e014）导出 RSDT/XSDT/DSDT/全部 SSDT（见 `~/acpi_tables/`），用 `iasl -d` 反编译分析。

### 3. initrd 表覆盖 + 二分法定位坏表

原理：内核启动早期会从 initrd 的 early cpio 段（`kernel/firmware/acpi/` 目录）加载同签名 ACPI 表覆盖固件原表。

**两个关键坑：**

- 覆盖表的 **OEM 修订号必须严格大于原表**，否则内核跳过（`acpi_table_initrd_override`）。
- GRUB 测试条目名必须与实际生成的一致，否则静默回退默认项，测试结果失真。判断测试项是否真跑：看 `journalctl | grep "Table Upgrade: override"` 和 cmdline。

做法：把某张表替换为同 OEMID/OEMTID 的空表（等于禁用），二分 26 张 SSDT：

| 轮次 | 禁用的表 | 结果 | 结论 |
|---|---|---|---|
| 1 | 前 13 张 | 进桌面 | 坏表在前 13 张 |
| 3 | 19,20,21,22,25,26 | 进桌面 | 缩小到 6 张 |
| 4 | 19,20,21 | panic | 坏表在 {22,25,26} |
| 5 | 仅 22 | 进桌面 | **22 号表（AOD）实锤** |

配套技巧：`GRUB_DEFAULT=saved` + `grub-reboot '条目名'` 实现"下次启动进测试项、之后自动回正常系统"，避免人工选错。

### 4. 键鼠"失灵"取证（排除法）

写了后台诊断服务（`~/diag_input*.py`），在测试启动中采集：evdev 事件流、/proc/interrupts 增量、GPE 计数、100ms 级停顿检测。结论：

- 无 GPE/中断风暴、无系统级停顿、CPU 频率正常；
- USB 输入事件**有送达**（文本模式下实测按键/鼠标事件正常流动，日志里甚至有盲打触发的 PAM 认证记录）；
- 真正不工作的是**画面刷新** → 指向显示驱动而非输入栈。

### 5. 显示问题定位

`amdgpu.dcdebugmask=0x10`（关旧版 PSR）无效 → 判断新面板用的是 Panel Replay（PR）。最终 `0x414` 生效：

```
0x4   = DC_DISABLE_DSC    （显示流压缩）
0x10  = DC_DISABLE_PSR    （面板自刷新）
0x400 = DC_DISABLE_REPLAY （Panel Replay，PSR 的继任者）
```

## 四、最终修复方案

### 1. 修补 22 号表（而非禁用，保留 AMD OverDrive 功能）

源码修改（`~/acpi_fix/ssdt22_aod.dsl`，由反编译得来）：

```
DefinitionBlock ("", "SSDT", 2, "AMD", "AOD     ", 0x00000001→0x00000002)  # 修订号+1（覆盖的前提）
Name (ASMI, 0x00B2)  →  Name (ASMX, 0x00B2)
Name (ISMI, 0xB9)    →  Name (ISMX, 0xB9)
OperationRegion (PSMI, SystemIO, ASMI, 0x02)  →  (PSMI, SystemIO, ASMX, 0x02)
ASMO = ISMI  →  ASMO = ISMX
```

编译打包为 early cpio：

```bash
iasl -tc ssdt22_aod.dsl          # 生成 ssdt22_aod.aml
mkdir -p root/kernel/firmware/acpi
cp ssdt22_aod.aml root/kernel/firmware/acpi/
(cd root && find . | cpio -H newc -o --quiet) > ssdt22_aod_fix.cpio
sudo cp ssdt22_aod_fix.cpio /boot/acpi/
```

### 2. GRUB 永久化（`/etc/default/grub`）

```bash
# 删掉 acpi=off，加显示规避参数
GRUB_CMDLINE_LINUX_DEFAULT="quiet splash amdgpu.dcdebugmask=0x414"

# 每次启动自动用修补表覆盖坏表（对 grub.cfg 里所有内核条目生效，含未来新内核）
GRUB_EARLY_INITRD_LINUX_CUSTOM="acpi/ssdt22_aod_fix.cpio"

GRUB_TIMEOUT=3   # 留 3 秒菜单时间，按 ESC 可选旧内核兜底
```

然后 `sudo update-grub`。生成条目的 initrd 行会变成：

```
initrd  /boot/acpi/ssdt22_aod_fix.cpio /boot/initrd.img-<版本>
```

> 注意：本机 Ubuntu 26.04 用 **dracut** 生成 initrd，`/etc/initramfs-tools/hooks/` 方式无效，所以走 GRUB 的 early initrd 机制（GRUB 2.12+ 支持）。

### 3. 验证标准（全部通过）

- 默认启动项正常开机，无 `acpi=off`；
- `journalctl -b | grep "Table Upgrade"` 显示 `override [SSDT- AMD-AOD]`；
- `nproc` = 20；负载正常；
- 自带键盘、触摸板、USB 键鼠、屏幕刷新全部正常。

## 五、文件清单

| 文件 | 作用 |
|---|---|
| `/boot/acpi/ssdt22_aod_fix.cpio` | 修补版表（**勿删**，删了会回到 panic） |
| `/etc/default/grub` | 含 early initrd 与 dcdebugmask 配置 |
| `~/acpi_fix/ssdt22_aod.dsl/.aml` | 修补表源码（BIOS 更新后重建用） |
| `~/acpi_tables/` | 固件全部 ACPI 表导出件（分析存档） |
| `~/diag_input*.py`、`~/build_bisect.py` | 排查工具（已无用，可删） |

## 六、后续维护

- **如果华硕发布新 BIOS**：先用 `sudo python3 ~/acpi_tables/dump_acpi.py`（或按 RSDP 新地址）重新导出 22 号表，检查 `ASMI/ISMI` 冲突是否修复。若已修复，可删除 `/etc/default/grub` 中的 `GRUB_EARLY_INITRD_LINUX_CUSTOM` 行并 `sudo update-grub` 撤掉补丁。
- **内核升级无需任何操作**：GRUB 机制自动对所有内核条目生效。
- 当前默认内核为主线 7.2.6（不随 Ubuntu 自动更新）；Ubuntu 官方内核条目同样带修复，可随时在 GRUB 菜单切换。
- **建议向华硕反馈此固件 bug**（AOD 表与 DSDT 的 ASMI/ISMI 命名冲突），推动 BIOS 层面根治。
