#!/system/bin/sh
# Docker 网络看门狗
#
# 解决的问题：Android 的默认网关会随网络变化（WiFi ↔ 移动数据 ↔ 热点），
# 而 netd 在切换时会重写自己的路由表，我们给 Docker 补的 main 表默认路由
# 和 ip rule 可能因此对不上（或直接被清掉）。
#
# 本脚本每 30 秒检查一次，只在「网关变了」或「规则不见了」时才重跑
# docker-net.sh，平时不产生任何操作。
LOG=/data/docker/net-watch.log
PIDFILE=/data/docker/net-watch.pid

# 单实例保护：Android 的 pgrep 读不到完整 cmdline，不能用进程名判断，
# 改用 PID 文件 + kill -0 探测存活。
if [ -f "$PIDFILE" ]; then
  old=$(cat "$PIDFILE" 2>/dev/null)
  if [ -n "${old:-}" ] && kill -0 "$old" 2>/dev/null; then
    exit 0
  fi
fi
echo $$ > "$PIDFILE"

while true; do
  GW=$(ip route get 223.5.5.5 2>/dev/null | sed -n 's/.* via \([0-9.]*\) .*/\1/p')
  CUR=$(ip route show table main default 2>/dev/null | sed -n 's/.* via \([0-9.]*\) .*/\1/p' | head -1)
  HAS_RULE=$(ip rule 2>/dev/null | grep -c "9000:")

  NEED=0
  [ -n "${GW:-}" ] && [ "$GW" != "${CUR:-}" ] && NEED=1
  [ "${HAS_RULE:-0}" -eq 0 ] && [ -n "${GW:-}" ] && NEED=1

  if [ "$NEED" -eq 1 ]; then
    echo "[$(date '+%m-%d %H:%M:%S')] 需要重设规则 gw=${GW:-无} main=${CUR:-无} rule=$HAS_RULE" >> "$LOG"
    sh /data/docker/docker-net.sh >> "$LOG" 2>&1
    # 日志超过 200 行就截断，避免无限增长
    n=$(wc -l < "$LOG" 2>/dev/null)
    if [ "${n:-0}" -gt 200 ]; then
      tail -100 "$LOG" > "$LOG.tmp" && mv -f "$LOG.tmp" "$LOG"
    fi
  fi

  sleep 30
done
