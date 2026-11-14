#!/system/bin/sh
# 在私有 mount namespace 内启动 dockerd，并隐藏 cpuset 控制器。
#
# 原因：Android 以 noprefix 方式挂载 cpuset（文件名是 cpus / mems），
# 而 runc 固定去找 cpuset.cpus，必然 ENOENT，导致容器创建失败。
# runc 是按 /proc/self/mountinfo 查找控制器的，所以在本命名空间里把
# cpuset 相关挂载点卸掉，runc 就会直接跳过 cpuset —— 容器照常运行，
# 代价只是不能用 --cpuset-cpus 绑核。宿主机（Android）完全不受影响。

BB=/data/adb/magisk/busybox

# 把本命名空间内的挂载传播设为私有：
# pivot_root 要求 old root 不是 shared 挂载，否则返回 EINVAL
# 注意：toybox 的 mount 不支持 --make-rprivate，必须用 busybox
$BB mount --make-rprivate / 2>/dev/null && echo "make-rprivate / ok" || echo "make-rprivate / FAIL"

for m in /data/docker/rootfs/sys/fs/cgroup/cpuset \
         /data/docker/rootfs/dev/cpuset \
         /sys/fs/cgroup/cpuset \
         /dev/cpuset; do
  /system/bin/umount -l "$m" 2>/dev/null && echo "umount $m"
done

n=$(/system/bin/grep -c cpuset /proc/self/mountinfo 2>/dev/null)
echo "namespace 内剩余 cpuset 挂载: ${n:-0}"

exec /system/bin/chroot /data/docker/rootfs \
  /usr/bin/dockerd --config-file /etc/docker/daemon.json
