# Android Docker

[English](README.en.md) | **简体中文**

在 root 过的 Android 手机上运行**真正的 Docker**——不是 proot 模拟、不是用户态假容器，是能跑标准镜像、能用 `docker compose`、能映射端口、容器能正常上网的那一套。

> 唯一硬性前提：**内核要支持 namespace 和 cgroup**。很多机型的原厂内核阉割了这些选项，需要自编译。

---

> ## ⚠️ 使用前必读
>
> 本项目需要**解锁 Bootloader**、**刷入自定义内核**、**关闭 SELinux（`setenforce 0`）**，并以 root 身份运行容器。
>
> 这意味着你将要面对：**设备变砖、数据全部清空、保修失效，以及 SELinux 关闭后显著上升的安全风险**。
>
> 请**只在专用测试机 / 备用机**上使用，不要在存放重要账号和数据的日常机上折腾。
>
> 完整条款见 **[DISCLAIMER.md](DISCLAIMER.md)**。**继续使用即表示你已阅读并接受全部风险。**

---

## 它解决什么问题

Android 内核其实完整具备容器所需的一切能力（namespace、cgroup v1、veth、overlayfs）。
但原厂系统把这些能力"改造"得和标准 Linux 不一致，直接跑 dockerd 会连环失败。

本项目把 5 个关键差异逐一对齐：

| # | 差异点 | Android 的实际行为 | 标准 Linux | 本项目的处理 |
|---|---|---|---|---|
| 1 | **cgroup 位置** | 控制器散落在 `/dev/memcg`、`/dev/cpuctl`、`/dev/cpuset` | 统一在 `/sys/fs/cgroup/<name>` | `docker-cgroup.sh` 逐个 bind 到标准位置 |
| 2 | **cpuset 文件名** | `cpus` / `mems`（noprefix 挂载） | `cpuset.cpus` / `cpuset.mems` | `dockerd-ns.sh` 在私有 namespace 里卸载 cpuset，让 runc 直接跳过 |
| 3 | **根文件系统** | `/` 只读，**没有 `/run`** | 可写，有 `/run` | chroot 到 `/data/docker/rootfs` |
| 4 | **iptables** | chroot 里没有 iptables 二进制 | dockerd 自己管理 NAT | `--iptables=false`，宿主机脚本手工维护 |
| 5 | **ip rule** | 没有 `lookup main`，末尾是 `32000: from all unreachable` | 有 main 表兜底 | 加 `9000/9001` 规则把 Docker 网段导回 main |

此外还有两个隐藏坑：

- **`tetherctrl_FORWARD` 末尾有无条件 DROP**（不开热点时链里只有这一条），所有转发包都会撞上。必须在 `FORWARD` 最前面抢先 ACCEPT。
- **默认网关会随网络切换而变**，netd 重写自己的路由表时会把我们补的规则冲掉。所以有一个 30 秒轮询的看门狗。

## 已验证设备

| 设备 | 代号 | SoC | 系统 | 内核 | 状态 |
|---|---|---|---|---|---|
| Xiaomi Mi 10 Pro | `cmi` | Snapdragon 865 | HyperOS 1.0 / Android 13 | 4.19.157-perf（自编译，2026-11-11） | **完整可用** |

测试环境：

```
架构      aarch64
Root      Magisk 28.1
Docker    24.0.9（静态二进制）
SELinux   Permissive
内核配置  CONFIG_NAMESPACES / CGROUPS / VETH / BRIDGE /
          OVERLAY_FS / NETFILTER / IP_NF_NAT / IP_NF_FILTER /
          IP_ADVANCED_ROUTER / SECCOMP  —— 全部 =y

实测通过  docker run hello-world              OK
          nginx:alpine + volume + :8090       OK（局域网可访问）
          docker compose up -d                OK
          容器出站网络                         OK
          网关切换（WiFi 漫游）                 OK（看门狗自动重设规则）
```

> 在别的机型上跑通了？欢迎开 issue 说明型号、内核版本和
> `zcat /proc/config.gz | grep CGROUP` 的结果。
> **原厂内核能跑通尤其有价值**——说明厂商没有阉割 cgroup。

## 前置条件

### 1. root

Magisk 即可（本项目用 `su -c` 执行，不依赖特定 root 方案）。

### 2. 内核配置

以下选项**缺一不可**，检查：

```bash
su -c "zcat /proc/config.gz | grep -E 'CONFIG_(NAMESPACES|CGROUPS|OVERLAY_FS|VETH|BRIDGE|NETFILTER)'"
```

```
CONFIG_NAMESPACES=y
CONFIG_CGROUPS=y
CONFIG_CGROUP_FREEZER=y
CONFIG_OVERLAY_FS=y
CONFIG_VETH=y
CONFIG_BRIDGE=y
CONFIG_NETFILTER=y
CONFIG_IP_NF_NAT=y
CONFIG_IP_NF_FILTER=y
CONFIG_IP_ADVANCED_ROUTER=y
CONFIG_SECCOMP=y
```

原厂内核通常至少缺 `CONFIG_CGROUPS` 或 `CONFIG_VETH`。需要自己编译内核（见 [docs/kernel.md](docs/kernel.md)）。

> `/proc/config.gz` 不存在的话，说明内核没开 `CONFIG_IKCONFIG_PROC`，只能从源码 defconfig 里查。

### 3. 架构

脚本按 **aarch64** 写的。armv7 / x86_64 需要换 Docker 二进制，脚本本身通用。

### 4. 资源

- 内存 ≥ 2GB（dockerd + containerd 常驻约 120MB，跑容器另算）
- 存储 ≥ 4GB（rootfs 1.5GB + Docker 二进制 171MB + 镜像）
- 建议关闭 Android 的激进内存回收（lmkd 可能杀掉 containerd）

## 安装

### 一键安装（推荐）

把仓库整个 push 到手机（或者 clone 下来），在仓库目录执行：

```bash
su -c "sh install.sh"
```

脚本会依次：检查 root 和内核 → 下载 Debian rootfs → 下载 Docker 静态二进制 → 部署脚本 → 装 compose 插件 → 启动并跑 hello-world 验证。

**可选参数**（放在命令前面）：

```bash
# Docker 走官方源（默认阿里云）
su -c "MIRROR=official sh install.sh"

# rootfs 和 compose 走 GitHub 代理
su -c "MIRROR=ghproxy sh install.sh"

# 跳过 compose 插件
su -c "SKIP_COMPOSE=1 sh install.sh"

# 换安装目录
su -c "DOCKER_ROOT=/data/dk sh install.sh"
```

脚本是幂等的，下载过的部分会跳过，可以重复执行。

传文件到手机的方式：`adb push . /data/local/tmp/android-docker && adb shell "su -c 'cd /data/local/tmp/android-docker && sh install.sh'"`

### 手动安装

#### 1. 准备 rootfs

Docker 需要一个可写的 Linux 根，Android 的 `/` 不行（只读且没有 `/run`）。
用 Debian minirootfs：

```bash
su -c "mkdir -p /data/docker/rootfs"
su -c "cd /data/docker/rootfs && curl -LO https://github.com/debuerreotype/docker-debian-artifacts/raw/dist-arm64v8/bookworm/rootfs.tar.xz && tar -xJf rootfs.tar.xz && rm rootfs.tar.xz"
```

> 国内访问 GitHub 慢，可以换清华镜像或代理。

#### 2. 准备 Docker 静态二进制

```bash
su -c "mkdir -p /data/docker/bin /data/docker/lib"
su -c "cd /tmp && curl -LO https://download.docker.com/linux/static/stable/aarch64/docker-24.0.9.tgz && tar -xzf docker-24.0.9.tgz && cp docker/* /data/docker/bin/ && rm -rf docker docker-24.0.9.tgz"
```

需要 `dockerd`、`containerd`、`containerd-shim-runc-v2`、`runc`、`docker`、`docker-proxy`、`docker-init`、`ctr`。

#### 3. 部署脚本

```bash
su -c "cp start.sh dockerd-ns.sh docker-cgroup.sh docker-mounts.sh docker-net.sh docker-net-watch.sh dc docker /data/docker/"
su -c "mkdir -p /data/docker/etc && cp daemon.json /data/docker/etc/"
su -c "chmod +x /data/docker/*.sh /data/docker/dc /data/docker/docker"
```

#### 4. 启动

```bash
su -c "/data/docker/start.sh"
```

看到 `dockerd 已就绪` 就成了。验证：

```bash
su -c "/data/docker/docker run --rm hello-world"
```

#### 5. 开机自启（可选）

```bash
su -c "cat > /data/adb/service.d/docker.sh << 'EOF'
#!/system/bin/sh
until [ \".\$(getprop sys.boot_completed)\" = \".1\" ]; do sleep 5; done
sleep 60
sh /data/docker/start.sh > /data/docker/autostart.log 2>&1
EOF
su -c "chmod 755 /data/adb/service.d/docker.sh"
```

**注意 `sleep 60`**：Magisk 的 `service.d` 脚本和系统模块并行执行，太早启动会和其它模块（如充电控制、性能调度）抢资源导致它们初始化失败。等系统完全就绪再动。

`docker.sh` 放在 `service.d` 里会阻塞后续脚本，如果你有多个自启脚本，记得都用后台方式。

## 使用

### docker 命令

```bash
su -c "/data/docker/docker ps"
su -c "/data/docker/docker run -d -p 8080:80 nginx:alpine"
```

建议加个 alias：

```bash
# Termux 的 ~/.bashrc 或 /system/etc/mkshrc
alias docker='su -c /data/docker/docker'
```

### docker compose

```bash
su -c "/data/docker/dc <项目名> up -d"
su -c "/data/docker/dc <项目名> ps"
su -c "/data/docker/dc <项目名> down"
```

项目目录约定：`/data/docker/projects/<项目名>/docker-compose.yml`
（chroot 内对应 `/projects/<项目名>/`）

首次使用需要装 compose 插件：

```bash
su -c "mkdir -p /data/docker/rootfs/usr/local/lib/docker/cli-plugins"
su -c "curl -L -o /data/docker/rootfs/usr/local/lib/docker/cli-plugins/docker-compose https://github.com/docker/compose/releases/latest/download/docker-compose-linux-aarch64"
su -c "chmod +x /data/docker/rootfs/usr/local/lib/docker/cli-plugins/docker-compose"
```

### 挂载手机存储

容器里的 `/sdcard` 就是手机的 `/data/media/0`：

```bash
su -c "/data/docker/docker run --rm -v /sdcard/Download:/data alpine ls /data"
```

⚠️ **路径必须写成 chroot 内可见的**。因为 dockerd 和 CLI 都在 chroot 里，写宿主机的 `/storage/emulated/0` 会找不到。

## 示例

`examples/` 下有两个可以直接跑的最小项目：

| 示例 | 验证什么 |
|---|---|
| **nginx** | 镜像能拉、端口能映射、volume 能挂、局域网能访问 |
| **alpine-cron** | 容器能在后台长期跑、日志能查、日志不会吃满存储 |

```bash
su -c "cp -r examples/nginx /data/docker/projects/nginx"
su -c "/data/docker/dc nginx up -d"
# 浏览器打开 http://手机IP:8090
```

`alpine-cron` 的重点在日志配置那段——**手机上必须限制日志大小**，默认的 `json-file` 驱动不封顶，一个每 10 秒打一行的容器跑半年能吃掉 1GB+。

详见 [examples/README.md](examples/README.md)。

## 已知限制

| 限制 | 说明 |
|---|---|
| **SELinux 必须 Permissive** | `start.sh` 里 `setenforce 0`。要在 Enforcing 下跑需要写 sepolicy 规则，很麻烦 |
| **不能用 `--cpuset-cpus`** | cpuset 控制器被故意隐藏（见原理），绑核功能不可用 |
| **重启后要重新启动** | 内核的 mount 和 iptables 规则都不持久，靠 `service.d` 重跑 `start.sh` |
| **镜像兼容性** | 只能跑 arm64 镜像。x86 镜像需要 qemu 模拟，性能不可用 |
| **内存吃紧** | Android 的 lmkd 可能杀掉 containerd，容器多时要注意 |

## 排错

### dockerd 起不来

```bash
su -c "tail -30 /data/docker/dockerd.log"
```

常见报错：

| 报错 | 原因 | 处理 |
|---|---|---|
| `failed to start daemon: error initializing graphdriver: ... overlay2` | 内核没开 `CONFIG_OVERLAY_FS` | 重编内核 |
| `failed to mount overlay: invalid argument` | 存储分区不支持 overlayfs | 改 `daemon.json` 的 `storage-driver` 为 `vfs`（慢但能用） |
| `failed to create cgroup` | cgroup 没对齐 | 看 `/data/docker/cgroup.log` |

### 容器创建失败

```
runc: cpuset.cpus: no such file or directory
```

说明 cpuset 没被隐藏——`dockerd-ns.sh` 没生效，检查 `start.sh` 里是不是走了 `unshare -m`。

### 容器能起但上不了网

```bash
su -c "cat /data/docker/net.log"
su -c "ip rule | head -4"
su -c "iptables -t nat -L POSTROUTING -n | head -5"
```

要点：
- `FORWARD` 链最前面必须有 `ACCEPT` 规则（否则撞 `tetherctrl_FORWARD` 的 DROP）
- `ip rule` 里要有 `9000: from 172.16.0.0/12 lookup main`
- 默认网关变了要重跑 `docker-net.sh`（看门狗会自动做）

### 端口映射不通

`docker -p` 靠 `docker-proxy`（用户态转发），不依赖 iptables DNAT。
如果宿主机能连、局域网连不上，检查手机是否开了 WiFi 防火墙或 AP 隔离。

### 重启后全挂

正常现象。Android 不保留 mount 和 iptables 规则，必须重跑 `start.sh`。用 `service.d` 自启。

完整的排错手册见 **[docs/troubleshooting.md](docs/troubleshooting.md)** —— 按报错信息分类，附实际日志样本、诊断命令，以及提 issue 时该附上什么。

## 原理：为什么用 chroot 而不是 proot

| | chroot + 真 dockerd | proot |
|---|---|---|
| 容器隔离 | 真 namespace | 无（只是路径重定向） |
| 端口映射 | 正常 | 受限 |
| 性能 | 接近原生 | 有 syscall 拦截开销 |
| 内核要求 | namespace + cgroup | 无 |
| 权限 | 必须 root | 免 root |

本项目选择 chroot，因为要的是**真的能跑容器的 Docker**，不是"看起来像 Docker"。

`chroot` 之后仍有三个坑要处理（就是前面表格里的 1、3、5），这也是本项目 90% 的代码在做的事。

## 目录结构

```
/data/docker/
├── bin/                  # Docker 静态二进制（bind 到 chroot /usr/bin）
├── lib/                  # Docker 数据（bind 到 chroot /var/lib/docker）
├── rootfs/               # Debian 根（chroot 目标）
├── etc/daemon.json       # dockerd 配置
├── projects/             # compose 项目（bind 到 chroot /projects）
├── start.sh              # 总入口
├── dockerd-ns.sh         # 私有 namespace 启动 dockerd
├── docker-cgroup.sh      # cgroup 控制器归位
├── docker-mounts.sh      # chroot 挂载准备
├── docker-net.sh         # NAT / 转发 / 策略路由
├── docker-net-watch.sh   # 网关变化看门狗
├── dc                    # compose 包装
└── docker                # CLI 包装
```

## 免责声明

**使用前请完整阅读 [DISCLAIMER.md](DISCLAIMER.md)**（English: [DISCLAIMER.en.md](DISCLAIMER.en.md)）。摘要：

| 风险 | 具体后果 |
|---|---|
| **设备** | 刷内核可能变砖，最坏要用 EDL/9008 救砖；解锁 Bootloader 清空全部数据、可能永久失去保修 |
| **数据** | 容器与系统共用 `/data` 分区，写满会导致无法拍照/装应用/开机；本项目不含任何备份机制 |
| **安全** | `setenforce 0` 关闭 SELinux 强制访问控制，恶意应用更易提权；容器以 root 运行，不受 Android 沙箱限制 |
| **硬件** | 长期插电加速电池老化，第三方电池鼓包风险高；持续高温可能损伤屏幕和主板 |
| **合规** | 解锁/root 可能违反当地法规或运营商条款；不得用于非本人设备或规避版权保护 |

**作者与贡献者不对设备损坏、数据丢失、保修失效、安全事件、法律纠纷，以及任何直接或间接损失承担责任。**

本项目按 MIT 许可证「按原样」提供，不附带任何明示或暗示担保。

**仅建议在专用测试机上使用。继续使用即表示你接受上述全部风险。**

## License

MIT。欢迎提 issue 说你的机型适配情况。

如果你在原厂内核上跑通了，麻烦说明机型和内核版本——这说明厂商没有阉割 cgroup，对其他人很有参考价值。
