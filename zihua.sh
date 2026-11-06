#!/usr/bin/env bash
#===============================================================================
#  ProxyBox — 多协议代理一键安装/管理 + 网络优化(BBR/内核调优) 交互式脚本
#-------------------------------------------------------------------------------
#  适用系统 : Debian 10+ / Ubuntu 18.04+ / Rocky / Alma / CentOS 7+(部分) /
#             Fedora / Alpine 3.15+ / Arch  (systemd 或 OpenRC 均可)
#  运行方式 : 以 root 运行   bash zihua.sh   (root 下直接运行即可, 无需 sudo)
#  快捷命令 : 首次运行后自动安装 zihua 命令, 以后直接输入 zihua 即可再次打开
#  三内核   : sing-box (SS2022 / TUIC)
#             Xray (VLESS-Reality-Vision / gRPC, 配置与 v2ray-agent 同款)
#             hysteria 官方内核 (Hysteria2, 安装直接调用 seagullz4/hysteria2 的 install.sh)
#             三个服务独立管理, 可同时运行, UDP/TCP 端口互不冲突
#  多协议   : 各协议独立实例+独立证书, TCP/UDP 端口可复用, 可同时运行
#  附加功能 : 一键重装系统 (调用同仓库 reinstall-vm.sh, 支持 KVM/LXC)
#  版本     : v1.6.1  (2026-11)
#===============================================================================

#--------------------------------- 全局变量 ------------------------------------
PROXYBOX_VERSION="1.6.1"
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
# 固定 Xray 版本: >=v26.9.8 的 Reality 服务端强制要求客户端 ClientHello 携带后量子密钥交换
# (X25519MLKEM768), 旧版 sing-box/Mihomo 等客户端不带该扩展 → reality verification failed。
# v26.7.11 起又默认启用 minClientVer 拒绝旧客户端, 故固定在 v26.6.27 (无这两个坑)。
XRAY_PIN_VER="v26.6.27"
# Hysteria2: 用官方 hysteria 内核(与 seagullz4/hysteria2 脚本同方案), 独立服务, 与 sing-box/Xray 并存
HY_BIN="/usr/local/bin/hysteria"
HY_DIR="/etc/sing-box/hysteria"
HY_CFG="$HY_DIR/config.yaml"
HY_SERVICE="zihua-hy2"
HY_LOG_FILE="/var/log/zihua-hy2.log"
# Hysteria2 安装/卸载交给第三方脚本完成, 出处: https://github.com/seagullz4/hysteria2 (作者 seagullz4, 感谢)
HY3_DIR="/root/hy3"
HY3_CFG="$HY3_DIR/config.yaml"
HY3_SERVICE="hysteria"
HY3_LOCAL="/usr/local/bin/hy2-install.sh"
HY3_REPO="https://github.com/seagullz4/hysteria2"
UNIT_PATH="/etc/systemd/system/${SERVICE_NAME}.service"
SYSCTL_FILE="/etc/sysctl.d/99-proxybox-optimize.conf"
SYSCTL_BAK="/etc/sysctl.d/proxybox-optimize.orig"   # 调优前原值备份(无 .conf 后缀, 不会被 sysctl 加载)
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
    own_pids=" $(svc_own_pids) $(command -v "$XRAY_BIN" >/dev/null 2>&1 && xsvc_own_pids) $(command -v "$HY_BIN" >/dev/null 2>&1 && hysvc_own_pids) "
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
proto_kernel() {
    case "$1" in
        vless-rv|vless-rg) echo xray ;;
        hy2)               echo hysteria ;;
        *)                 echo sing-box ;;
    esac
}
kernel_active() {
    case "$(proto_kernel "$1")" in
        xray)     xsvc_active ;;
        hysteria) hysvc_active ;;
        *)        svc_active ;;
    esac
}
# 按协议所属内核打印日志尾部(避免 Xray/Hysteria 协议去 tail sing-box 的日志, 看不到真实报错)
kernel_log_tail() {
    case "$(proto_kernel "$1")" in
        xray)     xsvc_log_tail "${2:-20}" ;;
        hysteria) hysvc_log_tail "${2:-20}" ;;
        *)        svc_log_tail "${2:-20}" ;;
    esac
}

xray_download_urls() {
    local fname
    case "$ARCH" in
        amd64) fname="Xray-linux-64.zip" ;;
        arm64) fname="Xray-linux-arm64-v8a.zip" ;;
        *) return 1 ;;
    esac
    local u="https://github.com/XTLS/Xray-core/releases/download/${XRAY_PIN_VER}/${fname}"
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
    # 已装 Xray 版本若与固定版本不一致(尤其新版>=v26.9.8 强制后量子), 自动重装固定版本
    if [[ -x "$XRAY_BIN" ]]; then
        local cur
        cur="$("$XRAY_BIN" version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1)"
        if [[ -n "$cur" && "$cur" == "${XRAY_PIN_VER#v}" ]]; then
            return 0
        fi
        if [[ -n "$cur" ]]; then
            warn "检测到 Xray $cur 与固定版本 ${XRAY_PIN_VER} 不一致(新版会强制后量子密钥交换, 旧客户端会 reality verification failed), 重新安装 ${XRAY_PIN_VER}..."
        fi
    fi
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

#--------------------------------- Hysteria2 内核 (官方 hysteria) ------------------
# 方案对照 seagullz4/hysteria2: 独立二进制 + YAML 配置 + 独立服务, 与 sing-box / Xray 并存互不干扰。
# 之前用 sing-box 的 hysteria2 入站, 客户端连不上时服务端日志无任何记录; 换成官方内核后一致。
hy_arch() {
    case "$ARCH" in
        amd64) echo amd64 ;;
        arm64) echo arm64 ;;
        armv7) echo arm ;;
        *)     return 1 ;;
    esac
}

hysteria_download_urls() {
    local a
    a="$(hy_arch)" || return 1
    local gh="https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-${a}"
    echo "https://download.hysteria.network/app/latest/hysteria-linux-${a}"
    echo "$gh"
    echo "https://gh-proxy.com/${gh}"
    echo "https://ghfast.top/${gh}"
}

install_hysteria() {
    ensure_dirs
    title "Hysteria2 内核安装 (官方 hysteria)"
    local a url okdl=0 tmp
    a="$(hy_arch)" || die "不支持的 CPU 架构: $(uname -m), 官方 hysteria 无对应二进制。"
    tmp="$(mktemp -d)" || die "创建临时目录失败"
    while IFS= read -r url; do
        [[ -z "$url" ]] && continue
        printf '%s    下载: %s%s\n' "$GRAY" "$url" "$NC"
        if curl -fSL --connect-timeout 8 --max-time 300 -o "$tmp/hysteria" "$url" 2>/dev/null && [[ -s "$tmp/hysteria" ]]; then
            okdl=1; break
        fi
        warn "该地址下载失败，切换备用地址..."
    done < <(hysteria_download_urls)
    [[ "$okdl" != "1" ]] && { rm -rf "$tmp"; die "hysteria 下载失败(所有地址均不可达)。"; }
    install -m 0755 "$tmp/hysteria" "$HY_BIN"
    rm -rf "$tmp"
    if ! "$HY_BIN" version >/dev/null 2>&1; then
        die "hysteria 已下载但无法运行, 请检查系统兼容性。"
    fi
    ok "Hysteria2 安装完成: $("$HY_BIN" version 2>/dev/null | head -n1)"
}

ensure_hy_core() {
    if [[ -x "$HY_BIN" ]] && "$HY_BIN" version >/dev/null 2>&1; then return 0; fi
    install_hysteria
}

update_hy_core() {
    title "更新 Hysteria2 内核"
    if hy2_third_installed; then
        warn "Hysteria2 由第三方脚本管理, 内核更新用它菜单里的 5(在线更新hy2内核)"
        ask "现在运行第三方脚本? [Y/n]" "y"
        [[ "$RESULT" =~ ^[nN]$ ]] && return 0
        [[ -f "$HY3_LOCAL" ]] || hy2_third_fetch || { err "下载失败, 可手动执行: bash <(curl -fsSL $HY3_REPO/raw/main/install.sh)"; return 1; }
        ( cd /root && bash "$HY3_LOCAL" )
        return 0
    fi
    if [[ ! -x "$HY_BIN" ]]; then info "尚未安装 Hysteria2 内核, 无需更新"; return 0; fi
    local old new
    old="$("$HY_BIN" version 2>/dev/null | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -n1)"
    install_hysteria || return 1
    new="$("$HY_BIN" version 2>/dev/null | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -n1)"
    if [[ -n "$old" && "$old" == "$new" ]]; then
        ok "已是最新版本 ($new)"
    else
        ok "已更新: ${old:-未知} → ${new:-未知}"
        [[ -f "$HY_CFG" ]] && hysvc_restart && ok "Hysteria2 服务已重启"
    fi
}

hy_ensure_service() {
    if [[ "$INIT_SYS" == "openrc" ]] && [[ -x "/etc/init.d/${HY_SERVICE}" ]]; then return 0; fi
    if [[ "$INIT_SYS" == "systemd" ]] && [[ -f "/etc/systemd/system/${HY_SERVICE}.service" ]]; then return 0; fi
    if [[ "$INIT_SYS" == "openrc" ]]; then
        cat > "/etc/init.d/${HY_SERVICE}" <<UNIT
#!/sbin/openrc-run
description="ProxyBox Hysteria2 server"
command="${HY_BIN}"
command_args="server -c ${HY_CFG}"
command_background="yes"
pidfile="/run/${HY_SERVICE}.pid"
output_log="${HY_LOG_FILE}"
error_log="${HY_LOG_FILE}"
depend() {
    need net
    use dns
}
UNIT
        chmod +x "/etc/init.d/${HY_SERVICE}"
    else
        cat > "/etc/systemd/system/${HY_SERVICE}.service" <<UNIT
[Unit]
Description=ProxyBox Hysteria2 server
After=network.target nss-lookup.target

[Service]
Type=simple
ExecStart=${HY_BIN} server -c ${HY_CFG}
WorkingDirectory=${HY_DIR}
Restart=on-failure
RestartSec=3s
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
UNIT
        systemctl daemon-reload
    fi
    if [[ "$INIT_SYS" == "systemd" ]]; then
        systemctl enable "$HY_SERVICE" >/dev/null 2>&1
    else
        rc-update add "$HY_SERVICE" default >/dev/null 2>&1
    fi
    ok "已创建并启用 Hysteria2 服务: $HY_SERVICE"
}

# 第三方脚本装的是 hysteria.service, 内置流程装的是 zihua-hy2; 两者统一从这里分发
hy2_unit() { if hy2_third_installed && [[ "$INIT_SYS" == "systemd" ]]; then printf '%s' "$HY3_SERVICE"; else printf '%s' "$HY_SERVICE"; fi; }
hysvc_restart()  { local u; u="$(hy2_unit)"; if [[ "$INIT_SYS" == "systemd" ]]; then systemctl restart "$u"; else rc-service "$u" restart; fi; }
hysvc_active()   {
    local u; u="$(hy2_unit)"
    if [[ "$INIT_SYS" == "systemd" ]]; then
        systemctl is-active --quiet "$u" 2>/dev/null && return 0
        # 第三方脚本会先用 nohup 起进程再建服务, 服务没接管时兜底看进程
        [[ "$u" == "$HY3_SERVICE" ]] && pgrep -f "${HY3_DIR}/hysteria" >/dev/null 2>&1 && return 0
        return 1
    fi
    rc-service "$u" status >/dev/null 2>&1
}
hysvc_stop_now() { local u; u="$(hy2_unit)"; if [[ "$INIT_SYS" == "systemd" ]]; then systemctl disable --now "$u" >/dev/null 2>&1; else rc-service "$u" stop >/dev/null 2>&1; rc-update del "$u" default >/dev/null 2>&1; fi; }
hysvc_log_tail() { local u; u="$(hy2_unit)"; if [[ "$INIT_SYS" == "systemd" ]]; then journalctl -u "$u" -n "${1:-60}" --no-pager -e 2>/dev/null; else tail -n "${1:-60}" "$HY_LOG_FILE" 2>/dev/null; fi; }
hysvc_own_pids() {
    if hy2_third_installed; then
        pgrep -f "${HY3_DIR}/hysteria" 2>/dev/null | tr '\n' ' '
    else
        pgrep -f "hysteria server -c ${HY_CFG}" 2>/dev/null | tr '\n' ' '
    fi
}

# 生成 config.yaml (字段与官方文档一致: listen / tls 或 acme / auth / masquerade / bandwidth)
hy_gen_config() {
    load_env hy2
    mkdir -p "$HY_DIR"
    local cert="" key=""
    case "$CERT_MODE" in
        acme)
            if [[ -z "$DOMAIN" ]]; then err "ACME 方式缺少域名"; return 1; fi ;;
        manual)
            if [[ ! -r "$CERT_FILE" || ! -r "$KEY_FILE" ]]; then
                err "证书文件不可读: cert=$CERT_FILE key=$KEY_FILE"; return 1
            fi
            cert="$CERT_FILE"; key="$KEY_FILE" ;;
        *)
            cert="$SB_CERT_DIR/hy2.pem"; key="$SB_CERT_DIR/hy2.key"
            if [[ ! -f "$cert" || ! -f "$key" ]]; then
                gen_self_signed_cert hy2 "${DOMAIN:-bing.com}" >/dev/null || { err "自签证书生成失败"; return 1; }
            fi ;;
    esac
    {
        printf 'listen: :%s\n\n' "$PORT"
        if [[ "$CERT_MODE" == "acme" ]]; then
            printf 'acme:\n  domains:\n    - %s\n  email: %s\n\n' "$DOMAIN" "${ACME_EMAIL:-proxybox@$(printf '%s' "$DOMAIN" | sed 's/^[^.]*\.//')}"
        else
            printf 'tls:\n  cert: %s\n  key: %s\n\n' "$cert" "$key"
        fi
        printf 'auth:\n  type: password\n  password: %s\n\n' "$PASSWORD"
        printf 'masquerade:\n  type: proxy\n  proxy:\n    url: "%s"\n    rewriteHost: true\n\n' "${MASQ:-https://news.ycombinator.com/}"
        printf 'bandwidth:\n  up: 0 gbps\n  down: 0 gbps\n\n'
        printf 'udpIdleTimeout: 90s\n'
    } > "$HY_CFG" 2>/dev/null || { err "写入 $HY_CFG 失败"; return 1; }
    chmod 600 "$HY_CFG"
    ok "Hysteria2 配置已生成: $HY_CFG"
    return 0
}

# 端口跳跃(iptables DNAT, 可选): 与参考脚本一致, 规则持久化到独立 oneshot 服务
hy_hop_clean() {
    command -v iptables >/dev/null 2>&1 || return 0
    local i
    for i in 1 2 3 4 5 6 7 8 9 10; do
        iptables -t nat -D PREROUTING -p udp --dport "$1":"$2" -j DNAT --to-destination ":$3" >/dev/null 2>&1 || break
    done
    return 0
}

hy_hop_apply() {
    if [[ -z "${HOP_START:-}" || -z "${HOP_END:-}" ]]; then
        # 关闭端口跳跃: 清掉旧规则与持久化脚本/服务
        if [[ -f "$HY_DIR/port-hop.sh" ]]; then
            local ps pe
            ps="$(sed -n 's/.*--dport \([0-9]*\):\([0-9]*\).*/\1/p' "$HY_DIR/port-hop.sh" | head -n1)"
            pe="$(sed -n 's/.*--dport \([0-9]*\):\([0-9]*\).*/\2/p' "$HY_DIR/port-hop.sh" | head -n1)"
            [[ -n "$ps" && -n "$pe" ]] && hy_hop_clean "$ps" "$pe" "$PORT"
            rm -f "$HY_DIR/port-hop.sh"
            if [[ "$INIT_SYS" == "systemd" ]]; then
                systemctl disable --now "${HY_SERVICE}-hop" >/dev/null 2>&1
                rm -f "/etc/systemd/system/${HY_SERVICE}-hop.service"; systemctl daemon-reload
            else
                rm -f "/etc/local.d/${HY_SERVICE}-hop.start"
            fi
            info "已关闭端口跳跃"
        fi
        return 0
    fi
    if ! command -v iptables >/dev/null 2>&1; then
        warn "未安装 iptables, 端口跳跃已跳过(其余功能正常)"
        HOP_START=""; HOP_END=""
        return 0
    fi
    hy_hop_clean "$HOP_START" "$HOP_END" "$PORT"
    if ! iptables -t nat -A PREROUTING -p udp --dport "$HOP_START":"$HOP_END" -j DNAT --to-destination ":$PORT" 2>/dev/null; then
        warn "端口跳跃规则写入失败(nat 表不可用), 已跳过该项"
        HOP_START=""; HOP_END=""
        return 0
    fi
    ok "端口跳跃已生效: UDP ${HOP_START}-${HOP_END} → ${PORT}"
    mkdir -p "$HY_DIR"
    {
        echo '#!/bin/sh'
        printf 'iptables -t nat -D PREROUTING -p udp --dport %s:%s -j DNAT --to-destination :%s 2>/dev/null\n' "$HOP_START" "$HOP_END" "$PORT"
        printf 'iptables -t nat -A PREROUTING -p udp --dport %s:%s -j DNAT --to-destination :%s\n' "$HOP_START" "$HOP_END" "$PORT"
    } > "$HY_DIR/port-hop.sh"
    chmod +x "$HY_DIR/port-hop.sh"
    if [[ "$INIT_SYS" == "systemd" ]]; then
        cat > "/etc/systemd/system/${HY_SERVICE}-hop.service" <<UNIT
[Unit]
Description=ProxyBox Hysteria2 port hopping
After=network.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=${HY_DIR}/port-hop.sh

[Install]
WantedBy=multi-user.target
UNIT
        systemctl daemon-reload
        systemctl enable --now "${HY_SERVICE}-hop" >/dev/null 2>&1
    elif [[ -d /etc/local.d ]]; then
        cp -f "$HY_DIR/port-hop.sh" "/etc/local.d/${HY_SERVICE}-hop.start"
        chmod +x "/etc/local.d/${HY_SERVICE}-hop.start"
        rc-update add local default >/dev/null 2>&1
    fi
    return 0
}

# 应用 Hysteria2: 生成配置 → 起服务 → 存活检查 (与 Xray 分支同样的严格校验)
hy_apply() {
    ensure_dirs
    if [[ ! -f "$SB_ENV_DIR/hy2.env" ]]; then err "未找到 hy2 参数文件"; return 1; fi
    load_env hy2
    # 第三方脚本装的: 配置归它管, 这里只同步参数 + 重启它的服务, 绝不覆盖 /root/hy3/config.yaml
    if hy2_third_installed; then
        hy2_third_sync >/dev/null 2>&1 || true
        # 第三方脚本自己不碰防火墙, 这里补上; 漏放行就是"服务在跑但客户端超时"
        [[ -n "${PORT:-}" ]] && open_port_in_firewall "$PORT" udp
        if hysvc_restart; then
            sleep 1
            verify_installed hy2
            return $?
        fi
        err "重启 $HY3_SERVICE 失败, 最近日志:"
        hysvc_log_tail 20 | sed 's/^/    /'
        return 1
    fi
    ensure_hy_core || return 1
    hy_ensure_service
    hy_gen_config || return 1
    # Hysteria2 走 UDP, 必须放行; 漏这一步是"服务起来了但客户端超时"的常见原因
    open_port_in_firewall "$PORT" udp
    # sing-box 若还挂着旧版 hysteria2 入站, 必须先删掉并重启, 否则两个内核抢同一个 UDP 端口
    if [[ -f "$SB_CFG_DIR/hy2.json" ]]; then
        rm -f "$SB_CFG_DIR/hy2.json" "$SB_BAK_DIR/hy2.json.bak"
        info "已清理 sing-box 的旧 Hysteria2 配置(避免与官方内核抢端口)"
        # 只剩 hy2 时 sing-box 目录已空, 此时不应再启动 sing-box(空配置会启动失败)
        if compgen -G "$SB_CFG_DIR/*.json" >/dev/null; then
            svc_do_restart >/dev/null 2>&1 || true
        else
            svc_do_stop >/dev/null 2>&1 || true
        fi
    fi
    hy_hop_apply
    if ! hysvc_restart; then
        err "Hysteria2 服务启动失败, 最近日志:"
        hysvc_log_tail 20 | sed 's/^/    /'
        return 1
    fi
    sleep 1
    if ! hysvc_active; then
        err "Hysteria2 启动后立即退出, 最近日志:"
        hysvc_log_tail 25 | sed 's/^/    /'
        if [[ "$CERT_MODE" == "acme" ]]; then
            warn "ACME 方式需要: 域名已解析到本机 + UDP/TCP 443 未被占用; 也可改用自签证书。"
        fi
        return 1
    fi
    verify_installed hy2
}

# 老版本( sing-box 内核 )安装的 Hysteria2 迁移到官方内核: 只动 hy2, 不碰 SS2022 / Reality
hy_migrate_check() {
    [[ -f "$SB_ENV_DIR/hy2.env" ]] || return 0
    [[ -f "$HY_DIR/.migrated" || -f "$HY_DIR/.migrate_skip" ]] && return 0
    # 第三方脚本(seagullz4/hysteria2)装的: 跟"旧版 sing-box 内核"毫无关系, 直接标记, 不再提示
    if hy2_third_installed; then
        mkdir -p "$HY_DIR"; : > "$HY_DIR/.migrated"; return 0
    fi
    # 已经是官方内核(内置流程装的)也直接标记
    if [[ -x "$HY_BIN" ]] && [[ -f "$HY_CFG" ]]; then
        mkdir -p "$HY_DIR"; : > "$HY_DIR/.migrated"; return 0
    fi
    # 只有确实还留着 sing-box 内核的 hy2 配置时才提示
    if [[ ! -f "$SB_CFG_DIR/hy2.json" ]]; then
        mkdir -p "$HY_DIR"; : > "$HY_DIR/.migrated"; return 0
    fi
    warn "检测到 Hysteria2 是 v1.4.x 旧版(sing-box 内核)装的。"
    info "新版改用官方 hysteria 内核(与 seagullz4/hysteria2 同方案); 只重建 Hysteria2, SS2022 / Reality 完全不受影响。"
    info "也可以不管它, 直接『删除某个代理』删掉 hy2, 再重新安装一次。"
    ask "现在升级为官方内核? [Y/n]" "y"
    if [[ "$RESULT" =~ ^[nN]$ ]]; then
        mkdir -p "$HY_DIR"; : > "$HY_DIR/.migrate_skip"
        info "已跳过, 以后不再提示。"
        return 0
    fi
    if hy_apply; then
        mkdir -p "$HY_DIR"; : > "$HY_DIR/.migrated"
        print_share hy2
        ok "Hysteria2 已切换到官方内核"
    else
        mkdir -p "$HY_DIR"; : > "$HY_DIR/.migrate_skip"
        err "升级失败, 原配置未被破坏。可『删除某个代理』删掉 hy2 后重新安装。"
    fi
}

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
    HOP_START=""; HOP_END=""; ACME_EMAIL=""
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
        tuic)
            if [[ "$CERT_MODE" != "manual" && ( ! -f "$SB_CERT_DIR/$k.pem" || ! -f "$SB_CERT_DIR/$k.key" ) ]]; then
                gen_self_signed_cert "$k" "${DOMAIN:-localhost}" >/dev/null || true
            fi ;;
    esac
    [[ -f "$cfg" ]] && cp -f "$cfg" "$bak"
    case "$k" in
        ss2022)   cfg_body_ss2022   > "$cfg" ;;
        tuic)     cfg_body_tuic     > "$cfg" ;;
        vless-ts) cfg_body_vless_ts > "$cfg" ;;
        # Hysteria2 由官方 hysteria 内核接管(独立服务), sing-box 不再生成该入站
        hy2)      rm -f "$cfg" "$bak"; rm -f "$errf"; return 0 ;;
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
    local k rc=0 has_reality=0 has_hy2=0
    for k in $(installed_keys); do
        # Reality 走 Xray 内核 / Hysteria2 走官方 hysteria 内核, 都不由 sing-box 承载
        case "$k" in
            vless-rv|vless-rg) has_reality=1; continue ;;
            hy2)               has_hy2=1; continue ;;
        esac
        gen_config "$k" || rc=1
    done
    # 清掉 sing-box 目录里的 Reality / Hysteria2 残留(老版本迁移遗留), 避免内核之间抢端口
    rm -f "$SB_CFG_DIR/vless-rv.json" "$SB_CFG_DIR/vless-rg.json" "$SB_CFG_DIR/hy2.json"
    (( rc == 1 )) && return 1
    # 没有 sing-box 承载的协议时(只装了 Hysteria2 / Reality), 空配置会启动失败, 直接跳过
    if compgen -G "$SB_CFG_DIR/*.json" >/dev/null; then
        svc_restart
    else
        svc_do_stop >/dev/null 2>&1 || true
        info "sing-box 当前无承载协议, 已跳过 sing-box 启动"
    fi
    # 有 Reality 协议时重建并重启 Xray
    if [[ "$has_reality" == "1" ]]; then
        ensure_xray_core && xray_ensure_service && xray_rebuild_config && xsvc_restart
    fi
    # 有 Hysteria2 时应用并重启官方内核
    if [[ "$has_hy2" == "1" ]]; then
        hy_apply || rc=1
    fi
    return $rc
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
    # 官方 hysteria 服务端: insecure 仅自签需要; 端口跳跃用 mport 参数
    local p=()
    [[ -n "$DOMAIN" && "$DOMAIN" != "localhost" ]] && p+=("sni=${DOMAIN}")
    [[ "$CERT_MODE" != "manual" && "$CERT_MODE" != "acme" ]] && p+=("insecure=1")
    [[ -n "${HOP_START:-}" && -n "${HOP_END:-}" ]] && p+=("mport=${PORT},${HOP_START}-${HOP_END}")
    echo "hy2://${PASSWORD}@${IP}:${PORT}/?$(IFS='&'; echo "${p[*]}")#${NODE_LABEL}"
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
            case "$CERT_MODE" in
                manual) printf '  证书: 自有/签发证书(%s, 无需开不安全)\n' "$CERT_FILE" ;;
                acme)   printf '  证书: 内置 ACME 自动申请/续期(无需开不安全)\n' ;;
                *)      printf '  证书: 自签(客户端需开启『允许不安全/Insecure』)\n' ;;
            esac
            [[ -n "${HOP_START:-}" && -n "${HOP_END:-}" ]] && printf '  端口跳跃: %s-%s (客户端链接已带 mport)\n' "$HOP_START" "$HOP_END" ;;
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
#-------------------- Hysteria2: 直接调用第三方脚本 seagullz4/hysteria2 ------------------
# 出处: https://github.com/seagullz4/hysteria2  (作者 seagullz4, 非常感谢)
# 约定: 安装/卸载逻辑一律以第三方脚本为准, 本脚本只做三件事
#   ① 下载并调用它的 install.sh  ② 把它的 config.yaml 反解进 hy2.env 供列表/分享链接使用
#   ③ 状态/日志/启停转发到它的 systemd 服务 hysteria.service

hy2_third_installed() {
    [[ -f "$HY3_CFG" ]] && return 0
    if [[ "$INIT_SYS" == "systemd" ]] && systemctl list-unit-files 2>/dev/null | grep -q "^${HY3_SERVICE}\.service"; then
        return 0
    fi
    return 1
}

hy2_third_credit() {
    info "Hysteria2 部分直接调用第三方脚本完成, 出处:"
    printf '   %s%s%s   (作者 seagullz4, 感谢)\n' "$BOLD" "$HY3_REPO" "$NC"
    info "本脚本只负责下载与调用, 并把它的安装结果接进本脚本的节点列表/状态/删除里。"
}

_hy2_third_dl() {
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --connect-timeout 10 --max-time 90 "$1" -o "$2" 2>/dev/null
    else
        wget -q -T 30 -O "$2" "$1" 2>/dev/null
    fi
}

hy2_third_fetch() {
    local u tmp="${HY3_LOCAL}.new"
    mkdir -p "$(dirname "$HY3_LOCAL")"
    for u in \
        "https://cdn.jsdelivr.net/gh/seagullz4/hysteria2@main/install.sh" \
        "https://raw.githubusercontent.com/seagullz4/hysteria2/main/install.sh" \
        "https://ghfast.top/https://raw.githubusercontent.com/seagullz4/hysteria2/main/install.sh" \
        "https://gh-proxy.com/https://raw.githubusercontent.com/seagullz4/hysteria2/main/install.sh"; do
        if _hy2_third_dl "$u" "$tmp" && [[ -s "$tmp" ]] && grep -q "hysteria" "$tmp"; then
            mv -f "$tmp" "$HY3_LOCAL"
            chmod +x "$HY3_LOCAL"
            ok "已获取第三方安装脚本: $HY3_LOCAL"
            return 0
        fi
        rm -f "$tmp"
    done
    return 1
}

# 把第三方 config.yaml 的关键参数反解进本脚本的 hy2.env(供列表/分享链接用)
hy2_third_sync() {
    [[ -f "$HY3_CFG" ]] || return 1
    local p pw dom mode="self" masq cert hs he nm
    p="$(sed -n 's/^listen:[[:space:]]*:*\([0-9][0-9]*\).*/\1/p' "$HY3_CFG" | head -n1)"
    pw="$(sed -n 's/^[[:space:]]*password:[[:space:]]*//p' "$HY3_CFG" | head -n1 | tr -d "'\"")"
    masq="$(sed -n 's/^[[:space:]]*url:[[:space:]]*//p' "$HY3_CFG" | head -n1 | tr -d "'\"")"
    if grep -q '^acme:' "$HY3_CFG"; then
        mode="acme"
        dom="$(sed -n '/^acme:/,/^[a-z]/p' "$HY3_CFG" | sed -n 's/^[[:space:]]*-[[:space:]]*//p' | head -n1)"
    else
        cert="$(sed -n 's/^[[:space:]]*cert:[[:space:]]*//p' "$HY3_CFG" | head -n1 | tr -d "'\"")"
        dom="$(basename "${cert:-none}")"
        dom="${dom%.crt}"; dom="${dom%.pem}"
        [[ -n "$cert" && "$cert" != /etc/ssl/private/* ]] && mode="manual"
    fi
    if [[ -z "$p" ]]; then
        err "解析 $HY3_CFG 的监听端口失败, 无法生成分享链接"
        return 1
    fi
    if [[ -f "$HY3_DIR/ipppp.sh" ]]; then
        hs="$(sed -n 's/.*--dport \([0-9]*\):\([0-9]*\).*/\1/p' "$HY3_DIR/ipppp.sh" | head -n1)"
        he="$(sed -n 's/.*--dport \([0-9]*\):\([0-9]*\).*/\2/p' "$HY3_DIR/ipppp.sh" | head -n1)"
    fi
    nm="hysteria2-${dom:-hy2}"
    [[ -n "$hs" ]] && nm="$nm-hop"
    mkdir -p "$SB_ENV_DIR" "$HY_DIR"
    {
        printf 'PORT=%s\n' "$p"
        printf "PASSWORD='%s'\n" "$pw"
        printf "DOMAIN='%s'\n" "$dom"
        printf 'CERT_MODE=%s\n' "$mode"
        printf "CERT_FILE=''\nKEY_FILE=''\n"
        printf "CERT_CN='%s'\n" "$dom"
        printf "MASQ='%s'\n" "$masq"
        printf "ACME_EMAIL=''\n"
        printf "HOP_START='%s'\n" "$hs"
        printf "HOP_END='%s'\n" "$he"
        printf "NAME='%s'\n" "$nm"
        printf 'CREATED="%s"\n' "$(date '+%F %T')"
    } > "$SB_ENV_DIR/hy2.env" 2>/dev/null || { err "写入 hy2.env 失败"; return 1; }
    chmod 600 "$SB_ENV_DIR/hy2.env"
    : > "$HY_DIR/.thirdparty"
    ok "已同步第三方配置: 端口 ${p}/udp, 证书方式 ${mode}, SNI ${dom:-无}"
    return 0
}

# 内置 zihua-hy2 若还在, 先停掉, 免得和第三方脚本抢同一个 UDP 端口
hy2_drop_builtin() {
    [[ -f "/etc/systemd/system/${HY_SERVICE}.service" || -f "/etc/init.d/${HY_SERVICE}" ]] || return 0
    warn "检测到本脚本内置的 zihua-hy2 服务, 先停掉, 避免与第三方脚本抢同一个 UDP 端口"
    if [[ "$INIT_SYS" == "systemd" ]]; then
        systemctl disable --now "$HY_SERVICE" >/dev/null 2>&1
        rm -f "/etc/systemd/system/${HY_SERVICE}.service" "/etc/systemd/system/${HY_SERVICE}-hop.service"
        systemctl daemon-reload
    else
        rc-service "$HY_SERVICE" stop >/dev/null 2>&1
        rc-update del "$HY_SERVICE" default >/dev/null 2>&1
        rm -f "/etc/init.d/${HY_SERVICE}" "/etc/local.d/${HY_SERVICE}-hop.start"
    fi
    ok "内置 Hysteria2 服务已停用(它的配置仍保留在 $HY_DIR)"
}

# 按第三方脚本的卸载逻辑清理: 只动 hysteria / ipppp, 不碰 SS2022 与 Reality
hy2_third_uninstall() {
    local force="${1:-}"
    warn "Hysteria2 由第三方脚本安装, 按它的卸载逻辑清理(只动 hysteria, 不影响 SS2022/Reality)"
    if [[ "$force" != "-y" ]]; then
        ask "确认卸载 Hysteria2? [y/N]" "n"
        [[ "$RESULT" =~ ^[yY]([eE][sS])?$ ]] || { info "已取消"; return 1; }
    fi
    local mp hs he
    mp="$(sed -n 's/^listen:[[:space:]]*:*\([0-9][0-9]*\).*/\1/p' "$HY3_CFG" 2>/dev/null | head -n1)"
    if [[ -f "$HY3_DIR/ipppp.sh" ]]; then
        hs="$(sed -n 's/.*--dport \([0-9]*\):\([0-9]*\).*/\1/p' "$HY3_DIR/ipppp.sh" | head -n1)"
        he="$(sed -n 's/.*--dport \([0-9]*\):\([0-9]*\).*/\2/p' "$HY3_DIR/ipppp.sh" | head -n1)"
        if [[ -n "$hs" && -n "$he" && -n "$mp" ]] && command -v iptables >/dev/null 2>&1; then
            iptables -t nat -D PREROUTING -i eth0 -p udp --dport "${hs}:${he}" -j DNAT --to-destination ":$mp" >/dev/null 2>&1
        fi
    fi
    if [[ "$INIT_SYS" == "systemd" ]]; then
        systemctl disable --now "$HY3_SERVICE" >/dev/null 2>&1
        systemctl disable --now ipppp >/dev/null 2>&1
        rm -f "/etc/systemd/system/${HY3_SERVICE}.service" "/etc/systemd/system/ipppp.service"
        systemctl daemon-reload
    fi
    rm -rf "$HY3_DIR" /usr/local/bin/hy2 "$HY3_LOCAL"
    rm -f "$HY_DIR/.thirdparty" "$SB_ENV_DIR/hy2.env"
    ok "Hysteria2 已卸载(SS2022 / Reality 未改动)"
    return 0
}

add_hy2() {
    pre_install "安装 Hysteria2(调用第三方脚本)" "Hysteria2 的安装直接交给 seagullz4/hysteria2 的 install.sh 完成, 与它自己一键安装完全一致; 本脚本只负责下载、调用并把结果接进节点列表。UDP 传输, 与 TCP 443 的 Reality 可同号并存。" || return 1
    # 第三方脚本只认 systemd 系统(Debian/Ubuntu/CentOS), Alpine/OpenRC 上直接调用必然装不上
    if [[ "$INIT_SYS" != "systemd" ]]; then
        warn "第三方脚本只支持 systemd 系统(Debian/Ubuntu/CentOS), 当前是 ${INIT_SYS:-未知}(如 Alpine), 直接调用装不上。"
        ask "改用本脚本内置流程安装 Hysteria2? [Y/n]" "y"
        [[ "$RESULT" =~ ^[nN]$ ]] && return 1
        add_hy2_builtin
        return $?
    fi
    # 两种方式都可用, 默认第三方; 想逐项对照排查时可用内置流程
    ask_choice "Hysteria2 安装方式" 1 \
        1 "调用第三方脚本 seagullz4/hysteria2（与它自己一键安装完全一致，推荐）" \
        2 "用本脚本内置流程（官方 hysteria 内核，参数由本脚本询问）"
    if [[ "$RESULT" == "2" ]]; then
        add_hy2_builtin
        return $?
    fi
    hy2_third_credit
    warn "接下来进入第三方脚本自己的交互界面, 它依次问你: 端口(默认443) / 证书方式(1=ACME, 2=自签) / 密码 / 伪装网址 / 端口跳跃。"
    warn "进去先选 1(安装)。装完它会打印节点链接, 然后回到本脚本, 由本脚本统一展示。"
    ask "继续? [Y/n]" "y"
    [[ "$RESULT" =~ ^[nN]$ ]] && { info "已取消"; return 1; }

    if [[ ! -f "$HY3_LOCAL" ]] && ! hy2_third_fetch; then
        err "下载第三方脚本失败(四个通道都不通)"
        info "也可以在服务器上手动执行这一条, 效果完全一样:"
        printf '   %sbash <(curl -fsSL %s/raw/main/install.sh)%s\n' "$BOLD" "$HY3_REPO" "$NC"
        ask "改用本脚本内置流程安装? [y/N]" "n"
        if [[ "$RESULT" =~ ^[yY]$ ]]; then add_hy2_builtin; return $?; fi
        return 1
    fi

    # 已经装过时它的安装向导会直接拒绝(提示『Hysteria 正在运行，请先卸载再安装』), 先在外部清掉
    if hy2_third_installed; then
        warn "检测到已经装过一次 Hysteria2(第三方脚本), 它的向导会拒绝『正在运行，请先卸载再安装』。"
        ask "先卸载现有 Hysteria2 再重新安装? [Y/n]" "y"
        if [[ "$RESULT" =~ ^[nN]$ ]]; then
            info "已取消。只想改参数的话, 请先『删除某个代理』删掉 hy2 再重装。"
            return 1
        fi
        hy2_third_uninstall -y || return 1
    fi

    hy2_drop_builtin
    title "进入第三方安装脚本"
    printf '   文件: %s\n   来源: %s\n\n' "$HY3_LOCAL" "$HY3_REPO"
    info "进去选 1(安装)。装完按它自己的提示回到本脚本即可。"
    ( cd /root && bash "$HY3_LOCAL" ) || info "第三方脚本已退出, 继续检测安装结果..."

    if hy2_third_installed && hy2_third_sync; then
        # 第三方脚本会先用 nohup 跑一个进程再建 systemd 服务, 这里统一交给 systemd 托管
        if [[ -f "/etc/systemd/system/${HY3_SERVICE}.service" ]]; then
            pkill -f "${HY3_DIR}/hysteria" >/dev/null 2>&1
            sleep 1
            hysvc_restart >/dev/null 2>&1 && ok "已交给 systemd 托管并重启($HY3_SERVICE), 开机自启已生效"
        fi
        # 第三方脚本不管本机防火墙, 这里补放行(漏了就是"服务在跑但客户端超时")
        load_env hy2
        [[ -n "${PORT:-}" ]] && open_port_in_firewall "$PORT" udp
        # 标记为已迁移, 避免下次进『代理管理』又被当成旧版反复提示
        mkdir -p "$HY_DIR"; : > "$HY_DIR/.migrated"; rm -f "$HY_DIR/.migrate_skip"
        print_share hy2
        ok "Hysteria2 已就绪(第三方脚本安装), 已接入本脚本的节点列表"
        info "之后可在『代理管理』里查看/启停/看日志; 卸载请用『删除某个代理』, 会走第三方脚本的清理逻辑。"
    else
        warn "没有检测到 $HY3_CFG, 看起来没装成功"
        printf '   重新执行: %sbash %s%s 然后选 1\n' "$BOLD" "$HY3_LOCAL" "$NC"
    fi
}

add_hy2_builtin() {
    pre_install "安装 Hysteria2" "Hysteria2 使用官方 hysteria 内核(与 seagullz4/hysteria2 同方案), QUIC/UDP 传输, 弱网/高丢包环境速度快。UDP 与 TCP 端口互不影响, 可与 VLESS(TCP 443)同号并存。" || return 1
    ask_port 443 udp
    title "Hysteria2 密码设置"
    local defpass
    defpass="$(gen_rand 16)"
    info "填写规则: 仅字母/数字/下划线/点/短横线（会拼进分享链接，别用特殊符号），8~32 位。回车直接用随机密码。"
    ask_valid "输入连接密码" "$defpass" v_uri_safe
    PASSWORD="$RESULT"

    title "TLS 证书设置"
    info "Hysteria2 走加密的 QUIC，必须有 TLS 证书。三种来源:"
    info "① 自签证书: 不需要域名，脚本自动生成；客户端节点里要打开『允许不安全/Insecure』开关。"
    info "② 已有证书文件: 用 acme.sh / certbot / 宝塔 签好的 pem + key，直接填路径。"
    info "③ 内置 ACME 自动申请: 填域名+邮箱，由 hysteria 自己申请并自动续期，客户端无需开不安全。"
    ask_choice "选择证书来源" 1 \
        1 "自签证书（没有域名选这个，最快最简单）" \
        2 "已有证书文件（我有签发好的 pem + key）" \
        3 "内置 ACME 自动申请（我有域名且已解析到本机）"
    local sel="$RESULT"
    CERT_FILE=""; KEY_FILE=""; ACME_EMAIL=""
    case "$sel" in
        2)
            ask_valid "输入证书(.pem/.crt)完整路径" "" v_path
            CERT_FILE="$RESULT"
            ask_valid "输入私钥(.key)完整路径" "" v_path
            KEY_FILE="$RESULT"
            ask_valid "输入证书对应的域名(用于客户端 SNI)" "" v_domain
            DOMAIN="$RESULT"
            CERT_MODE="manual"; CERT_CN="$DOMAIN" ;;
        3)
            ask_valid "输入你的域名(需已解析到本机 IP)" "" v_domain
            DOMAIN="$RESULT"
            ask "输入 ACME 邮箱(用于证书到期通知, 回车用默认)" "admin@${DOMAIN#*.}"
            ACME_EMAIL="$RESULT"
            if [[ "$PORT" != "443" ]]; then
                warn "内置 ACME 用 443 端口做 TLS-ALPN-01 验证, 当前 ${PORT} 会签发失败。"
                ask "改用 UDP 443 端口? [Y/n]" "y"
                if [[ "$RESULT" =~ ^[nN]$ ]]; then
                    warn "保持 ${PORT}: ACME 大概率失败, 失败后可改回自签证书。"
                elif port_in_use 443 udp; then
                    err "UDP 443 已被占用, 无法改用; 请释放后重试, 或退回上一步选自签证书。"
                    return 1
                else
                    PORT="443"
                fi
            fi
            CERT_MODE="acme" ;;
        *)
            CERT_MODE="self" ;;
    esac
    if [[ "$CERT_MODE" == "self" ]]; then
        title "自签证书域名(伪装用)"
        info "这个域名只是写进自签证书的名字（不需要真实存在、不需要解析），客户端 SNI 也填它。"
        info "客户端需打开『允许不安全/Insecure』开关。直接回车用默认即可。"
        ask_valid "输入伪装域名" "bing.com" v_domain
        DOMAIN="$RESULT"
        rm -f "$SB_CERT_DIR/hy2.pem" "$SB_CERT_DIR/hy2.key"
        gen_self_signed_cert hy2 "$DOMAIN" >/dev/null || { err "自签证书生成失败"; return 1; }
        CERT_CN="$DOMAIN"
    fi

    title "网站伪装(可选)"
    info "未通过认证的 HTTP 请求会被反代到下面这个网站，端口扫描看起来像正常站点。直接回车即可。"
    ask_valid "输入伪装网址" "https://news.ycombinator.com/" v_url
    MASQ="$RESULT"

    title "端口跳跃(可选)"
    info "开启后客户端可在一段 UDP 端口范围内跳跃, 抗封锁更强。需要 iptables 支持, 不用就回车跳过。"
    ask "开启端口跳跃? [y/N]" "n"
    HOP_START=""; HOP_END=""
    if [[ "$RESULT" =~ ^[yY] ]]; then
        ask_valid "输入起始端口(如 20000)" "" v_port
        HOP_START="$RESULT"
        while :; do
            ask_valid "输入结束端口(需大于起始端口)" "" v_port
            HOP_END="$RESULT"
            (( 10#$HOP_END > 10#$HOP_START )) && break
            err "结束端口必须大于起始端口"
        done
        (( 10#$HOP_END - 10#$HOP_START > 2000 )) && warn "范围超过 2000 个端口, 可能被安全组/运营商丢弃, 建议 200~1000 个。"
    fi

    ask_node_name "hysteria2-${DOMAIN}"
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
ACME_EMAIL='$ACME_EMAIL'
HOP_START='$HOP_START'
HOP_END='$HOP_END'
NAME='$SAVE_NAME'
CREATED="$(date '+%F %T')"
ENV
    chmod 600 "$SB_ENV_DIR/hy2.env"
    apply_one "hy2" || return 1
    [[ -n "$HOP_START" && -n "$HOP_END" ]] && info "端口跳跃范围 ${HOP_START}-${HOP_END} 若用云服务器, 请到控制台安全组一并放行 UDP。"
    print_share "hy2"
    ok "Hysteria2 安装完成"
}

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
    if [[ "$(proto_kernel "$k")" == "hysteria" ]]; then
        # ---- Hysteria2: 官方 hysteria 内核(独立服务) ----
        hy_apply
        return $?
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
    for k in "${keys[@]}"; do
        load_env "$k"
        # 每个协议按自己所属内核判断运行状态(sing-box / Xray / hysteria 三套服务)
        st="未运行"
        kernel_active "$k" && st="运行中"
        case "$k" in
            ss2022)   proto_name="Shadowsocks-2022 (TCP)" ;;
            hy2)      proto_name="Hysteria2 (第三方脚本安装, UDP/QUIC)" ;;
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
    if [[ -x "$HY_BIN" ]]; then
        info "Hysteria2(官方内核) 状态: $(hysvc_active && echo 运行中 || echo 未运行)   版本: $("$HY_BIN" version 2>/dev/null | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -n1 || echo 未知)"
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
    local base="PORT UUID PASSWORD METHOD NAME DOMAIN CERT_MODE CERT_FILE KEY_FILE CERT_CN MASQ SNI_HOST SNI_PORT RPC REALITY_PUB REALITY_PK SHORT_ID HOP_START HOP_END ACME_EMAIL"
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
    if hy2_third_installed; then
        warn "Hysteria2 由第三方脚本安装, 端口/证书/密码/伪装都在它的安装流程里改"
        info "重跑一遍它的安装向导即可(它会先卸载旧配置再按新参数装), 也可选 3 查看当前配置。"
        ask "现在运行第三方脚本? [Y/n]" "y"
        [[ "$RESULT" =~ ^[nN]$ ]] && return 0
        [[ -f "$HY3_LOCAL" ]] || hy2_third_fetch || {
            err "脚本不存在且下载失败, 可手动执行: bash <(curl -fsSL $HY3_REPO/raw/main/install.sh)"
            return 1
        }
        ( cd /root && bash "$HY3_LOCAL" )
        hy2_third_sync >/dev/null 2>&1 && print_share hy2
        pause
        return 0
    fi
    ask_choice "Hysteria2 修改项" "" \
        1 "修改监听端口(当前: $PORT)" \
        2 "修改连接密码(当前已设置)" \
        3 "更换证书方式(自签/已有文件/内置ACME)" \
        4 "修改伪装网址(当前: ${MASQ})" \
        5 "修改伪装域名(当前: ${DOMAIN}; 自签模式下会重新生成证书)" \
        6 "端口跳跃开关(当前: ${HOP_START:+$HOP_START-$HOP_END}${HOP_START:-关闭})" \
        7 "修改节点名称(当前: ${NAME})"
    [[ -z "$RESULT" ]] && return 0
    case "$RESULT" in
        1) ask_port "$PORT" udp ;;
        2) ask_valid "输入新密码" "$(gen_rand 16)" v_uri_safe; PASSWORD="$RESULT" ;;
        3)
            ask_choice "TLS 证书来源" 1 \
                1 "自签证书(客户端需允许不安全)" \
                2 "已有证书文件" \
                3 "内置 ACME 自动申请(需域名解析到本机+443端口空闲)"
            case "$RESULT" in
                2)
                    ask_valid "输入证书路径" "${CERT_FILE:-}" v_path; CERT_FILE="$RESULT"
                    ask_valid "输入私钥路径" "${KEY_FILE:-}" v_path; KEY_FILE="$RESULT"
                    ask_valid "输入证书对应域名(客户端 SNI)" "$DOMAIN" v_domain; DOMAIN="$RESULT"
                    CERT_MODE="manual"; CERT_CN="$DOMAIN" ;;
                3)
                    ask_valid "输入你的域名" "${DOMAIN:-}" v_domain; DOMAIN="$RESULT"
                    ask "输入 ACME 邮箱" "${ACME_EMAIL:-admin@${DOMAIN#*.}}"; ACME_EMAIL="$RESULT"
                    if [[ "$PORT" != "443" ]]; then
                        warn "内置 ACME 用 443 端口做 TLS-ALPN-01 验证, 当前 ${PORT} 会签发失败。"
                        ask "改用 UDP 443 端口? [Y/n]" "y"
                        if [[ ! "$RESULT" =~ ^[nN]$ ]]; then
                            if port_in_use 443 udp; then err "UDP 443 被占用, 保持原端口"; else PORT="443"; fi
                        fi
                    fi
                    CERT_MODE="acme"; CERT_FILE=""; KEY_FILE="" ;;
                *)
                    ask_valid "输入伪装域名(自签证书用)" "${DOMAIN:-bing.com}" v_domain; DOMAIN="$RESULT"
                    rm -f "$SB_CERT_DIR/hy2.pem" "$SB_CERT_DIR/hy2.key"
                    gen_self_signed_cert hy2 "$DOMAIN" >/dev/null && CERT_CN="$DOMAIN"
                    CERT_MODE="self"; CERT_FILE=""; KEY_FILE=""
                    warn "已重新生成自签证书, 客户端需勾选『允许不安全』" ;;
            esac ;;
        4) ask_valid "输入伪装网址" "${MASQ:-https://news.ycombinator.com/}" v_url; MASQ="$RESULT" ;;
        5)
            ask_valid "输入伪装域名" "$DOMAIN" v_domain; DOMAIN="$RESULT"
            if [[ "$CERT_MODE" != "manual" && "$CERT_MODE" != "acme" ]]; then
                rm -f "$SB_CERT_DIR/hy2.pem" "$SB_CERT_DIR/hy2.key"
                gen_self_signed_cert hy2 "$DOMAIN" >/dev/null && CERT_CN="$DOMAIN"
                ok "自签证书已按新域名重新生成"
            fi ;;
        6)
            if [[ -n "${HOP_START:-}" ]]; then
                HOP_START=""; HOP_END=""; info "已关闭端口跳跃"
            else
                ask_valid "输入起始端口(如 20000)" "" v_port; HOP_START="$RESULT"
                while :; do
                    ask_valid "输入结束端口(需大于起始端口)" "" v_port; HOP_END="$RESULT"
                    (( 10#$HOP_END > 10#$HOP_START )) && break
                    err "结束端口必须大于起始端口"
                done
            fi ;;
        7) ask "输入新名称" "${NAME:-$k}"; NAME="$RESULT" ;;
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
    # Hysteria2: 第三方脚本装的就按它的逻辑卸载, 内置流程装的清我们自己的服务
    if [[ "$k" == "hy2" ]] && hy2_third_installed; then
        hy2_third_uninstall
    elif [[ "$k" == "hy2" ]]; then
        [[ -n "${HOP_START:-}" && -n "${HOP_END:-}" ]] && hy_hop_clean "$HOP_START" "$HOP_END" "$PORT"
        hysvc_stop_now
        if [[ "$INIT_SYS" == "systemd" ]]; then
            rm -f "/etc/systemd/system/${HY_SERVICE}.service" "/etc/systemd/system/${HY_SERVICE}-hop.service"
            systemctl daemon-reload
        else
            rm -f "/etc/init.d/${HY_SERVICE}" "/etc/local.d/${HY_SERVICE}-hop.start"
        fi
        rm -rf "$HY_DIR"
        ok "已停止并移除 Hysteria2 服务(其余协议不受影响)"
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
        1)
            svc_do_start && ok "sing-box 已启动"
            [[ -f "$XRAY_CFG" ]] && { xray_ensure_service; xsvc_restart && ok "Xray 已启动"; }
            [[ -f "$SB_ENV_DIR/hy2.env" ]] && { hy_apply && ok "Hysteria2 已启动"; } ;;
        2)
            svc_do_stop && ok "sing-box 已停止"
            [[ -f "$XRAY_CFG" ]] && { xsvc_stop_now; ok "Xray 已停止"; }
            [[ -f "$HY_CFG" ]] && { hysvc_stop_now; ok "Hysteria2 已停止"; } ;;
        3)
            svc_restart
            if [[ -f "$XRAY_CFG" ]]; then info "重启 Xray(Reality) 服务..."; xray_ensure_service; xsvc_restart; fi
            if [[ -f "$SB_ENV_DIR/hy2.env" ]]; then info "重启 Hysteria2 服务..."; hy_apply && ok "Hysteria2 已重启"; fi ;;
        4)
            svc_show_status
            if [[ -f "$XRAY_CFG" ]]; then
                info "--- Xray (Reality) ---"
                if [[ "$INIT_SYS" == "systemd" ]]; then systemctl status "$XRAY_SERVICE" --no-pager -l 2>/dev/null | head -n 12; else rc-service "$XRAY_SERVICE" status 2>/dev/null; fi
            fi
            if [[ -f "$HY_CFG" ]]; then
                info "--- Hysteria2 ---"
                if [[ "$INIT_SYS" == "systemd" ]]; then systemctl status "$HY_SERVICE" --no-pager -l 2>/dev/null | head -n 12; else rc-service "$HY_SERVICE" status 2>/dev/null; fi
            fi ;;
    esac
    pause
}

menu_logs() {
    title "查看日志(最近 60 行)"
    info "--- sing-box (SS2022/TUIC) ---"
    svc_log_tail 40 | sed 's/^/  /'
    if [[ -x "$XRAY_BIN" ]]; then
        info "--- Xray (Reality) ---"
        xsvc_log_tail 40 | sed 's/^/  /'
        info "Xray 日志文件: $XRAY_LOG_FILE"
    fi
    if [[ -x "$HY_BIN" ]]; then
        info "--- Hysteria2 (官方内核) ---"
        hysvc_log_tail 40 | sed 's/^/  /'
        info "Hysteria2 日志文件: $HY_LOG_FILE   配置: $HY_CFG"
    fi
    if [[ "$INIT_SYS" == "systemd" ]]; then
        info "持续跟踪: journalctl -u $SERVICE_NAME -f ; journalctl -u $XRAY_SERVICE -f ; journalctl -u $HY_SERVICE -f"
    else
        info "持续跟踪: tail -f $LOG_FILE ; tail -f $XRAY_LOG_FILE ; tail -f $HY_LOG_FILE"
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
    # Hysteria2 官方内核一并卸载
    hysvc_stop_now
    if [[ "$INIT_SYS" == "systemd" ]]; then
        rm -f "/etc/systemd/system/${HY_SERVICE}.service" "/etc/systemd/system/${HY_SERVICE}-hop.service"
        systemctl daemon-reload
    elif [[ "$INIT_SYS" == "openrc" ]]; then
        rm -f "/etc/init.d/${HY_SERVICE}" "/etc/local.d/${HY_SERVICE}-hop.start"
    fi
    rm -f "$HY_BIN" "$HY_LOG_FILE" "/run/${HY_SERVICE}.pid"
    ok "sing-box / Xray / Hysteria2 内核、服务均已卸载"
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
    # 裸 iptables: 只有 INPUT 存在拦截策略时才插放行规则, 全放行的机器不去污染规则表
    if command -v iptables >/dev/null 2>&1; then
        local pol ndrop
        pol="$(iptables -S INPUT 2>/dev/null | sed -n 's/^-P INPUT //p' | head -n1)"
        ndrop="$(iptables -S INPUT 2>/dev/null | grep -cE '^-A INPUT .*-j (DROP|REJECT)')"
        if [[ "$pol" != "ACCEPT" || "${ndrop:-0}" != "0" ]]; then
            if iptables -C INPUT -p "$proto" --dport "$p" -j ACCEPT >/dev/null 2>&1; then
                ok "iptables 已有 ${p}/${proto} 放行规则"
            elif iptables -I INPUT -p "$proto" --dport "$p" -j ACCEPT >/dev/null 2>&1; then
                ok "iptables 已放行 ${p}/${proto}"
                # netfilter-persistent 的保存目录存在时顺手持久化, 避免重启失效
                [[ -d /etc/iptables ]] && iptables-save > /etc/iptables/rules.v4 2>/dev/null
            else
                warn "iptables 放行 ${p}/${proto} 失败, 请手动处理"
            fi
            return 0
        fi
    fi
    info "提示: 如使用云服务器(AWS/GCP/阿里云等), 请到控制台『安全组/防火墙』手动放行 ${p}/${proto}。"
}

#--------------------------------- 网络优化 (BBR/内核调优) -------------------------
# 读值并兜底显示(容器内部分键不可读)
_v() { local x; x="$(sysctl_cur "$1")"; printf '%s' "${x:--}"; }

# 该键是否被容器/宿主完全隐藏(/proc 里没有, sysctl 也读不到)
sysctl_hidden() {
    [[ -e "/proc/sys/${1//./\/}" ]] && return 1
    [[ -n "$(sysctl -n "$1" 2>/dev/null)" ]] && return 1
    return 0
}

# 队列调度器状态: 内核不暴露 net.core.default_qdisc 时, 退而查询网卡实际 qdisc
qdisc_state() {
    local q iface d
    q="$(sysctl_cur net.core.default_qdisc)"
    if [[ -n "$q" ]]; then printf '%s' "$q"; return 0; fi
    iface="$(ip route show default 2>/dev/null | sed -n 's/.* dev \([^ ]*\).*/\1/p' | head -n 1)"
    [[ -z "$iface" ]] && iface="$(ls /sys/class/net 2>/dev/null | grep -v '^lo$' | head -n 1)"
    if command -v tc >/dev/null 2>&1 && [[ -n "$iface" ]]; then
        d="$(tc qdisc show dev "$iface" 2>/dev/null | head -n 1 | awk '{print $2}')"
        [[ -n "$d" ]] && { printf '不可读(%s 实际 %s)' "$iface" "$d"; return 0; }
    fi
    printf '不可读(容器由宿主机控制)'
}

show_net_status() {
    title "当前网络内核参数状态"
    local cc qdisc avail kern mem buf
    kern="$KERNEL"
    mem="$(mem_total_mb)"
    buf="$(tune_buf_bytes "$mem")"
    info "内核版本: ${kern}   内存: ${mem} MB"
    if version_ge "${kern%%-*}" "4.9"; then
        ok "内核版本满足 BBR 要求 (≥ 4.9)"
    else
        warn "内核版本低于 4.9，无法开启 BBR。建议升级系统(如 Debian 12 / Ubuntu 22.04)。"
    fi
    cc="$(sysctl_cur net.ipv4.tcp_congestion_control)"
    qdisc="$(qdisc_state)"
    avail="$(cat /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null | tr ' ' '/' )"
    printf '  拥塞控制算法: %s%s%s   (可选: %s)\n' "$BOLD" "${cc:-不可读}" "$NC" "${avail:-未知}"
    printf '  默认队列算法: %s%s%s\n' "$BOLD" "${qdisc:-不可读}" "$NC"
    printf '  收发缓冲上限: rmem=%s  wmem=%s   (本机建议: %s)\n' \
        "$(_v net.core.rmem_max)" "$(_v net.core.wmem_max)" "$buf"
    printf '  并发队列    : somaxconn=%s  backlog=%s  SYN=%s\n' \
        "$(_v net.core.somaxconn)" "$(_v net.core.netdev_max_backlog)" "$(_v net.ipv4.tcp_max_syn_backlog)"
    printf '  加速项      : fastopen=%s  空闲不重置窗口=%s  MTU探测=%s  TIME_WAIT复用=%s\n' \
        "$(_v net.ipv4.tcp_fastopen)" "$(_v net.ipv4.tcp_slow_start_after_idle)" \
        "$(_v net.ipv4.tcp_mtu_probing)" "$(_v net.ipv4.tcp_tw_reuse)"
    if [[ "${cc:-}" == "bbr" ]]; then
        ok "BBR 已启用"
    else
        warn "BBR 未启用 (选 1 或 2 开启)"
    fi
    if [[ -f "$SYSCTL_FILE" ]]; then
        info "调优配置文件: $SYSCTL_FILE ($(grep -c ' = ' "$SYSCTL_FILE" 2>/dev/null || echo 0) 项, 重启自动生效)"
    else
        info "调优配置文件: 未创建"
    fi
    return 0
}

# --- 内核调优基础工具 ---
# 物理内存(MB)
mem_total_mb() {
    local kb
    kb="$(awk '/^MemTotal:/{print $2}' /proc/meminfo 2>/dev/null)"
    [[ -z "$kb" || "$kb" -le 0 ]] && kb=1048576
    echo $(( kb / 1024 ))
}

# 收发缓冲上限: 按物理内存缩放(照抄大盘鸡脚本的 64M/128M 会让小内存机型 OOM)
tune_buf_bytes() {
    local mb="${1:-1024}"
    if   (( mb <= 384 ));  then echo 8388608      # 8M
    elif (( mb <= 768 ));  then echo 16777216     # 16M
    elif (( mb <= 1536 )); then echo 33554432     # 32M
    elif (( mb <= 3072 )); then echo 50331648     # 48M
    elif (( mb <= 6144 )); then echo 67108864     # 64M
    else                       echo 134217728     # 128M
    fi
}

# sysctl 键在当前内核/命名空间是否存在(容器与老内核常有缺项, 直接写会整批报错)
sysctl_ok() { [[ -e "/proc/sys/${1//./\/}" ]]; }

# 读取 sysctl 当前值
sysctl_cur() {
    local p="/proc/sys/${1//./\/}"
    if [[ -r "$p" ]]; then
        tr -s '[:space:]' ' ' < "$p" 2>/dev/null | sed 's/^ //; s/ $//'
    else
        sysctl -n "$1" 2>/dev/null | tr -s '[:space:]' ' ' | sed 's/^ //; s/ $//'
    fi
}

# 首次调优时记录原值, 供『恢复默认参数』精确回滚
sysctl_backup() {
    local k="$1" v="$2"
    mkdir -p "$(dirname "$SYSCTL_BAK")" 2>/dev/null || return 0
    [[ -f "$SYSCTL_BAK" ]] || : > "$SYSCTL_BAK" 2>/dev/null || return 0
    grep -qF "$k = " "$SYSCTL_BAK" 2>/dev/null && return 0
    printf '%s = %s\n' "$k" "$v" >> "$SYSCTL_BAK" 2>/dev/null
}

# 完整调优参数表: 键|建议值|作用域|说明    (n=网络命名空间内可写; g=全局, 容器内通常不可写)
tune_table_full() {
    local mem buf
    mem="$(mem_total_mb)"
    buf="$(tune_buf_bytes "$mem")"
    cat <<EOF
net.core.default_qdisc|fq|n|BBR 配套 fq 队列(必选)
net.ipv4.tcp_congestion_control|bbr|n|BBR 拥塞控制算法
net.core.rmem_max|$buf|n|接收缓冲上限(按 ${mem}MB 内存缩放)
net.core.wmem_max|$buf|n|发送缓冲上限
net.core.rmem_default|1048576|n|默认接收缓冲
net.core.wmem_default|1048576|n|默认发送缓冲
net.ipv4.tcp_rmem|4096 87380 $buf|n|TCP 接收缓冲(内核自动调节)
net.ipv4.tcp_wmem|4096 16384 $buf|n|TCP 发送缓冲(内核自动调节)
net.core.optmem_max|65536|n|辅助数据结构缓冲
net.core.somaxconn|32768|n|监听队列上限(高并发)
net.core.netdev_max_backlog|16384|n|网卡收包队列(高并发关键)
net.ipv4.tcp_max_syn_backlog|8192|n|SYN 半连接队列
net.ipv4.tcp_fastopen|3|n|TCP Fast Open(客户端+服务端)
net.ipv4.tcp_slow_start_after_idle|0|n|空闲后不重置拥塞窗口
net.ipv4.tcp_notsent_lowat|16384|n|减少发送缓冲积压, 降延迟
net.ipv4.tcp_mtu_probing|1|n|MTU 黑洞探测(防丢包卡死)
net.ipv4.tcp_no_metrics_save|1|n|新连接不沿用历史拥塞状态
net.ipv4.tcp_autocorking|0|n|关闭发送聚合, 降小包延迟
net.ipv4.tcp_tw_reuse|1|n|TIME_WAIT 快速复用(短连接多)
net.ipv4.tcp_fin_timeout|15|n|FIN_WAIT2 超时
net.ipv4.tcp_max_tw_buckets|6000|n|TIME_WAIT 桶上限
net.ipv4.tcp_keepalive_time|300|n|保活起始时间
net.ipv4.tcp_keepalive_intvl|15|n|保活探测间隔
net.ipv4.tcp_keepalive_probes|5|n|保活探测次数
net.ipv4.ip_local_port_range|1024 65000|n|本地端口范围(中转/反代关键)
net.ipv4.tcp_syncookies|1|n|SYN Flood 防护
net.ipv4.tcp_rfc1337|1|n|丢弃 TIME_WAIT 状态的 RST
net.ipv4.udp_rmem_min|8192|n|UDP 最小接收缓冲(QUIC/Hysteria2)
net.ipv4.udp_wmem_min|8192|n|UDP 最小发送缓冲(QUIC/Hysteria2)
net.ipv4.icmp_echo_ignore_broadcasts|1|n|忽略广播 ICMP
net.ipv4.conf.all.rp_filter|0|n|关闭反向路径校验(多网卡中转友好)
net.netfilter.nf_conntrack_max|65536|n|连接跟踪上限(NAT 中转关键)
fs.file-max|1048576|g|系统文件句柄上限
vm.swappiness|10|g|降低交换倾向(小内存机型)
EOF
}

# 仅 BBR 参数表
tune_table_bbr() {
    cat <<'EOF'
net.core.default_qdisc|fq|n|BBR 配套 fq 队列
net.ipv4.tcp_congestion_control|bbr|n|BBR 拥塞控制算法
net.ipv4.tcp_fastopen|3|n|TCP Fast Open
net.ipv4.tcp_slow_start_after_idle|0|n|空闲后不重置拥塞窗口
net.ipv4.tcp_mtu_probing|1|n|MTU 黑洞探测
EOF
}

# 逐条应用(单条失败不影响其余), 结果放入 TUNE_OK / TUNE_APPLIED / TUNE_SKIP / TUNE_HOST / TUNE_FAIL
apply_sysctl_table() {
    local table="$1" key val scope desc
    TUNE_OK=0; TUNE_APPLIED=""; TUNE_SKIP=""; TUNE_HOST=""; TUNE_FAIL=""
    while IFS='|' read -r key val scope desc; do
        [[ -z "$key" || "$key" == \#* ]] && continue
        if ! sysctl_ok "$key"; then
            # 区分: 内核根本没有该键(容器未暴露) / 容器不可见但宿主有
            if sysctl_hidden "$key"; then TUNE_SKIP+="$key "; else TUNE_HOST+="$key "; fi
            continue
        fi
        sysctl_backup "$key" "$(sysctl_cur "$key")"
        if sysctl -w "${key}=${val}" >/dev/null 2>&1; then
            TUNE_OK=$(( TUNE_OK + 1 ))
            TUNE_APPLIED+="$key = $val"$'\n'
        elif [[ "$scope" == "g" ]]; then
            TUNE_HOST+="$key "
        else
            TUNE_FAIL+="$key "
        fi
    done <<< "$table"
}

_tune_list_warn() {
    local msg="$1" list="$2" n
    [[ -z "${list// /}" ]] && return 0
    n="$(printf '%s\n' $list | grep -c .)"
    warn "${msg} (${n} 项):"
    printf '%s\n' $list | grep . | head -n 12 | sed 's/^/    - /'
    [[ "$n" -gt 12 ]] && printf '    ... 其余 %d 项略\n' $(( n - 12 ))
    return 0
}

report_tune_result() {
    ok "本次生效 ${TUNE_OK} 项"
    _tune_list_warn "该内核/容器未暴露此参数, 已跳过" "$TUNE_SKIP"
    _tune_list_warn "宿主级参数不可写(容器/权限限制, 不影响代理)" "$TUNE_HOST"
    _tune_list_warn "写入被拒" "$TUNE_FAIL"
    # 容器内改不了队列调度时给出准确解释, 避免误以为 BBR 没生效
    if [[ "$TUNE_SKIP$TUNE_HOST" == *net.core.default_qdisc* ]]; then
        info "net.core.default_qdisc 由宿主机管理, 容器内改不了; 属正常现象。"
        info "Linux 4.20 起 BBR 自带 pacing, 缺 fq 不影响加速效果; 网卡实际队列见上方状态行。"
    fi
    return 0
}

# Alpine(OpenRC): 确保开机会应用 /etc/sysctl.d/*.conf
ensure_sysctl_boot() {
    [[ -d /etc/init.d ]] || return 0
    [[ -x /etc/init.d/sysctl ]] || return 0
    command -v rc-update >/dev/null 2>&1 || return 0
    if ! rc-update show boot 2>/dev/null | grep -qw sysctl; then
        rc-update add sysctl boot >/dev/null 2>&1 && info "已把 sysctl 服务加入 boot 运行级(Alpine 开机自动应用)"
    fi
    return 0
}

# 应用参数表并写入持久化文件(只记录实际生效的项)
write_tune_file() {
    local table="$1" header="$2"
    apply_sysctl_table "$table"
    mkdir -p "$(dirname "$SYSCTL_FILE")" 2>/dev/null
    {
        printf '# ProxyBox 内核网络调优 — %s\n' "$header"
        printf '# 生成: %s | 内存 %s MB | 缓冲上限 %s 字节(按内存自动缩放)\n' \
            "$(date '+%F %T')" "$(mem_total_mb)" "$(tune_buf_bytes "$(mem_total_mb)")"
        printf '# 仅记录本次实际生效的参数; 删除本文件或用菜单『恢复默认参数』即可还原\n'
        printf '%s' "$TUNE_APPLIED"
    } > "$SYSCTL_FILE" 2>/dev/null || warn "无法写入 $SYSCTL_FILE (本次仅临时生效, 重启后失效)"
    ensure_sysctl_boot
    return 0
}

enable_bbr_only() {
    title "开启 BBR"
    if ! version_ge "${KERNEL%%-*}" "4.9"; then
        die "内核 $(uname -r) 太旧(< 4.9)，无法启用 BBR，请先升级系统/内核。"
    fi
    local virt="none" tbl k
    command -v systemd-detect-virt >/dev/null 2>&1 && virt="$(systemd-detect-virt 2>/dev/null || echo unknown)"
    case "$virt" in
        openvz|lxc|lxc-libvirt) warn "检测到 $virt 容器环境: 内核参数由宿主机控制, 部分项可能写入失败。" ;;
    esac
    # bbr 属内核模块, 独立内核(非云厂商定制内核)需先加载
    if ! grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
        info "内核未加载 bbr 模块, 尝试 modprobe tcp_bbr ..."
        command -v modprobe >/dev/null 2>&1 && modprobe tcp_bbr >/dev/null 2>&1 || true
    fi
    if ! grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
        err "当前内核不提供 bbr 算法 (可用: $(cat /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null | tr ' ' '/'))"
        err "容器内无法自行加载内核模块, 需宿主机内核支持 BBR。"
        return 1
    fi
    tbl="$(tune_table_bbr)"
    apply_sysctl_table "$tbl"
    if [[ -f "$SYSCTL_FILE" ]]; then
        # 已有完整调优文件: 只更新 BBR 相关行, 其余参数原样保留
        for k in net.core.default_qdisc net.ipv4.tcp_congestion_control; do
            sed -i "/^${k//./\\.} = /d" "$SYSCTL_FILE" 2>/dev/null
        done
        printf '%s' "$TUNE_APPLIED" >> "$SYSCTL_FILE" 2>/dev/null
    else
        write_tune_file "$tbl" "仅 BBR"
    fi
    ensure_sysctl_boot
    report_tune_result
    printf '  当前设置: tcp_congestion_control=%s  default_qdisc=%s\n' \
        "$(_v net.ipv4.tcp_congestion_control)" "$(qdisc_state)"
    if [[ "$(sysctl_cur net.ipv4.tcp_congestion_control)" == "bbr" ]]; then
        ok "BBR 已启用"
    else
        warn "BBR 未生效: 容器/内核限制了该参数 (tcping 正常但吞吐上不去时可换用『一键优化』或联系服务商)"
    fi
    return 0
}

net_optimize_full() {
    title "一键 BBR + 网络调优"
    if ! version_ge "${KERNEL%%-*}" "4.9"; then
        die "内核 $(uname -r) 太旧(< 4.9)，无法启用。请升级系统！"
    fi
    local virt="none" mem
    command -v systemd-detect-virt >/dev/null 2>&1 && virt="$(systemd-detect-virt 2>/dev/null || echo unknown)"
    case "$virt" in
        openvz|lxc|lxc-libvirt) warn "检测到 $virt 容器环境: 宿主级参数会写入失败, 已自动跳过并汇总提示, 不影响代理使用。" ;;
    esac
    mem="$(mem_total_mb)"
    info "内存 ${mem} MB → 收发缓冲上限按 $(tune_buf_bytes "$mem") 字节设置(按内存自动缩放, 不会吃爆小内存)"
    if ! grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
        command -v modprobe >/dev/null 2>&1 && modprobe tcp_bbr >/dev/null 2>&1 || true
    fi
    write_tune_file "$(tune_table_full)" "一键优化 (BBR + 全量网络参数)"
    report_tune_result
    printf '  拥塞控制: %s   队列: %s\n' \
        "$(_v net.ipv4.tcp_congestion_control)" "$(qdisc_state)"
    printf '  缓冲上限: rmem=%s  wmem=%s\n' \
        "$(sysctl_cur net.core.rmem_max)" "$(sysctl_cur net.core.wmem_max)"
    info "调优文件: $SYSCTL_FILE (重启自动生效)"
    [[ "$(sysctl_cur net.ipv4.tcp_congestion_control)" == "bbr" ]] \
        || warn "BBR 未能启用(容器/内核限制), 其余可用参数已尽量应用。"
    ok "一键优化完成"
    return 0
}

net_restore() {
    title "恢复默认参数"
    local n=0 f=0 k v line
    [[ -f "$SYSCTL_FILE" ]] && rm -f "$SYSCTL_FILE"
    if [[ -s "$SYSCTL_BAK" ]]; then
        info "按首次调优前的原值逐项回滚..."
        while IFS= read -r line; do
            [[ -z "$line" || "$line" == \#* ]] && continue
            k="${line%% = *}"; v="${line#* = }"
            [[ -z "$k" || -z "$v" ]] && continue
            if sysctl -w "${k}=${v}" >/dev/null 2>&1; then n=$(( n + 1 )); else f=$(( f + 1 )); fi
        done < "$SYSCTL_BAK"
        rm -f "$SYSCTL_BAK"
        ok "已回滚 ${n} 项参数"
        [[ "$f" -gt 0 ]] && warn "${f} 项回滚失败(容器限制), 重启后由系统默认值接管。"
    else
        sysctl -w net.ipv4.tcp_congestion_control=cubic >/dev/null 2>&1 || true
        sysctl -w net.core.default_qdisc=pfifo_fast >/dev/null 2>&1 || true
        info "未找到调优前的原值记录, 已切回 cubic + pfifo_fast(其余参数重启后恢复默认)。"
    fi
    printf '  拥塞控制: %s   队列: %s\n' \
        "$(_v net.ipv4.tcp_congestion_control)" "$(qdisc_state)"
    ok "已恢复默认参数"
    return 0
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
        printf '  %s2)%s '   "$BOLD" "$NC"; mark_installed "hy2";      echo "Hysteria2            UDP/QUIC, 调用第三方脚本安装, 弱网提速"
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

#----------------------------- Hysteria2 连通性自检 --------------------------------
# 客户端超时但服务端日志毫无反应时, 用它判断卡在 进程/监听/NAT/防火墙/安全组 哪一段
hy_diagnose() {
    title "Hysteria2 连通性自检"
    if [[ ! -f "$SB_ENV_DIR/hy2.env" ]]; then
        err "本机没有安装 Hysteria2"
        return 1
    fi
    load_env hy2
    local port="${PORT:-443}" ll conn authf src ext pol ndrop
    printf '  当前配置: 端口 %s/udp   证书方式 %s   SNI %s\n' "$port" "${CERT_MODE:-self}" "${DOMAIN:-}"
    if hy2_third_installed; then
        printf '  安装方式: 第三方脚本(seagullz4/hysteria2)   配置: %s\n' "$HY3_CFG"
    fi
    printf '\n'

    info "① 服务与监听"
    if hysvc_active; then ok "zihua-hy2 运行中"; else err "zihua-hy2 未运行, 先到『启动/停止/重启/状态』里启动"; fi
    ll="$(ss -H -lunp 2>/dev/null | grep -E "[:.]${port}[[:space:]]" | head -n1)"
    if [[ -n "$ll" ]]; then
        ok "UDP ${port} 正在监听"
    else
        err "UDP ${port} 没有监听(端口被别的程序占用或配置未生效)"
    fi

    info "② 地址与 NAT"
    printf '   网卡地址: %s\n' "$(ip -4 -o addr show 2>/dev/null | awk '{print $2" "$4}' | tr '\n' ';')"
    src="$(ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p' | head -n1)"
    printf '   出口源地址: %s\n' "${src:-未知}"
    ext="$(curl -4 -fsS --max-time 6 https://api.ipify.org 2>/dev/null || curl -4 -fsS --max-time 6 https://ifconfig.me/ip 2>/dev/null)"
    [[ -n "$ext" ]] && printf '   公网出口 IP: %s\n' "$ext"
    case "$src" in
        10.*|192.168.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*|100.6[4-9].*|100.[7-9][0-9].*)
            warn "本机出口是内网地址 → 这是 NAT/容器机器, 公网端口映射由服务商负责, 没映射就一定连不上。" ;;
    esac
    if [[ -n "$ext" && -n "$src" && "$ext" != "$src" ]]; then
        warn "公网 IP(${ext}) 与网卡地址(${src}) 不一致 → 本机在 NAT 后面, 需服务商做 UDP ${port} 端口映射。"
    fi

    info "③ 防火墙"
    if command -v ufw >/dev/null 2>&1; then
        if ufw status 2>/dev/null | grep -q "Status: active"; then
            if ufw status 2>/dev/null | grep -qE "${port}(/udp)?([[:space:]]|$)"; then
                ok "ufw 已放行 UDP ${port}"
            else
                err "ufw 已启用, 但没有 UDP ${port} 的放行规则 → 执行: ufw allow ${port}/udp"
            fi
        else
            info "ufw: 未启用(不拦截)"
        fi
    else
        info "ufw: 未安装"
    fi
    if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld 2>/dev/null; then
        if firewall-cmd --query-port="${port}/udp" >/dev/null 2>&1; then
            ok "firewalld 已放行 UDP ${port}"
        else
            err "firewalld 已启用, 但没有 UDP ${port} → 执行: firewall-cmd --permanent --add-port=${port}/udp && firewall-cmd --reload"
        fi
    fi
    if command -v iptables >/dev/null 2>&1; then
        pol="$(iptables -S INPUT 2>/dev/null | sed -n 's/^-P INPUT //p' | head -n1)"
        ndrop="$(iptables -S INPUT 2>/dev/null | grep -cE '^-A INPUT .*-j (DROP|REJECT)')"
        if [[ "$pol" == "ACCEPT" && "${ndrop:-0}" == "0" ]]; then
            info "iptables: INPUT 默认放行且无 DROP 规则(不会拦 UDP ${port})"
        elif iptables -S INPUT 2>/dev/null | grep -q -- "--dport ${port}"; then
            ok "iptables: 已有 UDP ${port} 相关规则"
        else
            warn "iptables: INPUT 策略=${pol:-未知}, 有 ${ndrop:-0} 条 DROP/REJECT 规则, 但没看到 UDP ${port} 的放行 → 执行: iptables -I INPUT -p udp --dport ${port} -j ACCEPT"
        fi
    fi

    info "④ 服务端是否收到过客户端数据"
    conn="$(hysvc_log_tail 500 2>/dev/null | grep -ci "client connected")"
    authf="$(hysvc_log_tail 500 2>/dev/null | grep -ci "authentication failed")"
    printf '   client connected: %s 次    authentication failed: %s 次\n' "${conn:-0}" "${authf:-0}"
    if [[ "${conn:-0}" -gt 0 ]]; then
        ok "已经成功认证过客户端 → 服务端没问题, 排查客户端(是否开『允许不安全』、密码/SNI 是否与链接一致)"
    elif [[ "${authf:-0}" -gt 0 ]]; then
        warn "连接到达但认证失败 → 客户端密码不对, 重新复制分享链接导入"
    else
        warn "一条连接记录都没有 → UDP 包没到本机。按顺序查: ①云控制台安全组放行 UDP ${port} ②上面的防火墙 ③换 UDP 443 再试 ④若机器在 NAT 后面, 找服务商做端口映射"
    fi

    info "⑤ 抓包验证(最直接)"
    printf '   另开一个 SSH 窗口执行, 然后手机点一次连接:\n'
    printf '   %stcpdump -nni any udp port %s -c 5%s\n' "$BOLD" "$port" "$NC"
    if ! command -v tcpdump >/dev/null 2>&1; then
        printf '   (未装 tcpdump: Debian/Ubuntu 用 apt install -y tcpdump, CentOS 用 yum install -y tcpdump, Alpine 用 apk add tcpdump)\n'
    fi
    printf '   有包飘过 = 网络通, 问题在 TLS/密码; 一个包都没有 = 服务商安全组或运营商拦了 UDP。\n'
    return 0
}

menu_manage() {
    hy_migrate_check
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
        echo "  ${BOLD}8)${NC} 更新 Hysteria2 内核(官方)"
        echo "  ${BOLD}9)${NC} Hysteria2 连通性自检(连不上时先跑这个)"
        echo "  ${BOLD}10)${NC} 彻底卸载(内核+全部配置)"
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
            8) update_hy_core; pause ;;
            9) hy_diagnose; pause ;;
            10)
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
    local rf="/usr/local/bin/reinstall-vm.sh" okdl=0 u base tmpf="$rf.new"
    # 每次都尝试拉取最新版(修复过 bug 的重装脚本才能生效), 失败则回退本地已有副本
    info "获取最新重装脚本 reinstall-vm.sh ..."
    base="https://raw.githubusercontent.com/xiaoluaibb/zihua/main/reinstall-vm.sh"
    while IFS= read -r u; do
        [[ -z "$u" ]] && continue
        if curl -fsSL --connect-timeout 8 --max-time 120 -o "$tmpf" "$u" 2>/dev/null && [[ -s "$tmpf" ]] && head -n1 "$tmpf" | grep -q "bin/"; then
            okdl=1; break
        fi
    done <<EOF
$base
https://gh-proxy.com/$base
https://ghfast.top/$base
https://cdn.jsdelivr.net/gh/xiaoluaibb/zihua@main/reinstall-vm.sh
EOF
    if [[ "$okdl" == "1" ]]; then
        mv -f "$tmpf" "$rf" && chmod 700 "$rf"
        ok "重装脚本已更新: $rf ($(grep -m1 'REINSTALL_VM_VERSION=' "$rf" 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || echo '版本未知'))"
    else
        rm -f "$tmpf"
        if [[ -f "$rf" ]]; then
            warn "在线更新失败, 使用本地已有副本: $rf"
        else
            err "下载失败且本地无副本, 请检查网络后重试"; return
        fi
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
    # 先替换当前执行文件, 成功后再同步另一份入口, 保证 /root/zihua.sh 与快捷命令 zihua 版本一致
    install -m 700 "$tmp" "$self" 2>/dev/null || { err "替换脚本失败(旧版已保留在 $backup)"; return 1; }
    [[ "$self" != "$dest" ]] && install -m 700 "$tmp" "$dest" 2>/dev/null || true
    [[ "$self" != "/root/zihua.sh" ]] && install -m 700 "$tmp" "/root/zihua.sh" 2>/dev/null || true
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
    local self dest="/usr/local/bin/zihua" sv dv
    self="$(readlink -f "$0" 2>/dev/null || echo "$0")"
    [[ -z "$self" || "$self" == "$dest" ]] && return 0
    if ! cmp -s "$self" "$dest" 2>/dev/null; then
        # 防止旧版 /root/zihua.sh 覆盖已更新的快捷命令(版本漂移回退)
        sv="$(grep -m1 'PROXYBOX_VERSION=' "$self" 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')"
        dv="$(grep -m1 'PROXYBOX_VERSION=' "$dest" 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')"
        if [[ -n "$sv" && -n "$dv" ]] && ver_gt "$dv" "$sv"; then
            return 0
        fi
        if install -m 700 "$self" "$dest" 2>/dev/null; then
            ok "快捷命令已就绪: 以后直接输入 zihua 即可再次打开本脚本"
        fi
    fi
}

main "$@"
