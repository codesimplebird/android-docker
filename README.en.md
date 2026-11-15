# Android Docker

**English** | [简体中文](README.md)

Run **real Docker** on a rooted Android phone — not proot emulation, not a user-space fake. Real images, real `docker compose`, real port mapping, containers that actually reach the internet.

> The one hard requirement: **your kernel must support namespaces and cgroups**. Many stock kernels ship with these options stripped out, which means compiling your own.

---

> ## ⚠️ Read before you start
>
> This project requires **unlocking the bootloader**, **flashing a custom kernel**, **disabling SELinux (`setenforce 0`)**, and running containers as root.
>
> That means you are signing up for: **a bricked device, wiped data, voided warranty, and a meaningfully weaker security posture**.
>
> Use it on a **spare / test device only**. Do not do this on the phone that holds your accounts and photos.
>
> Full terms in **[DISCLAIMER.en.md](DISCLAIMER.en.md)**. **Using this project means you accept all of it.**

---

## What it solves

Android's kernel actually has everything containers need — namespaces, cgroup v1, veth, overlayfs. The problem is that OEMs wire these up differently from a standard Linux system, so `dockerd` fails in a cascade of confusing ways.

This project closes five specific gaps:

| # | Gap | What Android actually does | Standard Linux | What this project does |
|---|---|---|---|---|
| 1 | **cgroup location** | Controllers scattered across `/dev/memcg`, `/dev/cpuctl`, `/dev/cpuset` | Unified under `/sys/fs/cgroup/<name>` | `docker-cgroup.sh` bind-mounts each one into place |
| 2 | **cpuset filenames** | `cpus` / `mems` (mounted with `noprefix`) | `cpuset.cpus` / `cpuset.mems` | `dockerd-ns.sh` unmounts cpuset inside a private namespace so runc skips it |
| 3 | **Root filesystem** | `/` is read-only and **has no `/run`** | Writable, has `/run` | chroot into `/data/docker/rootfs` |
| 4 | **iptables** | No iptables binary inside the chroot | dockerd manages NAT itself | Run with `--iptables=false`, maintain rules from the host |
| 5 | **ip rule** | No `lookup main`; last rule is `32000: from all unreachable` | Falls back to the main table | Add rules 9000/9001 to steer Docker subnets back to `main` |

Plus two less obvious traps:

- **`tetherctrl_FORWARD` ends with an unconditional DROP** (when hotspot is off, that's the only rule in the chain). Every forwarded packet hits it. You have to insert an ACCEPT at the top of `FORWARD`.
- **The default gateway changes when the network switches.** netd rewrites its own routing tables and wipes the rules we added. Hence a 30-second watchdog.

## Verified on

| Device | Codename | SoC | OS | Kernel | Status |
|---|---|---|---|---|---|
| Xiaomi Mi 10 Pro | `cmi` | Snapdragon 865 | HyperOS 1.0 / Android 13 | 4.19.157-perf (self-built, 2026-11-11) | **Fully working** |

Test environment details:

```
Architecture   aarch64
Root           Magisk 28.1
Docker         24.0.9 (static binary)
SELinux        Permissive
Kernel config  CONFIG_NAMESPACES / CGROUPS / VETH / BRIDGE /
               OVERLAY_FS / NETFILTER / IP_NF_NAT / IP_NF_FILTER /
               IP_ADVANCED_ROUTER / SECCOMP   — all =y

Verified       docker run hello-world          OK
               nginx:alpine + volume + :8090   OK (LAN reachable)
               docker compose up -d            OK
               container outbound networking   OK
               gateway switch (WiFi roaming)   OK (watchdog re-applies)
```

> Ran it on another device? Open an issue with your model, kernel version and `zcat /proc/config.gz | grep CGROUP`. A stock kernel that works is especially interesting — it means the OEM didn't gut cgroups.

## Prerequisites

### 1. Root

Magisk is enough. Everything runs through `su -c`; no specific root implementation is required.

### 2. Kernel config

All of these are **mandatory**:

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

Stock kernels usually miss at least `CONFIG_CGROUPS` or `CONFIG_VETH`. You'll need to build your own:

- **[docs/kernel.en.md](docs/kernel.en.md)** — condensed English guide (step 0 through flashing)
- **[docs/kernel.md](docs/kernel.md)** — full Chinese guide (vendor repos, clang matrix, fragment debugging, three packaging paths, unbricking)

> **Read step 0 first.** A lot of devices don't need rebuilding at all — all four options
> may already be `=y`.

> If `/proc/config.gz` doesn't exist, `CONFIG_IKCONFIG_PROC` is off — you'll have to check the defconfig in the kernel source instead.

### 3. Architecture

Scripts target **aarch64**. For armv7 / x86_64 you'd need different Docker binaries; the scripts themselves are portable.

### 4. Resources

- RAM ≥ 2GB (dockerd + containerd idle around 120MB, containers extra)
- Storage ≥ 4GB (rootfs ~1.5GB + binaries 171MB + images)
- Consider disabling aggressive lmkd — it may kill containerd under memory pressure

## Installation

### One-click (recommended)

Push the repo to your phone (or clone it there), then from the repo root:

```bash
su -c "sh install.sh"
```

The script checks root and kernel config, downloads the Debian rootfs, downloads the static Docker binaries, deploys the scripts, installs the compose plugin, then starts and runs `hello-world` as a smoke test.

Options:

```bash
su -c "MIRROR=official sh install.sh"       # Docker from download.docker.com (default: Aliyun)
su -c "MIRROR=ghproxy sh install.sh"        # rootfs and compose via GitHub proxy
su -c "SKIP_COMPOSE=1 sh install.sh"        # skip the compose plugin
su -c "DOCKER_ROOT=/data/dk sh install.sh"  # custom install path
```

The script is idempotent — already-downloaded pieces are skipped.

### Manual

#### 1. Prepare the rootfs

Docker needs a writable Linux root. Android's `/` won't do (read-only, no `/run`). Use a Debian minirootfs:

```bash
su -c "mkdir -p /data/docker/rootfs"
su -c "cd /data/docker/rootfs && curl -LO https://github.com/debuerreotype/docker-debian-artifacts/raw/dist-arm64v8/bookworm/rootfs.tar.xz && tar -xJf rootfs.tar.xz && rm rootfs.tar.xz"
```

> Android's `tar` may not support xz. If it fails, use `busybox xz -d` first, or `xz -d | tar -xf -`.

#### 2. Docker static binaries

```bash
su -c "mkdir -p /data/docker/bin /data/docker/lib"
su -c "cd /tmp && curl -LO https://download.docker.com/linux/static/stable/aarch64/docker-24.0.9.tgz && tar -xzf docker-24.0.9.tgz && cp docker/* /data/docker/bin/ && rm -rf docker docker-24.0.9.tgz"
```

You need `dockerd`, `containerd`, `containerd-shim-runc-v2`, `runc`, `docker`, `docker-proxy`, `docker-init`, `ctr`.

#### 3. Deploy scripts

```bash
su -c "cp start.sh dockerd-ns.sh docker-cgroup.sh docker-mounts.sh docker-net.sh docker-net-watch.sh dc docker /data/docker/"
su -c "mkdir -p /data/docker/etc && cp daemon.json /data/docker/etc/"
su -c "chmod +x /data/docker/*.sh /data/docker/dc /data/docker/docker"
```

#### 4. Start

```bash
su -c "/data/docker/start.sh"
```

Wait for `dockerd 已就绪` (dockerd is ready), then:

```bash
su -c "/data/docker/docker run --rm hello-world"
```

#### 5. Autostart (optional)

```bash
su -c "cat > /data/adb/service.d/docker.sh << 'EOF'
#!/system/bin/sh
until [ \".\$(getprop sys.boot_completed)\" = \".1\" ]; do sleep 5; done
sleep 60
sh /data/docker/start.sh > /data/docker/autostart.log 2>&1
EOF
su -c "chmod 755 /data/adb/service.d/docker.sh"
```

**Note the `sleep 60`.** Magisk runs `service.d` scripts in parallel with system modules. Starting too early starves other modules (charging control, performance tuning) during their init and can break them.

## Usage

```bash
su -c "/data/docker/docker ps"
su -c "/data/docker/docker run -d -p 8080:80 nginx:alpine"
```

Handy alias:

```bash
alias docker='su -c /data/docker/docker'
```

### docker compose

```bash
su -c "/data/docker/dc <project> up -d"
su -c "/data/docker/dc <project> ps"
su -c "/data/docker/dc <project> down"
```

Projects live in `/data/docker/projects/<project>/docker-compose.yml` (inside the chroot that's `/projects/<project>/`).

Install the compose plugin once:

```bash
su -c "mkdir -p /data/docker/rootfs/usr/local/lib/docker/cli-plugins"
su -c "curl -L -o /data/docker/rootfs/usr/local/lib/docker/cli-plugins/docker-compose https://github.com/docker/compose/releases/latest/download/docker-compose-linux-aarch64"
su -c "chmod +x /data/docker/rootfs/usr/local/lib/docker/cli-plugins/docker-compose"
```

### Mounting phone storage

`/sdcard` inside a container is the phone's `/data/media/0`:

```bash
su -c "/data/docker/docker run --rm -v /sdcard/Download:/data alpine ls /data"
```

⚠️ **Paths must be visible inside the chroot.** dockerd and the CLI both run in there, so the host path `/storage/emulated/0` won't resolve.

## Examples

Two minimal projects under `examples/`:

| Example | What it verifies |
|---|---|
| **nginx** | Image pull, port mapping, volume mount, LAN access |
| **alpine-cron** | Long-running background container, log inspection, log size limits |

```bash
su -c "cp -r examples/nginx /data/docker/projects/nginx"
su -c "/data/docker/dc nginx up -d"
# open http://<phone-ip>:8090
```

The point of `alpine-cron` is the logging config — **on a phone you must cap log size**. The default `json-file` driver has no limit; a container logging every 10 seconds will eat 1GB+ in half a year.

See [examples/README.md](examples/README.md).

## Known limitations

| Limitation | Details |
|---|---|
| **SELinux must be Permissive** | `start.sh` calls `setenforce 0`. Running under Enforcing requires custom sepolicy rules — a lot of work |
| **No `--cpuset-cpus`** | The cpuset controller is deliberately hidden (see below), so CPU pinning is unavailable |
| **Does not survive reboot** | Mounts and iptables rules aren't persistent; `start.sh` must run again each boot |
| **arm64 images only** | x86 images need qemu, which isn't viable performance-wise |
| **Memory pressure** | Android's lmkd may kill containerd; keep container count low |

## Troubleshooting

See **[docs/troubleshooting.md](docs/troubleshooting.md)** — organized by error message, with real log samples, diagnostic commands, and a script that collects everything you need for an issue report.

## Why chroot instead of proot

| | chroot + real dockerd | proot |
|---|---|---|
| Container isolation | Real namespaces | None (path redirection only) |
| Port mapping | Works normally | Limited |
| Performance | Near-native | syscall interception overhead |
| Kernel requirements | namespaces + cgroups | None |
| Privileges | root required | Works without root |

This project picks chroot because the goal is **a Docker that actually runs containers**, not something that looks like Docker.

After `chroot` three problems remain (gaps 1, 3 and 5 in the table above) — that's what 90% of the code here is about.

## Directory layout

```
/data/docker/
├── bin/                  # static Docker binaries (bind-mounted to chroot /usr/bin)
├── lib/                  # Docker data (bind-mounted to chroot /var/lib/docker)
├── rootfs/               # Debian root (chroot target)
├── etc/daemon.json       # dockerd config
├── projects/             # compose projects (bind-mounted to chroot /projects)
├── start.sh              # entry point
├── dockerd-ns.sh         # launch dockerd inside a private namespace
├── docker-cgroup.sh      # relocate cgroup controllers
├── docker-mounts.sh      # prepare chroot mounts
├── docker-net.sh         # NAT / forwarding / policy routing
├── docker-net-watch.sh   # gateway-change watchdog
├── dc                    # compose wrapper
└── docker                # CLI wrapper
```

## Disclaimer

**Read [DISCLAIMER.en.md](DISCLAIMER.en.md) before use.** Summary:

| Risk | Consequence |
|---|---|
| **Device** | A bad kernel flash can brick it; recovery may need EDL/9008. Unlocking wipes all data and may void warranty permanently |
| **Data** | Containers share `/data` with the system — filling it breaks camera, app installs, even boot. No backup mechanism is provided |
| **Security** | `setenforce 0` disables SELinux mandatory access control; containers run as root outside the Android sandbox |
| **Hardware** | Continuous charging ages the battery; third-party batteries risk swelling; sustained heat can damage screen and board |
| **Legal** | Unlocking/rooting may violate local law or carrier terms. Do not use on devices you don't own |

**The authors and contributors accept no liability** for device damage, data loss, voided warranty, security incidents, legal disputes, or any direct or indirect damages.

Provided under the MIT License, **as is**, without warranty of any kind.

**Use on a spare/test device only. Continuing means you accept all of the above.**

## License

MIT. Issues about device compatibility are welcome.

If it works on a stock kernel, please say so with your model and kernel version — that tells everyone the OEM didn't gut cgroups, which is genuinely useful information.
