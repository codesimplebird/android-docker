# Kernel Build Guide (condensed)

> This is a condensed English version. The **full guide** — including vendor source
> repos, clang version matrix, fragment-override debugging, three packaging approaches,
> and unbricking — is in **[kernel.md](kernel.md)** (Chinese; machine translation
> works reasonably well on it).

**Read this first: if you can find a prebuilt kernel that already supports Docker
(XDA, Telegram groups, GitHub — search "`<device>` kernel cgroup"), use it.
Compiling your own is the highest-risk path in this project.**

> ## ⚠️ Before you start
>
> Kernel flashing has three failure modes with very different costs:
>
> | Outcome | Recoverable | Cost |
> |---|---|---|
> | Won't boot, fastboot works | Yes | Restore backup, minutes |
> | fastboot gone, only EDL / 9008 | Yes | Licence or disassembly, **all data lost** |
> | **Flashed below the ARB version** | **No** | **eFuse burned — motherboard replacement** |
>
> **Finish step 3 (back up your boot image) before step 7.** It's your only way back.
>
> Also: sharing the `boot.img` you build triggers **GPLv2 source obligations** —
> see [DISCLAIMER.en.md](../DISCLAIMER.en.md) section 6. Shipping the binary alone
> is a licence violation.

---

## Step 0: Find out whether you need to build at all

```bash
su -c "zcat /proc/config.gz | grep -E 'CONFIG_(CGROUPS|NAMESPACES|VETH|OVERLAY_FS)='"
```

| Result | Meaning | Next |
|---|---|---|
| all four `=y` | Kernel is already fine | **Don't build.** Install the project |
| some `=m` | Built as modules | Usually works, try it first |
| `is not set` or missing | Genuinely missing | Continue below |
| `/proc/config.gz` not found | `CONFIG_IKCONFIG_PROC` is off | Can't self-check; inspect the source defconfig |

**Plenty of people assume they need to compile and then discover they don't.**

---

## Step 1: Get matching kernel source

Check your running version:

```bash
uname -r     # e.g. 4.19.157-perf-g00f8d3a28662
```

- `4.19.157` — mainline version
- `-perf` — Android Common Kernel
- `-g00f8d3a` — vendor commit

You must use source of the **same major/minor line**. A 4.19 config will not work on 5.10.

Common sources:

| Vendor | Location |
|---|---|
| Xiaomi / Redmi | `github.com/MiCode/Xiaomi_Kernel_OpenSource` — branches like `cmi-r-oss` |
| OnePlus / OPPO | `github.com/OnePlusOSS` |
| Samsung | `opensource.samsung.com` |
| Pixel | `source.android.com` (most well-maintained) |

Xiaomi branch naming: `<codename>-<android-version>-oss`. Codename via
`getprop ro.product.device`.

Sanity check after cloning:

```bash
ls arch/arm64/configs/ | grep -i <codename>   # should show xxx_defconfig
head -5 Makefile                               # version must match
```

---

## Step 2: Toolchain

Android kernels (4.19+) build with **clang**, not gcc. Version matters:

| Kernel | clang |
|---|---|
| 4.19 | 10 – 12 |
| 5.4 | 12 – 14 |
| 5.10+ | 14 – 17 |

Wrong version gives errors like `error: unknown argument: '-mno-fp-ret-in-387'`.

Recommended: build inside a container so you don't pollute your host.

```bash
docker run --rm -it -v $PWD:/kernel -w /kernel \
  ghcr.io/khronokernel/aosp-clang:latest bash
```

Or on Debian/Ubuntu with clang-12:

```bash
apt install -y clang-12 lld-12 llvm-12 device-tree-compiler bc bison flex libssl-dev
```

---

## Step 3: Back up your stock boot image ⚠️

**Skip this and a single mistake may leave you with an unrecoverable device.**

```bash
# Find the partition name first — it differs per device
su -c "ls /dev/block/by-name/ | grep -i boot"

# Usually boot_a / boot_b (A/B) or boot (single)
su -c "dd if=/dev/block/by-name/boot_a of=/sdcard/boot-backup.img"
```

Copy it to your PC, and keep a second copy somewhere else.

Verify it's usable:

```bash
magiskboot unpack boot-backup.img    # must succeed
```

---

## Step 4: Configure

```bash
make ARCH=arm64 O=out vendor/<codename>_defconfig
```

Then enable what containers need:

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

**Verify the options actually stuck** — vendor fragment files can silently override them:

```bash
grep -E "CONFIG_(CGROUPS|NAMESPACES|VETH|OVERLAY_FS|IKCONFIG_PROC)=" out/.config
```

All should read `=y`. If any shows `is not set`, check
`arch/arm64/configs/vendor/` for fragments that turn it back off.

---

## Step 5: Build

```bash
make ARCH=arm64 O=out \
  CC=clang \
  CLANG_TRIPLE=aarch64-linux-gnu- \
  CROSS_COMPILE=aarch64-linux-gnu- \
  LLVM=1 LLVM_IAS=1 \
  -j$(nproc) \
  Image.gz-dtb
```

Target varies by SoC: `Image.gz-dtb` (Qualcomm), `Image`, `Image.gz`, occasionally
`Image.lz4`. Check `out/arch/arm64/boot/` after building.

Build time: 15–40 minutes on 8 cores.

---

## Step 6: Package boot.img

### Option A — magiskboot (keeps Magisk working)

```bash
mkdir work && cd work
magiskboot unpack ../boot-backup.img     # extracts kernel / ramdisk.cpio / dtb
cp ../kernel-source/out/arch/arm64/boot/Image.gz-dtb ./kernel
magiskboot repack ../boot-backup.img ../boot-new.img
```

`repack` re-applies Magisk's patches and **keeps the stock ramdisk**. Do **not**
manually rebuild the cpio — you'll lose SELinux labels and fstab edits.

### Option B — AnyKernel3 (easiest, safest)

[AnyKernel3](https://github.com/osm0sis/AnyKernel3) is a flashable template that pulls
the ramdisk from your current boot and swaps only the kernel.

```bash
git clone https://github.com/osm0sis/AnyKernel3
cd AnyKernel3
cp ../kernel-source/out/arch/arm64/boot/Image.gz-dtb ./
# edit anykernel.sh: device.name1=<codename>
zip -r9 ../kernel-<codename>.zip * -x .git/*
```

Flash the zip from Magisk's "install from storage".

---

## Step 7: Flash

```bash
adb reboot bootloader
fastboot flash boot ../boot-new.img
fastboot reboot
```

A/B devices: `fastboot flash boot_a ...` and check `fastboot getvar current-slot`.

### If it doesn't boot

1. Hold power 15s to force reboot
2. If fastboot is reachable: `fastboot flash boot boot-backup.img` and reboot
3. If not, you need EDL/9008 mode (may require opening the device)
4. Xiaomi has MiAssistant/9008 modes that can often recover without disassembly

**This is exactly why step 3 exists.**

---

## Step 8: Verify

```bash
su -c "zcat /proc/config.gz | grep -E 'CONFIG_(CGROUPS|NAMESPACES|VETH|OVERLAY_FS)='"
```

All `=y` → you're good. Then run `sh install.sh`.

---

## Can I skip kernel building?

Three options:

1. **Find a prebuilt kernel** with cgroup support — fastest path.
2. **Switch to a custom ROM** whose kernel keeps cgroups (LineageOS, crDroid sometimes do).
3. **Use proot** — no kernel requirements, but it's not real containerization.

This project needs real containers, so eventually you need a capable kernel.

---

## Full CONFIG fragment

```conf
CONFIG_NAMESPACES=y
CONFIG_NET_NS=y
CONFIG_PID_NS=y
CONFIG_IPC_NS=y
CONFIG_UTS_NS=y
CONFIG_USER_NS=y

CONFIG_CGROUPS=y
CONFIG_CGROUP_FREEZER=y
CONFIG_CGROUP_PIDS=y
CONFIG_CGROUP_DEVICE=y
CONFIG_CGROUP_CPUACCT=y
CONFIG_CGROUP_SCHED=y
CONFIG_MEMCG=y
CONFIG_BLK_CGROUP=y

CONFIG_OVERLAY_FS=y

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

CONFIG_IP_ADVANCED_ROUTER=y
CONFIG_IP_MULTIPLE_TABLES=y

CONFIG_SECCOMP=y
CONFIG_SECCOMP_FILTER=y

CONFIG_POSIX_MQUEUE=y
CONFIG_IKCONFIG=y
CONFIG_IKCONFIG_PROC=y
```

The last two aren't required by containers, but **enable them anyway** — they give you
`/proc/config.gz`, which turns every future debugging session from guesswork into a
one-line check.
