#!/system/bin/sh
# 容器网络：NAT、转发与策略路由（幂等，可反复执行）
#
# 背景一：dockerd 以 --iptables=false 运行（chroot 里没有 iptables 二进制），
#         所以 NAT 规则由这里用 Android 自带的 iptables 手工维护。
#         端口发布（-p）由 docker-proxy 完成，不依赖 iptables DNAT。
#
# 背景二：Android 的 ip rule 里**没有 lookup main**，最后一条是
#         "32000: from all unreachable"。内核往 main 表里加的
#         "172.17.0.0/16 dev docker0" 永远轮不到，回包会被
#         "31000: iif lo lookup wlan0" 抢走送到 WiFi 网关。
#         所以要给 Docker 网段单独加规则，把它导回 main 表。
set -u

IPT=/system/bin/iptables
# 网段参数说明：
#   SUBNET 用整个 Docker 默认地址池 172.16.0.0/12，
#   否则新建网络（172.18/172.19…）的容器出不去。
SUBNET=172.16.0.0/12     # Docker 默认地址池全集（NAT + 路由规则都用它）
POOL=172.16.0.0/12       # Docker 默认地址池全集（路由规则用）
BR=docker0

# 1. 打开转发
echo 1 > /proc/sys/net/ipv4/ip_forward 2>/dev/null
echo "ip_forward = $(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null)"

# 2. 出站 MASQUERADE（-C 先检查，避免重复添加）
#    先清掉旧版本只覆盖 172.17.0.0/16 的那条规则
if $IPT -t nat -C POSTROUTING -s 172.17.0.0/16 ! -o $BR -j MASQUERADE 2>/dev/null; then
  $IPT -t nat -D POSTROUTING -s 172.17.0.0/16 ! -o $BR -j MASQUERADE 2>/dev/null \
    && echo "清理旧规则 172.17.0.0/16"
fi

if $IPT -t nat -C POSTROUTING -s $SUBNET ! -o $BR -j MASQUERADE 2>/dev/null; then
  echo "nat POSTROUTING: 已存在"
else
  $IPT -t nat -A POSTROUTING -s $SUBNET ! -o $BR -j MASQUERADE 2>/dev/null \
    && echo "nat POSTROUTING: 已添加" || echo "nat POSTROUTING: 添加失败"
fi

# 3. 转发放行
#    ★ 关键：Android 的 tetherctrl_FORWARD 链最后有一条无条件 DROP
#      （不开热点时链里只有这一条），所有转发包都会撞上它。
#      所以必须在 FORWARD 最前面抢先 ACCEPT，否则容器出不去。
#      这里按网段匹配而不是按接口名，这样 docker0 和自定义网络的
#      br-xxxx 都能覆盖，新增网络不用改脚本。
for spec in "-s $POOL" "-d $POOL"; do
  if $IPT -C FORWARD $spec -j ACCEPT 2>/dev/null; then
    echo "FORWARD $spec: 已存在"
  else
    $IPT -I FORWARD 1 $spec -j ACCEPT 2>/dev/null \
      && echo "FORWARD $spec: 已添加" || echo "FORWARD $spec: 添加失败"
  fi
done

# 清理旧版本按接口名加的规则（已被上面的网段规则取代）
if $IPT -C FORWARD -i $BR -j ACCEPT 2>/dev/null; then
  $IPT -D FORWARD -i $BR -j ACCEPT 2>/dev/null && echo "清理旧规则 -i $BR"
fi
if $IPT -C FORWARD -o $BR -j ACCEPT 2>/dev/null; then
  $IPT -D FORWARD -o $BR -j ACCEPT 2>/dev/null && echo "清理旧规则 -o $BR"
fi

# 4. 策略路由
# 探测当前默认网关（走的是 netd 自己的表，不受我们规则影响）
# ★ 开机自启时本脚本常常跑在 WiFi 连上之前，此时探测不到网关，
#   所以先等最多 60 秒，避免规则被跳过。
i=0
while [ $i -lt 20 ]; do
  GW=$(ip route get 223.5.5.5 2>/dev/null | sed -n 's/.* via \([0-9.]*\) .*/\1/p')
  [ -n "${GW:-}" ] && break
  sleep 3
  i=$((i + 1))
done

DEV=$(ip route get 223.5.5.5 2>/dev/null | sed -n 's/.* dev \([a-zA-Z0-9_]*\) .*/\1/p')
echo "默认出口: gw=${GW:-无} dev=${DEV:-无}（等待 ${i} 轮）"

if [ -n "${GW:-}" ] && [ -n "${DEV:-}" ]; then
  # main 表补一条默认路由（Android 平时不用 main 表，加这条不影响系统；
  # 而 Docker 各网段的直连路由是 dockerd 自己写进 main 的）
  ip route replace default via "$GW" dev "$DEV" table main 2>/dev/null \
    && echo "main 表默认路由: 已设置" || echo "main 表默认路由: 设置失败"

  # 容器发出的包（源在 Docker 池内）→ main
  ip rule del pref 9000 2>/dev/null
  ip rule add pref 9000 from "$POOL" lookup main 2>/dev/null \
    && echo "ip rule 9000 (from $POOL): 已添加" || echo "ip rule 9000: 添加失败"

  # 发往容器的包（目的在 Docker 池内）→ main
  ip rule del pref 9001 2>/dev/null
  ip rule add pref 9001 to "$POOL" lookup main 2>/dev/null \
    && echo "ip rule 9001 (to $POOL): 已添加" || echo "ip rule 9001: 添加失败"
else
  echo "警告: 探测不到默认网关，跳过策略路由"
fi

# 5. 状态汇总
echo "--- ip rule 前 4 条 ---"
ip rule 2>/dev/null | head -4
echo "--- main 表 ---"
ip route show table main 2>/dev/null | head -6
echo "--- nat POSTROUTING ---"
$IPT -t nat -L POSTROUTING -n 2>/dev/null | head -5
