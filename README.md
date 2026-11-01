# zihua.sh

多协议代理一键安装 / 管理脚本（sing-box 统一内核），附带 BBR 开启与内核网络参数调优。

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

- 双内核架构（v1.4.0 起）：
  - sing-box：SS2022 / Hysteria2 / TUIC / VLESS-Vision-TLS（自签证书）
  - Xray：VLESS-Reality-Vision / VLESS-Reality-gRPC（配置与 v2ray-agent 同款模板，独立服务 zihua-xray，抗封锁首选）
- 多协议同时运行：各协议独立实例与独立证书，TCP 与 UDP 端口可同号并存（如 Vision 用 TCP 443，Hysteria2 用 UDP 443）
- Reality 偷域名：内置大厂域名可选（也可偷自己的域名），选择后自动测试目标是否支持 TLS1.3，并检测 Cloudflare CDN 代理（套 CDN 的域名会被警告，防止 VPS 流量被滥用）
- 安装后自动验证：服务运行状态 + 端口监听检查；卸载后自动验证程序 / 配置 / 进程清除干净
- TLS 证书三种来源（Hysteria2 / TUIC）：
  1. 自签证书：无域名一键生成，客户端开『允许不安全』
  2. 已有证书文件：填 acme.sh / certbot / 宝塔 签发的 pem + key 路径
  3. acme.sh 自动申请：自有域名解析到本机即可，全自动签发 + 自动续期
- 交互式菜单：安装、新增 / 修改 / 删除协议实例、查看配置
- 系统兼容：systemd 与 OpenRC 双支持（Alpine 原生可用，无需 systemd）
- 快捷命令：首次运行后自动安装 `zihua` 命令，以后直接输入 `zihua` 即可再次打开
- 一键重装系统：主菜单第 5 项，调用同仓库 `reinstall-vm.sh`（KVM netboot+preseed 全自动 / LXC rootfs 原位替换，支持 Debian/Ubuntu/Alpine/Rocky 等十余种系统）
- 网络优化：BBR 开启与内核参数调优（`/etc/sysctl.d/99-proxybox-optimize.conf`）
- 配置安全：每次修改前自动备份到 `/etc/sing-box/backup`

## 系统要求

| 项目 | 要求 |
|------|------|
| 系统 | Debian 10+ / Ubuntu 18.04+ / Rocky / Alma / CentOS 7+(部分) / Fedora / Alpine 3.15+ / Arch |
| 初始化 | systemd 或 OpenRC（Alpine 原生可用） |
| 权限 | root 直接运行（无需 sudo） |

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
