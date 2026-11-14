#!/system/bin/sh
# 把 Android 分散的 cgroup v1 控制器归位到 /sys/fs/cgroup/<name>
# 让 dockerd 的 cgroupfs 驱动能找到它们
set -u

CG=/sys/fs/cgroup

bind_existing() {
  src="$1"; name="$2"
  if [ ! -d "$src" ]; then
    echo "  skip  $name（源 $src 不存在）"
    return
  fi
  mkdir -p "$CG/$name" 2>/dev/null
  if mountpoint -q "$CG/$name" 2>/dev/null; then
    echo "  ok    $name 已挂载"
    return
  fi
  if mount --bind "$src" "$CG/$name" 2>/dev/null; then
    echo "  ok    $name <- $src"
  else
    echo "  FAIL  $name <- $src"
  fi
}

new_hierarchy() {
  name="$1"
  mkdir -p "$CG/$name" 2>/dev/null
  if mountpoint -q "$CG/$name" 2>/dev/null; then
    echo "  ok    $name 已挂载"
    return
  fi
  if mount -t cgroup -o "$name" "$name" "$CG/$name" 2>/dev/null; then
    echo "  ok    $name（新建 hierarchy）"
  else
    echo "  FAIL  $name"
  fi
}

echo "=== 1. 复用 Android 已挂的控制器 ==="
bind_existing /dev/memcg  memory
bind_existing /dev/cpuctl cpu
bind_existing /dev/cpuset  cpuset
bind_existing /dev/blkio   blkio

echo "=== 2. 新建 Android 未使用的控制器 ==="
new_hierarchy devices
new_hierarchy pids

echo "=== 3. 结果 ==="
for n in memory cpu cpuset blkio freezer devices pids; do
  if mountpoint -q "$CG/$n" 2>/dev/null; then
    echo "  $n: OK"
  else
    echo "  $n: 缺失"
  fi
done
