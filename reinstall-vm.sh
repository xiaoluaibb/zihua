#!/usr/bin/env bash
# ============================================================================
#  reinstall-vm.sh —— KVM 虚拟机 / LXC 容器 一键交互式重装 Linux 系统
# ----------------------------------------------------------------------------
#  工作原理:
#    KVM : 下载发行版官方 netboot 内核 (vmlinuz + initrd.gz), 重建 initrd 并把
#          preseed.cfg 内嵌到 initramfs 根目录 (d-i 官方机制: initrd 里的
#          /preseed.cfg 会被自动加载, 无需外部服务器)。写入 GRUB 一次性引导项,
#          重启后全自动安装并自动重启进新系统。
#    LXC : 从 images.linuxcontainers.org (或 TUNA 镜像) 下载官方 rootfs.tar.xz,
#          清空现有根文件系统 (仅保留挂载点), 原位解包替换, 配置好 root 密码 /
#          SSH / 网络 / 主机名 / 时区 后重启即可。
#
#  支持范围:
#    KVM : Debian 10/11/12/13, Ubuntu 20.04 (全自动)
#          * Ubuntu 22.04+ 与 RHEL 系在 KVM 上需要更复杂的外部引擎, 暂不支持
#    LXC : Debian / Ubuntu / Alpine / Rocky / AlmaLinux / CentOS Stream
#          / Fedora / openSUSE / Arch (全自动)
#
#  用法:
#    bash reinstall-vm.sh                  # 交互式菜单
#    bash reinstall-vm.sh debian bookworm  # 带参数快速执行
#    bash reinstall-vm.sh --rules          # 仅查看硬件需求对照表
#
#  !! 风险提示 !!
#    重装会清空当前系统全部数据 (KVM 整盘重新分区; LXC 清空容器根目录)。
#    执行前请务必确认服务器上没有需要保留的数据, 建议先在测试机上演练。
# ============================================================================
# 设计参考与致谢:
#   bin456789/reinstall            initrd 重建手法 (cpio -H newc) 与 GRUB 写法
#   leitbogioro/InstallNET         交互式设计思路
#   Debian Installer 官方 preseed 文档 (apbs02 / example-preseed)
# ============================================================================

REINSTALL_VM_VERSION="1.1.0"

LC_ALL=C
set -u
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"

# ---------------------------------------------------------------- 颜色与输出
if [ -t 1 ]; then
    C0=$'\033[0m' CR=$'\033[1;31m' CG=$'\033[1;32m' CY=$'\033[1;33m'
    CB=$'\033[1;36m' CM=$'\033[1;35m' CD=$'\033[2m'
else
    C0='' CR='' CG='' CY='' CB='' CM='' CD=''
fi
info()    { printf '%s[信息]%s %s\n'  "$CB" "$C0" "$*"; }
ok()      { printf '%s[完成]%s %s\n'  "$CG" "$C0" "$*"; }
warn()    { printf '%s[注意]%s %s\n'  "$CY" "$C0" "$*"; }
err()     { printf '%s[错误]%s %s\n'  "$CR" "$C0" "$*"; }
die()     { err "$*"; exit 1; }

confirm() { # confirm <提示> —— 输入 y/yes 才返回 0
    local reply
    printf '%s[确认]%s %s %s[y/N]%s: ' "$CY" "$C0" "$*" "$CD" "$C0"
    read -r reply
    case $reply in y|Y|yes|YES|Yes) return 0 ;; *) return 1 ;; esac
} # ask <变量名> <提示> [默认值]
ask() {
    local __var=$1 __msg=$2 __def=${3:-} reply
    if [ -n "$__def" ]; then printf '%s[输入]%s %s %s[%s]%s: ' "$CB" "$C0" "$__msg" "$CD" "$__def" "$C0"
    else printf '%s[输入]%s %s: ' "$CB" "$C0" "$__msg"; fi
    read -r reply
    if [ -z "$reply" ]; then reply=$__def; fi
    printf '%s\n' "$C0"
    printf -v "$__var" '%s' "$reply"
}

# 通用选择器: 从临时文件列出的 "键|描述" 中选择
MENU_RESULT=
pick() { # pick <标题> <选项文件路径> ; 结果存 MENU_RESULT, 取消返回 9
    local __title=$1 __file=$2 choice
    printf '\n%s%s%s\n' "$CM" "========== $__title ==========" "$C0"
    while IFS='|' read -r key desc; do
        printf '  %s%s%s) %s\n' "$CG" "$key" "$C0" "$desc"
    done <"$__file"
    printf '%s q%s) %s\n' "$CD" "$C0" "返回/取消"
    while :; do
        printf '%s请输入编号>%s ' "$CB" "$C0"; read -r choice || return 9
        [ -z "$choice" ] && continue
        if [ "$choice" = q ] || [ "$choice" = Q ]; then return 9; fi
        if awk -F'|' -v k="$choice" '$1==k {found=1} END{exit found?0:1}' "$__file" 2>/dev/null; then
            MENU_RESULT=$choice
            return 0
        fi
        warn "无效编号: $choice"
    done
}

# ------------------------------------------------------------ 依赖检测与安装
PKG_MGR=
detect_pkg_mgr() {
    for m in apt-get dnf yum zypper pacman apk; do
        command -v "$m" >/dev/null 2>&1 && { PKG_MGR=$m; return 0; }
    done
    return 1
}

install_pkg() { # install_pkg <包名> —— 自动按当前系统包管理器安装
    local p=$1
    detect_pkg_mgr || { warn "未找到包管理器, 无法安装 $p (可能需要手动安装)"; return 1; }
    info "安装依赖包: $p (via $PKG_MGR)"
    case $PKG_MGR in
        apt-get) DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$p" >/dev/null 2>&1 ;;
        dnf)     dnf install -y -q "$p" >/dev/null 2>&1 ;;
        yum)     yum install -y -q "$p" >/dev/null 2>&1 ;;
        zypper)  zypper --non-interactive in "$p" >/dev/null 2>&1 ;;
        pacman)  pacman -S --noconfirm --needed "$p" >/dev/null 2>&1 ;;
        apk)     apk add --no-cache "$p" >/dev/null 2>&1 ;;
    esac
}

require_cmd() { # require_cmd <命令> <包名>
    command -v "$1" >/dev/null 2>&1 && return 0
    install_pkg "$2"
    command -v "$1" >/dev/null 2>&1 && return 0
    err "缺少命令 $1 (包: $2), 安装失败"; die "请手动安装后重跑本脚本"
}

# ------------------------------------------------------------ 运行环境检测
VIRT=           # kvm / lxc
ARCH=
ARCH_IMG=       # d-i 命名: amd64 / arm64
ARCH_LXC=       # lxc 镜像站命名: amd64 / arm64 / armhf

detect_arch() {
    case $(uname -m) in
        x86_64)  ARCH=x86_64;  ARCH_IMG=amd64;  ARCH_LXC=amd64 ;;
        aarch64) ARCH=aarch64; ARCH_IMG=arm64;  ARCH_LXC=arm64 ;;
        armv7l|armv8l) ARCH=armhf; ARCH_IMG=armhf; ARCH_LXC=armhf ;;
        *) die "不支持的架构: $(uname -m) (支持 amd64 / arm64)" ;;
    esac
}

detect_virt() {
    local v=""
    if command -v systemd-detect-virt >/dev/null 2>&1; then
        v=$(systemd-detect-virt 2>/dev/null) || v=""
    fi
    if [ -z "$v" ] || [ "$v" = none ]; then
        # 无 systemd 检测工具时兜底
        if grep -qE 'container=lxc' /proc/1/environ 2>/dev/null; then v=lxc
        elif [ -f /.dockerenv ]; then v=docker
        elif grep -qE 'hypervisor' /proc/cpuinfo 2>/dev/null; then v=kvm
        elif [ -d /proc/xen ]; then v=xen
        else v=kvm; fi
    fi
    case $v in
        lxc)         VIRT=lxc ;;
        docker|podman) die "检测到 Docker/Podman 容器, 不支持在此类环境中重装系统" ;;
        chroot|none) die "检测到 chroot 环境, 不支持" ;;
        xen|kvm|qemu|vmware|microsoft|oracle|bochs|uml|openvz) VIRT=kvm ;;
        *) VIRT=kvm ;;
    esac
    [ "$v" = openvz ] && warn "OpenVZ 时代环境, 兼容性不作保证"
    [ "$v" = microsoft ] && warn "Hyper-V 环境: kexec 引导可能失败, 将自动回落到 GRUB 引导"
    return 0
}

need_root() { [ "$(id -u)" -eq 0 ] || die "请使用 root 用户运行 (sudo -i / su -)" ; }

# ------------------------------------------------------------ 硬件信息收集
RAM_MB=0 SWAP_MB=0 DISK_MB=0 DISK_AVAIL_MB=0

get_hw() {
    RAM_MB=$(awk '/^MemTotal:/ {printf "%d", $2/1024}' /proc/meminfo)
    SWAP_MB=$(awk '/^SwapTotal:/ {printf "%d", $2/1024}' /proc/meminfo)
    # 根分区所在磁盘的容量与可用空间
    local src dfout
    dfout=$(df -BM / 2>/dev/null | awk 'NR==2 {print $2, $4}')
    DISK_MB=${dfout%% *}; DISK_MB=${DISK_MB%M}
    DISK_AVAIL_MB=${dfout##* }; DISK_AVAIL_MB=${DISK_AVAIL_MB%M}
    # LXC 下 / 可用即整个容器; KVM 下取整盘更准确, 但 df / 已够用
    if [ "$VIRT" = kvm ] && command -v findmnt >/dev/null 2>&1; then
        local diskname
        diskname=$(findmnt -n -o SOURCE / 2>/dev/null | sed 's/[0-9]*$//; s/p$//')
        diskname=$(basename "${diskname:-}")
        if [ -n "$diskname" ] && [ -e "/sys/block/$diskname" ] && command -v lsblk >/dev/null 2>&1; then
            local total
            total=$(lsblk -b -n -o SIZE "/dev/$diskname" 2>/dev/null | head -1)
            [ -n "$total" ] && DISK_MB=$((total / 1048576))
        fi
    fi
}

show_hw_summary() {
    local arch_label=${ARCH_IMG:-$ARCH}
    info "运行环境: $( [ "$VIRT" = lxc ] && echo 'LXC 容器' || echo 'KVM 虚拟机' ) / 架构: $arch_label"
    info "内存     : ${RAM_MB} MB  (swap: ${SWAP_MB} MB)"
    info "磁盘     : 根分区容量 ${DISK_MB} MB, 可用 ${DISK_AVAIL_MB} MB"
}

# ---------------------------------------------------------------- 网络信息收集
NET_MODE=dhcp          # dhcp / static
NET_IP= NET_MASK= NET_GW= NET_DNS= NET_IFACE= NET_PREFIX= HOSTNAME_OLD=

get_net() {
    HOSTNAME_OLD=$(hostname 2>/dev/null)
    [ -n "$HOSTNAME_OLD" ] || HOSTNAME_OLD=$(cat /proc/sys/kernel/hostname 2>/dev/null || echo localhost)
    [ "$HOSTNAME_OLD" = none ] && HOSTNAME_OLD=localhost
    NET_IFACE=$(ip -o -4 route show default 2>/dev/null | awk '{print $5; exit}')
    [ -n "$NET_IFACE" ] || NET_IFACE=$(ip -o -4 addr show 2>/dev/null | awk '$2!="lo"{print $2; exit}' | sed 's/[:@].*//')
    local cidr
    cidr=$(ip -4 addr show "$NET_IFACE" 2>/dev/null | awk '/inet /{print $2; exit}')
    NET_IP=${cidr%%/*}; NET_PREFIX=${cidr##*/}
    case $NET_PREFIX in
        8)  NET_MASK=255.0.0.0 ;;
        16) NET_MASK=255.255.0.0 ;;
        24) NET_MASK=255.255.255.0 ;;
        25) NET_MASK=255.255.255.128 ;;
        26) NET_MASK=255.255.255.192 ;;
        27) NET_MASK=255.255.255.224 ;;
        28) NET_MASK=255.255.255.240 ;;
        29) NET_MASK=255.255.255.248 ;;
        30) NET_MASK=255.255.255.252 ;;
        *)  NET_MASK=255.255.255.0 ;;
    esac
    NET_GW=$(ip -o -4 route show default 2>/dev/null | awk '{print $3; exit}')
    NET_DNS=$(awk '/^nameserver / && $2 ~ /\./ {print $2; c++; if(c==2) exit}' /etc/resolv.conf 2>/dev/null | paste -sd' ' -)
}

show_net_summary() {
    info "网络接口 : $NET_IFACE  IP: ${NET_IP:-未知}/${NET_PREFIX:-24}  网关: ${NET_GW:-未知}  DNS: ${NET_DNS:-未知}"
}
# ============================================================================
# 系统目录
#   名称|distro|版本|支持环境|最少内存MB|最少磁盘MB(装好后占用)|说明
# ============================================================================
RULE_NOTE='
各系统硬件需求对照表 (超过推荐值体验更佳):
┌───────────────────────────┬─────────┬─────────┬──────────────────────────────┐
│ 系统                      │ 最低内存│ 最低磁盘│ 备注                         │
├───────────────────────────┼─────────┼─────────┼──────────────────────────────┤
│ Alpine 3.x/edge (容器)    │  128 MB │  500 MB │ 最轻量, busybox 生态, 小内存首选 │
│ Debian 12/13 (最简安装)   │  384 MB │ 1500 MB │ KVM 上安装时 d-i 需 ~300MB 内存 │
│ Debian 12/13 (标准)       │  512 MB │ 2000 MB │ 标准 taskset, 稳定通用       │
│ Ubuntu 20.04 (KVM 自动)   │  512 MB │ 4000 MB │ Ubuntu 仅 20.04 支持 KVM 一键装 │
│ Ubuntu 22.04/24.04 (LXC)  │  512 MB │ 2000 MB │ LXC rootfs 安装              │
│ Rocky/Alma 8/9/10 (LXC)   │  512 MB │ 2000 MB │ 企业生态 (RHEL 兼容)          │
│ CentOS Stream 9/10 (LXC)  │  512 MB │ 2000 MB │ 紧跟 RHEL 上游               │
│ Fedora 43/44 (LXC)        │  512 MB │ 2500 MB │ 软件最新                     │
│ openSUSE Leap/Tumb. (LXC) │  512 MB │ 2000 MB │ SUSE 生态                   │
│ Arch current (LXC)        │  256 MB │ 1500 MB │ 滚动更新, 追求最新           │
│ Debian 10/11 (KVM+LXC)    │  384 MB │ 1500 MB │ 老机器/兼容场景              │
└───────────────────────────┴─────────┴─────────┴──────────────────────────────┘
提示: install 时安装器本身比装好后的系统更吃内存 (d-i 约 300~500MB)。
推荐逻辑:  <384MB → Alpine(LXC);  <1GB → Debian 最简;  ≥1GB → Debian 13 / Ubuntu LTS。
'

# 系统明细 (会被菜单过滤: 不支持当前环境/资源不足的会标注并给出推荐)
CATALOG='
Debian 13 (trixie) 最新稳定|debian|trixie|l,k|384|1800|推荐: 资源占用低且软件新
Debian 12 (bookworm) 经典稳定|debian|bookworm|l,k|384|1800|推荐: 兼容性最好, 小内存首选
Debian 11 (bullseye) 老稳定|debian|bullseye|l,k|384|1800|老项目兼容
Debian 10 (buster) EOL|debian|buster|k|384|1600|已 EOL, KVM 存档源可用 (慢)
Ubuntu 24.04 (noble) LTS|ubuntu|noble|l|512|2200|生态最好, 仅 LXC
Ubuntu 22.04 (jammy) LTS|ubuntu|jammy|l|512|2200|仅 LXC
Ubuntu 20.04 (focal)|ubuntu|focal|l,k|512|3600|唯一支持 KVM 一键装的 Ubuntu
Alpine 3.24 (LXC) 极轻量|alpine|3.24|l|128|800|最轻量, busybox
Alpine 3.23 (LXC) 极轻量|alpine|3.23|l|128|800|最轻量
Alpine edge (LXC) 极轻量滚动|alpine|edge|l|128|800|滚动版, 不建议生产
Rocky Linux 10 (LXC)|rocky|10|l|512|2200|RHEL 兼容
Rocky Linux 9 (LXC)|rocky|9|l|512|2200|RHEL 兼容
AlmaLinux 10 (LXC)|alma|10|l|512|2200|RHEL 兼容
AlmaLinux 9 (LXC)|alma|9|l|512|2200|RHEL 兼容
CentOS Stream 10 (LXC)|centos|10-Stream|l|512|2200|RHEL 上游
CentOS Stream 9 (LXC)|centos|9-Stream|l|512|2200|RHEL 上游
Fedora 44 (LXC)|fedora|44|l|512|2600|最先进
Fedora 43 (LXC)|fedora|43|l|512|2600|较新
openSUSE Tumbleweed (LXC)|opensuse|tumbleweed|l|512|2400|滚动更新
openSUSE Leap 16.0 (LXC)|opensuse|16.0|l|512|2000|SUSE 企业同步
Arch Linux (LXC)|arch|current|l|256|1600|滚动更新
'

# 把 CATALOG 展开成可选菜单文件; 过滤当前环境; 标注内存/磁盘不足
build_distro_menu() { # build_distro_menu <输出文件> <环境过滤: k|l|空=全部> <是否只显示轻量>
    # 输出两个文件: <out> 为 "编号|展示文本", <out>.map 为 "编号|label|distro|release|minram|mindisk"
    local out=$1 flt=$2 light=${3:-0}
    : >"$out"; : >"$out.map"
    local label distro release envs minram mindisk note n=0 hint=""
    while IFS='|' read -r label distro release envs minram mindisk note; do
        [ -z "$label" ] && continue
        if [ -n "$flt" ]; then
            case ",$envs," in *",$flt,"*) ;; *) continue ;; esac
        fi
        if [ "$light" = 1 ]; then
            case $distro in alpine|debian) ;; *) continue ;; esac
        fi
        hint=""
        # 资源校验 (KVM 额外要求安装期内存 >= 最低内存 - 表中已含)
        if [ "$RAM_MB" -lt "$minram" ]; then
            hint=" ${CR}内存不足(需${minram}MB)$C0"
        elif [ "$DISK_AVAIL_MB" -lt "$mindisk" ]; then
            hint=" ${CR}磁盘空间不足(需~$((mindisk/1024))GB)$C0"
        fi
        n=$((n + 1))
        printf '%d|%s  [%s %s]  RAM>%sM 磁盘>%sM  %s%s\n' \
            "$n" "$label" "$distro" "$release" "$minram" "$mindisk" "$note" "$hint" >>"$out"
        printf '%d|%s|%s|%s|%s|%s\n' \
            "$n" "$label" "$distro" "$release" "$minram" "$mindisk" >>"$out.map"
    done <<<"$CATALOG"
}

# 按当前硬件给出智能推荐 (输出推荐说明)
recommend() {
    local rec_body=''
    if [ "$VIRT" = lxc ] && [ "$RAM_MB" -lt 384 ]; then
        rec_body="Alpine 3.23/3.24 —— 你的内存较小, Alpine 运行时仅需几十 MB 内存"
    elif [ "$RAM_MB" -lt 512 ]; then
        rec_body="Debian 12 最简安装 + swap —— 小内存里生态最全, 运行稳"
    elif [ "$RAM_MB" -lt 1024 ]; then
        rec_body="Debian 13 (trixie) —— 稳定通用, 1GB 内存可顺畅运行"
    else
        if [ "$VIRT" = lxc ]; then
            rec_body="Ubuntu 24.04 LTS —— 生态最好, 适合跑应用; 或 Debian 13 更轻量省内存"
        else
            rec_body="Debian 13 (trixie) / Ubuntu 20.04 —— KVM 下一键全自动, Debian 更轻"
        fi
    fi
    [ "$DISK_AVAIL_MB" -lt 1200 ] && rec_body="Alpine —— 你的磁盘空间不足 1.2GB, 只有 Alpine 等极轻量系统能装下"
    info "智能推荐: $rec_body"
}

# ---------------------------------------------------------------- 选项收集
OPT_PASS= OPT_HASH= OPT_PORT=22 OPT_TZ= OPT_SWAP=auto OPT_KEEPKEY=1
OPT_NET_MODE=dhcp OPT_MIRROR=official OPT_KVMTASK=minimal OPT_MIRROR_URL=

ask_options() {
    local choice of mir_label task_label keepkey_label net_label envname
    while :; do
        case $OPT_MIRROR in
            official) mir_label="官方源" ;;
            tuna)     mir_label="TUNA(大陆加速)" ;;
            aliyun)   mir_label="Aliyun(大陆加速)" ;;
            custom)   mir_label="自定义 ${OPT_MIRROR_URL:-未填写URL}" ;;
            *)        mir_label="$OPT_MIRROR" ;;
        esac
        if [ "$OPT_NET_MODE" = dhcp ]; then net_label="DHCP 自动获取"; else net_label="静态IP(沿用当前配置)"; fi
        if [ "$OPT_KVMTASK" = minimal ]; then task_label="最小化(仅ssh)"; else task_label="标准(含常用工具)"; fi
        if [ "$OPT_KEEPKEY" = 1 ]; then keepkey_label="是"; else keepkey_label="否"; fi
        [ "$VIRT" = lxc ] && envname=LXC || envname=KVM
        of=$(mktemp)
        {
            printf '1|root 密码        : %s%s%s\n' "$CY" "${OPT_PASS:-未设置(将随机生成)}" "$C0"
            printf '2|SSH 端口         : %s\n' "$OPT_PORT"
            printf '3|安装源           : %s\n' "$mir_label"
            printf '4|网络             : %s\n' "$net_label"
            printf '5|时区             : %s\n' "${OPT_TZ:-跟随当前(未知则UTC)}"
            printf '6|swap 大小        : %s (KVM)\n' "$OPT_SWAP"
            printf '7|安装任务         : %s (KVM)\n' "$task_label"
            printf '8|保留原SSH公钥    : %s (LXC)\n' "$keepkey_label"
            printf 's|—————— 开始安装 ——————\n'
        } >"$of"
        pick "安装选项 (当前: $envname)" "$of" || { rm -f "$of"; return 9; }
        rm -f "$of"
        choice=$MENU_RESULT
        case $choice in
            1) local p1 p2
               while :; do
                   ask p1 "请输入 root 密码 (留空则用随机密码)" ""
                   if [ -z "$p1" ]; then
                       OPT_PASS=$(mkstr_random 14)
                       info "已生成随机密码: $OPT_PASS"
                       break
                   fi
                   ask p2 "再输入一次以确认"
                   [ "$p1" = "$p2" ] && { OPT_PASS=$p1; break; }
                   warn "两次输入不一致, 请重新输入"
               done ;;
            2) ask OPT_PORT "SSH 端口" "$OPT_PORT"; case $OPT_PORT in ''|*[!0-9]*) OPT_PORT=22 ;; esac
               [ "$OPT_PORT" -lt 1 ] || [ "$OPT_PORT" -gt 65535 ] && OPT_PORT=22 ;;
            3) local mf; mf=$(mktemp)
               cat >"$mf" <<'EOF'
1|官方原图 (默认, 国外机器推荐)
2|TUNA 清华 (大陆机器推荐)
3|Aliyun 阿里云 (大陆机器推荐)
4|自定义镜像 (输入 URL)
EOF
               pick "选择安装源" "$mf" || { rm -f "$mf"; continue; }
               rm -f "$mf"
               case $MENU_RESULT in
                   1) OPT_MIRROR=official ;;
                   2) OPT_MIRROR=tuna ;;
                   3) OPT_MIRROR=aliyun ;;
                   4) local mu
                      ask mu "请输入镜像 base URL (如 https://mirrors.example.com/debian)" "${OPT_MIRROR_URL:-https://}"
                      case $mu in
                          https://*|http://*) OPT_MIRROR=custom; OPT_MIRROR_URL=${mu%/} ;;
                          *) warn "无效 URL, 已回退官方源"; OPT_MIRROR=official; OPT_MIRROR_URL= ;;
                      esac ;;
               esac ;;
            4) local nf; nf=$(mktemp)
               cat >"$nf" <<'EOF'
1|DHCP 自动获取 (推荐, 通用)
2|静态 IP (使用当前网络配置: 断网重装后同机房才适用)
EOF
               pick "网络配置" "$nf" || { rm -f "$nf"; continue; }
               rm -f "$nf"
               OPT_NET_MODE=dhcp; [ "$MENU_RESULT" = 2 ] && OPT_NET_MODE=static ;;
            5) local tzs
               ask tzs "时区 (如 Asia/Shanghai / UTC)" "$([ -n "${OPT_TZ:-}" ] && echo "$OPT_TZ" || echo Asia/Shanghai)"
               OPT_TZ=$tzs ;;
            6) if [ "$VIRT" = lxc ]; then warn "LXC 容器不适用 swap 选项"; else
                   local sw
                   ask sw "swap 大小 MB (0=禁用, auto=自动)" "$OPT_SWAP"
                   OPT_SWAP=$sw
               fi ;;
            7) [ "$VIRT" = lxc ] && { warn "仅 KVM 适用"; continue; }
               local tf; tf=$(mktemp)
               printf '1|最小化安装 (只装 ssh, 磁盘省, 小内存推荐)\n2|标准安装 (含常用工具集, 通用)\n' >"$tf"
               pick "Debian/Ubuntu 安装任务" "$tf" || { rm -f "$tf"; continue; }
               rm -f "$tf"; OPT_KVMTASK=$([ "$MENU_RESULT" = 1 ] && echo minimal || echo standard) ;;
            8) [ "$OPT_KEEPKEY" = 1 ] && OPT_KEEPKEY=0 || OPT_KEEPKEY=1 ;;
            s|S) return 0 ;;
            *) warn "无效编号: $choice" ;;
        esac
    done
}

# 生成密码 & 哈希
mkstr_random() { # 随机字符串
    local len=$1 s
    if command -v openssl >/dev/null 2>&1; then s=$(openssl rand -base64 $(( len * 2 )) | tr -dc 'A-Za-z0-9' | head -c "$len")
    elif command -v python3 >/dev/null 2>&1; then s=$(python3 -c "import random,string;print(''.join(random.choice(string.ascii_letters+string.digits) for _ in range($len)))")
    else s=$(date +%s%N | md5sum 2>/dev/null | tr -dc 'a-f0-9' | head -c "$len"); fi
    [ -n "${s:-}" ] || s=dbus_random_fallback
    printf '%s' "$s"
}

gen_pw_hash() { # 输出 SHA512 crypt hash
    local pw=$1 h=""
    if command -v openssl >/dev/null 2>&1; then
        h=$(openssl passwd -6 "$pw" 2>/dev/null)
    fi
    if [ -z "$h" ] && command -v python3 >/dev/null 2>&1; then
        h=$(python3 -c "import crypt;print(crypt.crypt('''$pw''', crypt.mksalt(crypt.METHOD_SHA512)))" 2>/dev/null)
    fi
    if [ -z "$h" ] && command -v busybox >/dev/null 2>&1; then
        h=$(busybox cryptpw -m sha512 "$pw" 2>/dev/null)
    fi
    [ -n "$h" ] || die "无法生成密码哈希, 请安装 openssl 后重试"
    printf '%s' "$h"
}
# ============================================================================
# KVM 安装引擎: netboot 内核 + initrd 内嵌 preseed + GRUB 一次性引导项
# ============================================================================
KVM_CODENAME= KVM_MIRROR= KVM_DISTRO= KVM_RELEASE= MAIN_DISK=
GRUB_CFG= GRUB_CFG_BAK= KVM_VMLINUZ_PATH= KVM_INITRD_PATH=

detect_main_disk() {
    local cand="" d
    for d in /sys/block/*; do
        d=${d##*/}
        case $d in loop*|ram*|fd*|zram*|sr*|dm-*|md*) continue ;; esac
        cand="$cand $d"
    done
    [ -z "$cand" ] && die "未找到可用磁盘"
    if echo "$cand" | grep -qw vda; then MAIN_DISK=/dev/vda
    elif echo "$cand" | grep -qw sda; then MAIN_DISK=/dev/sda
    elif echo "$cand" | grep -qw xvda; then MAIN_DISK=/dev/xvda
    elif echo "$cand" | grep -qw nvme0n1; then MAIN_DISK=/dev/nvme0n1
    else MAIN_DISK="/dev/$(echo $cand | awk '{print $1}')"
    fi
    warn "安装目标磁盘: $MAIN_DISK (整盘数据将被清空!)"
}

kvm_resolve_mirror() { # 设置 KVM_MIRROR (镜像站 base, 如 https://deb.debian.org/debian)
    case $OPT_MIRROR in
        official) if [ "$KVM_DISTRO" = debian ]; then KVM_MIRROR=https://deb.debian.org/debian
                  else KVM_MIRROR=http://archive.ubuntu.com/ubuntu; fi ;;
        tuna)     KVM_MIRROR=https://mirrors.tuna.tsinghua.edu.cn/$KVM_DISTRO ;;
        aliyun)   KVM_MIRROR=https://mirrors.aliyun.com/$KVM_DISTRO ;;
        custom)   KVM_MIRROR=$OPT_MIRROR_URL ;;
        *) KVM_MIRROR= ;;
    esac
}

# 依次探测 [自动镜像, 官方, 存档], 返回第一个可用 URL
kvm_pick_netboot_url() {
    local kind=$1  # kernel | initrd
    local fname= archdir= p rel= relpath= try_m tryu
    if [ "$KVM_DISTRO" = debian ]; then
        fname=$([ "$kind" = kernel ] && echo linux || echo initrd.gz)
        archdir=debian-installer/$ARCH_IMG
    else
        fname=$([ "$kind" = kernel ] && echo linux || echo initrd.gz)
        archdir=ubuntu-installer/$ARCH_IMG
    fi
    local sub="dists/$KVM_CODENAME/main/installer-$ARCH_IMG/current/images/netboot/$archdir"
    # Ubuntu 20.04 用 legacy-images 路径
    if [ "$KVM_DISTRO" = ubuntu ]; then
        sub="dists/focal/main/installer-$ARCH_IMG/current/legacy-images/netboot/$archdir"
    fi
    local -a bases=()
    [ -n "$KVM_MIRROR" ] && bases+=("$KVM_MIRROR")
    if [ "$KVM_DISTRO" = debian ]; then
        bases+=(https://deb.debian.org/debian)
        if [ "$KVM_CODENAME" = buster ]; then bases+=(http://archive.debian.org/debian); fi
    else
        bases+=(http://archive.ubuntu.com/ubuntu)
    fi
    for try_m in "${bases[@]}"; do
        tryu="$try_m/$sub/$fname"
        if curl -fsSI --connect-timeout 10 --max-time 30 "$tryu" >/dev/null 2>&1; then
            KVM_MIRROR=$try_m
            printf '%s' "$tryu"
            return 0
        fi
    done
    return 1
}

kvm_write_preseed() { # 写 preseed 到 $1
    local f=$1
    local swap_max=${KVM_SWAP_MAX_VAL:-2048}
    # 保证 d-i 全程无交互, 关键问题全部预置
    cat >"$f" <<'PRESEED'
#_preseed_V1
### 全自动无人值守 preseed (由 reinstall-vm.sh 生成) ###
d-i debian-installer/locale string en_US.UTF-8
d-i keyboard-configuration/xkb-keymap select us
d-i netcfg/choose_interface select auto
d-i netcfg/get_hostname string unassigned-hostname
d-i netcfg/get_domain string unassigned-domain
d-i netcfg/hostname string %HOSTNAME%
d-i netcfg/disable_autoconfig boolean false
d-i hw-detect/load_firmware boolean true
d-i mirror/country string manual
d-i mirror/http/hostname string %MIRROR_HOST%
d-i mirror/http/directory string %MIRROR_DIR%
d-i mirror/http/proxy string
d-i passwd/make-user boolean false
d-i passwd/root-password-crypted password %PWHASH%
d-i clock-setup/utc boolean true
d-i time/zone string %TZ%
d-i clock-setup/ntp boolean true
d-i partman-auto/method string regular
d-i partman-auto/disk string %DISK%
d-i partman-auto/expert_recipe string boot-root :: 538 538 1075 free $iflabel{ gpt } $reusemethod{ } method{ efi } format{ } . 500 10000 1000000000 ext4 method{ format } format{ } use_filesystem{ } filesystem{ ext4 } mountpoint{ / } . 128 512 %SWAP_MAX% linux-swap method{ swap } format{ } .
d-i partman-lvm/device_remove_lvm boolean true
d-i partman-md/device_remove_md boolean true
d-i partman-partitioning/confirm_write_new_label boolean true
d-i partman/choose_partition select finish
d-i partman/confirm boolean true
d-i partman/confirm_nooverwrite boolean true
d-i partman/mount_style select uuid
d-i apt-setup/non-free-firmware boolean true
d-i grub-installer/only_debian boolean true
d-i grub-installer/with_other_os boolean true
d-i grub-installer/bootdev string %DISK%
d-i finish-install/reboot_in_progress note
PRESEED
    # 任务与附加包
    if [ "$OPT_KVMTASK" = minimal ]; then
        {
            printf 'd-i pkgsel/run_tasksel boolean false\n'
            printf 'd-i pkgsel/include string openssh-server ca-certificates\n'
        } >>"$f"
    else
        printf 'tasksel tasksel/first multiselect standard\n' >>"$f"
        printf 'd-i pkgsel/include string openssh-server ca-certificates\n' >>"$f"
    fi
    # 内核偏好
    if [ "$KVM_DISTRO" = debian ]; then
        printf 'd-i base-installer/kernel/image string linux-image-cloud-%s\n' "$ARCH_IMG" >>"$f"
    else
        printf 'd-i base-installer/kernel/image string linux-image-virtual\n' >>"$f"
    fi
    # 静态 IP / SSH 端口 / 非交互收尾
    if [ "$OPT_NET_MODE" = static ]; then
        {
            printf 'd-i netcfg/disable_autoconfig boolean true\n'
            printf 'd-i netcfg/get_ipaddress string %s\n' "$NET_IP"
            printf 'd-i netcfg/get_netmask string %s\n' "$NET_MASK"
            printf 'd-i netcfg/get_gateway string %s\n' "$NET_GW"
            printf 'd-i netcfg/get_nameservers string %s\n' "${NET_DNS:-8.8.8.8}"
            printf 'd-i netcfg/confirm_static boolean true\n'
        } >>"$f"
    fi
    if [ "$OPT_PORT" != 22 ]; then
        printf "d-i preseed/late_command string in-target sh -c 'echo Port %s >>/etc/ssh/sshd_config'\n" "$OPT_PORT" >>"$f"
    fi
    # 变量注入 (避免 heredoc 展开被特殊字符破坏)
    local mh md
    mh=$(printf '%s' "$KVM_MIRROR" | sed 's|^https\?://||; s|/.*||')
    md=/$(printf '%s' "$KVM_MIRROR" | sed 's|^https\?://[^/]*||' | sed 's|^/||; s|/$||')
    sed -i \
        -e "s|%HOSTNAME%|$HOSTNAME_OLD|" \
        -e "s|%MIRROR_HOST%|$mh|" \
        -e "s|%MIRROR_DIR%|$md|" \
        -e "s|%PWHASH%|$OPT_HASH|" \
        -e "s|%TZ%|${OPT_TZ:-UTC}|" \
        -e "s|%DISK%|$MAIN_DISK|" \
        -e "s|%SWAP_MAX%|$swap_max|" \
        "$f"
}

kvm_build_bootline() {
    local cons="console=ttyS0,115200n8 console=tty0"
    # 若当前系统内核参数里是串口优先, 则反过来 (串口交互)
    if grep -q 'console=ttyS0' /proc/cmdline 2>/dev/null; then
        cons="console=tty0 console=ttyS0,115200n8"
    fi
    printf '%s' "auto=true priority=critical locale=en_US.UTF-8 $cons"
}

kvm_write_grub() {
    # 确认 vmlinuz 与 /boot 分区关系, 决定 GRUB 里看到的路径
    local kpath ipath
    if [ "$(stat -c %D /boot 2>/dev/null)" = "$(stat -c %D / 2>/dev/null)" ]; then
        kpath=/boot/reinstall-vmlinuz
        ipath=/boot/reinstall-initrd
    else
        kpath=/reinstall-vmlinuz   # /boot 是独立分区, 文件就在该分区根
        ipath=/reinstall-initrd
    fi
    # 选择 grub.cfg: 优先"真实"配置文件
    local grub_cands="" grubdir
    [ -f /boot/grub2/grub.cfg ] && grub_cands="/boot/grub2/grub.cfg"
    [ -z "$grub_cands" ] && [ -f /boot/grub/grub.cfg ] && grub_cands="/boot/grub/grub.cfg"
    if [ -z "$grub_cands" ] && [ -d /boot/efi/EFI ]; then
        for grubdir in /boot/efi/EFI/*/; do
            [ -f "${grubdir}grub.cfg" ] && { grub_cands="${grubdir}grub.cfg"; break; }
        done
    fi
    [ -n "$grub_cands" ] || die "未找到 GRUB 配置文件 (grub.cfg)"
    GRUB_CFG=$grub_cands
    GRUB_CFG_BAK="$GRUB_CFG.reinstall.bak"
    cp -f "$GRUB_CFG" "$GRUB_CFG_BAK" || warn "GRUB 原配置备份失败"
    local extra_mod=""
    if grep -qs ' / btrfs' /proc/mounts; then
        extra_mod="set btrfs_relative_path=n"
    fi
    {
        printf '### 重装引导配置 (由 reinstall-vm.sh 生成; 原配置备份于 %s) ###\n' "$GRUB_CFG_BAK"
        [ -n "$extra_mod" ] && printf '%s\n' "$extra_mod"
        cat <<GRUBEOF
menuentry 'reinstall (linux one-key)' --unrestricted {
    insmod lvm
    insmod all_video
    search --no-floppy --file --set=root $kpath
    linux $kpath $KVM_CMDLINE
    initrd $ipath
    boot
}
GRUBEOF
    } >"$GRUB_CFG"
    sync
    ok "GRUB 启动项已写入: $GRUB_CFG"
}

kvm_install() {
    KVM_DISTRO=$DISTRO; KVM_RELEASE=$RELEASE
    # 版本 -> codename
    case $RELEASE in
        10) KVM_CODENAME=buster ;;
        11) KVM_CODENAME=bullseye ;;
        12) KVM_CODENAME=bookworm ;;
        13) KVM_CODENAME=trixie ;;
        *) KVM_CODENAME=$RELEASE ;;
    esac
    if [ "$KVM_DISTRO" = ubuntu ] && [ "$RELEASE" != focal ]; then
        die "Ubuntu 在 KVM 上目前只支持 20.04 (focal)。22.04+ 请选择 LXC 路线, 或手动安装。"
    fi
    kvm_resolve_mirror
    [ -n "$KVM_MIRROR" ] || die "镜像未配置"
    detect_main_disk
    require_cmd cpio cpio
    require_cmd gzip gzip
    # swap 上限
    case $OPT_SWAP in
        auto) if [ "$RAM_MB" -le 1024 ]; then KVM_SWAP_MAX_VAL=$RAM_MB; else KVM_SWAP_MAX_VAL=2048; fi ;;
        0)    KVM_SWAP_MAX_VAL=0 ;;
        *)    KVM_SWAP_MAX_VAL=$OPT_SWAP ;;
    esac
    # 下载 netboot 内核
    info "获取 $KVM_DISTRO $RELEASE 安装器内核..."
    local ukernel uinitrd
    ukernel=$(kvm_pick_netboot_url kernel) || die "找不到 netboot 内核 (检查镜像/网络)"
    uinitrd=$(kvm_pick_netboot_url initrd) || die "找不到 netboot initrd"
    ok "使用安装源: $KVM_MIRROR"
    curl -fsSL --retry 3 --connect-timeout 15 -o /boot/reinstall-vmlinuz "$ukernel" || die "内核下载失败"
    curl -fsSL --retry 3 --connect-timeout 15 -o /boot/reinstall-initrd-orig.gz "$uinitrd" || die "initrd 下载失败"
    # 生成 preseed
    local seed=/root/.reinstall-preseed.cfg
    OPT_PORT=${OPT_PORT:-22}
    kvm_write_preseed "$seed"
    # 重建 initrd 并内嵌 preseed.cfg (d-i 会自动读取 initramfs 根目录的 /preseed.cfg)
    local workdir=/root/.reinstall-initrd-work
    rm -rf "$workdir"; mkdir -p "$workdir"
    ( cd "$workdir" && zcat /boot/reinstall-initrd-orig.gz | cpio -idm --quiet 2>/dev/null ) \
        || { rm -rf "$workdir"; die "initrd 解压失败 (非 gzip? 请反馈)"; }
    cp "$seed" "$workdir/preseed.cfg"
    ( cd "$workdir" && find . 2>/dev/null | cpio -o -H newc -R 0:0 --quiet 2>/dev/null | gzip -1 ) \
        > /boot/reinstall-initrd || { rm -rf "$workdir"; die "initrd 重建失败"; }
    rm -rf "$workdir" "$seed" /boot/reinstall-initrd-orig.gz
    sync
    [ -s /boot/reinstall-initrd ] || die "initrd 重建产物为空"
    ok "initrd 重建完成 (内嵌 preseed, 无需外部服务器)"
    KVM_CMDLINE=$(kvm_build_bootline)
    # 写 GRUB 引导项 (作为主引导方式; 装完由新系统自动重写自己的 GRUB)
    kvm_write_grub
    info "引导方式: GRUB 一次性引导项 (重启后自动进入安装器)"
    printf '\n%s重装即将开始, 安装约 5~15 分钟 (全自动, 装完自动重启进新系统)%s\n' "$CY" "$C0"
    printf  '%s登录信息%s  root / 你设置的密码 (SSH 端口 %s)\n' "$CB" "$C0" "$OPT_PORT"
    printf  '%s控制台%s  可在服务商 VNC / 串口观察安装进度\n' "$CB" "$C0"
    printf  '%s放弃方法%s  删除 %s 后按原配置启动即可\n' "$CB" "$C0" "$GRUB_CFG"
    confirm "确认现在重启开始重装?" || { warn "已取消。引导项已写入, 下次重启会直接进入安装器; 请先恢复 $GRUB_CFG_BAK 再重启!"; exit 0; }
    sync
    exec reboot -f
}
# ============================================================================
# LXC 安装引擎: 官方 rootfs.tar.xz 原位替换
# ============================================================================
LXC_BASE=      # 镜像站 base URL (含 /images)
TARBALL=/reinstall-rootfs.tar.xz
LXC_TS=

lxc_resolve_base() {
    local distro=$1
    case $OPT_MIRROR in
        tuna)     LXC_BASE=https://mirrors.tuna.tsinghua.edu.cn/lxc-images/images/$distro ;;
        aliyun)   warn "该镜像站暂无 LXC rootfs 镜像, 已回退官方源"
                  LXC_BASE=https://images.linuxcontainers.org/images/$distro ;;
        custom)   LXC_BASE=${OPT_MIRROR_URL%/}/images/$distro ;;
        *)        LXC_BASE=https://images.linuxcontainers.org/images/$distro ;;
    esac
}

lxc_pick_tarball() { # 输出所选 release 的 rootfs 下载 URL
    local html ts_list newest url
    html=$(curl -fsSL --connect-timeout 15 --max-time 60 "$LXC_BASE/$RELEASE/$ARCH_LXC/default/" 2>/dev/null) \
        || { err "无法访问镜像目录: $LXC_BASE/$RELEASE/$ARCH_LXC/default/"; return 1; }
    ts_list=$(printf '%s' "$html" | grep -oE '[0-9]{8}_[0-9]{2}:[0-9]{2}' | sort -u)
    newest=$(printf '%s\n' "$ts_list" | tail -1)
    [ -n "$newest" ] || { err "目录里没有可用版本"; return 1; }
    url="$LXC_BASE/$RELEASE/$ARCH_LXC/default/$newest/rootfs.tar.xz"
    if curl -fsSI --connect-timeout 10 --max-time 30 "$url" >/dev/null 2>&1; then
        printf '%s' "$url"
        return 0
    fi
    return 1
}

lxc_size_of() { curl -fsSI --connect-timeout 10 --max-time 30 "$1" | awk 'tolower($1)=="content-length:"{print $2}' | head -1; }

lxc_backup_essentials() {
    STASH=/reinstall-stash
    rm -rf "$STASH"; mkdir -p "$STASH"
    cp -f /etc/resolv.conf "$STASH/" 2>/dev/null
    cp -f /etc/localtime "$STASH/localtime" 2>/dev/null
    [ -f /etc/timezone ] && cat /etc/timezone >"$STASH/tzname" 2>/dev/null
    if [ "$OPT_KEEPKEY" = 1 ] && [ -f /root/.ssh/authorized_keys ]; then
        cp -f /root/.ssh/authorized_keys "$STASH/authorized_keys"
    fi
}

lxc_wipe_root() {
    warn "即将清空容器根文件系统 (保留挂载点与暂存文件)..."
    swapoff -a 2>/dev/null
    # 排除项: 挂载点 + 暂存文件 + tarball
    local keep=" / /proc /sys /dev /run /tmp $STASH $TARBALL" e mp
    while read -r _ mp _; do
        case $mp in /|/proc|/sys|/dev|/run|/tmp) : ;;
            /proc/*|/sys/*|/dev/*|/run/*) : ;;
            *) keep="$keep $mp" ;;
        esac
    done </proc/mounts
    local entries=()
    for e in /* /.*; do
        case $e in /.|/..) continue ;; esac
        [ -e "$e" ] || continue
        case "$keep " in *" $e "*) continue ;; esac
        entries+=("$e")
    done
    for e in "${entries[@]}"; do
        rm -rf "$e" 2>/dev/null
    done
    info "已清空旧系统"
}

lxc_extract_rootfs() {
    require_cmd xz xz
    require_cmd tar tar
    info "解包新系统 (rootfs.tar.xz) ..."
    tar -Jxf "$TARBALL" --numeric-owner --directory=/ 2>/dev/null \
        || { err "rootfs 解包失败! 容器当前可能处于不完整状态, 请检查控制台!"; exit 1; }
    rm -f "$TARBALL"
    sync
    ok "rootfs 解包完成"
}

lxc_family_of() {
    if   [ -f /etc/alpine-release ];   then echo alpine
    elif [ -f /etc/arch-release ];     then echo arch
    elif [ -f /etc/debian_version ];   then echo deb
    elif grep -qsE 'opensuse|sles' /etc/os-release 2>/dev/null; then echo suse
    elif [ -f /etc/redhat-release ];   then echo el
    else echo unknown
    fi
}

# 兼容 systemd/openrc 两种风格启用服务
lxc_enable_svc() {
    local root=/ unit=$1 rcname=$2
    local unitpath=""
    for d in usr/lib/systemd/system lib/systemd/system; do
        [ -f "$root/$d/$unit" ] && { unitpath="/$d/$unit"; break; }
    done
    if [ -n "$unitpath" ]; then
        mkdir -p "$root/etc/systemd/system/multi-user.target.wants"
        ln -sf "$unitpath" "$root/etc/systemd/system/multi-user.target.wants/$unit"
    else
        [ -f "$root/etc/init.d/$rcname" ] || return 1
        mkdir -p "$root/etc/runlevels/default"
        ln -sf "/etc/init.d/$rcname" "$root/etc/runlevels/default/$rcname"
    fi
}

# 手式写网络配置 (DHCP 默认; static 时写入静态)
lxc_write_net() {
    local root=/ family=$1
    # 已有内置配置则尊重原配置 (官方 LXC 镜像默认 DHCP 即可用), 静态时强制覆盖
    if [ "$OPT_NET_MODE" != static ]; then
        case $family in
            deb)
                if [ -s "$root/etc/network/interfaces" ] || [ -n "$(find "$root/etc/network/interfaces.d" -type f 2>/dev/null | head -1)" ]; then return 0; fi ;;
        esac
    fi
    case $family in
        deb)
            mkdir -p "$root/etc/network/interfaces.d"
            rm -f "$root/etc/netplan"/*.yaml 2>/dev/null
            if [ "$OPT_NET_MODE" = static ]; then
                cat >"$root/etc/network/interfaces" <<EOF
auto lo
iface lo inet loopback

auto $NET_IFACE
iface $NET_IFACE inet static
    address $NET_IP/$NET_PREFIX
    gateway $NET_GW
    dns-nameservers ${NET_DNS:-8.8.8.8}
EOF
            else
                cat >"$root/etc/network/interfaces" <<EOF
auto lo
iface lo inet loopback

auto $NET_IFACE
iface $NET_IFACE inet dhcp
EOF
            fi
            [ "$OPT_NET_MODE" = static ] && touch "$root/etc/cloud/cloud-init.disabled" ;;
        alpine)
            if [ "$OPT_NET_MODE" = static ]; then
                cat >"$root/etc/network/interfaces" <<EOF
auto lo
iface lo inet loopback

auto $NET_IFACE
iface $NET_IFACE inet static
    address $NET_IP
    netmask $NET_MASK
    gateway $NET_GW
EOF
            else
                cat >"$root/etc/network/interfaces" <<EOF
auto lo
iface lo inet loopback

auto $NET_IFACE
iface $NET_IFACE inet dhcp
EOF
            fi
            ;&
        *)
            # systemd-networkd 通用写法
            if [ -d "$root/etc/systemd/network" ]; then
                if [ "$OPT_NET_MODE" = static ]; then
                    cat >"$root/etc/systemd/network/20-reinstall.network" <<EOF
[Match]
Name=$NET_IFACE

[Network]
Address=$NET_IP/$NET_PREFIX
Gateway=$NET_GW
DNS=${NET_DNS%% *}
EOF
                else
                    cat >"$root/etc/systemd/network/20-reinstall.network" <<EOF
[Match]
Name=$NET_IFACE

[Network]
DHCP=yes
EOF
                fi
                lxc_enable_svc "$root" systemd-networkd.service systemd-networkd
            fi
            ;;
    esac
    # netplan (Ubuntu 官方镜像)
    if [ -d "$root/etc/netplan" ] && [ ! -d "$root/etc/netplan_disabled" ]; then
        if [ "$OPT_NET_MODE" = static ]; then
            cat >"$root/etc/netplan/99-reinstall.yaml" <<EOF
network:
  version: 2
  ethernets:
    $NET_IFACE:
      dhcp4: false
      addresses: [$NET_IP/$NET_PREFIX]
      routes:
        - to: default
          via: $NET_GW
      nameservers:
        addresses: [$(echo ${NET_DNS:-8.8.8.8} | tr ' ' ',')]
EOF
        else
            cat >"$root/etc/netplan/99-reinstall.yaml" <<EOF
network:
  version: 2
  ethernets:
    $NET_IFACE:
      dhcp4: true
EOF
        fi
        chmod 600 "$root/etc/netplan/99-reinstall.yaml"
        [ "$OPT_NET_MODE" = static ] && touch "$root/etc/cloud/cloud-init.disabled"
    fi
    # RHEL 系 ifcfg
    if [ -d "$root/etc/sysconfig/network-scripts" ]; then
        if [ "$OPT_NET_MODE" = static ]; then
            cat >"$root/etc/sysconfig/network-scripts/ifcfg-$NET_IFACE" <<EOF
TYPE=Ethernet
BOOTPROTO=none
NAME=$NET_IFACE
DEVICE=$NET_IFACE
ONBOOT=yes
IPADDR=$NET_IP
PREFIX=$NET_PREFIX
GATEWAY=$NET_GW
DNS1=${NET_DNS%% *}
EOF
        else
            cat >"$root/etc/sysconfig/network-scripts/ifcfg-$NET_IFACE" <<EOF
TYPE=Ethernet
BOOTPROTO=dhcp
NAME=$NET_IFACE
DEVICE=$NET_IFACE
ONBOOT=yes
EOF
        fi
    fi
}
# rootfs 原位替换后, 新系统的文件就是当前容器根目录的内容;
# /proc /dev /sys 挂载依然有效, 因此直接执行新系统的包管理器即可 (无需 chroot)
lxc_install_sshd() {
    local family=$1 cmd
    case $family in
        deb)    cmd="DEBIAN_FRONTEND=noninteractive sh -c 'apt-get update -qq && apt-get install -y --no-install-recommends openssh-server'" ;;
        el)     cmd="sh -c 'dnf -y install openssh-server 2>/dev/null || yum -y install openssh-server'" ;;
        suse)   cmd="sh -c 'zypper --non-interactive install openssh'" ;;
        arch)   cmd="sh -c 'pacman -Sy --noconfirm openssh'" ;;
        alpine) cmd="sh -c 'apk add --no-cache openssh'" ;;
    esac
    info "新系统缺少 sshd, 尝试直接安装 (rootfs 挂载环境可直接使用新系统的包管理)..."
    if sh -c "$cmd" 2>/dev/null; then
        ok "openssh-server 安装成功"
        return 0
    fi
    warn "自动安装失败 —— 装好后请通过服务商『容器控制台』进入并手动安装 openssh-server。"
    return 1
}

lxc_post_config() {
    local family=$(lxc_family_of)
    local root=/ unit
    # 主机名 & hosts
    printf '%s\n' "$HOSTNAME_OLD" >"$root/etc/hostname" 2>/dev/null
    {
        printf '127.0.0.1\tlocalhost\n'
        [ -n "$NET_IP" ] && printf '%s\t%s\n' "$NET_IP" "$HOSTNAME_OLD"
        printf '::1\tlocalhost ip6-localhost ip6-loopback\n'
    } >"$root/etc/hosts" 2>/dev/null
    # DNS
    rm -f "$root/etc/resolv.conf"
    printf 'nameserver %s\nnameserver %s\n' \
        $([ -n "${NET_DNS%% *}" ] && echo ${NET_DNS%% *} || echo 8.8.8.8) \
        $([ -n "${NET_DNS#* }" ] && echo ${NET_DNS#* } || echo 1.1.1.1) \
        >"$root/etc/resolv.conf" 2>/dev/null
    # 时区
    if [ -f "$STASH/localtime" ]; then
        cp -f "$STASH/localtime" "$root/etc/localtime" 2>/dev/null
        [ -f "$STASH/tzname" ] && cp -f "$STASH/tzname" "$root/etc/timezone" 2>/dev/null
    fi
    # 公钥
    if [ "$OPT_KEEPKEY" = 1 ] && [ -s "$STASH/authorized_keys" ]; then
        mkdir -p "$root/root/.ssh"
        chmod 700 "$root/root/.ssh" 2>/dev/null
        cp -f "$STASH/authorized_keys" "$root/root/.ssh/authorized_keys"
        chmod 600 "$root/root/.ssh/authorized_keys" 2>/dev/null
        info "已保留原 SSH 公钥"
    fi
    # root 密码 (直接改 /etc/shadow)
    if [ -f "$root/etc/shadow" ]; then
        awk -v h="$OPT_HASH" 'BEGIN{FS=OFS=":"} $1=="root"{$2=h} {print}' \
            "$root/etc/shadow" >"$root/etc/shadow.new" 2>/dev/null \
            && mv "$root/etc/shadow.new" "$root/etc/shadow" \
            && chmod 600 "$root/etc/shadow"
    fi
    # 网络
    lxc_write_net "$family"
    # SSH
    if [ ! -e "$root/usr/sbin/sshd" ]; then
        lxc_install_sshd "$family"
    fi
    if [ -e "$root/usr/sbin/sshd" ]; then
        # 覆盖 root 登录/密码认证/端口
        local dropdir="$root/etc/ssh/sshd_config.d"
        local cfgcontent="PermitRootLogin yes\nPasswordAuthentication yes\n"
        [ "$OPT_PORT" != 22 ] && cfgcontent="Port $OPT_PORT\n$cfgcontent"
        if [ -d "$dropdir" ]; then
            printf "$cfgcontent" >"$dropdir/99-reinstall.conf"
        else
            sed -i -E 's/^[#[:space:]]*(PermitRootLogin|PasswordAuthentication|Port)[[:space:]].*//' \
                "$root/etc/ssh/sshd_config" 2>/dev/null
            printf "$cfgcontent" >>"$root/etc/ssh/sshd_config"
        fi
        # 启用服务 (Debian 系: ssh.service; 其他家: sshd.service)
        unit=ssh.service
        [ -f "$root/usr/lib/systemd/system/sshd.service" ] && ! [ -f "$root/usr/lib/systemd/system/ssh.service" ] && unit=sshd.service
        lxc_enable_svc "$root" "$unit" sshd
        ok "已配置 SSH (root 密码可登录, 端口 $OPT_PORT)"
    else
        warn "新系统似乎没有 sshd —— 稍后请通过服务商『容器控制台』进入手动安装 openssh-server。"
    fi
}

lxc_summary_and_done() {
    ok "重装完成! 新系统: $DISTRO $RELEASE"
    printf '%s登录方式%s: ssh root@%s  端口 %s  密码: %s\n' "$CB" "$C0" "$NET_IP" "$OPT_PORT" "$OPT_PASS"
    printf '%s重启方式%s: 部分服务商面板重启才生效; 也可在控制台执行 reboot\n' "$CB" "$C0"
    if ! confirm "现在尝试重启容器?" ; then
        info "请稍后自行通过服务商面板重启容器。"
        exit 0
    fi
    sync
    reboot 2>/dev/null || { warn "容器内 reboot 被限制, 请通过服务商面板重启。"; exit 0; }
}

lxc_install() {
    LXC_DISTRO=$DISTRO; LXC_RELEASE=$RELEASE
    lxc_resolve_base "$DISTRO"
    require_cmd xz xz
    require_cmd tar tar
    info "获取 rootfs 下载地址..."
    local u
    u=$(lxc_pick_tarball) || die "未找到 $LXC_BASE/$RELEASE/$ARCH_LXC/default 下的 rootfs, 请换镜像源或版本"
    local sz
    sz=$(lxc_size_of "$u")
    [ -n "$sz" ] || sz=0
    local est=$(( sz / 1048576 + 100 ))
    local need=$(( est * 4 + 500 ))
    if [ "$DISK_AVAIL_MB" -lt "$need" ]; then
        die "磁盘空间不足: rootfs 压缩包 ~${est}MB, 解压后需 ~$((need/1024*2))GB 级空间 (建议可用 ≥${need}MB, 当前 ${DISK_AVAIL_MB}MB)"
    fi
    printf '%s下载地址: %s  (压缩包约 %sMB)\n' "$CY" "$u" "$est"
    info "下载 rootfs..."
    if ! curl -fL --retry 3 --progress-bar -o "$TARBALL" "$u"; then
        rm -f "$TARBALL"; die "rootfs 下载失败"
    fi
    [ -s "$TARBALL" ] || die "下载产物为空"
    ok "下载完成 ($(du -sm "$TARBALL" | awk '{print $1}')MB)"
    lxc_backup_essentials
    printf '\n%s最终确认%s  即将清空容器全部数据并安装 %s %s !\n' "$CB" "$C0" "$DISTRO" "$RELEASE"
    printf '%s输入大写 RM-ALL 确认 (输入 yes 亦可):%s ' "$CY" "$C0"
    local reply
    read -r reply
    case $reply in
        yes|RM-ALL) : ;;
        *) warn "已取消, 未做任何修改"; rm -f "$TARBALL"; rm -rf "$STASH"; exit 0 ;;
    esac
    lxc_wipe_root
    lxc_extract_rootfs
    lxc_post_config
    lxc_summary_and_done
}
# ============================================================================
# 主流程
# ============================================================================
DISTRO= RELEASE= RELEASE_LABEL=

choose_system() {
    local envflag=$VIRT; [ "$VIRT" = kvm ] && envflag=k || envflag=l
    local cf
    cf=$(mktemp)
    while :; do
        recommend
        show_hw_summary; show_net_summary
        build_distro_menu "$cf" "$envflag" 0
        if [ ! -s "$cf" ]; then
            rm -f "$cf" "$cf.map"
            die "当前环境/资源没有可选系统 (内存或磁盘过小)"
        fi
        pick "选择要重装的系统 (当前为 $( [ $VIRT = lxc ] && echo 'LXC 容器' || echo 'KVM 虚拟机' ))" "$cf" || { rm -f "$cf" "$cf.map"; return 9; }
        local sel=$MENU_RESULT n label distro release minram mindisk found=0
        if [ -f "$cf.map" ]; then
            while IFS='|' read -r n label distro release minram mindisk; do
                [ "$n" = "$sel" ] || continue
                DISTRO=$distro; RELEASE=$release; RELEASE_LABEL=$label
                [ "$RAM_MB" -lt "$minram" ] && { warn "内存 $RAM_MB MB 低于该系统最低要求 $minram MB, 强行安装可能失败!"; }
                [ "$DISK_AVAIL_MB" -lt "$mindisk" ] && { warn "磁盘可用 $DISK_AVAIL_MB MB 低于该系统最低要求约 $mindisk MB, 强行安装可能失败!"; }
                found=1
                break
            done <"$cf.map"
        fi
        rm -f "$cf" "$cf.map"
        [ "$found" = 1 ] && return 0
        warn "无效选择"
    done
}

first_install_check() {
    need_root
    [ -t 0 ] || warn "当前似乎在非交互终端运行, 菜单可能无法输入 (请通过 SSH 登录使用)"
    require_cmd curl curl
    require_cmd xz xz
    require_cmd tar tar
}

show_install_summary() {
    printf '\n%s=================== 重装计划摘要 ===================%s\n' "$CM" "$C0"
    if [ "$VIRT" = lxc ]; then
        printf '  模式        | LXC 容器 (rootfs 原位替换)\n'
        printf '  安装源      | %s\n' "${LXC_BASE:-images.linuxcontainers.org (尚未解析)}"
    else
        printf '  模式        | KVM 虚拟机 (netboot + preseed + GRUB 引导)\n'
        printf '  安装源      | %s\n' "${KVM_MIRROR:-官方 (尚未解析)}"
    fi
    printf '  系统        | %s\n' "$RELEASE_LABEL"
    printf '  root 密码   | %s\n' "$([ -n "$OPT_PASS" ] && echo '已设置' || echo '未设置(将随机生成)')"
    printf '  SSH 端口    | %s\n' "$OPT_PORT"
    if [ "$OPT_NET_MODE" = dhcp ]; then
        printf '  网络        | DHCP 自动获取 (IP: %s)\n' "$NET_IP"
    else
        printf '  网络        | 静态 (%s netmask %s gw %s dns %s)\n' "$NET_IP" "$NET_MASK" "$NET_GW" "$NET_DNS"
    fi
    printf '  时区        | %s\n' "${OPT_TZ:-跟随当前}"
    if [ "$VIRT" = kvm ]; then
        printf '  swap        | %s\n' "$OPT_SWAP"
    fi
    printf '%s===================================================%s\n' "$CM" "$C0"
}

main_menu() {
    local mf choice
    while :; do
        mf=$(mktemp)
        cat >"$mf" <<EOF
1|开始重装 (交互式选择系统, 附推荐)
2|查看硬件需求对照表
EOF
        show_hw_summary
        pick "reinstall-vm.sh 主菜单 (v$REINSTALL_VM_VERSION)" "$mf" || { rm -f "$mf"; exit 0; }
        rm -f "$mf"
        case $MENU_RESULT in
            1) run_install ;;
            2) printf '%s\n' "$RULE_NOTE"; [ -t 0 ] && { read -r -p '回车返回> ' _; } ;;
        esac
    done
}

run_install() {
    choose_system || exit 0
    ask_options || exit 0
    [ -n "$OPT_PASS" ] || OPT_PASS=$(mkstr_random 14)
    OPT_HASH=$(gen_pw_hash "$OPT_PASS")
    if [ "$VIRT" = lxc ]; then lxc_resolve_base "$DISTRO"; else kvm_resolve_mirror; fi
    show_install_summary
    case $VIRT in
        lxc) lxc_install ;;
        kvm) kvm_install ;;
    esac
}

main() {
    if [ "${1:-}" = --rules ]; then printf '%s\n' "$RULE_NOTE"; exit 0; fi
    if [ "${1:-}" = --help ]; then sed -n '2,40p' "$0"; exit 0; fi
    first_install_check
    detect_arch
    detect_virt
    get_hw
    get_net
    # 参数快捷模式: ./reinstall-vm.sh <distro> <release>
    if [ -n "${1:-}" ]; then
        DISTRO=$1
        RELEASE=${2:-}
        while IFS='|' read -r label d r envs minram mindisk note; do
            [ -z "$label" ] && continue
            [ "$d" = "$DISTRO" ] && { [ -n "$RELEASE" ] || RELEASE=$r; RELEASE_LABEL=$label; }
        done <<<"$CATALOG"
        [ -n "$RELEASE" ] || die "未知系统: $DISTRO (可用: debian, ubuntu, alpine, rocky, alma, centos, fedora, opensuse, arch)"
        envflag=$( [ "$VIRT" = lxc ] && echo l || echo k )
        while IFS='|' read -r label d r envs minram mindisk note; do
            [ -z "$label" ] && continue
            [ "$d" = "$DISTRO" ] && [ "$r" = "$RELEASE" ] && case ",$envs," in *",$envflag,"*) : ;; *) die "$DISTRO $RELEASE 不支持当前环境 ($VIRT)" ;; esac
        done <<<"$CATALOG"
        OPT_PASS=$(mkstr_random 14)
        OPT_HASH=$(gen_pw_hash "$OPT_PASS")
        show_install_summary
        confirm "按上述配置执行重装?" || exit 0
        case $VIRT in lxc) lxc_install ;; kvm) kvm_install ;; esac
        exit 0
    fi
    main_menu
}

if [ "${REINSTALL_VM_NOEXEC:-0}" != 1 ]; then
    main "$@"
fi
