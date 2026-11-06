# zihua.sh

多协议代理一键安装 / 管理脚本（sing-box + Xray + hysteria 三内核），附带 BBR 开启与内核网络参数调优。

## 一键运行

登录 VPS 后以 root 用户直接执行（无需 sudo）：

```bash
wget -P /root -N --no-check-certificate "https://raw.githubusercontent.com/xiaoluaibb/zihua/main/zihua.sh" && chmod 700 /root/zihua.sh && /root/zihua.sh
```

没有 wget 时可用 curl：

```bash
curl -kfsSL "https://raw.githubusercontent.com/xiaoluaibb/zihua/main/zihua.sh" -o /root/zihua.sh && chmod 700 /root/zihua.sh && /root/zihua.sh
```

### Alpine 系统专用

Alpine 自带的 BusyBox wget 不支持 `-N` / `--no-check-certificate` 参数，且默认没有 bash，请用：

```sh
apk add bash curl openssl tar
wget -O /root/zihua.sh "https://raw.githubusercontent.com/xiaoluaibb/zihua/main/zihua.sh"
chmod 700 /root/zihua.sh
bash /root/zihua.sh
```

v1.2.0 起原生支持 Alpine（OpenRC 服务管理），无需 systemd。首次运行后会自动安装 `zihua` 快捷命令，之后直接输入 `zihua` 即可再次打开菜单。

## 手动下载运行

```bash
curl -fsSL https://raw.githubusercontent.com/xiaoluaibb/zihua/main/zihua.sh -o zihua.sh
bash zihua.sh
```

## 功能简介

- 三内核架构（v1.5.0 起，v1.6.0 调整 Hysteria2 安装方式）：
  - sing-box：SS2022 / TUIC / VLESS-Vision-TLS（自签证书）
  - Xray：VLESS-Reality-Vision / VLESS-Reality-gRPC（配置与 v2ray-agent 同款模板，独立服务 zihua-xray，抗封锁首选）
  - hysteria 官方内核：Hysteria2 —— **安装/卸载直接调用 [seagullz4/hysteria2](https://github.com/seagullz4/hysteria2) 的 install.sh**（作者 seagullz4，感谢），本脚本只负责下载、调用与结果展示
  - 三个服务彼此独立，只重启自己那份；装/改/删 Hysteria2 不会影响 SS2022 与 Reality
- 多协议同时运行：各协议独立实例与独立证书，TCP 与 UDP 端口可同号并存（如 Vision 用 TCP 443，Hysteria2 用 UDP 443）
- Reality 偷域名：内置大厂域名可选（也可偷自己的域名），选择后自动测试目标是否支持 TLS1.3，并检测 Cloudflare CDN 代理（套 CDN 的域名会被警告，防止 VPS 流量被滥用）
- 安装后自动验证：服务运行状态 + 端口监听检查；卸载后自动验证程序 / 配置 / 进程清除干净
- TLS 证书三种来源（TUIC）：
  1. 自签证书：无域名一键生成，客户端开『允许不安全』
  2. 已有证书文件：填 acme.sh / certbot / 宝塔 签发的 pem + key 路径
  3. acme.sh 自动申请（域名解析到本机即可）
- Hysteria2 的证书/端口/密码/伪装/端口跳跃，全部由第三方脚本问询，参数与它自己的安装完全一致
- 交互式菜单：安装、新增 / 修改 / 删除协议实例、查看配置
- 系统兼容：systemd 与 OpenRC 双支持（Alpine 原生可用，无需 systemd）
- 快捷命令：首次运行后自动安装 `zihua` 命令，以后直接输入 `zihua` 即可再次打开
- 一键重装系统：主菜单第 5 项，调用同仓库 `reinstall-vm.sh`（KVM netboot+preseed 全自动 / LXC rootfs 原位替换，支持 Debian/Ubuntu/Alpine/Rocky 等十余种系统）
- 网络优化：BBR 开启与内核参数调优（写入 `/etc/sysctl.d/99-proxybox-optimize.conf`）
  - 完整参数集 34 项：BBR + fq 队列、收发缓冲、并发队列（somaxconn / backlog / SYN）、TCP FastOpen、TIME_WAIT 复用、本地端口范围、UDP 缓冲（QUIC / Hysteria2）、conntrack 上限等
  - 收发缓冲按**物理内存自动缩放**（≤384M→8M，≤768M→16M，≤1.5G→32M，≤3G→48M，≤6G→64M，更大→128M），小内存机型不会因为照抄 64M/128M 而 OOM
  - 逐条应用：先检测该参数在当前内核是否存在，不存在的自动跳过并在结束时列出，不会像 `sysctl -p` 那样一条报错就整批中断
  - 支持精确回滚：首次调优前把原值记录到 `/etc/sysctl.d/proxybox-optimize.orig`，菜单『恢复默认参数』按原值逐项还原
  - Alpine 下自动检查并启用 `sysctl` 开机服务（`rc-update add sysctl boot`）
- 配置安全：每次修改前自动备份到 `/etc/sing-box/backup`
- 旧版迁移：v1.4.x 用 sing-box 装的 Hysteria2，进『代理管理』会提示一键切换到官方内核，只重建 Hysteria2，SS2022 / Reality 不受影响

## 系统要求

| 项目 | 要求 |
|------|------|
| 系统 | Debian 10+ / Ubuntu 18.04+ / Rocky / Alma / CentOS 7+(部分) / Fedora / Alpine 3.15+ / Arch |
| 初始化 | systemd 或 OpenRC（Alpine 原生可用） |
| 权限 | root 直接运行（无需 sudo） |

## Hysteria2 说明

Hysteria2 部分**直接调用第三方脚本** [seagullz4/hysteria2](https://github.com/seagullz4/hysteria2) 完成，安装流程、交互选项、配置写法与它自己一键安装完全一致。感谢原作者 seagullz4。

| 项目 | 说明 |
|------|------|
| 安装 | 菜单选 Hysteria2 → 自动下载它的 install.sh 到 `/usr/local/bin/hy2-install.sh` 并执行，选 1 安装；四个下载通道（jsdelivr / raw / ghfast / gh-proxy）任一可用即可 |
| 内核 | 官方 `hysteria`，由第三方脚本下载（`/root/hy3/hysteria-linux-<arch>`） |
| 服务 | systemd `hysteria.service`（第三方脚本创建），日志 `journalctl -u hysteria` |
| 配置 | `/root/hy3/config.yaml` |
| 端口 | 第三方脚本里填，默认 UDP 443；与 TCP 443 的 Reality 可以同号共存 |
| 接入本脚本 | 安装完自动反解 `config.yaml`（端口 / 密码 / 证书方式 / SNI / 端口跳跃范围），生成 `hy2://` 分享链接，并在代理列表里显示运行状态 |
| 删除 | 『删除某个代理』会按第三方脚本的卸载逻辑清理 `hysteria` / `ipppp`，不碰 SS2022 与 Reality |
| 排查 | 『代理管理 → Hysteria2 连通性自检』一键查 进程/监听/NAT/防火墙/是否收到过客户端数据，并给出结论 |

## 常见问题

### 提示 `bash: /dev/fd/63: No such file or directory`

两个可能原因：

1. `sudo bash <(curl ...)` 中 sudo 会丢弃外层 shell 的临时管道，导致 bash 找不到 `/dev/fd/63`。**root 用户直接运行即可，不要加 sudo**。
2. 服务器没能成功下载脚本：下载一失败管道就消失。此时改用"先下载、后运行"：

```bash
wget -P /root -N --no-check-certificate "https://raw.githubusercontent.com/xiaoluaibb/zihua/main/zihua.sh" && chmod 700 /root/zihua.sh && /root/zihua.sh
```

若 raw 域名连不上（大陆方向常见），可走 GitHub API 通道，通常更稳定：

```bash
curl -fsSL -H "Accept: application/vnd.github.raw" https://api.github.com/repos/xiaoluaibb/zihua/contents/zihua.sh -o /root/zihua.sh && chmod 700 /root/zihua.sh && /root/zihua.sh
```

仍不行时，在本地电脑下载脚本后用 scp 上传运行：

```bash
scp zihua.sh root@服务器IP:/root/
ssh root@服务器IP "bash /root/zihua.sh"
```

## 注意事项

- 请提前在云服务商安全组 / 防火墙放行脚本中使用的端口
- 脚本会安装 sing-box 及其依赖，重复运行可安全恢复
- 仅供学习与个人使用，请遵守当地法律法规，使用风险自负
