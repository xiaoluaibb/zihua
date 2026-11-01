#!/usr/bin/env bash
#===============================================================================
#  ProxyBox — 多协议代理一键安装/管理 + 网络优化(BBR/内核调优) 交互式脚本
#-------------------------------------------------------------------------------
#  适用系统 : Debian 10+ / Ubuntu 18.04+ / Rocky / Alma / CentOS 7+(部分) /
#             Fedora / Alpine 3.15+ / Arch  (systemd 或 OpenRC 均可)
#  运行方式 : 以 root 运行   bash zihua.sh   (root 下直接运行即可, 无需 sudo)
#  快捷命令 : 首次运行后自动安装 zihua 命令, 以后直接输入 zihua 即可再次打开
#  双内核   : sing-box (SS2022 / Hysteria2 / TUIC)
#             Xray (VLESS-Reality-Vision / gRPC, 配置与 v2ray-agent 同款)
#             两个服务独立管理, 可同时运行
#  多协议   : 各协议独立实例+独立证书, TCP/UDP 端口可复用, 可同时运行
#  附加功能 : 一键重装系统 (调用同仓库 reinstall-vm.sh, 支持 KVM/LXC)
#  版本     : v1.3.0  (2026-11)
#===============================================================================

#--------------------------------- 全局变量 ------------------------------------
PROXYBOX_VERSION="1.4.4"
SB_BIN="/usr/local/bin/sing-box"
SB_DIR="/etc/sing-box"
SB_ENV_DIR="$SB_DIR/instance.d"          # 每个协议一份参数(env)
SB_CFG_DIR="$SB_DIR/configs"             # 每个协议一份配置(json)
SB_CERT_DIR="$SB_DIR/certs"              # 自签证书
SB_BAK_DIR="$SB_DIR/backup"              # 修改前的配置备份
SERVICE_NAME="sing-box-proxy"
XRAY_BIN="/usr/local/bin/xray"                        # Xray 内核(Reality 协议专用, v2ray-agent 同款)
XRAY_CFG="/etc/sing-box/xray.json"                    # Xray 合并配置(所有 Reality 入站)
XRAY_SERVICE="zihua-xray"                             # Xray 服务名
XRAY_LOG_FILE="/var/log/zihua-xray.log"
UNIT_PATH="/etc/systemd/system/${SERVICE_NAME}.service"
SYSCTL_FILE="/etc/sysctl.d/99-proxybox-optimize.conf"
PUB_IP=""
INIT_SYS=""                                # systemd / openrc / none
LOG_FILE="/var/log/sing-box-proxy.log"     # OpenRC 模式下的日志文件

export PATH="$PATH:/usr/local/bin:/usr/local/sbin:/usr/sbin:/sbin"

#--------------------------------- 颜色/输出 -----------------------------------
RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; BLUE=$'\033[34m'
CYAN=$'\033[36m'; MAGENTA=$'\033[35m'; GRAY=$'\033[90m'; BOLD=$'\033[1m'; NC=$'\033[0m'

ok()    { printf '%s[OK] %s%s\n'   "$GREEN" "$NC" "$*"; }
warn()  { printf '%s[!!] %s%s\n'   "$YELLOW" "$NC" "$*"; }
err()   { printf '%s[NO] %s%s\n'   "$RED" "$NC" "$*"; }
info()  { printf '%s[**] %s%s\n'   "$CYAN" "$NC" "$*"; }
hr()    { printf '%s----------------------------------------------------------------%s\n' "$GRAY" "$NC"; }
title() { printf '\n%s%s=== %s ===%s\n' "$BOLD" "$CYAN" "$*" "$NC"; }
pause() { read -rp "$(printf '%s按回车键继续...%s' "$GRAY" "$NC")" _; }
die()   { err "$*"; exit 1; }

trap 'printf "\n"; warn "操作已中断，退出。"; exit 1' INT

#--------------------------------- 交互输入助手 ---------------------------------
# 用法: ask "提示语" "默认值" -> RESULT (提示语里可包含颜色)
ask() {
    local prompt="$1" def="$2" val
    if [[ -n "$def" ]]; then
        read -rp "$(printf '%s%s %s[回车=默认: %s]%s: ' "$CYAN" "$prompt" "$GRAY" "$def" "$NC")" val
    else
        read -rp "$(printf '%s%s %s[可为空]%s: ' "$CYAN" "$prompt" "$GRAY" "$NC")" val
    fi
    RESULT="${val:-$def}"
}

# 用法: ask_valid "提示语" "默认值" 校验函数 [校验参数...] -> RESULT
#       校验函数输入一个参数，成功返回0，失败返回1并设置全局 ERRMSG
ask_valid() {
    local prompt="$1" def="$2" check="$3"; shift 3 2>/dev/null || shift "$#"
    local val
    while :; do
        if [[ -n "$def" ]]; then
            read -rp "$(printf '%s%s %s[回车=默认: %s]%s: ' "$CYAN" "$prompt" "$GRAY" "$def" "$NC")" val
        else
            read -rp "$(printf '%s%s %s[必填, 请直接输入]%s: ' "$CYAN" "$prompt" "$GRAY" "$NC")" val
        fi
        val="${val:-$def}"
        ERRMSG=""
        if "$check" "$val" "$@"; then RESULT="$val"; return 0; fi
        err "${ERRMSG:-输入不合法，请重试}"
    done
}

# 选择题: ask_choice "提示语" 默认编号 Old 1 "选项一" 2 "选项二"...
# 用法: ask_choice "提示语" 1 1 "xx(推荐)" 2 "yy" ...  -> RESULT
ask_choice() {
    local prompt="$1" def="$2"; shift 2
    local i nopt=$(( ($#+1)/2 ))
    echo
    printf '%s%s%s\n' "$CYAN" "$prompt" "$NC"
    for ((i=1; i<=$#; i+=2)); do
        printf '  %s%s) %s%s\n' "$BOLD" "${!i}" "$NC" "${@:i+1:1}"
    done
    while :; do
        read -rp "$(printf '%s请选择 %s[回车=默认: %s]%s: ' "$GRAY" "$GRAY" "$def" "$NC")" c
        if [[ -z $c && -z $def ]]; then RESULT=""; return 0; fi
        c="${c:-$def}"
        if [[ "$c" =~ ^[0-9]+$ ]] && (( c>=1 && c<=nopt )); then RESULT="$c"; return 0; fi
        err "请输入 1~${nopt} 的选项编号"
    done
}

#--------------------------------- 常用校验器 -----------------------------------
v_notempty() {
    if [[ -z "$1" ]]; then ERRMSG="输入不能为空"; return 1; fi; return 0;
}
v_number() {
    if [[ ! "$1" =~ ^[0-9]+$ ]]; then ERRMSG="必须是纯数字"; return 1; fi; return 0;
}
v_any()   { if [[ -z "$1" ]]; then ERRMSG="不能为空"; return 1; fi; return 0; }

v_port() {
    v_number "$1" || return 1
    if (( 10#$1 < 1 || 10#$1 > 65535 )); then ERRMSG="端口范围 1~65535"; return 1; fi
    return 0
}

# 分享链接友好字符(字母数字 _ . - ~)
v_uri_safe() {
    if [[ -z "$1" ]]; then ERRMSG="不能为空"; return 1; fi
    if [[ "$1" =~ ^[a-zA-Z0-9_.~-]+$ ]]; then return 0; fi
    ERRMSG="为兼容订阅链接，仅允许字母/数字/下划线/点/短横线 (建议直接回车使用随机值)"
    return 1
}

v_domain() {
    if [[ "$1" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$ ]]; then return 0; fi
    ERRMSG="域名格式应为 example.com (仅字母/数字/点/短横线)"
    return 1
}

v_uuid() {
    if [[ "$1" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; then return 0; fi
    ERRMSG="UUID 格式: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx (直接回车可随机生成)"
    return 1
}

v_url() {
    if [[ "$1" =~ ^https?://[A-Za-z0-9] ]]; then return 0; fi
    ERRMSG="应为 http:// 或 https:// 开头的完整网址"
    return 1
}

v_path() {
    if [[ -r "$1" ]]; then return 0; fi
    ERRMSG="文件不存在或无读取权限: $1"
    return 1
}

#--------------------------------- 随机值生成 -----------------------------------
gen_uuid()   { cat /proc/sys/kernel/random/uuid 2>/dev/null || openssl rand -hex 16 | sed 's/../&-/4;s/../&-/6;s/../&-/8;s/../&-/10'; }
gen_b64()    { openssl rand -base64 "$1" 2>/dev/null | tr -d '\n'; }   # base64 标准
gen_hex()    { openssl rand -hex "$1" 2>/dev/null; }
gen_rand()   { tr -dc 'a-zA-Z0-9' </dev/urandom 2>/dev/null | head -c "$1"; }  # 等 长 数字字母
b64url()     { openssl base64 -A 2>/dev/null | tr '+/' '-_' | tr -d '='; }

#--------------------------------- 公网 IP 探测 ---------------------------------
get_public_ip() {
    local u ip cache="$SB_DIR/.pubip" cached
    # 本次会话探测失败过就不再重复探测，避免卡菜单
    if [[ -n "${PROBE_FAILED:-}" ]]; then PUB_IP=""; return 1; fi
    # 文件缓存(重启脚本后仍可复用)
    if [[ -r "$cache" ]]; then
        cached="$(head -n1 "$cache" 2>/dev/null | tr -d '[:space:]')"
        if [[ -n "$cached" && "$cached" != "none" ]]; then
            PUB_IP="$cached"; return 0
        fi
    fi
    for u in "https://api.ipify.org" "https://ifconfig.me" "https://api-ipv4.ip.sb/ip" \
             "https://ipinfo.io/ip" "https://curlmyip.net"; do
        ip=$(curl -4 -fsS --connect-timeout 3 --max-time 6 "$u" 2>/dev/null | head -n1 | tr -d '[:space:]')
        if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            PUB_IP="$ip"; echo "$ip" > "$cache" 2>/dev/null
            chmod 644 "$cache" 2>/dev/null
            return 0
        fi
    done
    for u in "https://api-ipv6.ip.sb/ip" "https://api6.ipify.org"; do
        ip=$(curl -6 -fsS --connect-timeout 3 --max-time 6 "$u" 2>/dev/null | head -n1 | tr -d '[:space:]')
        if [[ "$ip" == *:* ]]; then
            PUB_IP="[$ip]"; echo "[$ip]" > "$cache" 2>/dev/null
            chmod 644 "$cache" 2>/dev/null
            return 0
        fi
    done
    PROBE_FAILED=1
    PUB_IP=""
    return 1
}

#--------------------------------- 系统识别 -------------------------------------
OS_ID=""; OS_VER=""; OS_ID_LIKE=""; OS_PRETTY=""; PKG=""; KERNEL="$(uname -r 2>/dev/null)"; ARCH=""

detect_os() {
    if [[ -r /etc/os-release ]]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        OS_ID="${ID:-unknown}"; OS_VER="${VERSION_ID:-}"
        OS_ID_LIKE="${ID_LIKE:-}"; OS_PRETTY="${PRETTY_NAME:-$OS_ID}"
    fi
    case "${OS_ID}:${OS_ID_LIKE}" in
        debian:*|*debian*|ubuntu*|*ubuntu*) PKG="apt" ;;
        fedora*|*fedora*)                   PKG="dnf" ;;
        *centos*|*rhel*|*rocky*|*alma*|ol*|amzn*|*el*) PKG="yum"; command -v dnf >/dev/null 2>&1 && PKG="dnf" ;;
        alpine*)                            PKG="apk" ;;
        arch*|manjaro*)                     PKG="pacman" ;;
        opensuse*|*suse*)                   PKG="zypper" ;;
        *) PKG="" ;;
    esac
    case "$(uname -m)" in
        x86_64|amd64)  ARCH="amd64" ;;
        aarch64|arm64) ARCH="arm64" ;;
        armv7l|armhf)  ARCH="armv7" ;;
        *)             ARCH="unknown" ;;
    esac
    [[ "${KERNEL:0:1}" == "0" ]] && KERNEL="$(uname -r)"
}

version_ge() { [[ "$(printf '%s\n' "$1" "$2" | sort -V | head -n1)" == "$2" ]]; }

#--------------------------------- 依赖管理 -------------------------------------
pkg_install() {
    MISSING=()
    local p
    for p in "$@"; do command -v "$p" >/dev/null 2>&1 || MISSING+=("$p"); done
    [[ ${#MISSING[@]} -eq 0 ]] && return 0
    info "检测到缺少依赖: ${MISSING[*]} ，尝试自动安装..."
    case "$PKG" in
        apt)    apt-get update -y >/dev/null 2>&1; apt-get install -y "${MISSING[@]}" >/dev/null 2>&1 ;;
        dnf)    dnf install -y "${MISSING[@]}" >/dev/null 2>&1 ;;
        yum)    yum install -y "${MISSING[@]}" >/dev/null 2>&1 ;;
        apk)    apk add --no-cache "${MISSING[@]}" >/dev/null 2>&1 ;;
        pacman) pacman -Sy --noconfirm "${MISSING[@]}" >/dev/null 2>&1 ;;
        zypper) zypper -n in -y "${MISSING[@]}" >/dev/null 2>&1 ;;
        *) err "无法识别包管理器，请手动安装: ${MISSING[*]}"; return 1 ;;
    esac
    return 0
}

# 确保 curl/tar/openssl/ss 等基础工具存在
ensure_deps() {
    local progs=(curl tar gzip openssl sed grep awk)
    pkg_install "${progs[@]}" || warn "依赖安装失败，脚本可能无法正常工作"
    # iproute2 提供 ss
    if ! command -v ss >/dev/null 2>&1; then
        case "$PKG" in
            apt) apt-get install -y iproute2 >/dev/null 2>&1 ;;
            dnf|yum) "$PKG" install -y iproute iproute2 >/dev/null 2>&1 ;;
            apk) apk add --no-cache iproute2 >/dev/null 2>&1 ;;
            pacman) pacman -Sy --noconfirm iproute2 >/dev/null 2>&1 ;;
            zypper) zypper -n in -y iproute2 >/dev/null 2>&1 ;;
        esac
    fi
    [[ -n "$INIT_SYS" ]] || detect_init
    if [[ "$INIT_SYS" == "none" ]]; then
        die "未检测到 systemd / OpenRC，本脚本需要其中一种来管理服务。"
    fi
    for p in curl tar openssl; do
        command -v "$p" >/dev/null 2>&1 || die "缺少基础工具 $p ，请手动安装后重试。"
    done
    ok "依赖检查完成"
}

#--------------------------------- 系统体检 -------------------------------------
show_system_info() {
    local mem disk virt dep_line=""
    title "系统环境体检"
    hr
    printf '  %-14s %s\n' "系统:"      "${OS_PRETTY:-未知}"
    printf '  %-14s %s\n' "内核:"      "$KERNEL"
    printf '  %-14s %s\n' "架构:"      "$ARCH"
    mem=$(free -h 2>/dev/null | awk '/^Mem:/{print $2}')  && mem="${mem:-未知}"
    disk=$(df -h / 2>/dev/null | awk 'NR==2{print $4" 可用 / 共 "$2}')
    printf '  %-14s %s\n' "内存:"      "$mem"
    printf '  %-14s %s\n' "根分区:"    "${disk:-未知}"
    if command -v systemd-detect-virt >/dev/null 2>&1; then
        virt=$(systemd-detect-virt 2>/dev/null || echo "unknown")
    else
        virt="未知"
    fi
    printf '  %-14s %s\n' "虚拟化:"    "$virt"
    if [[ "$virt" == "openvz" || "$virt" == "lxc" || "$virt" == "lxc-libvirt" ]]; then
        warn "检测到 LXC/OpenVZ 容器环境: 内核升级和部分 BBR/内核调优可能受限，代理本身一般可正常使用。"
    fi
    if [[ "$ARCH" == "unknown" ]]; then
        warn "非常见架构 ($(uname -m))，程序下载可能没有对应版本。"
    fi
    hr
}

#--------------------------------- 端口检测 -------------------------------------
# 返回占用该端口的进程信息(可能为空)
port_busy_info() {
    local p="$1"
    # ss -lntup 列: 状态 收队列 发队列 本地地址:端口 远端 进程; 本地在第4列、进程在第6列
    ss -H -lntup 2>/dev/null | grep "[:.]${p}[[:space:]]" | awk '{print $4, $6}' | sort -u | sed 's/users:((.*//' | head -n 3
}

# 本机端口占用检测: port_in_use <端口> [tcp|udp|any]
port_in_use() {
    local p="$1" proto="${2:-any}" flags
    case "$proto" in
        tcp) flags="-lnt" ;;
        udp) flags="-lnu" ;;
        *)   flags="-lntu" ;;
    esac
    if command -v ss >/dev/null 2>&1; then
        # 直接对整行匹配「:端口+空白」: 只监听态下本地列才带端口, 远端列恒为 0.0.0.0:* / [::]:* 不会误中
        ss -H $flags 2>/dev/null | grep -qE "[:.]${p}[[:space:]]"
    elif command -v netstat >/dev/null 2>&1; then
        netstat -ln${proto:0:1} 2>/dev/null | grep -qE "[:.]${p}[[:space:]]"
    else
        # 尝试 TCP 连接 localhost (UDP 无法探测)
        [[ "$proto" == "udp" ]] && return 1
        if (exec 3<>"/dev/tcp/127.0.0.1/${p}") 2>/dev/null; then return 0; fi
        return 1
    fi
}

# 分配协议端口: ask_port "默认端口" "tcp|udp"
ask_port() {
    local def="$1" proto="$2" p
    title "监听端口设置"
    info "填写规则: 1~65535 的纯数字（建议使用 10000 以上的高位端口，避开 22/80/443 等常用端口）。"
    info "本协议走 ${proto^^} 传输。TCP 与 UDP 互不冲突：如 TCP 443 已被网站占用，UDP 443 仍可给本协议用。"
    info "同一 TCP 或同一 UDP 端口只能被一个协议使用（如 Vision 和 gRPC 都想用 TCP 443 则只能二选一）。"
    info "当前本机已监听端口: $(ss -H -lntu 2>/dev/null | awk '{print $5}' | sed 's/.*[:.]//' | sort -un | tr '\n' ' ' | cut -c1-120)..."
    while :; do
        ask_valid "输入端口" "$def" v_port
        p="$RESULT"
        if ! port_in_use "$p" "$proto"; then
            PORT="$p"; ok "端口 $p 可用(${proto^^})"; return 0
        fi
        warn "端口 $p 的 ${proto^^} 已被占用:"
        port_busy_info "$p" | sed 's/^/    /'
        info "提示: 若上方显示的是 TCP 占用而本协议是 UDP（或相反），实际并不冲突，可放心保留。"
        ask_choice "如何处理?" 1 1 "换一个端口(推荐)" 2 "仍使用该端口(另一传输层确实空闲时可用)"
        if [[ "$RESULT" == "1" ]]; then
            def=""; continue
        fi
        PORT="$p"
        warn "已选择保留端口 $p，若与服务冲突将导致启动失败，可稍后在菜单中修改。"
        return 0
    done
}

#--------------------------------- 已有代理冲突检测 -------------------------------
# 检测本机常见代理服务/进程，提示处理方式
check_proxy_conflicts() {
    local pat='xray|v2ray|trojan|hysteria|shadowsocks|ss-server|ssr|naive|tuic|brook|gost|clash|mihomo|sing-box|snell|wmproxy'
    local svc sname procs="" pid pn pname found=0
    declare -A seen=()
    info "检查是否已有正在运行/自启的代理服务..."
    if [[ "$INIT_SYS" == "systemd" ]]; then
        for svc in $(systemctl list-unit-files --type=service --no-pager 2>/dev/null | awk '{print $1}' | grep -Ei "${pat}" | grep -v "^${SERVICE_NAME}.service$"); do
            sname="${svc%.service}"
            [[ "$sname" == "$SERVICE_NAME" ]] && continue
            if systemctl is-active --quiet "$sname" 2>/dev/null; then
                printf '%s  - %s%s %s(运行中)%s\n' "$YELLOW" "$NC" "$sname" "$GRAY" "$NC"
                seen["$sname"]=1; found=1
            elif systemctl is-enabled --quiet "$sname" 2>/dev/null; then
                printf '%s  - %s%s %s(已启用开机自启, 当前未运行)%s\n' "$GRAY" "$NC" "$sname" "$GRAY" "$NC"
                seen["$sname"]=1; found=1
            fi
        done
    else
        for svc in $(ls /etc/init.d/ 2>/dev/null | grep -Ei "${pat}"); do
            [[ "$svc" == "$SERVICE_NAME" || "$svc" == "functions.sh" || "$svc" == "sysfs" ]] && continue
            if rc-service "$svc" status >/dev/null 2>&1; then
                printf '%s  - %s%s %s(运行中)%s\n' "$YELLOW" "$NC" "$svc" "$GRAY" "$NC"
                seen["$svc"]=1; found=1
            elif rc-update show default 2>/dev/null | grep -qw "$svc"; then
                printf '%s  - %s%s %s(已启用开机自启, 当前未运行)%s\n' "$GRAY" "$NC" "$svc" "$GRAY" "$NC"
                seen["$svc"]=1; found=1
            fi
        done
    fi
    # 进程级兜底检查(排除本脚本管理的 sing-box/Xray 进程, 避免把自己当成冲突代理)
    local own_pids
    own_pids=" $(svc_own_pids) $(command -v "$XRAY_BIN" >/dev/null 2>&1 && xsvc_own_pids) "
    for pn in $(pgrep -d' ' -f "${pat}" 2>/dev/null); do
        [[ "$own_pids" == *" $pn "* ]] && continue
        pname=$(ps -o comm= -p "$pn" 2>/dev/null | head -n1)
        [[ -n "$pname" && -z "${seen[$pname]:-}" ]] || continue
        printf '%s  - %s %s(PID %s 运行中)%s\n' "$YELLOW" "$pname" "$GRAY" "$pn" "$NC"
        found=1; seen["$pname"]=1
    done
    if [[ "$found" == "1" ]]; then
        title "发现同类代理软件"
        warn "已有其他代理服务在运行，可能与新装的代理发生端口/内核冲突。"
        ask_choice "如何处理?" 1 \
            1 "停止并禁用这些服务，避免冲突(推荐)" \
            2 "跳过，保留现有服务(可能出现冲突，请自行避开端口)"
        if [[ "$RESULT" == "1" ]]; then
            for sname in "${!seen[@]}"; do
                info "停止 ${sname} ..."
                if [[ "$INIT_SYS" == "systemd" ]]; then
                    systemctl stop "$sname" >/dev/null 2>&1
                    systemctl disable "$sname" >/dev/null 2>&1
                else
                    rc-service "$sname" stop >/dev/null 2>&1
                    rc-update del "$sname" default >/dev/null 2>&1
                fi
            done
            ok "已有代理已停止并禁用开机自启"
        fi
    else
        ok "未发现运行中的其他代理服务，无冲突"
    fi
    return 0
}

#--------------------------------- sing-box 内核 ---------------------------------
get_latest_sb() {
    curl -fsSL --connect-timeout 5 --max-time 20 "https://api.github.com/repos/SagerNet/sing-box/releases/latest" 2>/dev/null |
        grep -oE '"tag_name": *"v?[0-9.]+"' | head -n1 | grep -oE 'v?[0-9.]+' || true
}

sb_download_urls() {
    # $1=srcver 如 1.13.0
    local u="https://github.com/SagerNet/sing-box/releases/download/v${1}/sing-box-${1}-linux-${ARCH}.tar.gz"
    echo "$u"
    echo "https://gh-proxy.com/${u}"
    echo "https://ghfast.top/${u}"
}

install_core() {
    ensure_dirs
    title "sing-box 内核安装"
    if [[ "$ARCH" == "unknown" ]]; then
        die "不支持的 CPU 架构: $(uname -m)，没有对应的 sing-box 发行包。"
    fi
    info "获取最新版本号..."
    LATEST="$(get_latest_sb)"
    if [[ -z "$LATEST" ]]; then
        warn "无法从 GitHub 获取版本信息(可能网络受限)。"
        ask "请手动输入要安装的 sing-box 版本(如 1.13.0)" "1.12.14"
        LATEST="${RESULT#v}"
    else
        LATEST="${LATEST#v}"
        info "最新稳定版本: ${LATEST}"
    fi
    local tmp f url tmpurl base
    tmp="$(mktemp -d)" || die "创建临时目录失败"
    ok_list="$(sb_download_urls "$LATEST")"
    installed_ok=0
    while IFS= read -r url; do
        [[ -z "$url" ]] && continue
        printf '%s    下载: %s%s\n' "$GRAY" "$url" "$NC"
        if curl -fSL --connect-timeout 8 --max-time 300 --retry 1 -o "$tmp/sb.tgz" "$url" 2>/dev/null && tar -tzf "$tmp/sb.tgz" >/dev/null 2>&1; then
            installed_ok=1; break
        else
            warn "该地址下载失败，切换备用地址..."
        fi
    done <<< "$ok_list"
    [[ "$installed_ok" != "1" ]] && { rm -rf "$tmp"; die "所有下载地址均失败。可稍后重试，或在菜单中选择使用镜像。"; }
    tar -zxf "$tmp/sb.tgz" -C "$tmp" || { rm -rf "$tmp"; die "解压失败"; }
    base="$(tar -tzf "$tmp/sb.tgz" | head -n1 | cut -d/ -f1)"
    [[ -x "$tmp/$base/sing-box" ]] || { rm -rf "$tmp"; die "压缩包内未找到 sing-box 可执行文件"; }
    install -m 0755 "$tmp/$base/sing-box" "$SB_BIN"
    rm -rf "$tmp"
    chmod +x "$SB_BIN"
    # 真正执行一次验证: 二进制存在不代表能跑(musl/glibc 动态链接问题在 Alpine 上常见)
    if ! "$SB_BIN" version >/dev/null 2>&1; then
        err "sing-box 已下载但无法运行(常见于 Alpine/musl 系统: 缺少 glibc 兼容层)。"
        if command -v apk >/dev/null 2>&1; then
            info "正在自动安装兼容层 gcompat ..."
            apk add --no-cache gcompat libstdc++ >/dev/null 2>&1
            if "$SB_BIN" version >/dev/null 2>&1; then
                ok "兼容层安装成功, sing-box 可正常运行"
            else
                die "仍无法运行。请手动执行: apk add gcompat libstdc++ 后重试; 或改用 Debian/Ubuntu 系统。"
            fi
        else
            die "无法运行 $SB_BIN，请检查系统兼容性(可先手动执行 '$SB_BIN version' 查看报错)。"
        fi
    fi
    ok "sing-box 安装完成: $("$SB_BIN" version 2>/dev/null | head -n1)"
}

ensure_core() {
    if [[ -x "$SB_BIN" ]]; then
        # 不仅要存在, 还要真的能运行(防止上次残留一个跑不起来的二进制)
        if "$SB_BIN" version >/dev/null 2>&1; then
            info "检测到已安装内核: $($SB_BIN version 2>/dev/null | head -n1)"
            return 0
        fi
        warn "检测到 $SB_BIN 存在但无法运行(可能是 musl 系统缺少 glibc 兼容层), 尝试修复..."
        if command -v apk >/dev/null 2>&1; then
            apk add --no-cache gcompat libstdc++ >/dev/null 2>&1 || true
            "$SB_BIN" version >/dev/null 2>&1 && { info "修复成功: $($SB_BIN version 2>/dev/null | head -n1)"; return 0; }
        fi
        rm -f "$SB_BIN"
        warn "修复失败, 已删除损坏内核, 重新安装..."
    fi
    info "未检测到 sing-box 内核，开始安装..."
    install_core
}

update_core() {
    title "更新 sing-box 内核"
    if [[ ! -x "$SB_BIN" ]]; then
        warn "尚未安装内核，执行完整安装..."
        install_core
    else
        local cur latest
        cur="$($SB_BIN version 2>/dev/null | head -n1 | awk '{print $3}')"
        latest="$(get_latest_sb | tr -d 'v')"
        info "当前版本: ${cur:-未知}  最新版本: ${latest:-获取失败}"
        if [[ -n "$latest" && "$cur" == "$latest" ]]; then
            ok "已是最新版本，无需更新"; return 0
        fi
        ask_choice "是否更新?" 1 1 "更新到最新版本(推荐)" 2 "暂不更新"
        [[ "$RESULT" == "1" ]] || return 0
        install_core
        # 重新生成所有配置(内核版本变化以防字段变更) 并按需重启
        local k
        for k in $(installed_keys); do
            gen_config "$k" || warn "配置 $k 重新校验失败，请查看日志"
        done
        if svc_active; then
            svc_do_restart && ok "服务已重启"
        fi
    fi
}

#-------------------------- 初始化系统识别与服务管理封装 ---------------------------
# 兼容 systemd (Debian/Ubuntu/RHEL系) 与 OpenRC (Alpine/Gentoo)
detect_init() {
    if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
        INIT_SYS="systemd"
    elif command -v rc-service >/dev/null 2>&1; then
        INIT_SYS="openrc"
    else
        INIT_SYS="none"
    fi
}

svc_do_start()    { if [[ "$INIT_SYS" == "systemd" ]]; then systemctl start "$SERVICE_NAME"; else rc-service "$SERVICE_NAME" start; fi; }
svc_do_stop()     { if [[ "$INIT_SYS" == "systemd" ]]; then systemctl stop "$SERVICE_NAME"; else rc-service "$SERVICE_NAME" stop; fi; }
svc_do_restart()  { if [[ "$INIT_SYS" == "systemd" ]]; then systemctl restart "$SERVICE_NAME"; else rc-service "$SERVICE_NAME" restart; fi; }
svc_active()      { if [[ "$INIT_SYS" == "systemd" ]]; then systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; else rc-service "$SERVICE_NAME" status >/dev/null 2>&1; fi; }
svc_status_text() { if [[ "$INIT_SYS" == "systemd" ]]; then systemctl is-active "$SERVICE_NAME" 2>/dev/null; else rc-service "$SERVICE_NAME" status 2>/dev/null | head -n1 | awk '{print $2}'; fi; }
svc_enabled()     { if [[ "$INIT_SYS" == "systemd" ]]; then systemctl is-enabled --quiet "$1" 2>/dev/null; else rc-update show default 2>/dev/null | grep -qw "$1"; fi; }
svc_enable()      { if [[ "$INIT_SYS" == "systemd" ]]; then systemctl enable "$SERVICE_NAME" >/dev/null 2>&1; else rc-update add "$SERVICE_NAME" default >/dev/null 2>&1; fi; }
svc_disable_now() { if [[ "$INIT_SYS" == "systemd" ]]; then systemctl disable --now "$SERVICE_NAME" >/dev/null 2>&1; else rc-service "$SERVICE_NAME" stop >/dev/null 2>&1; rc-update del "$SERVICE_NAME" default >/dev/null 2>&1; fi; }
svc_show_status() { if [[ "$INIT_SYS" == "systemd" ]]; then systemctl status "$SERVICE_NAME" --no-pager -l 2>/dev/null | head -n 25; else rc-service "$SERVICE_NAME" status 2>/dev/null; grep -A3 "^#!/sbin/openrc-run" /etc/init.d/"$SERVICE_NAME" 2>/dev/null | head -n 4; fi; }
svc_own_pids() {
    # 本脚本管理的 sing-box 进程 PID(用于冲突检测排除自身)
    if [[ "$INIT_SYS" == "systemd" ]]; then
        local p; p="$(systemctl show -p MainPID --value "$SERVICE_NAME" 2>/dev/null)"
        [[ -n "$p" && "$p" != "0" ]] && echo "$p"
    else
        pgrep -f "$SB_BIN run -C" 2>/dev/null | tr '\n' ' '
    fi
}
svc_log_tail() {
    # $1 = 行数
    if [[ "$INIT_SYS" == "systemd" ]]; then
        journalctl -u "$SERVICE_NAME" -n "${1:-60}" --no-pager -e 2>/dev/null
    else
        tail -n "${1:-60}" "$LOG_FILE" 2>/dev/null
    fi
}

#--------------------------------- 目录/服务 -------------------------------------
ensure_dirs() {
    mkdir -p "$SB_DIR" "$SB_ENV_DIR" "$SB_CFG_DIR" "$SB_CERT_DIR" "$SB_BAK_DIR"
    chmod 700 "$SB_DIR"
}

ensure_service() {
    if [[ "$INIT_SYS" == "openrc" ]] && [[ -x "/etc/init.d/${SERVICE_NAME}" ]]; then return 0; fi
    if [[ "$INIT_SYS" == "systemd" ]] && [[ -f "$UNIT_PATH" ]]; then return 0; fi
    if [[ "$INIT_SYS" == "openrc" ]]; then
        cat > "/etc/init.d/${SERVICE_NAME}" <<UNIT
#!/sbin/openrc-run
description="ProxyBox sing-box multi-inbound service"
command="${SB_BIN}"
command_args="run -C ${SB_CFG_DIR}"
command_background="yes"
pidfile="/run/${SERVICE_NAME}.pid"
output_log="${LOG_FILE}"
error_log="${LOG_FILE}"
depend() {
    need net
    use dns
}
start_pre() {
    ebegin "检查 sing-box 配置"
    ${SB_BIN} check -C ${SB_CFG_DIR}
    eend \$?
}
UNIT
        chmod +x "/etc/init.d/${SERVICE_NAME}"
        svc_enable
        ok "已创建并启用 OpenRC 服务: $SERVICE_NAME"
        return 0
    fi
    cat > "$UNIT_PATH" <<UNIT
[Unit]
Description=ProxyBox sing-box multi-inbound service
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${SB_BIN} run -C ${SB_CFG_DIR}
ExecStartPre=${SB_BIN} check -C ${SB_CFG_DIR}
Restart=on-failure
RestartSec=5s
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
UNIT
    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME" >/dev/null 2>&1
    ok "已创建并启用 systemd 服务: $SERVICE_NAME"
}

svc_restart() {
    cleanup_orphan_configs
    ensure_service
    if ! svc_do_restart; then
        err "服务重启失败，最近日志如下:"
        svc_log_tail 20 | sed 's/^/    /'
        return 1
    fi
    sleep 1
    svc_active && ok "服务运行中" || warn "服务状态异常，请查看日志"
}

#------------------------- Xray 内核 (Reality 协议专用, v2ray-agent 同款) -------------------------
# 内核路由: Reality 协议走 Xray, 其余走 sing-box
proto_kernel() { case "$1" in vless-rv|vless-rg) echo xray ;; *) echo sing-box ;; esac; }
kernel_active() { if [[ "$(proto_kernel "$1")" == "xray" ]]; then xsvc_active; else svc_active; fi; }
# 按协议所属内核打印日志尾部(避免 Xray 协议去 tail sing-box 的日志, 看不到真实报错)
kernel_log_tail() { if [[ "$(proto_kernel "$1")" == "xray" ]]; then xsvc_log_tail "${2:-20}"; else svc_log_tail "${2:-20}"; fi; }

xray_download_urls() {
    local fname
    case "$ARCH" in
        amd64) fname="Xray-linux-64.zip" ;;
        arm64) fname="Xray-linux-arm64-v8a.zip" ;;
        *) return 1 ;;
    esac
    local u="https://github.com/XTLS/Xray-core/releases/latest/download/${fname}"
    echo "$u"
    echo "https://gh-proxy.com/${u}"
    echo "https://ghfast.top/${u}"
}

install_xray() {
    ensure_dirs
    title "Xray 内核安装 (Reality 协议)"
    [[ "$ARCH" == "unknown" ]] && die "不支持的 CPU 架构: $(uname -m)"
    command -v unzip >/dev/null 2>&1 || { die "缺少 unzip 命令, 请先安装 (apt/yum/apk install unzip) 后重试。"; }
    local tmp url okdl=0
    tmp="$(mktemp -d)" || die "创建临时目录失败"
    while IFS= read -r url; do
        [[ -z "$url" ]] && continue
        printf '%s    下载: %s%s\n' "$GRAY" "$url" "$NC"
        if curl -fSL --connect-timeout 8 --max-time 300 -o "$tmp/xray.zip" "$url" 2>/dev/null && [[ -s "$tmp/xray.zip" ]]; then
            okdl=1; break
        fi
        warn "该地址下载失败，切换备用地址..."
    done < <(xray_download_urls)
    [[ "$okdl" != "1" ]] && { rm -rf "$tmp"; die "Xray 下载失败(所有地址均不可达)。"; }
    unzip -o "$tmp/xray.zip" xray -d "$tmp" >/dev/null 2>&1
    [[ -f "$tmp/xray" ]] || { rm -rf "$tmp"; die "压缩包内未找到 xray 可执行文件"; }
    install -m 0755 "$tmp/xray" "$XRAY_BIN"
    if [[ -f "$tmp/geoip.dat" ]]; then
        mkdir -p /usr/local/share/xray
        install -m 0644 "$tmp/geoip.dat" /usr/local/share/xray/ 2>/dev/null
        install -m 0644 "$tmp/geosite.dat" /usr/local/share/xray/ 2>/dev/null
    fi
    rm -rf "$tmp"
    # 真正执行一次验证(musl 系统常见无法运行)
    if ! "$XRAY_BIN" version >/dev/null 2>&1; then
        err "Xray 已下载但无法运行(常见于 Alpine/musl 系统)。"
        if command -v apk >/dev/null 2>&1; then
            info "正在自动安装兼容层 gcompat ..."
            apk add --no-cache gcompat libstdc++ >/dev/null 2>&1
            "$XRAY_BIN" version >/dev/null 2>&1 || die "仍无法运行。请手动执行: apk add gcompat libstdc++ 后重试。"
            ok "兼容层安装成功, Xray 可正常运行"
        else
            die "无法运行 $XRAY_BIN, 请检查系统兼容性。"
        fi
    fi
    ok "Xray 安装完成: $("$XRAY_BIN" version 2>/dev/null | head -n1)"
}

ensure_xray_core() {
    if [[ -x "$XRAY_BIN" ]] && "$XRAY_BIN" version >/dev/null 2>&1; then return 0; fi
    install_xray
}

xray_ensure_service() {
    if [[ "$INIT_SYS" == "openrc" ]] && [[ -x "/etc/init.d/${XRAY_SERVICE}" ]]; then return 0; fi
    if [[ "$INIT_SYS" == "systemd" ]] && [[ -f "/etc/systemd/system/${XRAY_SERVICE}.service" ]]; then return 0; fi
    if [[ "$INIT_SYS" == "openrc" ]]; then
        cat > "/etc/init.d/${XRAY_SERVICE}" <<UNIT
#!/sbin/openrc-run
description="ProxyBox Xray (Reality) service"
command="${XRAY_BIN}"
command_args="run -config ${XRAY_CFG}"
command_background="yes"
pidfile="/run/${XRAY_SERVICE}.pid"
output_log="${XRAY_LOG_FILE}"
error_log="${XRAY_LOG_FILE}"
depend() {
    need net
    use dns
}
UNIT
        chmod +x "/etc/init.d/${XRAY_SERVICE}"
    else
        cat > "/etc/systemd/system/${XRAY_SERVICE}.service" <<UNIT
[Unit]
Description=ProxyBox Xray (Reality) service
After=network.target nss-lookup.target

[Service]
Type=simple
ExecStart=${XRAY_BIN} run -config ${XRAY_CFG}
Restart=on-failure
RestartSec=5s
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
UNIT
        systemctl daemon-reload
    fi
    if [[ "$INIT_SYS" == "systemd" ]]; then
        systemctl enable "$XRAY_SERVICE" >/dev/null 2>&1
    else
        rc-update add "$XRAY_SERVICE" default >/dev/null 2>&1
    fi
    ok "已创建并启用 Xray 服务: $XRAY_SERVICE"
}

xsvc_restart()  { if [[ "$INIT_SYS" == "systemd" ]]; then systemctl restart "$XRAY_SERVICE"; else rc-service "$XRAY_SERVICE" restart; fi; }
xsvc_active()   { if [[ "$INIT_SYS" == "systemd" ]]; then systemctl is-active --quiet "$XRAY_SERVICE" 2>/dev/null; else rc-service "$XRAY_SERVICE" status >/dev/null 2>&1; fi; }
xsvc_stop_now() { if [[ "$INIT_SYS" == "systemd" ]]; then systemctl disable --now "$XRAY_SERVICE" >/dev/null 2>&1; else rc-service "$XRAY_SERVICE" stop >/dev/null 2>&1; rc-update del "$XRAY_SERVICE" default >/dev/null 2>&1; fi; }
xsvc_log_tail() { if [[ "$INIT_SYS" == "systemd" ]]; then journalctl -u "$XRAY_SERVICE" -n "${1:-60}" --no-pager -e 2>/dev/null; else tail -n "${1:-60}" "$XRAY_LOG_FILE" 2>/dev/null; fi; }
xsvc_own_pids() { pgrep -f "xray run -config ${XRAY_CFG}" 2>/dev/null | tr '\n' ' '; }

# Xray 配置自检(兼容新旧命令行形式); 失败时把内核真实报错打印到 stderr 便于排查
xray_test_config() {
    local cfg="$1" out rc
    out="$("$XRAY_BIN" run -test -config "$cfg" 2>&1)"; rc=$?
    if [[ "$rc" == "0" ]]; then return 0; fi
    out="$("$XRAY_BIN" -test -config "$cfg" 2>&1)"; rc=$?
    if [[ "$rc" == "0" ]]; then return 0; fi
    echo "$out" | tail -n 2 | sed 's/^/    /' >&2
    return 1
}

# 从 env 文件读单个字段(不污染全局状态): env_get <key> <FIELD>
env_get() { grep -E "^$2=" "$SB_ENV_DIR/$1.env" 2>/dev/null | head -n1 | cut -d= -f2- | tr -d "'\""; }

# 生成单个 Xray Reality-Vision 入站 (模板与 v2ray-agent 07_VLESS_vision_reality 一致)
xray_inbound_rv() {
    cat <<EOF
{
  "listen": "0.0.0.0",
  "port": $1,
  "protocol": "vless",
  "tag": "in-xray-rv-$1",
  "settings": {
    "clients": [ { "id": "$2", "flow": "xtls-rprx-vision" } ],
    "decryption": "none"
  },
  "streamSettings": {
    "network": "tcp",
    "security": "reality",
    "realitySettings": {
      "show": false,
      "target": "$3:$4",
      "xver": 0,
      "serverNames": [ "$3" ],
      "privateKey": "$5",
      "shortIds": [ "$6", "" ],
      "maxTimeDiff": 70000
    }
  }
}
EOF
}

# 生成单个 Xray Reality-gRPC 入站
xray_inbound_rg() {
    cat <<EOF
{
  "listen": "0.0.0.0",
  "port": $1,
  "protocol": "vless",
  "tag": "in-xray-rg-$1",
  "settings": {
    "clients": [ { "id": "$2" } ],
    "decryption": "none"
  },
  "streamSettings": {
    "network": "grpc",
    "security": "reality",
    "realitySettings": {
      "show": false,
      "target": "$3:$4",
      "xver": 0,
      "serverNames": [ "$3" ],
      "privateKey": "$5",
      "shortIds": [ "$6", "" ],
      "maxTimeDiff": 70000
    },
    "grpcSettings": {
      "serviceName": "$7",
      "multiMode": true
    }
  }
}
EOF
}

# 重建 Xray 合并配置(读取所有已安装的 rv/rg 协议):
# 返回 0=成功 1=校验失败 2=没有任何 Reality 协议
xray_rebuild_config() {
    local keys=() k frag all="" p u sh sp pk sid rpc rc
    ensure_dirs
    mapfile -t keys < <(installed_keys)
    for k in "${keys[@]}"; do
        case "$k" in vless-rv|vless-rg) ;; *) continue ;; esac
        p="$(env_get "$k" PORT)"; u="$(env_get "$k" UUID)"
        sh="$(env_get "$k" SNI_HOST)"; sp="$(env_get "$k" SNI_PORT)"
        pk="$(env_get "$k" REALITY_PK)"; sid="$(env_get "$k" SHORT_ID)"
        rpc="$(env_get "$k" RPC)"
        [[ -z "$p" || -z "$u" || -z "$sh" || -z "$pk" ]] && { warn "跳过 $k: 参数文件不完整"; continue; }
        if ! reality_key_valid "$pk"; then
            warn "$k 的 Reality 私钥格式异常(${#pk} 位, 应为 43 位 base64url)!"
            warn "  这种密钥能通过配置校验, 但 Xray 启动时会立即退出(端口不监听)。"
            warn "  修复: 代理管理 → 修改配置 → 选『重新生成伪装域名(并重置 Reality 密钥)』后重新导入链接。"
        fi
        sp="${sp:-443}"
        if [[ "$k" == "vless-rv" ]]; then
            frag="$(xray_inbound_rv "$p" "$u" "$sh" "$sp" "$pk" "$sid")"
        else
            frag="$(xray_inbound_rg "$p" "$u" "$sh" "$sp" "$pk" "$sid" "${rpc:-grpcTls}")"
        fi
        all+="${all:+,}$frag"
    done
    if [[ -z "$all" ]]; then return 2; fi
    # 注意: 临时文件必须以 .json 结尾, 新版 Xray 按扩展名识别配置格式, .tmp 会被拒绝加载
    printf '{"log":{"loglevel":"warning"},"inbounds":[%s],"outbounds":[{"protocol":"freedom","tag":"direct"}]}' "$all" > "${XRAY_CFG}.tmp.json"
    if ! xray_test_config "${XRAY_CFG}.tmp.json"; then
        mv -f "${XRAY_CFG}.tmp.json" "${XRAY_CFG}.testfail.json" 2>/dev/null
        err "Xray 配置校验失败, 内容已保留在 ${XRAY_CFG}.testfail.json (上方为内核报错)"
        return 1
    fi
    mv -f "${XRAY_CFG}.tmp.json" "$XRAY_CFG"
    # 老版本残留: rv/rg 曾由 sing-box 承载, 迁移到 Xray 后移除其配置, 避免端口双占用
    rm -f "$SB_CFG_DIR/vless-rv.json" "$SB_CFG_DIR/vless-rg.json"
    return 0
}

#--------------------------------- 配置/env 管理 ----------------------------------
installed_keys() {
    local f k
    for f in "$SB_ENV_DIR"/*.env; do
        [[ -f "$f" ]] || continue
        k="$(basename "$f" .env)"
        echo "$k"
    done
}

load_env() {
    local k="$1"
    # 以下变量将被 env 文件覆盖/补充
    PORT=""; METHOD=""; PASSWORD=""; UUID=""; NAME=""; MASQ=""
    CERT_MODE=""; CERT_FILE=""; KEY_FILE=""; DOMAIN=""; CERT_CN=""
    SNI_HOST=""; SNI_PORT=""; RPC=""
    REALITY_PK=""; REALITY_PUB=""; SHORT_ID=""
    # shellcheck disable=SC1090
    source "$SB_ENV_DIR/$k.env"
}

#--------------------------------- 自签证书 -------------------------------------
gen_self_signed_cert() {
    # $1 = 协议key, $2 = CN(伪装域名或 localhost)；产出 $SB_CERT_DIR/$1.pem / $1.key
    # 每个协议独立证书, 多协议可各自使用不同伪装域名互不干扰
    local k="$1"
    local cn="$(echo "$2" | grep -oE '^[a-zA-Z0-9.-]+' || true)"
    mkdir -p "$SB_CERT_DIR"
    if [[ -f "$SB_CERT_DIR/$k.pem" && -f "$SB_CERT_DIR/$k.key" ]]; then
        echo "$SB_CERT_DIR/$k.pem"; return 0
    fi
    # 优先带 SAN(新 openssl), 失败则退回普通模式(老 openssl)
    if ! openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
            -keyout "$SB_CERT_DIR/$k.key" -out "$SB_CERT_DIR/$k.pem" \
            -addext "subjectAltName=DNS:${cn:-localhost}" \
            -subj "/CN=${cn:-localhost}" >/dev/null 2>&1; then
        openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
            -keyout "$SB_CERT_DIR/$k.key" -out "$SB_CERT_DIR/$k.pem" \
            -subj "/CN=${cn:-localhost}" >/dev/null 2>&1 || return 1
    fi
    chmod 600 "$SB_CERT_DIR/$k.key"
    echo "$SB_CERT_DIR/$k.pem"
}

#--------------------------------- ACME 证书自动签发 (acme.sh) --------------------
# $1 = 协议key, $2 = 域名; 成功后产出 $SB_CERT_DIR/$1.pem / $1.key (acme.sh 自动续期)
acme_issue_cert() {
    local k="$1" domain="$2"
    local acme="$HOME/.acme.sh/acme.sh"
    local ipres="${PUB_IP//[\[\]]/}" resolved log
    if port_in_use 80 tcp; then
        err "80 端口已被占用(HTTP 验证需要临时监听 80 端口)，请先释放后重试:"
        port_busy_info 80 | sed 's/^/    /'
        return 1
    fi
    # 域名解析检查(尽力而为, 仅提示不强制)
    resolved=""
    command -v getent >/dev/null 2>&1 && resolved="$(getent ahostsv4 "$domain" 2>/dev/null | awk 'NR==1{print $1}')"
    [[ -z "$resolved" ]] && resolved="$(ping -c1 -W2 "$domain" 2>/dev/null | head -n1 | grep -oE '\([0-9.]+\)' | tr -d '()')"
    if [[ -n "$resolved" && -n "$ipres" && "$resolved" != "$ipres" ]]; then
        warn "域名 $domain 当前解析到 $resolved，与本机公网 IP $ipres 不一致，签发大概率失败。"
        warn "常见原因: 域名套了 CDN 代理(如 Cloudflare 小黄云)、A 记录还没改。"
        ask_choice "如何处理?" 2 1 "仍然继续尝试" 2 "取消, 改用自签证书"
        [[ "$RESULT" == "1" ]] || return 1
    fi
    if [[ ! -x "$acme" ]]; then
        info "安装 acme.sh ..."
        curl -fsSL --connect-timeout 8 --max-time 120 https://get.acme.sh | sh -s email=proxybox@localhost >/dev/null 2>&1
        if [[ ! -x "$acme" ]]; then
            err "acme.sh 安装失败(可能网络受限)。可改用『已有证书文件』方式。"
            return 1
        fi
    fi
    info "向 Let's Encrypt 申请证书(域名: $domain, HTTP 验证)..."
    if ! log="$("$acme" --issue --standalone -d "$domain" --server letsencrypt --keylength ec-256 2>&1)"; then
        printf '%s\n' "$log" | tail -n 8 | sed 's/^/    /'
        err "证书签发失败。常见原因: 域名未解析到本机 / 80 端口被运营商封禁 / 域名仍在 CDN 代理状态。"
        return 1
    fi
    mkdir -p "$SB_CERT_DIR"
    local reload_cmd
    if [[ "$INIT_SYS" == "systemd" ]]; then reload_cmd="systemctl restart $SERVICE_NAME"; else reload_cmd="rc-service $SERVICE_NAME restart"; fi
    if ! "$acme" --install-cert -d "$domain" --ecc \
            --fullchain-file "$SB_CERT_DIR/$k.pem" \
            --key-file "$SB_CERT_DIR/$k.key" \
            --reloadcmd "$reload_cmd" >/dev/null 2>&1; then
        err "证书安装失败。"
        return 1
    fi
    chmod 600 "$SB_CERT_DIR/$k.key"
    ok "证书已签发并安装: $SB_CERT_DIR/$k.pem (acme.sh 会自动续期并重启服务)"
    return 0
}

#--------------------------------- 配置生成 -------------------------------------
# 生成单协议配置文件 + 语法校验 + 失败回滚备份
gen_config() {
    local k="$1"
    local cfg="$SB_CFG_DIR/$k.json"
    local bak="$SB_BAK_DIR/$k.json.bak"
    local errf
    errf="$(mktemp)"
    load_env "$k"
    CUR_KEY="$k"
    # TLS 型协议使用自签模式但还没有本协议独立证书时, 先补生成(兼容旧版共享证书的安装)
    case "$k" in
        hy2|tuic)
            if [[ "$CERT_MODE" != "manual" && ( ! -f "$SB_CERT_DIR/$k.pem" || ! -f "$SB_CERT_DIR/$k.key" ) ]]; then
                gen_self_signed_cert "$k" "${DOMAIN:-localhost}" >/dev/null || true
            fi ;;
    esac
    [[ -f "$cfg" ]] && cp -f "$cfg" "$bak"
    case "$k" in
        ss2022)   cfg_body_ss2022   > "$cfg" ;;
        hy2)      cfg_body_hy2      > "$cfg" ;;
        tuic)     cfg_body_tuic     > "$cfg" ;;
        vless-ts) cfg_body_vless_ts > "$cfg" ;;
        # Reality(vless-rv/vless-rg) 由 Xray 内核接管, 绝不能再生成 sing-box 配置,
        # 否则 sing-box 与 Xray 同时监听同一端口 → 客户端握手失败(超时)
        vless-rv|vless-rg) rm -f "$cfg" "$bak"; rm -f "$errf"; return 0 ;;
        *) err "未知协议: $k"; rm -f "$errf"; return 1 ;;
    esac
    chmod 600 "$cfg"
    if ! "$SB_BIN" check -C "$SB_CFG_DIR" >"$errf" 2>&1; then
        err "配置校验未通过 ($k):"
        sed 's/^/    /' "$errf"
        if [[ -f "$bak" ]]; then warn "已回滚到修改前的配置"; mv -f "$bak" "$cfg"; else rm -f "$cfg"; fi
        rm -f "$errf"
        return 1
    fi
    rm -f "$errf"
    ok "配置校验通过: $k"
    return 0
}

# 重新生成全部配置并重启
apply_all() {
    ensure_service
    local k rc=0 has_reality=0
    for k in $(installed_keys); do
        # Reality 协议走 Xray 内核, 跳过 sing-box 配置生成
        case "$k" in vless-rv|vless-rg) has_reality=1; continue ;; esac
        gen_config "$k" || rc=1
    done
    # 清掉 sing-box 目录里的 Reality 残留(老版本迁移遗留), 避免与 Xray 抢端口
    rm -f "$SB_CFG_DIR/vless-rv.json" "$SB_CFG_DIR/vless-rg.json"
    (( rc == 1 )) && return 1
    svc_restart
    # 有 Reality 协议时重建并重启 Xray
    if [[ "$has_reality" == "1" ]]; then
        ensure_xray_core && xray_ensure_service && xray_rebuild_config && xsvc_restart
    fi
}

cfg_body_ss2022() {
    cat <<EOF
{
  "inbounds": [
    {
      "type": "shadowsocks",
      "tag": "in-ss2022",
      "listen": "$(listen_host)",
      "listen_port": ${PORT},
      "method": "${METHOD}",
      "password": "${PASSWORD}"
    }
  ]
}
EOF
}

# hy2 / tuic 共用的 TLS 字段拼装(自签或指定证书, 各协议独立证书文件)
tls_fields() {
    if [[ "$CERT_MODE" == "manual" ]]; then
        echo "\"certificate_path\": \"${CERT_FILE}\", \"key_path\": \"${KEY_FILE}\""
    else
        echo "\"certificate_path\": \"${SB_CERT_DIR}/${CUR_KEY}.pem\", \"key_path\": \"${SB_CERT_DIR}/${CUR_KEY}.key\""
    fi
}

cfg_body_hy2() {
    local tls
    tls="$(tls_fields)"
    cat <<EOF
{
  "inbounds": [
    {
      "type": "hysteria2",
      "tag": "in-hy2",
      "listen": "$(listen_host)",
      "listen_port": ${PORT},
      "users": [
        { "password": "${PASSWORD}" }
      ],
      "masquerade": "${MASQ}",
      "tls": {
        "enabled": true,
        "alpn": ["h3"],
        ${tls}
      }
    }
  ]
}
EOF
}

cfg_body_tuic() {
    local tls
    tls="$(tls_fields)"
    cat <<EOF
{
  "inbounds": [
    {
      "type": "tuic",
      "tag": "in-tuic",
      "listen": "$(listen_host)",
      "listen_port": ${PORT},
      "users": [
        { "uuid": "${UUID}", "password": "${PASSWORD}" }
      ],
      "congestion_control": "bbr",
      "udp_relay_mode": "native",
      "tls": {
        "enabled": true,
        "alpn": ["h3"],
        ${tls}
      }
    }
  ]
}
EOF
}

cfg_body_vless_rv() {
    cat <<EOF
{
  "inbounds": [
    {
      "type": "vless",
      "tag": "in-vless-rv",
      "listen": "$(listen_host)",
      "listen_port": ${PORT},
      "users": [
        { "uuid": "${UUID}", "flow": "xtls-rprx-vision" }
      ],
      "tls": {
        "enabled": true,
        "reality": {
          "enabled": true,
          "handshake": { "server": "${SNI_HOST}", "server_port": ${SNI_PORT} },
          "private_key": "${REALITY_PK}",
          "short_id": [ "${SHORT_ID}" ]
        }
      }
    }
  ]
}
EOF
}

cfg_body_vless_rg() {
    cat <<EOF
{
  "inbounds": [
    {
      "type": "vless",
      "tag": "in-vless-rg",
      "listen": "$(listen_host)",
      "listen_port": ${PORT},
      "users": [
        { "uuid": "${UUID}" }
      ],
      "transport": {
        "type": "grpc",
        "service_name": "${RPC}"
      },
      "tls": {
        "enabled": true,
        "reality": {
          "enabled": true,
          "handshake": { "server": "${SNI_HOST}", "server_port": ${SNI_PORT} },
          "private_key": "${REALITY_PK}",
          "short_id": [ "${SHORT_ID}" ]
        }
      }
    }
  ]
}
EOF
}

# VLESS-Vision-TLS(带域名·自签证书): 标准 TLS + 自签证书, 兼容性最好
cfg_body_vless_ts() {
    cat <<EOF
{
  "inbounds": [
    {
      "type": "vless",
      "tag": "in-vless-ts",
      "listen": "$(listen_host)",
      "listen_port": ${PORT},
      "users": [
        { "uuid": "${UUID}", "flow": "xtls-rprx-vision" }
      ],
      "tls": {
        "enabled": true,
        "server_name": "${DOMAIN}",
        "certificate_path": "${SB_CERT_DIR}/vless-ts.pem",
        "key_path": "${SB_CERT_DIR}/vless-ts.key"
      }
    }
  ]
}
EOF
}

#--------------------------------- 分享链接生成 ----------------------------------
insecure_hint() {
    if [[ "$CERT_MODE" == "manual" ]]; then echo "0"; else echo "1"; fi
}

link_ss2022() {
    local userinfo
    userinfo="$(printf '%s' "${METHOD}:${PASSWORD}" | b64url)"
    echo "ss://${userinfo}@${IP}:${PORT}#${NODE_LABEL}"
}

link_hy2() {
    local q=""
    [[ -n "$DOMAIN" && "$DOMAIN" != "localhost" ]] && q="&sni=${DOMAIN}"
    [[ "$(insecure_hint)" == "1" ]] && q="${q}&insecure=1"
    echo "hy2://${PASSWORD}@${IP}:${PORT}/?obfs=none${q}#${NODE_LABEL}"
}

link_tuic() {
    local q="&sni=${DOMAIN}&congestion_control=bbr&udp_relay_mode=native&alpn=h3"
    [[ "$(insecure_hint)" == "1" ]] && q="${q}&allow_insecure=1"
    echo "tuic://${UUID}:${PASSWORD}@${IP}:${PORT}/?${q}#${NODE_LABEL}"
}

link_vless_rv() {
    echo "vless://${UUID}@${IP}:${PORT}?encryption=none&type=tcp&security=reality&flow=xtls-rprx-vision&sni=${SNI_HOST}&fp=chrome&pbk=${REALITY_PUB}&sid=${SHORT_ID}#${NODE_NAME}"
}

link_vless_rg() {
    echo "vless://${UUID}@${IP}:${PORT}?encryption=none&type=grpc&security=reality&serviceName=${RPC}&sni=${SNI_HOST}&fp=chrome&pbk=${REALITY_PUB}&sid=${SHORT_ID}#${NODE_NAME}"
}

link_vless_ts() {
    echo "vless://${UUID}@${IP}:${PORT}?encryption=none&type=tcp&security=tls&flow=xtls-rprx-vision&sni=${DOMAIN}&fp=chrome&allowInsecure=1#${NODE_NAME}"
}

# 打印某协议的分享信息: print_share <key>
print_share() {
    local k="$1"
    load_env "$k"
    local name
    name="${NAME:-${k}}-${PORT}"
    if [[ "$k" == "ss2022" || "$k" == "hy2" ]]; then NODE_LABEL="$(echo "$name" | sed 's/ /_/g')"; else NODE_NAME="$(echo "$name" | sed 's/ /_/g')"; fi
    get_public_ip >/dev/null 2>&1 || warn "探测公网 IP 失败，链接中的 IP 请自行替换"
    IP="${PUB_IP}"
    [[ -z "$IP" ]] && IP="[服务器IP]"
    local raw=""
    case "$k" in
        ss2022)   raw="$(link_ss2022)" ;;
        hy2)      raw="$(link_hy2)" ;;
        tuic)     raw="$(link_tuic)" ;;
        vless-rv) raw="$(link_vless_rv)" ;;
        vless-rg) raw="$(link_vless_rg)" ;;
        vless-ts) raw="$(link_vless_ts)" ;;
    esac
    hr
    title "${k} 节点信息"
    printf '  端口: %s    名称: %s\n' "$PORT" "$name"
    case "$k" in
        ss2022)
            printf '  加密: %s\n' "$METHOD"
            printf '  密码: %s\n' "$PASSWORD" ;;
        hy2)
            printf '  密码: %s\n' "$PASSWORD"
            printf '  SNI/伪装域名: %s\n' "$DOMAIN"
            printf '  证书: %s\n' "$([[ "$CERT_MODE" == "manual" ]] && echo "自有/签发证书(已校验, 无需开不安全)" || echo "自签(客户端需开启『允许不安全』)")" ;;
        tuic)
            printf '  UUID: %s\n' "$UUID"
            printf '  密码: %s\n' "$PASSWORD"
            printf '  SNI/伪装域名: %s\n' "$DOMAIN"
            printf '  证书: %s\n' "$([[ "$CERT_MODE" == "manual" ]] && echo "自有/签发证书(已校验, 无需开不安全)" || echo "自签(客户端需开启『允许不安全』)")" ;;
        vless-rv|vless-rg)
            printf '  UUID: %s\n' "$UUID"
            printf '  伪装站点(SNI): %s:%s\n' "$SNI_HOST" "${SNI_PORT:-443}"
            [[ "$k" == "vless-rg" ]] && printf '  grpc 服务名: %s\n' "$RPC"
            printf '  公钥(pbk): %s\n' "$REALITY_PUB"
            printf '  short_id(sid): %s\n' "$SHORT_ID" ;;
        vless-ts)
            printf '  UUID: %s\n' "$UUID"
            printf '  域名(SNI): %s\n' "$DOMAIN"
            printf '  证书: 自签证书(客户端需开启『允许不安全』/allowInsecure)\n' ;;
    esac
    echo
    info "分享链接(可直接导入主流客户端如 v2rayN / v2rayNG / NekoBox / Shadowrocket / Streisand):"
    printf '%s  %s%s\n' "$BOLD" "$raw" "$NC"
    echo
}

#--------------------------------- 安装前公共准备 ----------------------------------
pre_install() {
    title "$1"
    info "说明: $2"
    ensure_deps
    ensure_core || return 1
    check_proxy_conflicts || return 1
    return 0
}

# 询问节点名称
ask_node_name() {
    local def="$1"
    ask_valid "设置节点名称(用于分享链接备注, 建议不含空格)" "$def" v_any
    NODE_NAME="$RESULT"
}

# 测试目标站点是否支持 TLS1.3 (Reality 必需): 0=支持 1=不支持 2=无法测试
test_tls13() {
    local host="$1" port="${2:-443}" out
    command -v openssl >/dev/null 2>&1 || return 2
    command -v timeout >/dev/null 2>&1 || return 2
    out="$(echo | timeout 8 openssl s_client -connect "${host}:${port}" -servername "$host" -tls1_3 2>/dev/null)"
    [[ "$out" == *"TLSv1.3"* ]] || return 1
    return 0
}

# 检查 Reality 目标域名是否套了 Cloudflare CDN(参考 v2ray-agent checkRealityDest):
# 返回 1=建议更换, 0=可用
check_reality_dest() {
    local trace
    trace="$(curl -s --connect-timeout 5 --max-time 8 "https://$(echo "$1" | cut -d ':' -f1)/cdn-cgi/trace" 2>/dev/null | grep 'visit_scheme=https')"
    if [[ -n "$trace" ]]; then
        warn "检测到 $1 启用了 Cloudflare CDN 代理。Reality 目标域名套 CDN 会导致你的 VPS 流量被他人滥用，强烈不建议。"
        ask_choice "如何处理?" 2 1 "换一个域名(推荐)" 2 "仍要使用(自行承担风险)"
        [[ "$RESULT" == "1" ]] && return 1
    fi
    return 0
}

# openssl 兜底生成 Reality X25519 密钥对(一次生成一对): 成功后写入 OSSL_PRIV / OSSL_PUB (base64)
ossl_reality_keypair() {
    command -v openssl >/dev/null 2>&1 || return 1
    local dir pem privhex pubhex
    dir="$(mktemp -d)" || return 1
    pem="$dir/x25519.pem"
    openssl genpkey -algorithm X25519 -out "$pem" 2>/dev/null || { rm -rf "$dir"; return 1; }
    privhex="$(openssl pkey -in "$pem" -text -noout 2>/dev/null | awk '/priv:/{f=1;next} /pub:/{f=0} f' | tr -d ' :\n')"
    pubhex="$(openssl pkey -in "$pem" -pubout -text -noout 2>/dev/null | awk '/pub:/{f=1;next} f' | tr -d ' :\n')"
    rm -rf "$dir"
    [[ "$privhex" =~ ^[0-9a-fA-F]{64}$ && "$pubhex" =~ ^[0-9a-fA-F]{64}$ ]] || return 1
    # Reality 只接受 base64url 无填充(43 字符): 标准 base64 的 + / = 必须转换/去除, 否则内核启动即退出
    OSSL_PRIV="$(printf '%b' "$(echo "$privhex" | sed 's/../\\x&/g')" | openssl base64 -A 2>/dev/null | tr '+/' '-_' | tr -d '=')"
    OSSL_PUB="$(printf '%b' "$(echo "$pubhex" | sed 's/../\\x&/g')" | openssl base64 -A 2>/dev/null | tr '+/' '-_' | tr -d '=')"
    [[ ${#OSSL_PRIV} -eq 43 && ${#OSSL_PUB} -eq 43 ]]
}

# Reality 密钥格式校验: X25519 密钥必须是 43 位 base64url(无填充)
reality_key_valid() { [[ "$1" =~ ^[A-Za-z0-9_-]{43}$ ]]; }

# reality 相关公共询问: 设置 SNI_HOST/SNI_PORT/REALITY_PK/REALITY_PUB/SHORT_ID
ask_reality_params() {
    title "Reality 偷域名(伪装目标)设置"
    info "原理: 把你的代理流量伪装成对某个真实大站的 HTTPS 访问，即『偷』别人的域名当门面，"
    info "      因此不需要自己的域名、也不需要购买或申请任何证书。"
    info "目标要求: ①境外可直连 ②支持 TLS1.3 与 H2 ③访问不发生 301/302 跳转 ④最好是大厂自有域名(而非公共 CDN)。"
    info "不确定就直接回车用默认，选择后脚本会自动测试目标是否合格。"
    while :; do
        ask_choice "选择要偷的域名(伪装目标)" 1 \
            1 "www.apple.com（推荐: 苹果自有站, 全球节点多, TLS1.3 稳定）" \
            2 "www.microsoft.com（微软官方站, TLS1.3）" \
            3 "www.bing.com（微软搜索引擎, TLS1.3）" \
            4 "www.spotify.com（流媒体站, 部分地区直连质量好）" \
            5 "偷自己的域名（需已解析到一台支持 TLS1.3 的服务器或 CDN; 注意不能解析到本机自身）" \
            6 "自定义其他域名（如 www.nvidia.com / dl.google.com, 需满足上述目标要求）"
        case "$RESULT" in
            1) SNI_HOST="www.apple.com" ;;
            2) SNI_HOST="www.microsoft.com" ;;
            3) SNI_HOST="www.bing.com" ;;
            4) SNI_HOST="www.spotify.com" ;;
            5) ask_valid "输入你自己的域名" "" v_domain; SNI_HOST="$RESULT"; check_reality_dest "$SNI_HOST" || continue ;;
            6) ask_valid "输入自定义目标域名" "www.nvidia.com" v_domain; SNI_HOST="$RESULT"; check_reality_dest "$SNI_HOST" || continue ;;
        esac
        while :; do
            ask_valid "目标站点端口(一般保持 443, 除非目标站用非标 TLS 端口)" "443" v_port
            SNI_PORT="$RESULT"
            (( 10#$SNI_PORT == 80 )) && { err "目标端口必须是 TLS(HTTPS) 端口, 80 端口是 HTTP 不支持"; continue; }
            break
        done
        info "正在测试 $SNI_HOST:$SNI_PORT 的 TLS1.3 支持(约 3~8 秒)..."
        test_tls13 "$SNI_HOST" "$SNI_PORT"
        local trc=$?
        if [[ "$trc" == "0" ]]; then
            ok "目标站点合格, 支持 TLS1.3"
            break
        elif [[ "$trc" == "2" ]]; then
            warn "本机缺少 openssl/timeout, 无法自动测试, 请自行确认目标支持 TLS1.3。"
            break
        else
            warn "$SNI_HOST:$SNI_PORT 未通过 TLS1.3 测试(网络不通 / 不支持 / 或解析到了本机自身)。"
            ask_choice "如何处理?" 1 \
                1 "换一个伪装目标(推荐)" \
                2 "仍然使用(Reality 握手可能失败, 无法工作)"
            [[ "$RESULT" == "1" ]] || break
        fi
    done
    info "生成 Reality 密钥对..."
    local kp tries=0
    while (( tries < 2 )); do
        tries=$((tries+1))
        kp="$("$SB_BIN" generate reality-keypair 2>&1)"
        REALITY_PK="$(echo "$kp" | awk '/PrivateKey/{print $2}')"
        REALITY_PUB="$(echo "$kp" | awk '/PublicKey/{print $2}')"
        reality_key_valid "$REALITY_PK" && reality_key_valid "$REALITY_PUB" && break
        # 兜底: sing-box 无法执行/输出异常时, 用 openssl 直接生成 X25519 密钥对(转 base64url)
        warn "密钥格式异常(私钥 ${#REALITY_PK} 位/公钥 ${#REALITY_PUB} 位, 应为 43 位), 尝试 openssl 兜底..."
        if ossl_reality_keypair && reality_key_valid "$OSSL_PRIV" && reality_key_valid "$OSSL_PUB"; then
            REALITY_PK="$OSSL_PRIV"
            REALITY_PUB="$OSSL_PUB"
            ok "openssl 兜底生成成功"
            break
        fi
    done
    if ! reality_key_valid "$REALITY_PK" || ! reality_key_valid "$REALITY_PUB"; then
        err "Reality 密钥生成异常: 私钥 ${#REALITY_PK} 位 / 公钥 ${#REALITY_PUB} 位, 正常均应为 43 位 base64url。"
        err "长度不对的密钥能通过配置校验, 但内核启动时会立即退出(端口不监听)。"
        err "请手动排查: '$SB_BIN version' 是否可运行; Alpine 先执行 apk add gcompat libstdc++ openssl。"
        die "生成 Reality 密钥失败。"
    fi
    SHORT_ID="$(gen_hex 4)"
    ok "Reality 参数就绪 (偷域名: $SNI_HOST:$SNI_PORT, 短ID: $SHORT_ID)"
}

#--------------------------------- SS2022 ----------------------------------------
add_ss2022() {
    pre_install "安装 Shadowsocks-2022" "SS2022 是 Shadowsocks 的最新规范，针对重放攻击加固，UDP 支持完整。TCP 传输，速度快，抗封锁强度中等。" || return 1
    ask_choice "选择加密方式" 1 \
        1 "2022-blake3-aes-256-gcm (推荐, 默认, 安全性最高)" \
        2 "2022-blake3-aes-128-gcm (更省 CPU, 速度略快)" \
        3 "2022-blake3-chacha20-poly1305 (老 CPU 无 AES 加速时选)"
    case "$RESULT" in
        1) METHOD="2022-blake3-aes-256-gcm"; PKG_LEN=32 ;;
        2) METHOD="2022-blake3-aes-128-gcm"; PKG_LEN=16 ;;
        3) METHOD="2022-blake3-chacha20-poly1305"; PKG_LEN=32 ;;
    esac
    ask_port 8388 tcp
    title "SS2022 密码设置"
    info "填写规则: 必须是与加密位数匹配的 Base64 密码(128 位=16 字节 / 256 位=32 字节)。"
    info "小白直接回车即可，脚本会自动生成合规随机密码。"
    local defpass
    defpass="$(gen_b64 "$PKG_LEN")"
    while :; do
        ask "输入 SS2022 密码(Base64)" "$defpass"
        PASSWORD="$RESULT"
        local d exp="$PKG_LEN"
        d="$(printf '%s' "$PASSWORD" | openssl base64 -d -A 2>/dev/null | wc -c | tr -d ' ')"
        if [[ "$d" != "$exp" ]]; then
            err "密码解码后为 $d 字节，需要 $exp 字节。规则: aes-128 用 16 字节 Base64；aes-256/chacha20 用 32 字节。可用命令 openssl rand -base64 $exp 生成"
            continue
        fi
        break
    done
    ask_node_name "ss2022-${PORT}"
    SAVE_NAME="$NODE_NAME"
    cat > "$SB_ENV_DIR/ss2022.env" <<ENV
PORT=$PORT
METHOD=$METHOD
PASSWORD='$PASSWORD'
NAME='$SAVE_NAME'
CREATED="$(date '+%F %T')"
ENV
    chmod 600 "$SB_ENV_DIR/ss2022.env"
    apply_one "ss2022" || return 1
    print_share "ss2022"
    ok "SS2022 安装完成"
}

#--------------------------------- Hysteria2 --------------------------------------
add_hy2() {
    pre_install "安装 Hysteria2" "Hysteria2 是基于 QUIC(UDP) 的高性能代理，弱网/高丢包环境速度优势明显。UDP 协议，端口号可与 TCP 型协议(如 VLESS-Vision 的 TCP 443)相同并存。" || return 1
    ask_port 8443 udp
    title "Hysteria2 密码设置"
    local defpass
    defpass="$(gen_rand 16)"
    info "填写规则: 仅字母/数字/下划线/点/短横线（会拼进分享链接，别用特殊符号），8~32 位。回车直接用随机密码。"
    ask_valid "输入连接密码" "$defpass" v_uri_safe
    PASSWORD="$RESULT"
    title "TLS 证书设置"
    info "Hysteria2 走加密的 QUIC，必须有 TLS 证书。三种来源:"
    info "① 自签证书: 不需要域名，脚本自动生成；代价是客户端节点里要打开『允许不安全/Insecure』开关。"
    info "② 已有证书文件: 你已经用 acme.sh / certbot / 宝塔 等给域名签发过证书，直接填 pem 和 key 路径。"
    info "③ acme.sh 自动申请: 需要你自己的域名已把 A 记录解析到本机 IP，且 80 端口空闲；签发全自动、自动续期，客户端无需开不安全。"
    ask_choice "选择证书来源" 1 \
        1 "自签证书（没有域名选这个，最快最简单）" \
        2 "已有证书文件（我有签发好的 pem + key）" \
        3 "acme.sh 自动申请（我有域名且已解析到本机）"
    local fallback_selfsign=0
    CERT_FILE=""; KEY_FILE=""
    if [[ "$RESULT" == "2" ]]; then
        ask_valid "输入证书(.pem/.crt)完整路径" "" v_path
        CERT_FILE="$RESULT"
        ask_valid "输入私钥(.key)完整路径" "" v_path
        KEY_FILE="$RESULT"
        CERT_MODE="manual"
        ask_valid "输入证书对应的域名(用于客户端 SNI)" "" v_domain
        DOMAIN="$RESULT"
    elif [[ "$RESULT" == "3" ]]; then
        ask_valid "输入你的域名(需已解析到本机 IP)" "" v_domain
        DOMAIN="$RESULT"
        if acme_issue_cert "hy2" "$DOMAIN"; then
            CERT_MODE="manual"; CERT_FILE="$SB_CERT_DIR/hy2.pem"; KEY_FILE="$SB_CERT_DIR/hy2.key"; CERT_CN="$DOMAIN"
        else
            warn "自动签发失败，改为自签证书。"
            fallback_selfsign=1
        fi
    fi
    if [[ "$CERT_MODE" != "manual" || "$fallback_selfsign" == "1" ]]; then
        title "自签证书域名(伪装用)"
        info "这个域名只是写进自签证书的名字（俗称『偷』一个域名填），不需要真实存在、不需要解析。"
        info "客户端 SNI 也填它；客户端需打开『允许不安全/Insecure』开关。直接回车用默认即可。"
        ask_valid "输入伪装域名" "bing.com" v_domain
        DOMAIN="$RESULT"
        [[ "$CERT_CN" != "$DOMAIN" ]] && rm -f "$SB_CERT_DIR/hy2.pem" "$SB_CERT_DIR/hy2.key"
        gen_self_signed_cert hy2 "$DOMAIN" >/dev/null || warn "自签证书生成失败，将沿用旧证书"
        CERT_MODE="auto"; CERT_FILE=""; KEY_FILE=""; CERT_CN="$DOMAIN"
    fi
    title "网站伪装(可选)"
    info "没有认证的 HTTP 请求会被重定向到下面这个网站，让端口扫描行为更像正常站点。直接回车即可。"
    ask_valid "输入伪装网址" "https://www.bing.com" v_url
    MASQ="$RESULT"
    ask_node_name "hy2-${DOMAIN}"
    SAVE_NAME="$NODE_NAME"
    cat > "$SB_ENV_DIR/hy2.env" <<ENV
PORT=$PORT
PASSWORD='$PASSWORD'
DOMAIN='$DOMAIN'
CERT_MODE=$CERT_MODE
CERT_FILE=$CERT_FILE
KEY_FILE=$KEY_FILE
CERT_CN='$CERT_CN'
MASQ='$MASQ'
NAME='$SAVE_NAME'
CREATED="$(date '+%F %T')"
ENV
    chmod 600 "$SB_ENV_DIR/hy2.env"
    apply_one "hy2" || return 1
    print_share "hy2"
    ok "Hysteria2 安装完成"
}

#--------------------------------- TUIC -------------------------------------------
add_tuic() {
    pre_install "安装 TUIC v5" "TUIC 是基于 QUIC(UDP) 的代理，支持 0-RTT，延迟低。与 Hysteria2 同为 UDP 协议，端口可与 TCP 型协议共用同号。" || return 1
    ask_port 9443 udp
    title "TUIC 身份与密码"
    local dpass duuid
    duuid="$(gen_uuid)"
    dpass="$(gen_rand 16)"
    info "UUID: 客户端身份标识（一串带横线的十六进制）。回车自动生成。"
    ask_valid "输入 UUID" "$duuid" v_uuid
    UUID="$RESULT"
    info "密码: 用于 TUIC 认证。仅字母/数字/下划线等（会拼进分享链接），回车使用随机。"
    ask_valid "输入密码" "$dpass" v_uri_safe
    PASSWORD="$RESULT"
    title "TLS 证书设置"
    info "TUIC 同样需要 TLS 证书。三种来源:"
    info "① 自签证书: 不需要域名，脚本自动生成；客户端需打开『允许不安全/Insecure』开关。"
    info "② 已有证书文件: 已给域名签发过证书，直接填 pem 和 key 路径。"
    info "③ acme.sh 自动申请: 域名需已解析到本机 IP，80 端口空闲；全自动签发+续期。"
    ask_choice "选择证书来源" 1 \
        1 "自签证书（没有域名选这个，最快最简单）" \
        2 "已有证书文件（我有签发好的 pem + key）" \
        3 "acme.sh 自动申请（我有域名且已解析到本机）"
    local fallback_selfsign=0
    CERT_FILE=""; KEY_FILE=""
    if [[ "$RESULT" == "2" ]]; then
        ask_valid "输入证书(.pem/.crt)完整路径" "" v_path
        CERT_FILE="$RESULT"
        ask_valid "输入私钥(.key)完整路径" "" v_path
        KEY_FILE="$RESULT"
        CERT_MODE="manual"
        ask_valid "输入证书对应的域名(用于客户端 SNI)" "" v_domain
        DOMAIN="$RESULT"
    elif [[ "$RESULT" == "3" ]]; then
        ask_valid "输入你的域名(需已解析到本机 IP)" "" v_domain
        DOMAIN="$RESULT"
        if acme_issue_cert "tuic" "$DOMAIN"; then
            CERT_MODE="manual"; CERT_FILE="$SB_CERT_DIR/tuic.pem"; KEY_FILE="$SB_CERT_DIR/tuic.key"; CERT_CN="$DOMAIN"
        else
            warn "自动签发失败，改为自签证书。"
            fallback_selfsign=1
        fi
    fi
    if [[ "$CERT_MODE" != "manual" || "$fallback_selfsign" == "1" ]]; then
        title "自签证书域名(伪装用)"
        info "这个域名只是写进自签证书的名字（俗称『偷』一个域名填），不需要真实存在、不需要解析。"
        info "客户端 SNI 也填它；客户端需打开『允许不安全/Insecure』开关。直接回车用默认即可。"
        ask_valid "输入伪装域名" "bing.com" v_domain
        DOMAIN="$RESULT"
        [[ "$CERT_CN" != "$DOMAIN" ]] && rm -f "$SB_CERT_DIR/tuic.pem" "$SB_CERT_DIR/tuic.key"
        gen_self_signed_cert tuic "$DOMAIN" >/dev/null || warn "自签证书生成失败，将沿用旧证书"
        CERT_MODE="auto"; CERT_FILE=""; KEY_FILE=""; CERT_CN="$DOMAIN"
    fi
    ask_node_name "tuic-${DOMAIN}"
    SAVE_NAME="$NODE_NAME"
    cat > "$SB_ENV_DIR/tuic.env" <<ENV
PORT=$PORT
UUID='$UUID'
PASSWORD='$PASSWORD'
DOMAIN='$DOMAIN'
CERT_MODE=$CERT_MODE
CERT_FILE=$CERT_FILE
KEY_FILE=$KEY_FILE
CERT_CN='$CERT_CN'
NAME='$SAVE_NAME'
CREATED="$(date '+%F %T')"
ENV
    chmod 600 "$SB_ENV_DIR/tuic.env"
    apply_one "tuic" || return 1
    print_share "tuic"
    ok "TUIC 安装完成"
}

#--------------------------------- VLESS-Reality-Vision ---------------------------
add_vless_rv() {
    pre_install "安装 VLESS-Reality-Vision" "目前抗封锁能力最强的 TCP 方案：流量伪装成真实的 HTTPS 站点，无需域名/证书，Vision 流控进一步消除特征。响应快、兼容主流新一代客户端。" || return 1
    ask_reality_params
    ask_port 443 tcp
    ask_valid "输入 VLESS UUID" "$(gen_uuid)" v_uuid
    UUID="$RESULT"
    ask_node_name "vless-rv-${SNI_HOST}"
    SAVE_NAME="$NODE_NAME"
    cat > "$SB_ENV_DIR/vless-rv.env" <<ENV
PORT=$PORT
UUID='$UUID'
SNI_HOST='$SNI_HOST'
SNI_PORT=$SNI_PORT
REALITY_PK='$REALITY_PK'
REALITY_PUB='$REALITY_PUB'
SHORT_ID=$SHORT_ID
NAME='$SAVE_NAME'
CREATED="$(date '+%F %T')"
ENV
    chmod 600 "$SB_ENV_DIR/vless-rv.env"
    apply_one "vless-rv" || return 1
    print_share "vless-rv"
    ok "VLESS-Reality-Vision 安装完成"
}

#--------------------------------- VLESS-Reality-gRPC -----------------------------
add_vless_rg() {
    pre_install "安装 VLESS-Reality-gRPC" "与 Vision 类似但走 gRPC 流(可穿多级转发/中转更稳定)，需要客户端选择 grpc 传输。默认端口也是 443，若已装 TCP 版，请换端口。" || return 1
    ask_reality_params
    ask_port 443 tcp
    ask_valid "输入 VLESS UUID" "$(gen_uuid)" v_uuid
    UUID="$RESULT"
    ask_valid "输入 gRPC 服务名(客户端需一致)" "grpc" v_uri_safe
    RPC="$RESULT"
    ask_node_name "vless-grpc-${RPC}"
    SAVE_NAME="$NODE_NAME"
    cat > "$SB_ENV_DIR/vless-rg.env" <<ENV
PORT=$PORT
UUID='$UUID'
SNI_HOST='$SNI_HOST'
SNI_PORT=$SNI_PORT
RPC='$RPC'
REALITY_PK='$REALITY_PK'
REALITY_PUB='$REALITY_PUB'
SHORT_ID=$SHORT_ID
NAME='$SAVE_NAME'
CREATED="$(date '+%F %T')"
ENV
    chmod 600 "$SB_ENV_DIR/vless-rg.env"
    apply_one "vless-rg" || return 1
    print_share "vless-rg"
    ok "VLESS-Reality-gRPC 安装完成"
}

#--------------------------------- VLESS-Vision-TLS(带域名·自签证书) ---------------
# 参考 v2ray-agent 的 VLESS+TLS_Vision 思路: 标准 TLS + 自签证书, 对 Reality 兼容性差
# 的客户端(部分 Shadowrocket 旧版等)是可靠的替代方案; 域名仅作 SNI 伪装, 无需真实解析
add_vless_ts() {
    pre_install "安装 VLESS-Vision-TLS(带域名·自签证书)" "与 Reality 版同样使用 Vision 流控, 但走标准 TLS+自签证书: 需要一个域名(仅作伪装/SNI, 无需真实解析、无需购买证书), 客户端开启『允许不安全』即可。适合 Reality 兼容性差的客户端。" || return 1
    ask_port 8443 tcp
    title "域名与自签证书"
    info "填写规则: 一个你拥有的域名, 仅作为 SNI 伪装用, 不需要真的解析到本机。"
    ask_valid "输入你的域名" "" v_domain
    DOMAIN="$RESULT"
    info "生成自签证书(10 年有效期, 含 SAN)..."
    gen_self_signed_cert vless-ts "$DOMAIN" >/dev/null || die "自签证书生成失败, 请确认已安装 openssl。"
    ok "证书就绪: $SB_CERT_DIR/vless-ts.pem"
    ask_valid "输入 VLESS UUID" "$(gen_uuid)" v_uuid
    UUID="$RESULT"
    ask_node_name "vless-ts-${DOMAIN}"
    SAVE_NAME="$NODE_NAME"
    cat > "$SB_ENV_DIR/vless-ts.env" <<ENV
PORT=$PORT
UUID='$UUID'
DOMAIN='$DOMAIN'
NAME='$SAVE_NAME'
CREATED="$(date '+%F %T')"
ENV
    chmod 600 "$SB_ENV_DIR/vless-ts.env"
    apply_one "vless-ts" || return 1
    print_share "vless-ts"
    ok "VLESS-Vision-TLS 安装完成"
}

#--------------------------------- 安装后应用 -------------------------------------
# 应用某个协议: 生成配置并重启服务 (参数已在 env 文件中)
# 清理孤儿配置: configs 下有 json 但 instance.d 缺少对应 env 的残留文件(防止已删协议继续被 sing-box 加载)
cleanup_orphan_configs() {
    local f k
    # Reality 由 Xray 内核接管, sing-box 配置目录里绝不允许残留 vless-rv/rg (否则抢端口)
    rm -f "$SB_CFG_DIR/vless-rv.json" "$SB_CFG_DIR/vless-rg.json"
    for f in "$SB_CFG_DIR"/*.json; do
        [[ -e "$f" ]] || return 0
        k="$(basename "$f" .json)"
        if [[ ! -f "$SB_ENV_DIR/$k.env" ]]; then
            rm -f "$f" "$SB_BAK_DIR/$k.json.bak"
            warn "已清理残留配置: $k.json (对应协议参数文件不存在)"
        fi
    done
}

# 安装/修改后验证(参考 v2ray-agent 的安装后校验): 服务活跃 + 端口监听
# 监听地址: IPv6 可用用 ::(双栈), 否则退回 0.0.0.0 (Incus/LXC 等无 IPv6 容器必配)
listen_host() {
    if [[ -s /proc/net/if_inet6 ]]; then
        echo "::"
    else
        echo "0.0.0.0"
    fi
}

verify_installed() {
    local k="$1" port scheme i
    port="$(grep -E '^PORT=' "$SB_ENV_DIR/$k.env" 2>/dev/null | head -n1 | cut -d= -f2 | tr -d "'\"")"
    [[ -z "$port" ]] && return 0
    if ! kernel_active "$k"; then
        warn "安装后验证: 服务未运行! 最近日志($( [[ "$(proto_kernel "$k")" == "xray" ]] && echo "$XRAY_LOG_FILE" || echo "$LOG_FILE" )):"
        kernel_log_tail "$k" 15 | sed 's/^/    /'
        return 1
    fi
    scheme="tcp"; case "$k" in hy2|tuic) scheme="udp" ;; esac
    # 重试 3 次(每次间隔 1 秒), 避免 sing-box 尚未完成绑定就误报
    for i in 1 2 3; do
        if port_in_use "$port" "$scheme"; then
            ok "安装后验证通过: 服务运行中, $scheme 端口 $port 正在监听"
            return 0
        fi
        sleep 1
    done
    warn "安装后验证: $scheme 端口 $port 未监听! 最近日志:"
    kernel_log_tail "$k" 20 | sed 's/^/    /'
    return 1
}

apply_one() {
    local k="$1" rc
    ensure_dirs
    if [[ ! -f "$SB_ENV_DIR/$k.env" ]]; then
        err "未找到 $k 参数文件: $SB_ENV_DIR/$k.env"
        return 1
    fi
    if [[ "$(proto_kernel "$k")" == "xray" ]]; then
        # ---- Reality 协议: Xray 内核 (v2ray-agent 同款) ----
        ensure_xray_core || return 1
        ensure_service            # sing-box 仍承载其他协议
        xray_ensure_service
        xray_rebuild_config; rc=$?
        if [[ "$rc" == "2" ]]; then
            warn "没有任何 Reality 协议了, 停止 Xray 服务"
            xsvc_stop_now; rm -f "$XRAY_CFG"
            return 0
        fi
        if [[ "$rc" != "0" ]]; then
            err "Xray 配置生成/校验失败"
            return 1
        fi
        # sing-box 若还挂着旧 Reality 入站(老版本迁移), 必须删除后重启释放端口, 否则与 Xray 抢端口
        if [[ -f "$SB_CFG_DIR/vless-rv.json" || -f "$SB_CFG_DIR/vless-rg.json" ]]; then
            rm -f "$SB_CFG_DIR/vless-rv.json" "$SB_CFG_DIR/vless-rg.json"
            svc_do_restart >/dev/null 2>&1 || true
        fi
        if ! xsvc_restart; then
            err "Xray 服务重启失败, 最近日志如下:"
            xsvc_log_tail 20 | sed 's/^/    /'
            return 1
        fi
        sleep 1
        # 启动后存活检查: 坏密钥等运行期错误会让 Xray 启动即退出, 这里立刻报出来
        if ! xsvc_active; then
            err "Xray 启动后立即退出(进程不存活), 最近日志如下:"
            xsvc_log_tail 20 | sed 's/^/    /'
            return 1
        fi
    else
        ensure_service
        if ! gen_config "$k"; then
            err "$k 配置校验失败，已回滚备份"
            return 1
        fi
        if ! svc_restart; then
            err "服务重启失败，请尝试『代理管理』中的查看日志"
            return 1
        fi
    fi
    verify_installed "$k"
    return 0
}

#--------------------------------- 代理管理 ---------------------------------------
menu_list() {
    title "已安装代理列表"
    local keys=() k
    mapfile -t keys < <(installed_keys)
    if [[ ${#keys[@]} -eq 0 ]]; then
        warn "还没有安装任何代理协议。请到主菜单『1) 安装代理』添加。"
        return 0
    fi
    hr
    printf '  %-10s %-28s %-8s %s\n' "协议" "说明" "端口" "转发状态"
    hr
    local proto proto_name port st
    st="禁用"; svc_active && st="$(svc_status_text)"
    for k in "${keys[@]}"; do
        load_env "$k"
        case "$k" in
            ss2022)   proto_name="Shadowsocks-2022 (TCP)" ;;
            hy2)      proto_name="Hysteria2 (UDP/QUIC)" ;;
            tuic)     proto_name="TUIC v5 (UDP/QUIC)" ;;
            vless-rv) proto_name="VLESS-Reality-Vision (TCP)" ;;
            vless-rg) proto_name="VLESS-Reality-gRPC (TCP)" ;;
            vless-ts) proto_name="VLESS-Vision-TLS自签 (TCP)" ;;
            *)        proto_name="未知" ;;
        esac
        printf '  %-10s %-32s %-8s %s\n' "$k" "$proto_name" "${PORT}" "$st"
    done
    hr
    info "sing-box 状态: $(svc_active && echo 运行中 || echo 未运行)   版本: $("$SB_BIN" version 2>/dev/null | head -n1 || echo 未知)"
    if [[ -x "$XRAY_BIN" ]]; then
        info "Xray(Reality) 状态: $(xsvc_active && echo 运行中 || echo 未运行)   版本: $("$XRAY_BIN" version 2>/dev/null | head -n1 | awk '{print $2}' || echo 未知)"
    fi
    return 0
}

pick_key() {
    local keys=() k i=1
    mapfile -t keys < <(installed_keys)
    if [[ ${#keys[@]} -eq 0 ]]; then
        warn "尚无已安装的代理协议。"
        return 1
    fi
    for k in "${keys[@]}"; do
        load_env "$k"
        printf '  %s%s)%s %-9s 端口:%-6s 名称:%s\n' "$BOLD" "$i" "$NC" "$k" "$PORT" "$NAME"
        i=$((i+1))
    done
    while :; do
        ask "输入编号" "1"
        if [[ "$RESULT" =~ ^[0-9]+$ ]] && (( RESULT>=1 && RESULT<=${#keys[@]} )); then
            PICKED="${keys[$((RESULT-1))]}"
            return 0
        fi
        err "请输入 1~${#keys[@]} 的编号"
    done
}

menu_view() {
    title "查看节点信息与分享链接"
    pick_key || { pause; return; }
    print_share "$PICKED"
    pause
}

# env 文件重写(修改后调用), 依赖 load_env 结果；单引号会被剔除以保护 env 语法
rewrite_env() {
    local k="$1"
    local base="PORT UUID PASSWORD METHOD NAME DOMAIN CERT_MODE CERT_FILE KEY_FILE CERT_CN MASQ SNI_HOST SNI_PORT RPC REALITY_PUB REALITY_PK SHORT_ID"
    local var val out=""
    {
        for var in $base; do
            val="${!var:-}"
            val="${val//\'/}"
            [[ -n "$val" ]] && printf "%s='%s'\n" "$var" "$val"
        done
        # 必须带引号: 无引号时 source 会把时间部分当成命令执行(line N: command not found)
        printf "CREATED='%s'\n" "$(date '+%F %T')"
    } > "$SB_ENV_DIR/$k.env"
    chmod 600 "$SB_ENV_DIR/$k.env"
}

menu_edit() {
    title "修改代理配置"
    pick_key || { pause; return; }
    local k="$PICKED"
    load_env "$k"
    hr
    case "$k" in
        ss2022)   menu_edit_ss2022 "$k" ;;
        hy2)      menu_edit_hy2 "$k" ;;
        tuic)     menu_edit_tuic "$k" ;;
        vless-rv) menu_edit_vless "$k" rv ;;
        vless-rg) menu_edit_vless "$k" rg ;;
        vless-ts) menu_edit_ts "$k" ;;
    esac
}

menu_edit_ts() {
    local k="$1"
    ask_choice "VLESS-Vision-TLS 修改项" "" \
        1 "修改监听端口(当前: $PORT)" \
        2 "修改 UUID" \
        3 "更换域名(将重新生成自签证书)" \
        4 "重新生成自签证书" \
        5 "修改节点名称(当前: ${NAME})"
    [[ -z "$RESULT" ]] && return 0
    case "$RESULT" in
        1) ask_port "$PORT" tcp ;;
        2) ask_valid "输入新 UUID" "$UUID" v_uuid; UUID="$RESULT" ;;
        3)
            ask_valid "输入新域名" "$DOMAIN" v_domain; DOMAIN="$RESULT"
            rm -f "$SB_CERT_DIR/vless-ts.pem" "$SB_CERT_DIR/vless-ts.key"
            gen_self_signed_cert vless-ts "$DOMAIN" >/dev/null || die "自签证书生成失败" ;;
        4)
            rm -f "$SB_CERT_DIR/vless-ts.pem" "$SB_CERT_DIR/vless-ts.key"
            gen_self_signed_cert vless-ts "$DOMAIN" >/dev/null
            warn "证书已重新生成, 自签证书客户端不校验, 无需改动客户端" ;;
        5) ask "输入新名称" "${NAME:-$k}"; NAME="$RESULT" ;;
    esac
    rewrite_env "$k"
    apply_one "$k" && print_share "$k"
    pause
}

menu_edit_ss2022() {
    local k="$1"
    ask_choice "SS2022 修改项" "" \
        1 "修改监听端口(当前: $PORT)" \
        2 "重新设置加密方式和密码" \
        3 "修改节点名称(当前: ${NAME})"
    [[ -z "$RESULT" ]] && return 0
    case "$RESULT" in
        1) ask_port "$PORT" tcp ;;
        2)
            ask_choice "选择加密方式" 1 \
                1 "2022-blake3-aes-256-gcm (推荐)" \
                2 "2022-blake3-aes-128-gcm (更省CPU)" \
                3 "2022-blake3-chacha20-poly1305"
            case "$RESULT" in
                1) METHOD="2022-blake3-aes-256-gcm"; PKG_LEN=32 ;;
                2) METHOD="2022-blake3-aes-128-gcm"; PKG_LEN=16 ;;
                3) METHOD="2022-blake3-chacha20-poly1305"; PKG_LEN=32 ;;
            esac
            local d exp="$PKG_LEN"
            while :; do
                ask "输入新密码(Base64, 回车自动生成合规密码)" "$(gen_b64 "$PKG_LEN")"
                PASSWORD="$RESULT"
                d="$(printf '%s' "$PASSWORD" | openssl base64 -d -A 2>/dev/null | wc -c | tr -d ' ')"
                [[ "$d" == "$exp" ]] && break
                err "密码解码后为 $d 字节，需要 $exp 字节。"
            done ;;
        3)
            ask "输入新名称" "${NAME:-$k}"
            NAME="$RESULT" ;;
    esac
    rewrite_env "$k"
    apply_one "$k" && print_share "$k"
    pause
}

menu_edit_hy2() {
    local k="$1"
    ask_choice "Hysteria2 修改项" "" \
        1 "修改监听端口(当前: $PORT)" \
        2 "修改连接密码(当前已设置)" \
        3 "更换证书方式(自签/已有文件/acme自动申请)" \
        4 "修改伪装域名(当前: ${DOMAIN}; 自签模式下会同步重新生成证书)" \
        5 "修改节点名称(当前: ${NAME})"
    [[ -z "$RESULT" ]] && return 0
    case "$RESULT" in
        1) ask_port "$PORT" udp ;;
        2) ask_valid "输入新密码" "$(gen_rand 16)" v_uri_safe; PASSWORD="$RESULT";;
        3)
            ask_choice "TLS 证书来源" 1 \
                1 "自签证书(客户端需允许不安全)" \
                2 "已有证书文件" \
                3 "acme.sh 自动申请(需域名解析到本机, 80 端口空闲)"
            if [[ "$RESULT" == "2" ]]; then
                ask_valid "输入证书路径" "${CERT_FILE:-}" v_path; CERT_FILE="$RESULT"
                ask_valid "输入私钥路径" "${KEY_FILE:-}" v_path; KEY_FILE="$RESULT"
                CERT_MODE="manual"
            elif [[ "$RESULT" == "3" ]]; then
                ask_valid "输入你的域名" "${DOMAIN:-}" v_domain; DOMAIN="$RESULT"
                if acme_issue_cert hy2 "$DOMAIN"; then
                    CERT_MODE="manual"; CERT_FILE="$SB_CERT_DIR/hy2.pem"; KEY_FILE="$SB_CERT_DIR/hy2.key"; CERT_CN="$DOMAIN"
                else
                    warn "签发失败, 保持原证书方式不变。"
                fi
            else
                [[ "$CERT_CN" != "$DOMAIN" ]] && rm -f "$SB_CERT_DIR/hy2.pem" "$SB_CERT_DIR/hy2.key"
                gen_self_signed_cert hy2 "$DOMAIN" >/dev/null && CERT_CN="$DOMAIN"
                CERT_MODE="auto"; CERT_FILE=""; KEY_FILE=""
                warn "已重新生成自签证书, 客户端需允许不安全"
            fi ;;
        4)
            ask_valid "输入伪装域名(自签模式下会同步重新生成证书)" "$DOMAIN" v_domain; DOMAIN="$RESULT"
            if [[ "$CERT_MODE" != "manual" && "$CERT_CN" != "$DOMAIN" ]]; then
                rm -f "$SB_CERT_DIR/hy2.pem" "$SB_CERT_DIR/hy2.key"
                gen_self_signed_cert hy2 "$DOMAIN" >/dev/null && CERT_CN="$DOMAIN"
                ok "自签证书已按新域名重新生成"
            fi;;
        5) ask "输入新名称" "${NAME:-$k}"; NAME="$RESULT";;
    esac
    rewrite_env "$k"
    apply_one "$k" && print_share "$k"
    pause
}

menu_edit_tuic() {
    local k="$1"
    ask_choice "TUIC 修改项" "" \
        1 "修改监听端口(当前: $PORT)" \
        2 "修改 UUID" \
        3 "修改密码" \
        4 "更换证书方式(自签/已有文件/acme自动申请)" \
        5 "修改伪装域名(当前: ${DOMAIN}; 自签模式下会同步重新生成证书)" \
        6 "修改节点名称(当前: ${NAME})"
    [[ -z "$RESULT" ]] && return 0
    case "$RESULT" in
        1) ask_port "$PORT" udp ;;
        2) ask_valid "输入新 UUID" "$UUID" v_uuid; UUID="$RESULT";;
        3) ask_valid "输入新密码" "$(gen_rand 16)" v_uri_safe; PASSWORD="$RESULT";;
        4)
            ask_choice "TLS 证书来源" 1 \
                1 "自签证书(客户端需允许不安全)" \
                2 "已有证书文件" \
                3 "acme.sh 自动申请(需域名解析到本机, 80 端口空闲)"
            if [[ "$RESULT" == "2" ]]; then
                ask_valid "输入证书路径" "${CERT_FILE:-}" v_path; CERT_FILE="$RESULT"
                ask_valid "输入私钥路径" "${KEY_FILE:-}" v_path; KEY_FILE="$RESULT"
                CERT_MODE="manual"
            elif [[ "$RESULT" == "3" ]]; then
                ask_valid "输入你的域名" "${DOMAIN:-}" v_domain; DOMAIN="$RESULT"
                if acme_issue_cert tuic "$DOMAIN"; then
                    CERT_MODE="manual"; CERT_FILE="$SB_CERT_DIR/tuic.pem"; KEY_FILE="$SB_CERT_DIR/tuic.key"; CERT_CN="$DOMAIN"
                else
                    warn "签发失败, 保持原证书方式不变。"
                fi
            else
                [[ "$CERT_CN" != "$DOMAIN" ]] && rm -f "$SB_CERT_DIR/tuic.pem" "$SB_CERT_DIR/tuic.key"
                gen_self_signed_cert tuic "$DOMAIN" >/dev/null && CERT_CN="$DOMAIN"
                CERT_MODE="auto"; CERT_FILE=""; KEY_FILE=""
                warn "已重新生成自签证书, 客户端需允许不安全"
            fi ;;
        5)
            ask_valid "输入伪装域名(自签模式下会同步重新生成证书)" "$DOMAIN" v_domain; DOMAIN="$RESULT"
            if [[ "$CERT_MODE" != "manual" && "$CERT_CN" != "$DOMAIN" ]]; then
                rm -f "$SB_CERT_DIR/tuic.pem" "$SB_CERT_DIR/tuic.key"
                gen_self_signed_cert tuic "$DOMAIN" >/dev/null && CERT_CN="$DOMAIN"
                ok "自签证书已按新域名重新生成"
            fi;;
        6) ask "输入新名称" "${NAME:-$k}"; NAME="$RESULT";;
    esac
    rewrite_env "$k"
    apply_one "$k" && print_share "$k"
    pause
}

menu_edit_vless() {
    local k="$1" kind="$2"
    if [[ "$kind" == "rv" ]]; then
        ask_choice "VLESS-Reality-Vision 修改项" "" \
            1 "修改监听端口(当前: $PORT)" \
            2 "修改 UUID" \
            3 "重新选择偷域名(伪装站点)并重置 Reality 密钥" \
            4 "修改节点名称(当前: ${NAME})"
    else
        ask_choice "VLESS-Reality-gRPC 修改项" "" \
            1 "修改监听端口(当前: $PORT)" \
            2 "修改 UUID" \
            3 "重新选择偷域名(伪装站点)并重置 Reality 密钥" \
            4 "修改 gRPC 服务名(当前: ${RPC})" \
            5 "修改节点名称(当前: ${NAME})"
    fi
    local sel="$RESULT"
    [[ -z "$sel" ]] && return 0
    case "$sel" in
        1) ask_port "$PORT" tcp ;;
        2) ask_valid "输入新 UUID" "$UUID" v_uuid; UUID="$RESULT";;
        3)
            ask_reality_params
            warn "伪装站点/密钥已更换, 所有客户端需要重新导入新分享链接！" ;;
        4)
            if [[ "$kind" == "rg" ]]; then
                ask_valid "输入 gRPC 服务名" "$RPC" v_uri_safe; RPC="$RESULT"
            else
                ask "输入新名称" "${NAME:-$k}"; NAME="$RESULT"
            fi ;;
        5)
            if [[ "$kind" == "rg" ]]; then
                ask "输入新名称" "${NAME:-$k}"; NAME="$RESULT"
            fi ;;
    esac
    rewrite_env "$k"
    apply_one "$k" && print_share "$k"
    pause
}

menu_delete() {
    title "删除代理"
    pick_key || { pause; return; }
    local k="$PICKED"
    load_env "$k"
    warn "即将删除协议 ${k} 的配置(端口 ${PORT}, 名称 ${NAME})"
    ask "确认删除? [y/N]" "n"
    if ! [[ "$RESULT" =~ ^[yY]([eE][sS])?$ ]]; then
        info "已取消删除"; pause; return
    fi
    rm -f "$SB_CFG_DIR/$k.json" "$SB_ENV_DIR/$k.env" "$SB_BAK_DIR/$k.json.bak"
    ok "已删除 $k"
    # Xray 承载的协议: 删除后重建合并配置并重启; 若无 Reality 协议了则停掉 Xray
    if [[ "$(proto_kernel "$k")" == "xray" ]]; then
        xray_rebuild_config; rc=$?
        if [[ "$rc" == "2" ]]; then
            xsvc_stop_now; rm -f "$XRAY_CFG"
            ok "已停止 Xray 服务(没有 Reality 协议了)"
        elif [[ "$rc" == "0" ]]; then
            xsvc_restart && ok "Xray 配置已重建并重启"
        else
            err "Xray 配置重建失败, 请查看上方提示"
        fi
    fi
    # 若已无任何协议, 询问是否连服务/内核一起卸载
    if [[ -z "$(installed_keys)" ]]; then
        ask_choice "已无任何代理配置, 是否继续清理?" 1 \
            1 "同时停止并禁用服务(保留内核程序)" \
            2 "彻底卸载(服务+sing-box程序+所有配置)" \
            3 "什么都不做"
        case "$RESULT" in
            1) svc_disable_now; ok "服务已停止并禁用自启" ;;
            2) uninstall_all ;;
        esac
    else
        svc_restart
    fi
    pause
}

menu_service() {
    title "服务控制"
    ask_choice "选择操作" 1 \
        1 "启动服务" \
        2 "停止服务" \
        3 "重启服务" \
        4 "查看服务状态"
    case "$RESULT" in
        1) svc_do_start && ok "已启动" ;;
        2) svc_do_stop && ok "已停止" ;;
        3) svc_restart; if [[ -f "$XRAY_CFG" ]]; then info "重启 Xray(Reality) 服务..."; xray_ensure_service; xsvc_restart; fi ;;
        4) svc_show_status ;;
    esac
    pause
}

menu_logs() {
    title "查看日志(最近 60 行)"
    info "--- sing-box (SS2022/Hy2/TUIC) ---"
    svc_log_tail 40 | sed 's/^/  /'
    if [[ -x "$XRAY_BIN" ]]; then
        info "--- Xray (Reality) ---"
        xsvc_log_tail 40 | sed 's/^/  /'
        info "Xray 日志文件: $XRAY_LOG_FILE"
    fi
    if [[ "$INIT_SYS" == "systemd" ]]; then
        info "持续跟踪: journalctl -u $SERVICE_NAME -f ; journalctl -u $XRAY_SERVICE -f"
    else
        info "持续跟踪: tail -f $LOG_FILE ; tail -f $XRAY_LOG_FILE"
    fi
    pause
}

uninstall_core() {
    if [[ "$INIT_SYS" == "systemd" && -f "$UNIT_PATH" ]]; then
        systemctl disable --now "$SERVICE_NAME" >/dev/null 2>&1
        rm -f "$UNIT_PATH"
        systemctl daemon-reload
    elif [[ "$INIT_SYS" == "openrc" && -x "/etc/init.d/${SERVICE_NAME}" ]]; then
        rc-service "$SERVICE_NAME" stop >/dev/null 2>&1
        rc-update del "$SERVICE_NAME" default >/dev/null 2>&1
        rm -f "/etc/init.d/${SERVICE_NAME}"
    fi
    rm -f "$SB_BIN" "$LOG_FILE" "/run/${SERVICE_NAME}.pid"
    # Xray 内核一并卸载
    xsvc_stop_now
    if [[ "$INIT_SYS" == "systemd" && -f "/etc/systemd/system/${XRAY_SERVICE}.service" ]]; then
        rm -f "/etc/systemd/system/${XRAY_SERVICE}.service"; systemctl daemon-reload
    elif [[ "$INIT_SYS" == "openrc" && -x "/etc/init.d/${XRAY_SERVICE}" ]]; then
        rm -f "/etc/init.d/${XRAY_SERVICE}"
    fi
    rm -f "$XRAY_BIN" "$XRAY_CFG" "$XRAY_LOG_FILE" "/run/${XRAY_SERVICE}.pid"
    rm -rf /usr/local/share/xray
    ok "sing-box 与 Xray 内核、服务均已卸载"
}

uninstall_all() {
    warn "该操作将删除: systemd 服务、sing-box 程序、/etc/sing-box 下全部配置与证书, 且不可恢复！"
    ask "确认彻底卸载? [y/N]" "n"
    [[ ! "$RESULT" =~ ^[yY]([eE][sS])?$ ]] && { info "已取消"; return 1; }
    uninstall_core
    rm -rf "$SB_DIR"
    ok "已彻底清除 ProxyBox 相关数据"
    # 卸载后验证(参考 v2ray-agent): 程序/配置/进程/服务均应清除
    local uv=1
    [[ -f "$SB_BIN" ]] && { warn "卸载验证: $SB_BIN 仍存在"; uv=0; }
    [[ -d "$SB_DIR" ]] && { warn "卸载验证: $SB_DIR 仍存在"; uv=0; }
    [[ -f "$UNIT_PATH" || -f "/etc/init.d/$SERVICE_NAME" ]] && { warn "卸载验证: 服务文件仍存在"; uv=0; }
    pgrep -x sing-box >/dev/null 2>&1 && { warn "卸载验证: 仍有 sing-box 进程运行"; uv=0; }
    [[ "$uv" == "1" ]] && ok "卸载后验证通过: 程序/配置/服务/进程均已清除"
    return 0
}

#--------------------------------- 防火墙放行 -------------------------------------
open_port_in_firewall() {
    local p="$1" proto="$2"
    [[ -z "$p" ]] && return 0
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
        ufw allow "${p}"/${proto} >/dev/null 2>&1 && ok "ufw 已放行 ${p}/${proto}" && return 0
    fi
    if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld 2>/dev/null; then
        firewall-cmd --permanent --add-port="${p}"/${proto} >/dev/null 2>&1
        firewall-cmd --reload >/dev/null 2>&1 && ok "firewalld 已放行 ${p}/${proto}" && return 0
    fi
    info "提示: 如使用云服务器(AWS/GCP/阿里云等), 请到控制台『安全组/防火墙』手动放行 ${p}/${proto}。"
}

#--------------------------------- 网络优化 (BBR/内核调优) -------------------------
show_net_status() {
    title "当前网络内核参数状态"
    local cc qdisc avail kern
    kern="$KERNEL"
    info "内核版本: ${kern}"
    if version_ge "${kern%%-*}" "4.9"; then
        ok "内核版本满足 BBR 要求 (≥ 4.9)"
    else
        warn "内核版本低于 4.9，无法开启 BBR。建议升级系统(如 Debian 12 / Ubuntu 22.04)。"
    fi
    cc="$([[ -r /proc/sys/net/ipv4/tcp_congestion_control ]] && cat /proc/sys/net/ipv4/tcp_congestion_control)"
    qdisc="$([[ -r /proc/sys/net/core/default_qdisc ]] && cat /proc/sys/net/core/default_qdisc)"
    avail="$(cat /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null | tr ' ' '\n' | tr '\n' ' ')"
    printf '  拥塞控制算法: %s%s%s   (可选: %s)\n' "$BOLD" "${cc:-未知}" "$NC" "${avail:-未知}"
    printf '  默认队列算法: %s%s%s\n' "$BOLD" "${qdisc:-未知}" "$NC"
    if [[ "${cc:-}" == "bbr" ]]; then
        ok "BBR 已启用"
    else
        info "BBR 未启用"
    fi
    return 0
}

write_tune_file() {
    mkdir -p /etc/sysctl.d
    cat > "$SYSCTL_FILE" <<EOF
# ProxyBox 内核参数调优 (删除本文件或运行本脚本『恢复默认』可还原)
fs.file-max = 1048576
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_notsent_lowat = 16384
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.core.rmem_default = 1048576
net.core.wmem_default = 1048576
net.ipv4.tcp_rmem = 4096 87380 33554432
net.ipv4.tcp_wmem = 4096 16384 33554432
net.core.netdev_max_backlog = 16384
net.ipv4.udp_mem = 378888 505184 1577776
net.ipv4.conf.all.route_localnet = 1
vm.swappiness = 10
EOF
}

enable_bbr_only() {
    title "开启 BBR"
    if ! version_ge "${KERNEL%%-*}" "4.9"; then
        die "内核 $(uname -r) 太旧(< 4.9)，无法启用 BBR，请先升级系统/内核。"
    fi
    local virt="none"
    command -v systemd-detect-virt >/dev/null 2>&1 && virt="$(systemd-detect-virt 2>/dev/null || echo unknown)"
    if [[ "$virt" == "openvz" || "$virt" == "lxc" || "$virt" == "lxc-libvirt" ]]; then
        warn "检测到 $virt 容器环境，若宿主内核不支持 BBR 会写入失败。"
    fi
    # 仅 BBR 模式保持原有 qdisc 或用 fq
    cat > "$SYSCTL_FILE" <<EOF
# ProxyBox BBR 配置
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
    if sysctl -p "$SYSCTL_FILE" >/dev/null 2>&1; then
        ok "BBR 已写入/生效"
    else
        warn "部分参数写入失败, 逐条探测..."
        sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null 2>&1 \
            || die "无法设置 bbr (容器/内核限制)。"
    fi
    printf '  当前 设置: tcp_congestion_control=%s  default_qdisc=%s\n' \
        "$(cat /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null)" \
        "$(cat /proc/sys/net/core/default_qdisc 2>/dev/null)"
    ok "完成"
}

net_optimize_full() {
    title "一键 BBR + 网络调优"
    if ! version_ge "${KERNEL%%-*}" "4.9"; then
        die "内核 $(uname -r) 太旧(< 4.9)，无法启用。请升级系统！"
    fi
    local virt="none"
    command -v systemd-detect-virt >/dev/null 2>&1 && virt="$(systemd-detect-virt 2>/dev/null || echo unknown)"
    if [[ "$virt" == "openvz" || "$virt" == "lxc" || "$virt" == "lxc-libvirt" ]]; then
        warn "检测到 $virt 容器环境，可能无法应用，尝试后请自行确认。"
    fi
    write_tune_file
    if sysctl -p "$SYSCTL_FILE" >/dev/null 2>&1; then
        ok "内核参数已生效"
    else
        warn "部分参数被拒绝(容器限制)，已尽量应用可用的参数。"
        sysctl -p "$SYSCTL_FILE" 2>&1 | sed 's/^/    /' | head -n 15
    fi
    printf '  拥塞控制: %s   队列: %s\n' \
        "$(cat /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null)" \
        "$(cat /proc/sys/net/core/default_qdisc 2>/dev/null)"
    info "调优文件已保存: $SYSCTL_FILE (重启自动生效)"
    ok "一键优化完成"
}

net_restore() {
    title "恢复默认参数"
    if [[ -f "$SYSCTL_FILE" ]]; then
        rm -f "$SYSCTL_FILE"
    fi
    # 回退到常见默认值
    sysctl -w net.ipv4.tcp_congestion_control=cubic >/dev/null 2>&1 || true
    sysctl -w net.core.default_qdisc=pfifo_fast >/dev/null 2>&1 || true
    echo "  拥塞控制: $(cat /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null)"
    echo "  队列: $(cat /proc/sys/net/core/default_qdisc 2>/dev/null)"
    ok "已恢复默认参数"
}

menu_network() {
    while :; do
        banner
        title "网络优化 (BBR/内核调优)"
        show_net_status
        hr
        echo "  ${BOLD}1)${NC} 一键 BBR + 网络调优(推荐)"
        echo "  ${BOLD}2)${NC} 仅开启 BBR"
        echo "  ${BOLD}3)${NC} 恢复默认参数"
        echo "  ${BOLD}0)${NC} 返回上级"
        ask "请选择" "0"
        case "$RESULT" in
            1) net_optimize_full; pause ;;
            2) enable_bbr_only; pause ;;
            3) net_restore; pause ;;
            0|*) return 0 ;;
        esac
    done
}

#--------------------------------- 安装/管理子菜单 ---------------------------------
mark_installed() {
    if [[ -f "$SB_ENV_DIR/$1.env" ]]; then
        printf '%s(已安装)%s ' "$GREEN" "$NC"
    else
        printf '     '
    fi
}

menu_install() {
    while :; do
        banner
        title "安装代理"
        printf '  %s1)%s '   "$BOLD" "$NC"; mark_installed "ss2022";   echo "Shadowsocks-2022     TCP, 抗重放强化"
        printf '  %s2)%s '   "$BOLD" "$NC"; mark_installed "hy2";      echo "Hysteria2            UDP/QUIC, 弱网提速"
        printf '  %s3)%s '   "$BOLD" "$NC"; mark_installed "vless-rv"; echo "VLESS-Reality-Vision TCP, 无域名偷站伪装 ★推荐·Xray内核·抗封锁最强"
        printf '  %s4)%s '   "$BOLD" "$NC"; mark_installed "vless-rg"; echo "VLESS-Reality-gRPC   TCP, 伪装+grpc传输"
        printf '  %s5)%s '   "$BOLD" "$NC"; mark_installed "vless-ts"; echo "VLESS-Vision-TLS     TCP, 带域名+自签证书 △仅作临时备用·易被探测封锁"
        printf '  %s6)%s '   "$BOLD" "$NC"; mark_installed "tuic";     echo "TUIC v5              UDP/QUIC, 0-RTT 低延迟"
        echo "  ${BOLD}0)${NC} 返回上级"
        info "推荐: 日常首选 3) Reality-Vision(主动探测免疫); 5) 自签证书易被 GFW 识别封 IP, 仅在客户端不兼容 Reality 时临时使用。"
        info "提示: 多个协议可同时运行互不影响; 端口规则: 同为 TCP 或同为 UDP 不可重复, TCP 与 UDP 可同号(如 Vision 用 TCP 443, Hysteria2 用 UDP 443)。"
        ask "请选择" "0"
        local key=""
        case "$RESULT" in
            1) key="ss2022" ;;
            2) key="hy2" ;;
            3) key="vless-rv" ;;
            4) key="vless-rg" ;;
            5) key="vless-ts" ;;
            6) key="tuic" ;;
            0|*) return 0 ;;
        esac
        if [[ -f "$SB_ENV_DIR/${key}.env" ]]; then
            ask_choice "该协议已安装, 如何处理?" 2 \
                1 "覆盖重装(重新设置参数)" \
                2 "返回, 到『代理管理』中修改"
            [[ "$RESULT" == "1" ]] || continue
            rm -f "$SB_ENV_DIR/${key}.env"
        fi
        case "$key" in
            ss2022)   add_ss2022 ;;
            hy2)      add_hy2 ;;
            vless-rv) add_vless_rv ;;
            vless-rg) add_vless_rg ;;
            vless-ts) add_vless_ts ;;
            tuic)     add_tuic ;;
        esac
        if [[ "$key" == "ss2022" || "$key" == "vless-rv" || "$key" == "vless-rg" || "$key" == "vless-ts" ]]; then
            load_env "$key"; open_port_in_firewall "$PORT" tcp
        else
            load_env "$key"; open_port_in_firewall "$PORT" udp
        fi
        pause
    done
}

menu_manage() {
    while :; do
        banner
        title "代理管理"
        local n
        n=$(installed_keys | grep -c . )
        echo "  ${BOLD}1)${NC} 查看已安装代理列表"
        echo "  ${BOLD}2)${NC} 查看节点信息与分享链接"
        echo "  ${BOLD}3)${NC} 修改配置(端口/密码/UUID/伪装等)"
        echo "  ${BOLD}4)${NC} 删除某个代理"
        echo "  ${BOLD}5)${NC} 启动/停止/重启/状态"
        echo "  ${BOLD}6)${NC} 查看运行日志"
        echo "  ${BOLD}7)${NC} 更新 sing-box 内核"
        echo "  ${BOLD}8)${NC} 彻底卸载(内核+全部配置)"
        echo "  ${BOLD}0)${NC} 返回上级"
        hr
        info "已安装 ${n} 个协议"
        ask "请选择" "0"
        case "$RESULT" in
            1) menu_list; pause ;;
            2) menu_view ;;
            3) menu_edit ;;
            4) menu_delete ;;
            5) menu_service ;;
            6) menu_logs ;;
            7) update_core; pause ;;
            8)
                if uninstall_all; then :; fi
                pause ;;
            0|*) return 0 ;;
        esac
    done
}

#--------------------------------- 重装系统 ----------------------------------------
menu_reinstall() {
    title "重装系统(极度危险)"
    warn "重装会清空本机全部数据(代理配置/网站/数据库/本脚本都会消失)，过程不可中断！"
    warn "执行前请确认: ①本机没有需要保留的数据 ②知道服务商 VNC/控制台入口 ③记录好重装时设置的 root 密码。"
    info "重装由同仓库的 reinstall-vm.sh 完成: KVM 走 netboot+preseed 全自动安装, LXC/容器走 rootfs 原位替换。"
    ask "确认继续? [y/N]" "n"
    [[ ! "$RESULT" =~ ^[yY]([eE][sS])?$ ]] && { info "已取消"; return; }
    local rf="/usr/local/bin/reinstall-vm.sh" okdl=0 u base
    if [[ ! -f "$rf" ]]; then
        info "下载重装脚本 reinstall-vm.sh ..."
        base="https://raw.githubusercontent.com/xiaoluaibb/zihua/main/reinstall-vm.sh"
        while IFS= read -r u; do
            [[ -z "$u" ]] && continue
            printf '%s    下载: %s%s\n' "$GRAY" "$u" "$NC"
            if curl -fsSL --connect-timeout 8 --max-time 120 -o "$rf" "$u" 2>/dev/null && [[ -s "$rf" ]] && head -n1 "$rf" | grep -q "bin/"; then
                okdl=1; break
            fi
        done <<EOF
$base
https://gh-proxy.com/$base
https://ghfast.top/$base
EOF
        if [[ "$okdl" != "1" ]]; then rm -f "$rf"; err "下载失败, 请检查网络后重试"; return; fi
        chmod 700 "$rf"
        ok "已保存到 $rf (以后可直接 bash $rf 单独运行)"
    fi
    info "启动重装脚本(交互式菜单, 随时输入 q 可退出)..."
    bash "$rf" || true
}

#--------------------------------- 脚本自更新 -------------------------------------
SELF_REPO_RAW="https://raw.githubusercontent.com/xiaoluaibb/zihua/main/zihua.sh"

# 版本比较: $1 > $2 时返回 0 (纯数字段逐位比较, 兼容无 sort -V 的 BusyBox)
ver_gt() {
    local IFS=.
    local a=(${1#v}) b=(${2#v}) i
    for i in 0 1 2 3; do
        [[ ${a[i]:-0} -gt ${b[i]:-0} ]] && return 0
        [[ ${a[i]:-0} -lt ${b[i]:-0} ]] && return 1
    done
    return 1
}

# 逐通道尝试下载最新脚本到 $1: raw → gh-proxy → ghfast → jsdelivr 三节点
#   $2=verbose(yes 时逐通道打印失败原因)  $3=最多尝试通道数(0=全部)
# 可用环境变量覆盖超时: DL_CONNECT_TIMEOUT(默认8) / DL_MAX_TIME(默认60)
# 成功: UPDATE_CHANNEL=通道名, 返回0; 全部失败: 返回1
try_update_channels() {
    local out="$1" verbose="${2:-no}" limit="${3:-0}" u name n=0
    [[ "$(command -v curl || true)" == "" ]] && return 1
    local ct="${DL_CONNECT_TIMEOUT:-8}" mt="${DL_MAX_TIME:-60}"
    UPDATE_CHANNEL=""
    while IFS='|' read -r name u; do
        [[ -z "$name" || -z "$u" ]] && continue
        (( limit > 0 && n >= limit )) && break
        n=$((n+1))
        if curl -fsSL --connect-timeout "$ct" --max-time "$mt" -o "$out" "$u" 2>/dev/null \
           && [[ -s "$out" ]] && grep -q 'PROXYBOX_VERSION="[0-9]' "$out"; then
            UPDATE_CHANNEL="$name"
            return 0
        fi
        [[ "$verbose" == "yes" ]] && warn "  通道 [$name] 下载失败或内容异常"
    done <<EOF
raw|$SELF_REPO_RAW
gh-proxy|https://gh-proxy.com/$SELF_REPO_RAW
ghfast|https://ghfast.top/$SELF_REPO_RAW
jsdelivr|https://cdn.jsdelivr.net/gh/xiaoluaibb/zihua@main/zihua.sh
fastly|https://fastly.jsdelivr.net/gh/xiaoluaibb/zihua@main/zihua.sh
testingcf|https://testingcf.jsdelivr.net/gh/xiaoluaibb/zihua@main/zihua.sh
EOF
    rm -f "$out"
    return 1
}

# 下载最新脚本到 $1 并做安全校验(语法合法 + 带版本号), 成功返回 0
download_latest_script() {
    local out="$1"
    try_update_channels "$out" "${2:-no}" "${3:-0}" || return 1
    # 下载内容必须语法合法且带版本号, 防止镜像返回错误页
    bash -n "$out" 2>/dev/null || { rm -f "$out"; return 1; }
    grep -q 'PROXYBOX_VERSION="[0-9]' "$out" || { rm -f "$out"; return 1; }
    return 0
}

# 获取远端最新版本号: 成功回显版本, 失败回显空
fetch_remote_version() {
    local tmp="$SB_BAK_DIR/.latest.sh"
    mkdir -p "$SB_BAK_DIR" 2>/dev/null
    download_latest_script "$tmp" "${2:-no}" "${3:-0}" || { rm -f "$tmp"; return 1; }
    grep -m1 'PROXYBOX_VERSION=' "$tmp" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+'
}

# 执行更新: 替换当前脚本与 zihua 快捷命令 (旧版自动备份)
do_self_update() {
    local remote_ver="$1" tmp backup dest="/usr/local/bin/zihua" self
    tmp="$SB_BAK_DIR/.latest.sh"
    backup="/root/zihua.sh.bak-$(date +%Y%m%d%H%M%S)"
    self="$(readlink -f "$0" 2>/dev/null || echo "$0")"
    info "备份当前版本到 $backup ..."
    cp -f "$self" "$backup" 2>/dev/null || warn "备份失败(继续更新)"
    if [[ "$self" != "$dest" ]]; then
        install -m 700 "$tmp" "$dest" 2>/dev/null || warn "更新快捷命令 $dest 失败"
    fi
    install -m 700 "$tmp" "$self" 2>/dev/null || { err "替换脚本失败(旧版已保留在 $backup)"; return 1; }
    ok "已更新到 v$remote_ver (旧版备份: $backup)"
    ask "立即重启脚本使用新版本? [Y/n]" "y"
    if [[ "$RESULT" =~ ^[yY]([eE][sS])?$ ]]; then
        exec bash "$self"
    else
        info "下次运行 zihua 时即为新版本。"
    fi
}

# 启动时静默检测(失败不打扰): 只试前 2 个通道且超时收紧, 避免阻塞进入菜单; 有新版才询问
startup_update_check() {
    [[ "${ZIHUA_NO_UPDATE_CHECK:-0}" == "1" ]] && return 0
    command -v curl >/dev/null 2>&1 || return 0
    local rv
    rv="$(DL_CONNECT_TIMEOUT=3 DL_MAX_TIME=8 fetch_remote_version "" no 2)" || return 0
    [[ -z "$rv" ]] && return 0
    if ver_gt "$rv" "$PROXYBOX_VERSION"; then
        hr
        warn "发现新版本: v$PROXYBOX_VERSION → v$rv"
        ask "是否立即更新? [Y/n]" "y"
        if [[ "$RESULT" =~ ^[yY]([eE][sS])?$ ]]; then
            do_self_update "$rv"
        else
            info "已跳过, 可稍后在主菜单『6) 检查更新』手动更新。"
        fi
    fi
    return 0
}

# 手动检查更新菜单
menu_update() {
    title "检查更新"
    info "当前版本: v$PROXYBOX_VERSION"
    info "正在检测远端最新版本(raw → gh-proxy → ghfast → jsdelivr 多通道)..."
    local rv tmp="$SB_BAK_DIR/.latest.sh"
    mkdir -p "$SB_BAK_DIR" 2>/dev/null
    if ! download_latest_script "$tmp" yes; then
        err "检测失败: 所有下载通道均不可达。"
        info "排查建议: 在服务器上执行以下命令测试各通道连通性 ——"
        echo "    ${GRAY}curl -fsSL --connect-timeout 8 -o /dev/null -w '%{http_code}\n' $SELF_REPO_RAW${NC}"
        echo "    ${GRAY}curl -fsSL --connect-timeout 8 -o /dev/null -w '%{http_code}\n' https://cdn.jsdelivr.net/gh/xiaoluaibb/zihua@main/zihua.sh${NC}"
        info "哪个通道返回 200 就用哪个手动下载: wget -O /root/zihua.sh <对应地址>"
        pause; return
    fi
    rv="$(grep -m1 'PROXYBOX_VERSION=' "$tmp" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')"
    info "下载通道: $UPDATE_CHANNEL  远端版本: v${rv:-未知}"
    if ver_gt "$rv" "$PROXYBOX_VERSION"; then
        warn "有可用更新: v$PROXYBOX_VERSION → v$rv"
        ask "是否立即更新? [Y/n]" "y"
        [[ "$RESULT" =~ ^[yY]([eE][sS])?$ ]] && do_self_update "$rv"
    else
        ok "当前已是最新版本 v$PROXYBOX_VERSION"
        rm -f "$tmp"
    fi
    pause
}

#--------------------------------- 封面/主菜单 -------------------------------------
banner() {
    clear 2>/dev/null || true
    printf '%s' "$CYAN"
    cat <<'BANNER'
    _____  ___  ______ _   _____  ___
   |  __ \|_  | | ___ \ | |_   _|/ _ \
   | |__) | | | | |_/ / |   | | / /_\ \
   |  _  /  | | |  __/| |   | | |  _  |
   | | \ \_/ /_| |   \| |___| |_| | | |
   |_|  \___/|_|_|   \_____\_____|_| |_|
BANNER
    printf '%s' "$NC"
    printf '%sProxyBox%s v%s%s  多协议代理 + 网络优化(信息: sing-box 内核, 交互式)%s\n' \
        "$BOLD" "$NC" "$PROXYBOX_VERSION" "$BOLD" "$NC"
    hr
    printf '  %s%s%s\n' "$GRAY" "系统: ${OS_PRETTY:-未知}   内核: ${KERNEL:-未知}   架构: ${ARCH:-未知}" "$NC"
    get_public_ip >/dev/null 2>&1
    if [[ -n "$PUB_IP" ]]; then
        printf '  %s%s%s\n' "$GRAY" "公网IP: $PUB_IP" "$NC"
    fi
    hr
}

main_menu() {
    while :; do
        banner
        echo "  ${BOLD}1)${NC} 安装代理 (SS2022 / Hysteria2 / VLESS Reality / TUIC ...)"
        echo "  ${BOLD}2)${NC} 代理管理 (查看/修改/删除/日志/更新/卸载)"
        echo "  ${BOLD}3)${NC} 网络优化 (BBR / 内核调优)"
        echo "  ${BOLD}4)${NC} 系统与依赖体检"
        echo "  ${BOLD}5)${NC} 重装系统 (调用 reinstall-vm.sh, 危险!)"
        echo "  ${BOLD}6)${NC} 检查更新 (当前 v${PROXYBOX_VERSION})"
        echo "  ${BOLD}0)${NC} 退出"
        hr
        ask "请选择" "1"
        case "$RESULT" in
            1) menu_install ;;
            2) menu_manage ;;
            3) menu_network ;;
            4) show_system_info; ensure_deps; pause ;;
            5) menu_reinstall ;;
            6) menu_update ;;
            0) ok "再见!"; exit 0 ;;
            *) err "请输入正确编号" ;;
        esac
    done
}

#--------------------------------- 主入口 ------------------------------------------
main() {
    [[ $EUID -eq 0 ]] || die "请以 root 运行: bash $0 (root 用户直接运行即可, 无需 sudo)"
    detect_os
    mkdir -p "$SB_DIR" "$SB_ENV_DIR" "$SB_CFG_DIR" "$SB_CERT_DIR" "$SB_BAK_DIR"
    chmod 700 "$SB_DIR"
    show_system_info
    # 版本兼容性提示
    local vmin="18.04" idok=1
    case "${OS_ID:-}" in
        debian)  vmin="10" ;;
        ubuntu)  vmin="18.04" ;;
        centos)  vmin="7" ;;
        rocky|almalinux|almalinux|almalinux|alma) vmin="8" ;;
        amzn)    vmin="2" ;;
        alpine)  vmin="3.15" ;;
        arch|manjaro|fedora) vmin="0" ;;
        *) idok=0 ;;
    esac
    if [[ "$idok" == "1" && "$vmin" != "0" ]]; then
        if ! version_ge "${OS_VER}" "$vmin"; then
            warn "检测到 ${OS_ID} ${OS_VER} 低于推荐最低版本 ${vmin}，可能无法正常运行，建议使用较新的系统。"
        fi
    elif [[ "$idok" == "0" ]]; then
        warn "未识别的系统发行版 (${OS_ID:-未知})，脚本会尽力尝试但可能失败。"
    fi
    check_init || true
    ensure_deps || true
    get_public_ip >/dev/null 2>&1 || true
    install_zihua_cmd
    startup_update_check
    main_menu
}

# 检查初始化系统是否可用 (systemd 或 OpenRC)
check_init() {
    detect_init
    if [[ "$INIT_SYS" == "none" ]]; then
        warn "未检测到 systemd / OpenRC，服务管理功能不可用。"
        return 1
    fi
    ok "初始化系统: $INIT_SYS"
    return 0
}

# 安装/更新 zihua 快捷命令: 以后直接输入 zihua 即可再次运行
install_zihua_cmd() {
    local self dest="/usr/local/bin/zihua"
    self="$(readlink -f "$0" 2>/dev/null || echo "$0")"
    [[ -z "$self" || "$self" == "$dest" ]] && return 0
    if ! cmp -s "$self" "$dest" 2>/dev/null; then
        if install -m 700 "$self" "$dest" 2>/dev/null; then
            ok "快捷命令已就绪: 以后直接输入 zihua 即可再次打开本脚本"
        fi
    fi
}

main "$@"
