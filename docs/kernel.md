# 内核要求

## 为什么原厂内核大多不行

Android 厂商为了省电和简化，在 defconfig 里关掉了不少容器需要的选项。最常见的缺失：

- `CONFIG_CGROUPS` —— 很多机型只留 `CONFIG_CGROUP_SCHED`（给 CPU 调度用），完整 cgroup 被关
- `CONFIG_VETH` —— 虚拟网卡对，容器网络的基石
- `CONFIG_OVERLAY_FS` —— Docker 默认存储驱动

只要缺一个，dockerd 在初始化阶段就会退出，日志里能看出是哪一步。

## 必须开启的选项

```conf
# 命名空间（容器隔离的基础）
CONFIG_NAMESPACES=y
CONFIG_NET_NS=y
CONFIG_PID_NS=y
CONFIG_IPC_NS=y
CONFIG_UTS_NS=y
CONFIG_USER_NS=y

# cgroup v1（Android 13 及以下基本都是 v1）
CONFIG_CGROUPS=y
CONFIG_CGROUP_FREEZER=y
CONFIG_CGROUP_PIDS=y
CONFIG_CGROUP_DEVICE=y
CONFIG_CGROUP_CPUACCT=y
CONFIG_CGROUP_SCHED=y
CONFIG_MEMCG=y
CONFIG_BLK_CGROUP=y

# 联合文件系统（Docker 的层）
CONFIG_OVERLAY_FS=y

# 虚拟网络
CONFIG_VETH=y
CONFIG_BRIDGE=y
CONFIG_BRIDGE_NETFILTER=y

# 防火墙与 NAT
CONFIG_NETFILTER=y
CONFIG_NF_CONNTRACK=y
CONFIG_NF_NAT=y
CONFIG_IP_NF_FILTER=y
CONFIG_IP_NF_NAT=y
CONFIG_IP_NF_TARGET_MASQUERADE=y
CONFIG_IP_NF_TARGET_REJECT=y

# 策略路由（本项目依赖 ip rule 导流）
CONFIG_IP_ADVANCED_ROUTER=y
CONFIG_IP_MULTIPLE_TABLES=y

# seccomp（Docker 默认安全配置）
CONFIG_SECCOMP=y
CONFIG_SECCOMP_FILTER=y

# 其他常被漏掉的
CONFIG_POSIX_MQUEUE=y
```

## 验证

刷入新内核后：

```bash
su -c "zcat /proc/config.gz | grep -E 'CONFIG_(CGROUPS|VETH|OVERLAY_FS|NAMESPACES)'"
```

如果 `/proc/config.gz` 不存在，说明没开 `CONFIG_IKCONFIG_PROC`，加上：

```conf
CONFIG_IKCONFIG=y
CONFIG_IKCONFIG_PROC=y
```

这条本身很值得开——不用它就只能靠猜。

## Android 13 / 14 的 cgroup v2 问题

Android 12 起，部分机型开始用 **cgroup v2**（统一层级，挂载在 `/sys/fs/cgroup` 单一挂载点）。
本项目的 `docker-cgroup.sh` 是按 **v1**（多个独立层级）写的。

判断你的是哪种：

```bash
su -c "mount | grep cgroup"
```

- 看到 `/sys/fs/cgroup/memory`、`/sys/fs/cgroup/cpu` 等多个挂载点 → **v1**，本项目直接可用
- 只看到 `/sys/fs/cgroup type cgroup2` → **v2**，需要改 `docker-cgroup.sh`

v2 下的思路不同：不需要逐个 bind 控制器，但需要在 cgroup2 层级里给 Docker 建子树，并且注意 `cgroup.subtree_control` 的委派规则。这块本项目暂未覆盖。

## 编译简要流程

以小米 10 Pro（cmi，骁龙 865，4.19 内核）为例：

```bash
# 1. 拉源码（厂商开源的内核树）
git clone --depth=1 https://github.com/MiCode/Xiaomi_Kernel_OpenSource -b cmi-r-oss

# 2. 用原厂 defconfig 做基底
make ARCH=arm64 O=out vendor/cmi-perf_defconfig

# 3. 补开容器需要的选项
scripts/config --file out/.config \
  -e CGROUPS -e CGROUP_FREEZER -e CGROUP_PIDS -e CGROUP_DEVICE \
  -e MEMCG -e BLK_CGROUP -e OVERLAY_FS -e VETH -e BRIDGE \
  -e NETFILTER -e NF_NAT -e IP_NF_NAT -e IP_NF_FILTER \
  -e IP_ADVANCED_ROUTER -e IP_MULTIPLE_TABLES -e SECCOMP_FILTER

# 4. 编译
make ARCH=arm64 O=out CC=clang LLVM=1 -j$(nproc)

# 5. 打包 boot.img（需要原厂 boot 做基底，替换 kernel）
```

**注意**：只换 kernel、保留原厂 ramdisk，否则 Magisk 会失效。打包工具用 `magiskboot unpack/repack` 最稳。

## 常见坑

| 现象 | 原因 | 处理 |
|---|---|---|
| 刷完开不了机 | defconfig 缺关键驱动 | 回原厂 boot，用 `--file` 逐个补 |
| 能开机但 WiFi 没了 | 少编译了 WiFi 模块 | 确认 `CONFIG_WLAN` 和厂商驱动 |
| dockerd 报 `operation not permitted` | SELinux enforcing | `setenforce 0` 或写 sepolicy |
| 容器起不来，日志提 cpuset | Android 的 noprefix 挂载 | 本项目已处理（`dockerd-ns.sh`） |
| 内存一紧容器就死 | lmkd 杀了 containerd | 把 containerd 加进 lmkd 白名单，或减小容器内存 |

## 不想编内核怎么办

有两条路：

1. **找现成的自定义内核**——XDA / 酷安上常有"支持 Docker"的内核，注意版本要和你的 ROM 匹配
2. **用 proot 方案**——不需要内核支持，但不是真容器（无隔离、端口映射受限、有性能损耗）。适合只跑个别 CLI 工具，不适合跑服务

本项目要的是**真容器**，所以绕不开内核。
