# 排错手册

按报错现象查，每一条都附了实际日志样本。

## 快速诊断

先跑这三个，多数问题能定位：

```bash
su -c "tail -40 /data/docker/dockerd.log"      # daemon 启动日志
su -c "cat /data/docker/cgroup.log"            # cgroup 对齐结果
su -c "cat /data/docker/net.log"               # 网络规则结果
su -c "/data/docker/docker info"               # daemon 是否活着
```

---

## 一、dockerd 起不来

### 1.1 graphdriver / overlay2

```
failed to start daemon: error initializing graphdriver: driver not supported
```

或

```
failed to mount overlay: invalid argument
```

**原因**：内核没开 `CONFIG_OVERLAY_FS`，或存储分区不支持 overlayfs。

**处理**：
- 先确认内核：`zcat /proc/config.gz | grep OVERLAY_FS`
- 如果没有，只能重编内核
- 临时绕过：改 `daemon.json` 的 `storage-driver` 为 `vfs`（能用，但慢且占空间）

```json
{ "storage-driver": "vfs" }
```

### 1.2 cgroup 相关

```
failed to start daemon: Error creating cgroup: ...
```

**处理**：看 `/data/docker/cgroup.log`，正常应该是：

```
=== 3. 结果 ===
  memory: OK
  cpu: OK
  cpuset: OK
  blkio: OK
  freezer: OK
  devices: OK
  pids: OK
```

哪个是「缺失」，说明那个控制器没 bind 上。常见原因：

- `/dev/memcg` 不存在 → 设备没开 `CONFIG_MEMCG`
- `mount --bind` 返回 `Permission denied` → SELinux 还是 Enforcing

### 1.3 PID 文件冲突

```
failed to start daemon: pid file found, ensure docker is not running
```

**处理**：

```bash
su -c "pkill -f usr/bin/dockerd; pkill -f usr/bin/containerd; rm -f /data/docker/rootfs/run/docker.pid"
su -c "/data/docker/start.sh"
```

`start.sh` 已经会清理，但如果上次异常退出留了 socket，手动删一次。

### 1.4 SELinux

```
permission denied
```

或各种 `operation not permitted`。

**处理**：`start.sh` 里已有 `setenforce 0`。确认它生效：

```bash
su -c "getenforce"     # 应该是 Permissive
```

如果重启后又变回 Enforcing，说明有东西在重置，加个 `service.d` 脚本开机设：

```bash
#!/system/bin/sh
until [ ".$(getprop sys.boot_completed)" = ".1" ]; do sleep 5; done
setenforce 0
```

要在 Enforcing 下跑，需要写 sepolicy 规则（`allow magisk docker_* ...`），工作量很大，不推荐。

---

## 二、容器创建失败

### 2.1 cpuset

```
runc: ... cpuset.cpus: no such file or directory
```

或

```
OCI runtime create failed: ... write /sys/fs/cgroup/cpuset/.../cpuset.cpus
```

**原因**：`dockerd-ns.sh` 没生效。runc 在找 `cpuset.cpus`，而 Android 挂的是 `cpus`。

**验证**：

```bash
su -c "grep -c cpuset /proc/$(pidof dockerd)/mountinfo"
```

正常应该是 0（已被隐藏）。不是 0 说明 `start.sh` 没有走 `unshare -m`。

**处理**：确认 `start.sh` 第 5 步是：

```sh
/system/bin/setsid /system/bin/unshare -m /system/bin/sh /data/docker/dockerd-ns.sh
```

不要直接 chroot 启 dockerd，那样 cpuset 藏不掉。

### 2.2 镜像架构不匹配

```
exec /bin/sh: exec format error
```

**原因**：拉了 x86 镜像。

**处理**：只拉 arm64 镜像，或指定 `--platform linux/arm64`。

### 2.3 没有 runc

```
failed to start: ... no such file or directory: /usr/bin/runc
```

**处理**：Docker 静态包里 `runc` 有时在独立目录，确认：

```bash
su -c "ls /data/docker/bin/ | grep runc"
```

没有的话从 `https://github.com/opencontainers/runc/releases` 下 `runc.arm64`，改名 `runc` 放进 `/data/docker/bin/`，`chmod 755`。

---

## 三、容器能起但没网

### 3.1 现象：容器 ping 不通外网

**先看规则**：

```bash
su -c "cat /data/docker/net.log"
su -c "ip rule | head -6"
su -c "iptables -t nat -L POSTROUTING -n | head -5"
```

正常应该包含：

```
ip rule:
9000:	from 172.16.0.0/12 lookup main
9001:	from all to 172.16.0.0/12 lookup main

nat POSTROUTING:
MASQUERADE  all  --  172.16.0.0/12  !docker0
```

缺哪个补哪个——直接重跑：

```bash
su -c "sh /data/docker/docker-net.sh"
```

### 3.2 出站规则在但回包进不来

**原因**：`tetherctrl_FORWARD` 链末尾有个无条件 `DROP`，所有转发包都撞上。

**验证**：

```bash
su -c "iptables -L FORWARD -n --line-numbers | head -10"
```

如果第一条不是 `ACCEPT  ... 172.16.0.0/12`，说明规则没插到最前面。

**处理**：`docker-net.sh` 用 `-I FORWARD 1` 插入，重跑即可。

### 3.3 换网络后突然断

**原因**：Android 的默认网关变了，netd 重写了自己的路由表，把 `main` 表里的默认路由和 `ip rule` 冲掉了。

**处理**：看门狗应该自动修。检查它在不在：

```bash
su -c "cat /data/docker/net-watch.pid && kill -0 \$(cat /data/docker/net-watch.pid) && echo alive"
su -c "tail -20 /data/docker/net-watch.log"
```

没在跑就手动起：

```bash
su -c "/system/bin/setsid /system/bin/sh /data/docker/docker-net-watch.sh > /dev/null 2>&1 < /dev/null &"
```

---

## 四、端口映射不通

`docker -p` 靠 `docker-proxy`（用户态转发），**不依赖 iptables DNAT**。

| 现象 | 原因 | 处理 |
|---|---|---|
| 宿主机 `127.0.0.1:端口` 能连，局域网连不上 | 手机防火墙 / AP 隔离 | 关掉路由器的「AP 隔离」 |
| 都连不上 | 容器内服务没监听 `0.0.0.0` | 检查容器内 `netstat -ltn` |
| 端口被占 | 已有进程 | `su -c "netstat -ltnp \| grep 端口"` |

验证端口有没有映射出来：

```bash
su -c "netstat -ltnp | grep 8080"
```

应该看到 `docker-proxy` 在监听 `:::8080`。

---

## 五、存储与空间

### 5.1 镜像越积越多

```bash
su -c "/data/docker/docker system df"          # 看占用
su -c "/data/docker/docker system prune -a"     # 清理未使用的镜像/容器/网络
```

### 5.2 磁盘满了

```bash
su -c "df -h /data"
su -c "du -sh /data/docker/lib/*"    # 镜像层在这里
```

⚠️ **不要 `du -sh /data/docker/rootfs`** —— 它 bind 了 `/sdcard`，会把整个手机存储算进去，结果虚高几十倍。

### 5.3 日志占满空间

`daemon.json` 里已经限制（`max-size: 10m`、`max-file: 3`），单个容器最多占 30MB。
如果某个容器日志仍然很大，说明它用了自己的日志配置，检查 `docker inspect <容器> | grep LogConfig`。

---

## 六、稳定性

### 6.1 跑一阵容器就消失

**原因**：Android 的 `lmkd`（低内存杀手）把 containerd 或容器进程杀了。

**验证**：

```bash
su -c "dmesg | grep -i 'lowmemorykiller\|lmkd' | tail -10"
```

**处理**：
- 减少并发容器数量
- 给容器设内存上限：`docker run -m 256m ...`
- 把 containerd 加进 lmkd 白名单（需要改系统属性，风险较高）

### 6.2 重启后全没了

**这是正常现象**。Android 不保留 mount 和 iptables 规则，必须重跑 `start.sh`。

配置开机自启（注意 `sleep 60`，别和系统模块抢）：

```bash
su -c "cat > /data/adb/service.d/docker.sh << 'EOF'
#!/system/bin/sh
until [ \".\$(getprop sys.boot_completed)\" = \".1\" ]; do sleep 5; done
sleep 60
sh /data/docker/start.sh > /data/docker/autostart.log 2>&1
EOF
su -c "chmod 755 /data/adb/service.d/docker.sh"
```

### 6.3 拉镜像卡住

```
context deadline exceeded
```

**原因**：国内直连 Docker Hub 慢或被墙。

**处理**：`daemon.json` 里配镜像加速（本项目默认已配两个）：

```json
"registry-mirrors": [
  "https://docker.m.daocloud.io",
  "https://docker.1panel.live"
]
```

改完重启 dockerd。加速源会失效，失效时换一个。

---

## 七、提 issue 时请附上

```bash
# 一次性收集
su -c "
echo '=== uname ==='; uname -a
echo '=== model ==='; getprop ro.product.model; getprop ro.build.version.release
echo '=== selinux ==='; getenforce
echo '=== kernel config ==='; zcat /proc/config.gz 2>/dev/null | grep -E 'CONFIG_(CGROUPS|NAMESPACES|VETH|OVERLAY_FS)='
echo '=== dockerd.log ==='; tail -30 /data/docker/dockerd.log
echo '=== cgroup.log ==='; cat /data/docker/cgroup.log
echo '=== net.log ==='; tail -25 /data/docker/net.log
echo '=== ip rule ==='; ip rule
echo '=== docker info ==='; /data/docker/docker info 2>&1 | head -30
" > /sdcard/docker-diag.txt
```

把 `/sdcard/docker-diag.txt` 贴出来，基本能定位 90% 的问题。
