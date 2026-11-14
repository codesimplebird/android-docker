#!/system/bin/sh
# 启动 dockerd（chroot 方式）
set -u

R=/data/docker/rootfs
LOG=/data/docker/dockerd.log

# 0. SELinux 设为宽容模式
# dockerd 需要 mount/mknod/cgroup 等特权操作，Enforcing 下会被拒绝。
# 想恢复：把下面这行注释掉，然后为 dockerd 写 Magisk sepolicy 规则。
setenforce 0 2>/dev/null

# 1. 清理残留
pkill -f "usr/bin/dockerd" 2>/dev/null
pkill -f "usr/bin/containerd" 2>/dev/null
sleep 1

# 2. cgroup 控制器归位
sh /data/docker/docker-cgroup.sh > /data/docker/cgroup.log 2>&1
grep -c "OK" /data/docker/cgroup.log > /dev/null 2>&1

# 3. chroot 根环境挂载
sh /data/docker/docker-mounts.sh > /data/docker/mounts.log 2>&1

# 4. 配置
cp -f /data/docker/etc/daemon.json "$R/etc/docker/daemon.json"

# 5. 启动：在私有 mount namespace 里跑，以便隐藏 cpuset 控制器（见 dockerd-ns.sh）
rm -f "$LOG"
PATH=/usr/bin:/bin \
TMPDIR=/tmp \
HOME=/root \
SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt \
/system/bin/setsid /system/bin/unshare -m /system/bin/sh /data/docker/dockerd-ns.sh \
  > "$LOG" 2>&1 < /dev/null &

# 6. 等 socket 出现并可用
i=0
while [ $i -lt 30 ]; do
  if [ -S "$R/run/docker.sock" ] && pgrep -f "usr/bin/dockerd" > /dev/null 2>&1; then
    echo "dockerd 已就绪"
    break
  fi
  sleep 1
  i=$((i + 1))
done

# 7. 容器网络（NAT / 转发 / 策略路由，幂等）
# dockerd 以 --iptables=false 运行，NAT 由宿主 iptables 维护；
# docker-net.sh 内部会先等网络就绪（开机时可能比 WiFi 连上更早）
if [ -d /sys/class/net/docker0 ]; then
  sh /data/docker/docker-net.sh > /data/docker/net.log 2>&1
  echo "容器网络规则已应用（见 net.log）"
else
  echo "警告: docker0 未创建，跳过 NAT 规则"
fi

# 7.1 网络看门狗：网关变化后自动重新对齐规则
# 单实例保护由脚本自己用 PID 文件完成（Android 的 pgrep 读不到完整命令行）
/system/bin/setsid /system/bin/sh /data/docker/docker-net-watch.sh \
  > /dev/null 2>&1 < /dev/null &
echo "网络看门狗已启动"

if [ -S "$R/run/docker.sock" ] && pgrep -f "usr/bin/dockerd" > /dev/null 2>&1; then
  exit 0
fi

echo "dockerd 未就绪，日志末尾："
tail -15 "$LOG"
exit 1
