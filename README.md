# zihua.sh

多协议代理一键安装 / 管理脚本（sing-box 统一内核），附带 BBR 开启与内核网络参数调优。

## 一键运行

在 VPS 上以 root 执行：

```bash
sudo bash <(curl -fsSL https://raw.githubusercontent.com/xiaoluaibb/zihua/main/zihua.sh)
```

若服务器没有 curl，可用 wget：

```bash
sudo bash <(wget -qO- https://raw.githubusercontent.com/xiaoluaibb/zihua/main/zihua.sh)
```

## 手动下载运行

```bash
curl -fsSL https://raw.githubusercontent.com/xiaoluaibb/zihua/main/zihua.sh -o zihua.sh
sudo bash zihua.sh
```

## 功能简介

- 统一内核：sing-box 一个服务承载多入站协议，方便增删改
  - Shadowsocks 2022
  - Hysteria2
  - TUIC
  - VLESS-Reality-Vision
  - VLESS-Reality-gRPC
- 交互式菜单：安装、新增 / 修改 / 删除协议实例、查看配置
- 网络优化：BBR 开启与内核参数调优（`/etc/sysctl.d/99-proxybox-optimize.conf`）
- 配置安全：每次修改前自动备份到 `/etc/sing-box/backup`

## 系统要求

| 项目 | 要求 |
|------|------|
| 系统 | Debian 10+ / Ubuntu 18.04+ / Rocky / Alma / CentOS 7+(部分) / Fedora / Alpine 3.15+ / Arch |
| 组件 | 需要 systemd |
| 权限 | root（sudo）运行 |

## 常见问题

### 提示 `bash: /dev/fd/63: No such file or directory`

这是服务器没能成功下载脚本导致的：`bash <(curl ...)` 依赖下载成功后产生的临时管道，下载一失败管道就消失。此时改用"先下载、后运行"：

```bash
curl -fsSL https://raw.githubusercontent.com/xiaoluaibb/zihua/main/zihua.sh -o zihua.sh && sudo bash zihua.sh
```

若 raw 域名连不上（大陆方向常见），可走 GitHub API 通道，通常更稳定：

```bash
curl -fsSL -H "Accept: application/vnd.github.raw" https://api.github.com/repos/xiaoluaibb/zihua/contents/zihua.sh -o zihua.sh && sudo bash zihua.sh
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
