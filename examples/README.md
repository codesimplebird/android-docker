# 示例

两个最小可用的 compose 项目，用来验证环境装对了没、以及演示手机上跑容器的两个关键约束。

## 怎么用

compose 项目要求放在 `/data/docker/projects/<名字>/`，把示例复制过去：

```bash
# 在仓库目录执行
su -c "mkdir -p /data/docker/projects"
su -c "cp -r examples/nginx /data/docker/projects/nginx"
su -c "cp -r examples/alpine-cron /data/docker/projects/alpine-cron"

# 启动
su -c "/data/docker/dc nginx up -d"
```

然后用浏览器打开 `http://手机IP:8090`。

停止：

```bash
su -c "/data/docker/dc nginx down"
```

## nginx — 静态站

**验证什么**：镜像能拉、端口能映射、volume 能挂载、局域网能访问。

```yaml
ports:   ["8090:80"]
volumes: ["./html:/usr/share/nginx/html:ro"]
```

页面在 `examples/nginx/html/index.html`，改完刷新浏览器立刻生效——这就证明 bind mount 是通的。

**改端口**：8090 被占用就改前面的数字。注意手机上的端口和宿主机一样是全局的，`netstat -ltn` 能看谁占了。

## alpine-cron — 后台常驻任务

**验证什么**：容器能长期在后台跑、日志能查、日志不会把存储吃满。

```bash
su -c "/data/docker/dc alpine-cron logs -f"    # 实时看，Ctrl+C 退出
su -c "/data/docker/dc alpine-cron ps"         # 运行状态
```

每 10 秒输出一行，带容器内 uptime。跑一晚上再看，uptime 应该是连续增长的——说明没被 Android 的内存回收杀掉。

**这个示例的重点在日志配置**：

```yaml
logging:
  driver: json-file
  options:
    max-size: "1m"
    max-file: "2"
```

手机上**必须**限制日志。默认的 json-file 驱动不限制大小，一个每 10 秒打一行日志的容器，跑半年能吃掉 1GB+。上面这个配置把单个容器压在 2MB 以内。

自己写 compose 时记得抄这段。

## 手机上写 compose 的几个注意点

| 事项 | 说明 |
|---|---|
| **端口冲突** | 手机上的端口是全局的，装之前先 `netstat -ltn` 看一眼 |
| **不要暴露到公网** | 家里的路由器如果做了端口转发或 DMZ，会把容器直接摊在互联网上。**没有任何一个示例配了认证**，nginx 示例就是个公开目录 |
| **日志限制** | 必须配 `max-size` + `max-file`，否则迟早吃满存储 |
| **内存限制** | 建议加 `mem_limit: 256m`，防止单个容器被 lmkd 盯上 |
| **volume 路径** | 用相对路径（`./html`）或 chroot 内路径（`/sdcard/xxx`），别用宿主的 `/storage/emulated/0` |
| **不要跑 x86 镜像** | 只会得到 `exec format error` |
| **restart 策略** | `unless-stopped` 只在容器异常退出时重启，手机重启后仍需先跑 `start.sh` |

## 下一步

跑通这两个之后，可以试试：

- **文件服务**：`filebrowser/filebrowser` 或 `nginx` 开 `autoindex on`
- **下载器**：`aria2` + `ariang`（注意限速和磁盘写入）
- **代码服务**：`gitea`（arm64 有镜像，内存占用约 150MB）
- **定时任务**：`mcuadros/ofelia` 调度容器内的 cron

内存有限，一次跑两三个轻量服务比较合适。`docker stats` 能看实时占用。
