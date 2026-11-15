# 内核编译指南

[English (condensed)](kernel.en.md) | **简体中文**

这是整个项目门槛最高的一步，也是最容易把手机变砖的一步。本文按实际流程走一遍，
每一步都说明「为什么」和「怎么判断做对了」。

> ## ⚠️ 动手前必读
>
> 编译内核有三种失败结局，代价差几十倍：
>
> | 结果 | 能否恢复 | 代价 |
> |---|---|---|
> | 开不了机，但能进 fastboot | 能 | 刷回备份，几分钟 |
> | 进不了 fastboot，只能 EDL / 9008 | 能 | 授权或拆机短接，**数据全失** |
> | **刷入低于 ARB 版本的内核或固件** | **不能** | **eFuse 已烧写，只能换主板** |
>
> **第 7 步之前必须先完成第 3 步（备份 boot）** —— 那是你唯一的退路。
>
> 另外：把编译好的 `boot.img` 发给别人会触发 **GPLv2 的源码提供义务**，
> 详见 [DISCLAIMER.md](../DISCLAIMER.md) 第 6 节。只发二进制不发源码是违规的。

**先说结论**：如果你能找到一个已经支持 Docker 的现成内核（XDA、酷安、GitHub 上搜
「机型 + kernel + docker」或「机型 + cgroup」），**用它，别自己编**。
自编内核的风险和耗时都不小，只有找不到现成的才值得动手。

---

## 第 0 步：确认你到底缺什么

不是所有机型都需要重编内核。先在现有系统上查：

```bash
su -c "zcat /proc/config.gz | grep -E 'CONFIG_(CGROUPS|NAMESPACES|VETH|OVERLAY_FS)='"
```

可能的结果：

| 情况 | 判断 | 下一步 |
|---|---|---|
| 四项都是 `=y` | 内核已经够用 | **不用编**，直接装本项目 |
| 有 `=m` | 编成了模块 | 通常也能用，试试再说 |
| 有 `is not set` 或缺失 | 真的缺 | 继续往下 |
| `/proc/config.gz` 不存在 | 没开 `CONFIG_IKCONFIG_PROC` | 无法自查，只能从源码 defconfig 判断 |

**如果四项都是 `=y`，别编了**，直接跳到 [README](../README.md) 的安装章节。
很多人以为自己需要编，其实不用。

---

## 第 1 步：找到匹配的内核源码

### 关键：版本必须对应

```bash
uname -r          # 例如 4.19.157-perf-g00f8d3a28662
```

- `4.19.157` 是主线版本
- `-perf` 是 Android 通用内核（ACK）的后缀
- `-g00f8d3a28662` 是厂商的 commit hash

**要用和你当前系统同大版本（4.19 / 5.4 / 5.10 / 5.15）的源码**。
4.19 的内核配置不能用在 5.10 上，结构完全不同。

### 各厂商的开源仓库

| 厂商 | 地址 | 说明 |
|---|---|---|
| 小米 / Redmi | `github.com/MiCode/Xiaomi_Kernel_OpenSource` | 按分支名找，如 `cmi-r-oss` 对应 Mi 10 Pro + Android 11 源码 |
| 一加 / OPPO | `github.com/OnePlusOSS` | 分支命名比较乱，按机型搜 |
| 三星 | `opensource.samsung.com` | 需要搜型号下载 tar 包 |
| Google Pixel | `github.com/aosp-mirror` 或 `source.android.com` | 最规范，直接 `repo` |

小米的分支命名规则：`<代号>-<Android 版本>-oss`。
代号怎么查：`getprop ro.product.device`（Mi 10 Pro 是 `cmi`）。

**注意**：厂商放出的源码通常是**发布时的版本**，可能比你现在系统里的内核旧。
只要你没改过内核，通常没问题；如果系统 OTA 过，最好找对应版本的 tag。

### 验证源码可用

```bash
cd kernel-source
ls arch/arm64/configs/ | grep -i <代号>     # 应该有 xxx_defconfig
cat Makefile | head -5                       # 确认版本号对得上
```

---

## 第 2 步：准备编译环境

### clang 版本很关键

Android 内核（4.19 及以后）用 **clang** 编译，不是 gcc。版本必须匹配：

| 内核版本 | 推荐 clang |
|---|---|
| 4.19 | clang 10 ~ 12（r353983c / r365631c）|
| 5.4 | clang 12 ~ 14 |
| 5.10+ | clang 14 ~ 17 |

**版本不对的典型报错**：

```
error: unknown argument: '-mno-fp-ret-in-387'
```

或者编到一半出现大量 `unrecognized command line option`。

### 推荐：在容器里编，别污染本机

```bash
# 用官方 AOSP 的预编译工具链镜像
docker run --rm -it -v $PWD:/kernel -w /kernel \
  ghcr.io/khronokernel/aosp-clang:latest \
  bash
```

或者在 WSL2 / Debian 里装 `clang-12` + `lld` + `llvm`：

```bash
apt install -y clang-12 lld-12 llvm-12 device-tree-compiler bc bison flex libssl-dev
```

### 检查工具链

```bash
clang --version        # 应该是 12.x
ld.lld --version
make --version         # 4.x 以上
```

---

## 第 3 步：备份原厂 boot.img（**最重要的一步**）

**这一步不做，后面任何一步出错都可能救不回来。**

### 方法 A：从设备直接读（推荐）

```bash
# 先确认分区名，不同机型不一样
su -c "ls /dev/block/by-name/ | grep -i boot"

# 常见结果：boot_a / boot_b（A/B 分区）或 boot（单分区）
su -c "dd if=/dev/block/by-name/boot_a of=/sdcard/boot-backup.img"
```

把 `/sdcard/boot-backup.img` 复制到电脑上存好，**并且再复制一份到别的地方**。

### 方法 B：从官方 ROM 包里提取

小米的 fastboot 包（`.tgz`）解开后有 `images/boot.img`。
注意要和**当前系统版本一致**，否则刷回去可能起不来。

### 验证备份可用

```bash
# 在电脑上
magiskboot unpack boot-backup.img    # 能解开说明文件完整
ls kernel ramdisk.cpio
```

---

## 第 4 步：配置内核

### 4.1 用原厂 defconfig 做基底

```bash
cd kernel-source
make ARCH=arm64 O=out vendor/<代号>_defconfig
```

`vendor/` 前缀表示厂商定制配置。如果找不到，试试：

```bash
ls arch/arm64/configs/ | grep <代号>
```

### 4.2 补开容器需要的选项

```bash
scripts/config --file out/.config \
  -e NAMESPACES -e NET_NS -e PID_NS -e IPC_NS -e UTS_NS \
  -e CGROUPS -e CGROUP_FREEZER -e CGROUP_PIDS -e CGROUP_DEVICE \
  -e MEMCG -e BLK_CGROUP -e CGROUP_CPUACCT \
  -e OVERLAY_FS -e VETH -e BRIDGE -e BRIDGE_NETFILTER \
  -e NETFILTER -e NF_CONNTRACK -e NF_NAT \
  -e IP_NF_FILTER -e IP_NF_NAT -e IP_NF_TARGET_MASQUERADE \
  -e IP_ADVANCED_ROUTER -e IP_MULTIPLE_TABLES \
  -e SECCOMP -e SECCOMP_FILTER \
  -e POSIX_MQUEUE -e IKCONFIG -e IKCONFIG_PROC
```

### 4.3 **必须验证选项真的生效**

`scripts/config` 改完，`make` 时还可能被厂商的 **fragment 文件**覆盖：

```bash
grep -E "CONFIG_(CGROUPS|NAMESPACES|VETH|OVERLAY_FS|IKCONFIG_PROC)=" out/.config
```

期望输出：

```
CONFIG_CGROUPS=y
CONFIG_NAMESPACES=y
CONFIG_VETH=y
CONFIG_OVERLAY_FS=y
CONFIG_IKCONFIG_PROC=y
```

**如果显示 `is not set`**，说明被覆盖了。检查：

```bash
# 厂商常在 arch/arm64/configs/vendor/ 下放 fragment
grep -rn "CGROUPS\|VETH" arch/arm64/configs/vendor/ 2>/dev/null
```

有的厂商用 `GENERIC_KERNEL_CONFIG` + `diffconfig` 机制，需要在 `build.config` 里加你的
fragment 路径。这种情况建议直接改 `arch/arm64/configs/vendor/<代号>_defconfig` 本身。

### 4.4 用 menuconfig（可选）

想看图形界面：

```bash
make ARCH=arm64 O=out menuconfig
```

但如果用交叉编译容器，需要 `ncurses` 支持，比较麻烦。**直接改 defconfig 更省事**。

---

## 第 5 步：编译

```bash
make ARCH=arm64 O=out \
  CC=clang \
  CLANG_TRIPLE=aarch64-linux-gnu- \
  CROSS_COMPILE=aarch64-linux-gnu- \
  LLVM=1 \
  LLVM_IAS=1 \
  -j$(nproc) \
  Image.gz-dtb
```

### 参数说明

| 参数 | 作用 |
|---|---|
| `O=out` | 输出到独立目录，不污染源码树 |
| `CC=clang` | 用 clang 而不是 gcc |
| `CLANG_TRIPLE` | clang 的目标三元组 |
| `CROSS_COMPILE` | binutils 前缀（用于汇编器等） |
| `LLVM=1` | 统一使用 LLVM 工具链（5.4+ 内核需要） |
| `LLVM_IAS=1` | 用 clang 内置汇编器 |
| `Image.gz-dtb` | 目标产物，多数高通机型需要这个 |

### 目标产物因机型而异

| 产物 | 适用 |
|---|---|
| `Image.gz-dtb` | 高通机型（内核 + 设备树打包在一起） |
| `Image` | 通用 arm64 |
| `Image.gz` | 压缩内核 |
| `Image.lz4` | 部分三星 |

不确定就先编 `Image.gz-dtb`，编完看 `out/arch/arm64/boot/` 下有什么。

### 常见报错

| 报错 | 原因 | 处理 |
|---|---|---|
| `clang: error: unknown argument` | clang 版本不匹配 | 换对应的 clang |
| `No rule to make target 'Image.gz-dtb'` | 该机型不用 dtb 打包 | 改 `Image` 或 `Image.gz` |
| `openssl/opensslv.h: No such file` | 缺开发库 | `apt install libssl-dev` |
| `dtc: command not found` | 缺设备树编译器 | `apt install device-tree-compiler` |
| `error: too many open files` | 文件描述符不够 | `ulimit -n 4096` |
| 编到 99% 报 `undefined reference` | 缺厂商闭源模块 | 检查是否需要额外的 prebuilt |

编译时间：8 核机器约 15-40 分钟，看配置大小。

### 关于闭源模块

有些机型的驱动是以 `.ko` 预编译形式提供的（`vendor/` 目录下），编译时需要
`CONFIG_XXX=m` 并且 `INSTALL_MOD_PATH` 指向正确位置。这类源码通常附带了
`build.sh`，**优先用它而不是手动 make**。

---

## 第 6 步：打包 boot.img

### 方案 A：magiskboot（保留 Magisk）

```bash
# 在电脑上
mkdir work && cd work
magiskboot unpack ../boot-backup.img      # 解出 kernel / ramdisk.cpio / dtb

# 用新编的内核替换
cp ../kernel-source/out/arch/arm64/boot/Image.gz-dtb ./kernel

# 重新打包
magiskboot repack ../boot-backup.img ../boot-new.img
```

**关键**：`magiskboot repack` 会自动把 Magisk 的补丁重新打上，
并且**保留原厂 ramdisk**。这是能不能保住 root 和正常开机的核心。

**不要**用 `unpack` 后手工改文件再 `cpio` 打包，很容易丢掉 Selinux label 和
`fstab` 的修改，导致开机失败。

### 方案 B：AnyKernel3（新手推荐）

[AnyKernel3](https://github.com/osm0sis/AnyKernel3) 是一个通用刷机包模板：
把新内核放进去，在 recovery 或 Magisk 里刷，它会自动从当前 boot 里提取 ramdisk
并替换内核。

好处：
- 不需要手动处理 boot.img
- 出问题可以直接刷原厂 boot 恢复
- 不用管机型的分区细节

流程：

```bash
git clone https://github.com/osm0sis/AnyKernel3
cd AnyKernel3
cp ../kernel-source/out/arch/arm64/boot/Image.gz-dtb ./
# 编辑 anykernel.sh，改 device.name1=<代号>
zip -r9 ../kernel-<代号>-docker.zip * -x .git/*
```

然后在 Magisk App → 模块 → 从本地安装，选这个 zip。

### 方案 C：厂商的 build 脚本

小米/一加的部分机型源码里带 `build.sh`，会调用 AOSP 的 `mkbootimg`。
用它最省事，但要注意它会重新生成 ramdisk，**可能覆盖 Magisk 的修改**。
刷之前先用 `magiskboot unpack` 检查生成的 boot 里有没有 Magisk 痕迹。

---

## 第 7 步：刷入

### ⚠️ 前提：boot 已经备份且验证过能解开

```bash
adb reboot bootloader
fastboot flash boot boot-new.img
fastboot reboot
```

A/B 分区的机型：

```bash
fastboot flash boot_a boot-new.img     # 当前槽位
fastboot --set-active=a                # 确保从 a 启动
```

### 如果开不了机

1. **别慌**，长按电源键 15 秒强制重启
2. 能进 fastboot 就刷回备份：
   ```bash
   fastboot flash boot boot-backup.img
   fastboot reboot
   ```
3. 进不了 fastboot，只能 EDL / 9008 模式（需要拆机短接或专用线）
4. 小米还有 MiAssistant / 9008 免拆模式，可以用官方工具救

**这就是为什么要备份**。

---

## 第 8 步：验证容器支持

开机后：

```bash
su -c "zcat /proc/config.gz | grep -E 'CONFIG_(CGROUPS|NAMESPACES|VETH|OVERLAY_FS)='"
```

四项都是 `=y` 就成了。然后：

```bash
su -c "getenforce"        # 应该是 Enforcing（正常系统状态）
su -c "sh install.sh"     # 装本项目
```

`install.sh` 会再检查一遍，缺什么会列出来。

---

## 机型差异速查

| 差异 | 影响 | 怎么处理 |
|---|---|---|
| **A/B 分区** | `boot` 分成 `boot_a` / `boot_b` | `fastboot flash boot_a`，注意当前槽位 `fastboot getvar current-slot` |
| **vbmeta / dm-verity** | 改动 boot 会触发校验失败 | 可能需要 `fastboot --disable-verity --disable-verification flash vbmeta vbmeta.img` |
| **anti-rollback** | 刷旧版本会变砖 | 小米/OPPO 有 ARB，**版本号不能降** |
| **动态分区** | `/system` 等是 super 分区的一部分 | 只动 boot 不受影响，但要改 system 就复杂了 |
| **闭源模块** | 驱动不在源码里 | 用厂商的 build 脚本，别手动 make |
| **cgroup v2** | Android 12+ 部分机型 | 本项目脚本按 v1 写，v2 需要改 `docker-cgroup.sh` |

### cgroup v1 还是 v2？

```bash
su -c "mount | grep cgroup"
```

- 多个 `/sys/fs/cgroup/<name>` 挂载点 → **v1**，本项目直接可用
- 只有 `/sys/fs/cgroup type cgroup2` → **v2**，需要改脚本

v2 的改法不在本文范围，思路是：不 bind 控制器，而是在 cgroup2 层级里建子树并用
`cgroup.subtree_control` 委派。可以参考 runc 在 cgroup v2 下的实现。

---

## 能不能不编内核

三条路：

1. **找现成的自定义内核** —— XDA、酷安、GitHub 搜「机型 + kernel + cgroup」。
   注意内核要和你的 ROM 版本匹配（尤其是 Android 大版本）。
2. **换一个支持容器的 ROM** —— 部分第三方 ROM（如 crDroid、LineageOS）的默认内核
   可能保留了 cgroup，值得先查一下。
3. **用 proot 方案** —— 不需要内核支持，但不是真容器：没有隔离、端口映射受限、
   有 syscall 拦截开销。只适合跑个别 CLI 工具，不适合跑服务。

本项目要的是**真容器**，所以绕不开内核。

---

## 附：一份完整的内核配置片段

如果你要自己写 fragment，可以直接抄：

```conf
# 命名空间
CONFIG_NAMESPACES=y
CONFIG_NET_NS=y
CONFIG_PID_NS=y
CONFIG_IPC_NS=y
CONFIG_UTS_NS=y
CONFIG_USER_NS=y

# cgroup v1
CONFIG_CGROUPS=y
CONFIG_CGROUP_FREEZER=y
CONFIG_CGROUP_PIDS=y
CONFIG_CGROUP_DEVICE=y
CONFIG_CGROUP_CPUACCT=y
CONFIG_CGROUP_SCHED=y
CONFIG_MEMCG=y
CONFIG_BLK_CGROUP=y

# 存储
CONFIG_OVERLAY_FS=y

# 网络
CONFIG_VETH=y
CONFIG_BRIDGE=y
CONFIG_BRIDGE_NETFILTER=y
CONFIG_NETFILTER=y
CONFIG_NF_CONNTRACK=y
CONFIG_NF_NAT=y
CONFIG_IP_NF_FILTER=y
CONFIG_IP_NF_NAT=y
CONFIG_IP_NF_TARGET_MASQUERADE=y
CONFIG_IP_NF_TARGET_REJECT=y

# 策略路由
CONFIG_IP_ADVANCED_ROUTER=y
CONFIG_IP_MULTIPLE_TABLES=y

# 安全
CONFIG_SECCOMP=y
CONFIG_SECCOMP_FILTER=y

# 其他
CONFIG_POSIX_MQUEUE=y
CONFIG_IKCONFIG=y
CONFIG_IKCONFIG_PROC=y
```

最后两行不是容器必需，但**强烈建议开**——有了它们才能用
`zcat /proc/config.gz` 自查配置，否则后面每次排查都得靠猜。
