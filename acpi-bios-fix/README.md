# ACPI/BIOS 修复（华硕 a豆14 Air 2026 · M5451GA）

这台机器的 BIOS（314 版）有两个硬件层面的兼容问题，全新安装 Ubuntu 后**必须**按本指引修复，否则无法正常开机/使用。完整的故障分析和排查过程见仓库根目录的 `../BIOS_ACPI修复全过程.md`。

## 问题一句话概括

1. BIOS 的 SSDT "AOD" 表（AMD OverDrive）里 `ASMI`/`ISMI` 与 DSDT 主表同名冲突 → 内核启动初期 panic，**不加 `acpi=off` 无法开机**。
2. AMD 核显的 PSR/Panel Replay 省电特性与自带屏幕不兼容 → **画面定格假死**（系统其实活着，只是屏幕不刷新）。

## 全新装机步骤

### 1. 安装系统时绕过 panic

BIOS 里关闭 Secure Boot。从 Ubuntu 安装 U 盘启动时：

- 在 GRUB 菜单按 `e` 编辑启动项，在 `linux` 行末尾**加一个空格和 `acpi=off`**，按 `F10` 启动；
- 安装完成后**第一次开机也要同样操作一次**（按 `e` 加 `acpi=off`）。

> 没有这一步，安装程序和首次启动都会在约 1 分钟后崩溃。`acpi=off` 下只有 1 个 CPU 核、自带键盘触摸板不可用，属正常现象，忍过这一阶段即可。

### 2. 进系统后一键修复

```bash
cd my-ubuntu-config/acpi-bios-fix
sudo bash install.sh
sudo reboot
```

脚本会：安装修补版 ACPI 表到 `/boot/acpi/` → 修改 `/etc/default/grub`（自动备份原文件）→ `update-grub`。之后每次开机（含未来所有内核更新）都会自动生效，**无需再做任何操作**。

### 3. 重启后验证

```bash
cat /proc/cmdline                        # 不应再有 acpi=off
journalctl -b | grep "Table Upgrade"     # 应显示 override [SSDT- AMD-AOD]
nproc                                    # 应为 20（而不是 1）
```

自带键盘、触摸板、屏幕刷新应全部正常。

## 目录内容

| 文件 | 说明 |
|---|---|
| `install.sh` | 一键应用修复（幂等，可重复运行） |
| `ssdt22_aod_fix.cpio` | 修补版 SSDT 表（GRUB early initrd 用，**核心文件**） |
| `ssdt22_aod.dsl` | 修补表源码（BIOS 更新后需重建时改它，用 `iasl -tc` 编译） |
| `tools/dump_acpi.py` | 导出本机全部 ACPI 表并反编译（需 `sudo` 和 `sudo apt install acpica-tools`） |
| `tools/build_bisect.py` | 生成"禁用指定 SSDT"的测试 cpio，用于二分定位坏表 |
| `tools/diag_input.py` | 输入/中断/停顿诊断：开机 cmdline 加 `acpidiag`，以 systemd 服务运行 5 分钟，结果写入 `~/diag_report.txt` |

## 如果修复后官方内核仍有异常（可选）

本次修复验证时使用的是主线内核 7.2.6。若 Ubuntu 官方内核出现画面异常，可安装更新的主线内核：

1. 打开 https://kernel.ubuntu.com/mainline/ 选择最新稳定版目录；
2. 下载 amd64 的 4 个 deb（`linux-headers-*_all`、`linux-headers-*-generic`、`linux-image-unsigned-*-generic`、`linux-modules-*-generic`）和 CHECKSUMS；
3. `sudo dpkg -i *.deb` 后在 GRUB 菜单选择新内核启动。

GRUB 的表覆盖与显示参数对所有内核条目自动生效，换内核不用重新配置。

## 撤销修复

```bash
sudo rm /boot/acpi/ssdt22_aod_fix.cpio
# 编辑 /etc/default/grub：删除 GRUB_EARLY_INITRD_LINUX_CUSTOM 行、
# 把 GRUB_CMDLINE_LINUX_DEFAULT 里的 amdgpu.dcdebugmask=0x414 删掉
sudo update-grub
```

## 华硕发布新 BIOS 后

1. 升级 BIOS，先别删修复，正常开机；
2. `sudo python3 tools/dump_acpi.py /tmp/acpi_new` 导出新表；
3. 检查新 AOD 表：`grep -E 'ASMI|ISMI' /tmp/acpi_new/*AOD*.dsl`——若冲突已修复，可按上一节撤销补丁；若仍在，保留现状即可（补丁兼容）。
