#!/system/bin/sh
# Android Docker 一键安装
#
# 用法：
#   su -c "sh install.sh"                      # 默认用阿里云镜像下 Docker
#   su -c "MIRROR=official sh install.sh"      # Docker 走官方源
#   su -c "MIRROR=ghproxy sh install.sh"       # rootfs 走 GitHub 代理
#   su -c "SKIP_COMPOSE=1 sh install.sh"       # 跳过 compose 插件
#   su -c "DOCKER_ROOT=/data/dk sh install.sh" # 换安装目录（进阶）
#
# 幂等：可以重复执行，已下载的部分会跳过。

set -u

DOCKER_ROOT=${DOCKER_ROOT:-/data/docker}
DOCKER_VER=${DOCKER_VER:-24.0.9}
MIRROR=${MIRROR:-aliyun}
SKIP_COMPOSE=${SKIP_COMPOSE:-0}
BB=/data/adb/magisk/busybox

log() { echo "[*] $*"; }
ok()  { echo "  [ok] $*"; }
warn(){ echo "  [!] $*"; }
die() { echo ""; echo "[X] $*" >&2; exit 1; }

# ---------------------------------------------------------------- 0. 检查
[ "$(id -u)" = "0" ] || die "需要 root：su -c \"sh install.sh\""
[ -x "$BB" ] || BB=$(command -v busybox 2>/dev/null) || die "找不到 busybox（Magisk 自带，检查 /data/adb/magisk/busybox）"

ARCH=$(uname -m)
case "$ARCH" in
  aarch64|arm64) ARCH_TAG=aarch64; DEB_TAG=arm64v8 ;;
  armv7l|armv8l) die "armv7 需要换 32 位 Docker 二进制，本项目未适配" ;;
  x86_64)        die "x86_64 需要换 amd64 二进制，本项目未适配" ;;
  *)             die "未知架构 $ARCH" ;;
esac
ok "架构 $ARCH"

# 内核检查
if [ -f /proc/config.gz ]; then
  MISS=""
  for c in CONFIG_CGROUPS CONFIG_NAMESPACES CONFIG_VETH CONFIG_OVERLAY_FS CONFIG_NETFILTER; do
    zcat /proc/config.gz 2>/dev/null | grep -q "^$c=y" || MISS="$MISS $c"
  done
  if [ -n "$MISS" ]; then
    warn "内核缺少以下选项，dockerd 很可能起不来："
    for m in $MISS; do echo "        $m"; done
    warn "详见 docs/kernel.md。按 Enter 继续，Ctrl+C 中止"
    read -r _
  else
    ok "内核配置完整"
  fi
else
  warn "没有 /proc/config.gz，跳过内核检查（建议开 CONFIG_IKCONFIG_PROC）"
fi

# 空间检查（rootfs ~1.5G + 二进制 ~200M + 余量）
set -- $(df -k "$(dirname "$DOCKER_ROOT")" 2>/dev/null | tail -1)
AVAIL_KB=${4:-0}
if [ "$AVAIL_KB" -lt 4000000 ] 2>/dev/null; then
  warn "剩余空间不足 4GB（当前 $((AVAIL_KB / 1024))MB），可能装不下"
fi

# ---------------------------------------------------------------- 1. 目录
log "创建目录 $DOCKER_ROOT"
mkdir -p "$DOCKER_ROOT/rootfs" "$DOCKER_ROOT/bin" "$DOCKER_ROOT/lib" \
         "$DOCKER_ROOT/etc" "$DOCKER_ROOT/projects" || die "创建目录失败"
ok "目录就绪"

# ---------------------------------------------------------------- 2. rootfs
if [ -f "$DOCKER_ROOT/rootfs/etc/os-release" ] || [ -d "$DOCKER_ROOT/rootfs/usr" ]; then
  ok "rootfs 已存在，跳过"
else
  log "下载 Debian bookworm rootfs（约 50MB）"
  case "$MIRROR" in
    ghproxy) RF_BASE="https://ghproxy.net/https://github.com" ;;
    *)       RF_BASE="https://github.com" ;;
  esac
  RF_URL="$RF_BASE/debuerreotype/docker-debian-artifacts/raw/dist-${DEB_TAG}/bookworm/rootfs.tar.xz"
  TMP="$DOCKER_ROOT/.rootfs.tar.xz"

  curl -fL --retry 3 --connect-timeout 20 -o "$TMP" "$RF_URL" || die "rootfs 下载失败。国内可试 MIRROR=ghproxy 或手动下载"
  ok "下载完成 ($(du -h "$TMP" | cut -f1))"

  log "解压到 $DOCKER_ROOT/rootfs"
  # Android 的 tar 未必支持 xz，按能力降级
  if $BB tar -xJf "$TMP" -C "$DOCKER_ROOT/rootfs" 2>/dev/null; then
    ok "解压完成（busybox tar -J）"
  elif [ -x "$BB" ] && $BB xz -d -c "$TMP" > "$TMP.tar" 2>/dev/null; then
    $BB tar -xf "$TMP.tar" -C "$DOCKER_ROOT/rootfs" && ok "解压完成（xz + tar）"
    rm -f "$TMP.tar"
  elif command -v xz >/dev/null 2>&1; then
    xz -d -c "$TMP" | tar -xf - -C "$DOCKER_ROOT/rootfs" && ok "解压完成（系统 xz）"
  else
    die "无法解压 .tar.xz，请手动解压到 $DOCKER_ROOT/rootfs"
  fi
  rm -f "$TMP"
  [ -d "$DOCKER_ROOT/rootfs/etc" ] || die "解压后目录结构异常"
fi

# ---------------------------------------------------------------- 3. Docker 二进制
if [ -x "$DOCKER_ROOT/bin/dockerd" ]; then
  ok "Docker 二进制已存在（$($DOCKER_ROOT/bin/dockerd --version 2>/dev/null | cut -d' ' -f3)），跳过"
else
  log "下载 Docker $DOCKER_VER 静态二进制（约 70MB）"
  case "$MIRROR" in
    official) DK_BASE="https://download.docker.com" ;;
    *)        DK_BASE="https://mirrors.aliyun.com/docker-ce" ;;
  esac
  DK_URL="$DK_BASE/linux/static/stable/${ARCH_TAG}/docker-${DOCKER_VER}.tgz"
  TMP="$DOCKER_ROOT/.docker.tgz"

  curl -fL --retry 3 --connect-timeout 20 -o "$TMP" "$DK_URL" || die "Docker 二进制下载失败：$DK_URL"
  ok "下载完成 ($(du -h "$TMP" | cut -f1))"

  mkdir -p "$DOCKER_ROOT/.unpack"
  $BB tar -xzf "$TMP" -C "$DOCKER_ROOT/.unpack" || die "解压失败"
  cp -f "$DOCKER_ROOT/.unpack/docker/"* "$DOCKER_ROOT/bin/" || die "复制二进制失败"
  chmod 755 "$DOCKER_ROOT/bin/"*
  rm -rf "$DOCKER_ROOT/.unpack" "$TMP"

  # runc 有时在单独目录
  [ -f "$DOCKER_ROOT/bin/runc" ] || warn "没找到 runc，容器可能启动失败"
  ok "Docker 二进制就位"
fi

# ---------------------------------------------------------------- 4. 脚本
log "安装启动脚本"
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
for f in start.sh dockerd-ns.sh docker-cgroup.sh docker-mounts.sh \
         docker-net.sh docker-net-watch.sh dc docker; do
  if [ -f "$SCRIPT_DIR/$f" ]; then
    cp -f "$SCRIPT_DIR/$f" "$DOCKER_ROOT/$f" || die "复制 $f 失败"
    chmod 755 "$DOCKER_ROOT/$f"
  else
    warn "缺少 $f（应从仓库根目录运行本脚本）"
  fi
done

if [ -f "$SCRIPT_DIR/daemon.json" ]; then
  cp -f "$SCRIPT_DIR/daemon.json" "$DOCKER_ROOT/etc/daemon.json"
else
  log "生成默认 daemon.json"
  cat > "$DOCKER_ROOT/etc/daemon.json" <<'JSON'
{
  "data-root": "/var/lib/docker",
  "exec-root": "/run/docker",
  "pidfile": "/run/docker.pid",
  "hosts": ["unix:///run/docker.sock"],
  "storage-driver": "overlay2",
  "iptables": false,
  "ip6tables": false,
  "userland-proxy": true,
  "ip-forward": true,
  "dns": ["223.5.5.5", "119.29.29.29"],
  "log-level": "info",
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" }
}
JSON
fi
ok "脚本就位"

# ---------------------------------------------------------------- 5. compose 插件
if [ "$SKIP_COMPOSE" = "1" ]; then
  ok "跳过 compose 插件"
elif [ -x "$DOCKER_ROOT/rootfs/usr/local/lib/docker/cli-plugins/docker-compose" ]; then
  ok "compose 插件已存在"
else
  log "安装 docker compose 插件"
  mkdir -p "$DOCKER_ROOT/rootfs/usr/local/lib/docker/cli-plugins"
  case "$MIRROR" in
    ghproxy) CP_BASE="https://ghproxy.net/https://github.com" ;;
    *)       CP_BASE="https://github.com" ;;
  esac
  curl -fL --retry 2 --connect-timeout 20 \
    -o "$DOCKER_ROOT/rootfs/usr/local/lib/docker/cli-plugins/docker-compose" \
    "$CP_BASE/docker/compose/releases/latest/download/docker-compose-linux-${ARCH_TAG}" \
    && chmod 755 "$DOCKER_ROOT/rootfs/usr/local/lib/docker/cli-plugins/docker-compose" \
    && ok "compose 已安装" \
    || warn "compose 下载失败，可稍后手动装或用 SKIP_COMPOSE=1 跳过"
fi

# ---------------------------------------------------------------- 6. 启动
log "启动 dockerd"
sh "$DOCKER_ROOT/start.sh"
RC=$?

# ---------------------------------------------------------------- 7. 验证
echo ""
if [ $RC -eq 0 ]; then
  log "验证"
  if "$DOCKER_ROOT/docker" version >/dev/null 2>&1; then
    ok "docker CLI 可用"
    "$DOCKER_ROOT/docker" version --format '  Client {{.Client.Version}} / Server {{.Server.Version}}' 2>/dev/null
  else
    warn "CLI 连不上 daemon，检查 $DOCKER_ROOT/dockerd.log"
  fi
  echo ""
  log "试跑 hello-world（需要联网拉镜像）"
  "$DOCKER_ROOT/docker" run --rm hello-world 2>&1 | tail -5
  echo ""
  echo "=========================================="
  echo " 安装完成"
  echo ""
  echo " 启动:  su -c \"$DOCKER_ROOT/start.sh\""
  echo " 使用:  su -c \"$DOCKER_ROOT/docker ps\""
  echo " 项目:  su -c \"$DOCKER_ROOT/dc <名字> up -d\""
  echo ""
  echo " 重启后需要重新执行 start.sh，"
  echo " 或参照 README 配置 service.d 自启。"
  echo "=========================================="
else
  die "dockerd 启动失败，查看 $DOCKER_ROOT/dockerd.log"
fi
