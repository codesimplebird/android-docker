#!/system/bin/sh
# 为 dockerd 准备 chroot 根环境
# 关键点：
#   1) 安卓根目录只读，Docker 硬编码 /run → 用 chroot 造 /run
#   2) 普通的 mount --bind 不带子挂载，cgroup 控制器必须逐个绑定
#   3) 在 chroot 的 /sys/fs/cgroup 上盖一层可写 tmpfs，才能 mkdir 挂点
set -u

R=/data/docker/rootfs
B=/data/docker/bin
L=/data/docker/lib
CG=/sys/fs/cgroup

echo "=== 0. 清理旧挂载（深到浅）==="
for m in run/docker sys/fs/cgroup/pids sys/fs/cgroup/devices sys/fs/cgroup/freezer \
         sys/fs/cgroup/blkio sys/fs/cgroup/cpuset sys/fs/cgroup/cpu sys/fs/cgroup/memory \
         sys/fs/cgroup tmp proc dev sys usr/bin var/lib/docker sdcard projects; do
  if mountpoint -q "$R/$m" 2>/dev/null; then
    # 优先正常卸载；卸载不掉再懒卸载。
    # 只用 -l 会留下"已分离但仍挂在表里"的记录，反复启动 dockerd 会越叠越多。
    umount "$R/$m" 2>/dev/null || umount -l "$R/$m" 2>/dev/null
    echo "  umount $m"
  fi
done
if mountpoint -q "$R" 2>/dev/null; then
  umount -l "$R" 2>/dev/null && echo "  umount $R（自身）"
fi
sleep 0.3

echo "=== 1. 目录骨架 ==="
mkdir -p "$R/usr/bin" "$R/run" "$R/tmp" "$R/root" "$R/data" \
         "$R/var/lib/docker" "$R/var/log" "$R/etc/docker" \
         "$R/proc" "$R/sys" "$R/dev" "$R/sys/fs/cgroup" \
         "$R/sdcard" "$R/projects" 2>/dev/null

echo "=== 2. 基础挂载 ==="
# 让 chroot 根自身成为挂载点。否则 Docker 解包镜像层时会对 "/" 做
# MS_SLAVE|MS_REC，而 "/" 不是挂载点会返回 EINVAL
if ! mountpoint -q "$R" 2>/dev/null; then
  if mount --bind "$R" "$R" 2>/dev/null; then
    echo "  ok   $R 自身成为挂载点"
  else
    echo "  FAIL $R 自身 bind"
  fi
fi
bind_one() {
  tgt="$1"; src="$2"
  if mount --bind "$src" "$tgt" 2>/dev/null; then echo "  ok   $tgt <- $src"; else echo "  FAIL $tgt"; fi
}
bind_one "$R/usr/bin"        "$B"
bind_one "$R/var/lib/docker" "$L"
bind_one "$R/sys"            "/sys"
bind_one "$R/dev"            "/dev"

# 用户数据与 compose 项目目录
# 注意：dockerd 与 CLI 都在 chroot 里，所以 -v 的源路径必须是 chroot 内可见的路径。
#
# /sdcard 在 Android 上是指向 /storage/self/primary 的符号链接，而 FUSE 挂载
# 不在 su 的 mount namespace 里（ls 到的是空目录），绑它等于绑一个坏链接。
# 真实存储路径是 /data/media/0，所以绑那个。
if [ -d /data/media/0 ]; then
  mkdir -p "$R/sdcard" 2>/dev/null
  bind_one "$R/sdcard" "/data/media/0"
fi
mkdir -p /data/docker/projects "$R/projects" 2>/dev/null
bind_one "$R/projects" "/data/docker/projects"
mount -t proc proc "$R/proc" 2>/dev/null && echo "  ok   proc"
mount -t tmpfs tmpfs "$R/run" 2>/dev/null && echo "  ok   run (tmpfs)"
mount -t tmpfs tmpfs "$R/tmp" 2>/dev/null && echo "  ok   tmp (tmpfs)"

echo "=== 3. cgroup：盖 tmpfs 再逐个绑控制器 ==="
if mount -t tmpfs tmpfs "$R/sys/fs/cgroup" 2>/dev/null; then
  echo "  ok   /sys/fs/cgroup 盖上可写 tmpfs"
else
  echo "  FAIL 盖 tmpfs"
fi

for n in memory cpu cpuset blkio freezer devices pids schedtune; do
  src="$CG/$n"
  tgt="$R/sys/fs/cgroup/$n"
  [ -d "$src" ] || continue
  mkdir -p "$tgt" 2>/dev/null
  if mount --bind "$src" "$tgt" 2>/dev/null; then
    echo "  ok   cgroup/$n"
  else
    echo "  FAIL cgroup/$n"
  fi
done

ln -sf ../run "$R/var/run" 2>/dev/null

echo "=== 4. DNS ==="
printf 'nameserver 223.5.5.5\nnameserver 119.29.29.29\n' > "$R/etc/resolv.conf"
printf '127.0.0.1 localhost\n' > "$R/etc/hosts"

echo "=== 4b. CA 根证书（安卓的在 /system/etc/security/cacerts）==="
mkdir -p "$R/etc/ssl/certs"
cat /system/etc/security/cacerts/* > "$R/etc/ssl/certs/ca-certificates.crt" 2>/dev/null
echo "  合成证书数: $(grep -c 'BEGIN CERTIFICATE' "$R/etc/ssl/certs/ca-certificates.crt" 2>/dev/null || echo 0)"

echo "=== 5. 校验（看真实挂载，不是空目录名）==="
for n in memory cpu cpuset blkio freezer devices pids; do
  if [ -f "$R/sys/fs/cgroup/$n/tasks" ] || [ -f "$R/sys/fs/cgroup/$n/cgroup.procs" ]; then
    echo "  $n: 真实可用"
  else
    echo "  $n: 不可用"
  fi
done
