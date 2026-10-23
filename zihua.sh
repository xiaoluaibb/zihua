#!/usr/bin/env bash
#===============================================================================
#  ProxyBox — 多协议代理一键安装/管理 + 网络优化(BBR/内核调优) 交互式脚本
#-------------------------------------------------------------------------------
#  适用系统 : Debian 10+ / Ubuntu 18.04+ / Rocky / Alma / CentOS 7+(部分) /
#             Fedora / Alpine 3.15+ / Arch  (需 systemd)
#  运行方式 : 以 root 运行   sudo bash proxybox.sh
#  统一内核 : sing-box (SS2022 / Hysteria2 / TUIC / VLESS-Reality-Vision /
#             VLESS-Reality-gRPC 共用一个内核，一个服务多入站，方便增删改)
#  版本     : v1.0.0  (2026-10)
#===============================================================================

#--------------------------------- 全局变量 ------------------------------------
PROXYBOX_VERSION="1.0.0"
SB_BIN="/usr/local/bin/sing-box"
SB_DIR="/etc/sing-box"
SB_ENV_DIR="$SB_DIR/instance.d"          # 每个协议一份参数(env)
SB_CFG_DIR="$SB_DIR/configs"             # 每个协议一份配置(json)
SB_CERT_DIR="$SB_DIR/certs"              # 自签证书
SB_BAK_DIR="$SB_DIR/backup"              # 修改前的配置备份
SERVICE_NAME="sing-box-proxy"
UNIT_PATH="/etc/systemd/system/${SERVICE_NAME}.service"
SYSCTL_FILE="/etc/sysctl.d/99-proxybox-optimize.conf"
PUB_IP=""

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
            read -rp "$(printf '%s%s %s[建议留空自动生成]%s: ' "$CYAN" "$prompt" "$GRAY" "$NC")" val
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
    if ! command -v systemctl >/dev/null 2>&1 && [[ ! -d /run/systemd/system ]]; then
        die "未检测到 systemd，本脚本需要 systemd 管理服务。Alpine 请确认安装了 systemd 或改用其他系统。"
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
    ss -H -lntup 2>/dev/null | grep "[:.]${p}[[:space:]]" | awk '{print $5, $6, $7}' | sort -u | sed 's/users:((.*//' | head -n 3
}

# 本机所有已监听端口列表
port_in_use() {
    local p="$1"
    if command -v ss >/dev/null 2>&1; then
        ss -H -lntu 2>/dev/null | awk '{print $5}' | grep -qE "[:.]${p}\$"
    elif command -v netstat >/dev/null 2>&1; then
        netstat -lntu 2>/dev/null | grep -qE "[:.]${p}[[:space:]]"
    else
        # 尝试 TCP 连接 localhost (UDP 无法探测)
        if (exec 3<>"/dev/tcp/127.0.0.1/${p}") 2>/dev/null; then return 0; fi
        return 1
    fi
}

# 分配协议端口: ask_port "默认端口" "tcp|udp"
ask_port() {
    local def="$1" proto="$2" p
    title "监听端口设置"
    info "填写规则: 1~65535 的纯数字；建议使用高位端口(如 10000 以上)；443/80 等低位端口可能与现有 Web 服务冲突。"
    info "当前本机已监听端口: $(ss -H -lntu 2>/dev/null | awk '{print $5}' | sed 's/.*[:.]//' | sort -un | tr '\n' ' ' | cut -c1-120)..."
    while :; do
        ask_valid "输入端口" "$def" v_port
        p="$RESULT"
        if ! port_in_use "$p"; then
            PORT="$p"; ok "端口 $p 可用"; return 0
        fi
        warn "端口 $p 已被占用:"
        port_busy_info "$p" | sed 's/^/    /'
        info "UDP 与 TCP 是不同通道：例如 TCP 443 被网站占用时，UDP 443 一般仍可给代理用。"
        ask_choice "如何处理?" 1 1 "换一个端口(推荐)" 2 "仍使用该端口(仅 UDP 型协议且另一协议占 TCP 时可用)"
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
    local svc sname procs="" pid pn found=0
    declare -A seen=()
    info "检查是否已有正在运行/自启的代理服务..."
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
    # 进程级兜底检查
    for pn in $(pgrep -d' ' -f "${pat}" 2>/dev/null); do
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
                systemctl stop "$sname" >/dev/null 2>&1
                systemctl disable "$sname" >/dev/null 2>&1
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
    ok "sing-box 安装完成: $("$SB_BIN" version 2>/dev/null | head -n1)"
}

ensure_core() {
    if [[ -x "$SB_BIN" ]]; then
        info "检测到已安装内核: $($SB_BIN version 2>/dev/null | head -n1)"
        return 0
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
        if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
            systemctl restart "$SERVICE_NAME" && ok "服务已重启"
        fi
    fi
}

#--------------------------------- 目录/服务 -------------------------------------
ensure_dirs() {
    mkdir -p "$SB_DIR" "$SB_ENV_DIR" "$SB_CFG_DIR" "$SB_CERT_DIR" "$SB_BAK_DIR"
    chmod 700 "$SB_DIR"
}

ensure_service() {
    if [[ -f "$UNIT_PATH" ]]; then return 0; fi
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
    ensure_service
    if ! systemctl restart "$SERVICE_NAME"; then
        err "服务重启失败，最近日志如下:"
        journalctl -u "$SERVICE_NAME" -n 20 --no-pager 2>/dev/null | sed 's/^/    /'
        return 1
    fi
    sleep 1
    systemctl is-active --quiet "$SERVICE_NAME" && ok "服务运行中" || warn "服务状态异常，请查看日志"
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
    CERT_MODE=""; CERT_FILE=""; KEY_FILE=""; DOMAIN=""
    SNI_HOST=""; SNI_PORT=""; RPC=""
    REALITY_PK=""; REALITY_PUB=""; SHORT_ID=""
    # shellcheck disable=SC1090
    source "$SB_ENV_DIR/$k.env"
}

#--------------------------------- 自签证书 -------------------------------------
gen_self_signed_cert() {
    # $1 = CN(域名或 localhost)；产出 $SB_CERT_DIR/self.pem / self.key
    local cn="$(echo "$1" | grep -oE '^[a-zA-Z0-9.-]+' || true)"
    mkdir -p "$SB_CERT_DIR"
    if [[ ! -f "$SB_CERT_DIR/self.pem" || ! -f "$SB_CERT_DIR/self.key" ]]; then
        openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
            -keyout "$SB_CERT_DIR/self.key" -out "$SB_CERT_DIR/self.pem" \
            -subj "/CN=${cn:-localhost}" >/dev/null 2>&1 || return 1
    fi
    echo "$SB_CERT_DIR/self.pem"
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
    [[ -f "$cfg" ]] && cp -f "$cfg" "$bak"
    case "$k" in
        ss2022)   cfg_body_ss2022   > "$cfg" ;;
        hy2)      cfg_body_hy2      > "$cfg" ;;
        tuic)     cfg_body_tuic     > "$cfg" ;;
        vless-rv) cfg_body_vless_rv > "$cfg" ;;
        vless-rg) cfg_body_vless_rg > "$cfg" ;;
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
    local k rc=0
    for k in $(installed_keys); do
        gen_config "$k" || rc=1
    done
    (( rc == 1 )) && return 1
    svc_restart
}

cfg_body_ss2022() {
    cat <<EOF
{
  "inbounds": [
    {
      "type": "shadowsocks",
      "tag": "in-ss2022",
      "listen": "::",
      "listen_port": ${PORT},
      "method": "${METHOD}",
      "password": "${PASSWORD}"
    }
  ]
}
EOF
}

# hy2 / tuic 共用的 TLS 字段拼装(自签或指定证书)
tls_fields() {
    if [[ "$CERT_MODE" == "manual" ]]; then
        echo "\"certificate_path\": \"${CERT_FILE}\", \"key_path\": \"${KEY_FILE}\""
    else
        echo "\"certificate_path\": \"${SB_CERT_DIR}/self.pem\", \"key_path\": \"${SB_CERT_DIR}/self.key\""
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
      "listen": "::",
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
      "listen": "::",
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
      "listen": "::",
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
      "listen": "::",
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
    echo "vless://${UUID}@${IP}:${PORT}?type=tcp&security=reality&flow=xtls-rprx-vision&sni=${SNI_HOST}&fp=chrome&pbk=${REALITY_PUB}&sid=${SHORT_ID}#${NODE_NAME}"
}

link_vless_rg() {
    echo "vless://${UUID}@${IP}:${PORT}?type=grpc&security=reality&serviceName=${RPC}&sni=${SNI_HOST}&fp=chrome&pbk=${REALITY_PUB}&sid=${SHORT_ID}#${NODE_NAME}"
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
            printf '  证书: %s\n' "$([[ "$CERT_MODE" == "manual" ]] && echo "自有证书(已校验)" || echo "自签(客户端需开启『允许不安全』)")" ;;
        tuic)
            printf '  UUID: %s\n' "$UUID"
            printf '  密码: %s\n' "$PASSWORD"
            printf '  证书: %s\n' "$([[ "$CERT_MODE" == "manual" ]] && echo "自有证书(已校验)" || echo "自签(客户端需开启『允许不安全』)")" ;;
        vless-rv|vless-rg)
            printf '  UUID: %s\n' "$UUID"
            printf '  伪装站点(SNI): %s:%s\n' "$SNI_HOST" "${SNI_PORT:-443}"
            [[ "$k" == "vless-rg" ]] && printf '  grpc 服务名: %s\n' "$RPC"
            printf '  公钥(pbk): %s\n' "$REALITY_PUB"
            printf '  short_id(sid): %s\n' "$SHORT_ID" ;;
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

# reality 相关公共询问: 设置 SNIHOST/SNIPORT/REALITY_PK/REALITY_PUB/SHORT_ID
ask_reality_params() {
    title "Reality 伪装目标设置"
    info "Reality 会伪装成访问真实大型网站的 HTTPS 流量，无需域名和证书。"
    info "目标站点要位于墙外、支持 TLS1.3/H2，实际访问不跳转(301/302)到别处。小白直接回车即可。"
    ask_choice "选择伪装目标站点" 1 \
        1 "www.apple.com (推荐, 大厂 CDN, 稳定)" \
        2 "www.microsoft.com" \
        3 "www.bing.com" \
        4 "www.spotify.com" \
        5 "自定义输入域名"
    case "$RESULT" in
        1) SNI_HOST="www.apple.com" ;;
        2) SNI_HOST="www.microsoft.com" ;;
        3) SNI_HOST="www.bing.com" ;;
        4) SNI_HOST="www.spotify.com" ;;
        5) ask_valid "输入自定义目标域名(如 www.nvidia.com)" "www.nvidia.com" v_domain; SNI_HOST="$RESULT" ;;
    esac
    while :; do
        ask_valid "目标站点端口" "443" v_port
        SNI_PORT="$RESULT"
        (( 10#$SNI_PORT == 80 )) && { err "目标端口必须是 TLS(HTTPS) 端口, 80 端口是 HTTP 不支持"; continue; }
        break
    done
    info "生成 Reality 密钥对..."
    local kp
    kp="$("$SB_BIN" generate reality-keypair 2>/dev/null)"
    REALITY_PK="$(echo "$kp" | awk '/PrivateKey/{print $2}')"
    REALITY_PUB="$(echo "$kp" | awk '/PublicKey/{print $2}')"
    [[ -z "$REALITY_PK" ]] && die "生成 Reality 密钥失败，请重试。"
    SHORT_ID="$(gen_hex 4)"
    ok "Reality 参数就绪 (短ID: $SHORT_ID)"
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
CREATED=$(date '+%F %T')
ENV
    chmod 600 "$SB_ENV_DIR/ss2022.env"
    apply_one "ss2022" || return 1
    print_share "ss2022"
    ok "SS2022 安装完成"
}

#--------------------------------- Hysteria2 --------------------------------------
add_hy2() {
    pre_install "安装 Hysteria2" "Hysteria2 是基于 QUIC(UDP) 的高性能代理，弱网/高丢包环境速度优势明显。需要 TLS 证书；没有域名也能用『自签证书+客户端允许不安全』跑起来。" || return 1
    ask_port 8443 udp
    title "Hysteria2 密码设置"
    local defpass
    defpass="$(gen_rand 16)"
    info "填写规则: 仅字母/数字/下划线/点/短横线，8~32 位。回车直接用随机密码。"
    ask_valid "输入连接密码" "$defpass" v_uri_safe
    PASSWORD="$RESULT"
    title "自签证书域名(可选)"
    info "没有域名就回车。此域名仅作为伪装, 不需要真实存在。"
    ask_valid "输入伪装域名" "bing.com" v_domain
    DOMAIN="$RESULT"
    ask_choice "TLS 证书来源" 1 \
        1 "自动生成自签证书(最简单, 客户端需允许不安全)" \
        2 "使用已有证书文件(输入证书和私钥路径)"
    CERT_MODE="auto"
    CERT_FILE=""; KEY_FILE=""
    if [[ "$RESULT" == "2" ]]; then
        ask_valid "输入证书(.pem/.crt)路径" "/etc/ssl/certs/ca.pem" v_path
        CERT_FILE="$RESULT"
        ask_valid "输入私钥(.key)路径" "/etc/ssl/private/ca.key" v_path
        KEY_FILE="$RESULT"
        CERT_MODE="manual"
    else
        gen_self_signed_cert "$DOMAIN" >/dev/null || warn "自签证书生成失败，将回退到自动证书"
    fi
    title "网站伪装(可选)"
    info "没有认证的 HTTP 请求会被重定向到下面这个网站，让扫描行为更像正常站点。直接回车即可。"
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
MASQ='$MASQ'
NAME='$SAVE_NAME'
CREATED=$(date '+%F %T')
ENV
    chmod 600 "$SB_ENV_DIR/hy2.env"
    apply_one "hy2" || return 1
    print_share "hy2"
    ok "Hysteria2 安装完成"
}

#--------------------------------- TUIC -------------------------------------------
add_tuic() {
    pre_install "安装 TUIC v5" "TUIC 是基于 QUIC(UDP) 的代理，支持 0-RTT，延迟低。与 Hysteria2 类似，需要 TLS。" || return 1
    ask_port 9443 udp
    title "TUIC 身份与密码"
    local dpass duuid
    duuid="$(gen_uuid)"
    dpass="$(gen_rand 16)"
    info "UUID: 客户端身份标识。回车自动生成。"
    ask_valid "输入 UUID" "$duuid" v_uuid
    UUID="$RESULT"
    info "密码: 用于 TUIC 认证。仅字母/数字/下划线等。回车使用随机。"
    ask_valid "输入密码" "$dpass" v_uri_safe
    PASSWORD="$RESULT"
    ask_valid "输入伪装域名(用于自签证书/客户端 SNI)" "bing.com" v_domain
    DOMAIN="$RESULT"
    ask_choice "TLS 证书来源" 1 \
        1 "自动生成自签证书(最简单, 客户端需允许不安全)" \
        2 "使用已有证书文件"
    CERT_MODE="auto"
    CERT_FILE=""; KEY_FILE=""
    if [[ "$RESULT" == "2" ]]; then
        ask_valid "输入证书路径" "/etc/ssl/certs/ca.pem" v_path
        CERT_FILE="$RESULT"
        ask_valid "输入私钥路径" "/etc/ssl/private/ca.key" v_path
        KEY_FILE="$RESULT"
        CERT_MODE="manual"
    else
        gen_self_signed_cert "$DOMAIN" >/dev/null || warn "自签证书生成失败，将回退到自动证书"
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
NAME='$SAVE_NAME'
CREATED=$(date '+%F %T')
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
    ask_node_name "vless- Vision-${SNI_HOST}"
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
CREATED=$(date '+%F %T')
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
CREATED=$(date '+%F %T')
ENV
    chmod 600 "$SB_ENV_DIR/vless-rg.env"
    apply_one "vless-rg" || return 1
    print_share "vless-rg"
    ok "VLESS-Reality-gRPC 安装完成"
}

#--------------------------------- 安装后应用 -------------------------------------
# 应用某个协议: 生成配置并重启服务 (参数已在 env 文件中)
apply_one() {
    local k="$1"
    ensure_dirs
    if [[ ! -f "$SB_ENV_DIR/$k.env" ]]; then
        err "未找到 $k 参数文件: $SB_ENV_DIR/$k.env"
        return 1
    fi
    ensure_service
    if ! gen_config "$k"; then
        err "$k 配置校验失败，已回滚备份"
        return 1
    fi
    if ! svc_restart; then
        err "服务重启失败，请尝试『代理管理』中的查看日志"
        return 1
    fi
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
    st="禁用"; systemctl is-active --quiet "$SERVICE_NAME" && st="$(systemctl is-active $SERVICE_NAME)"
    for k in "${keys[@]}"; do
        load_env "$k"
        case "$k" in
            ss2022)   proto_name="Shadowsocks-2022 (TCP)" ;;
            hy2)      proto_name="Hysteria2 (UDP/QUIC)" ;;
            tuic)     proto_name="TUIC v5 (UDP/QUIC)" ;;
            vless-rv) proto_name="VLESS-Reality-Vision (TCP)" ;;
            vless-rg) proto_name="VLESS-Reality-gRPC (TCP)" ;;
            *)        proto_name="未知" ;;
        esac
        printf '  %-10s %-32s %-8s %s\n' "$k" "$proto_name" "${PORT}" "$st"
    done
    hr
    info "sing-box 状态: $(systemctl is-active $SERVICE_NAME 2>/dev/null || echo 未安装)   版本: $("$SB_BIN" version 2>/dev/null | head -n1 || echo 未知)"
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
    local base="PORT UUID PASSWORD METHOD NAME DOMAIN CERT_MODE CERT_FILE KEY_FILE MASQ SNI_HOST SNI_PORT RPC REALITY_PUB REALITY_PK SHORT_ID"
    local var val out=""
    {
        for var in $base; do
            val="${!var:-}"
            val="${val//\'/}"
            [[ -n "$val" ]] && printf "%s='%s'\n" "$var" "$val"
        done
        echo "CREATED=$(date '+%F %T')"
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
    esac
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
            ask "输入新密码(Base64)" "$(gen_b64 "$PKG_LEN")"
            PASSWORD="$RESULT" ;;
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
        3 "更换证书方式(自签/自有)" \
        4 "修改伪装域名(当前: ${DOMAIN})" \
        5 "修改节点名称(当前: ${NAME})"
    [[ -z "$RESULT" ]] && return 0
    case "$RESULT" in
        1) ask_port "$PORT" udp ;;
        2) ask_valid "输入新密码" "$(gen_rand 16)" v_uri_safe; PASSWORD="$RESULT";;
        3)
            ask_choice "TLS 证书来源" 1 \
                1 "自动生成自签证书(客户端需允许不安全)" \
                2 "使用已有证书文件"
            if [[ "$RESULT" == "2" ]]; then
                ask_valid "输入证书路径" "${CERT_FILE:-/etc/ssl/certs/ca.pem}" v_path; CERT_FILE="$RESULT"
                ask_valid "输入私钥路径" "${KEY_FILE:-/etc/ssl/private/ca.key}" v_path; KEY_FILE="$RESULT"
                CERT_MODE="manual"
            else
                gen_self_signed_cert "$DOMAIN" >/dev/null
                CERT_MODE="auto"; CERT_FILE=""; KEY_FILE=""
                warn "已重新生成自签证书, 客户端需允许不安全"
            fi ;;
        4) ask_valid "输入伪装域名" "$DOMAIN" v_domain; DOMAIN="$RESULT";;
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
        4 "更换证书方式(自签/自有)" \
        5 "修改节点名称(当前: ${NAME})"
    [[ -z "$RESULT" ]] && return 0
    case "$RESULT" in
        1) ask_port "$PORT" udp ;;
        2) ask_valid "输入新 UUID" "$UUID" v_uuid; UUID="$RESULT";;
        3) ask_valid "输入新密码" "$(gen_rand 16)" v_uri_safe; PASSWORD="$RESULT";;
        4)
            ask_choice "TLS 证书来源" 1 \
                1 "自动生成自签证书(客户端需允许不安全)" \
                2 "使用已有证书文件"
            if [[ "$RESULT" == "2" ]]; then
                ask_valid "输入证书路径" "${CERT_FILE:-/etc/ssl/certs/ca.pem}" v_path; CERT_FILE="$RESULT"
                ask_valid "输入私钥路径" "${KEY_FILE:-/etc/ssl/private/ca.key}" v_path; KEY_FILE="$RESULT"
                CERT_MODE="manual"
            else
                gen_self_signed_cert "$DOMAIN" >/dev/null
                CERT_MODE="auto"; CERT_FILE=""; KEY_FILE=""
                warn "已重新生成自签证书, 客户端需允许不安全"
            fi ;;
        5) ask "输入新名称" "${NAME:-$k}"; NAME="$RESULT";;
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
            3 "重新选择伪装站点并重置 Reality 密钥" \
            4 "修改节点名称(当前: ${NAME})"
    else
        ask_choice "VLESS-Reality-gRPC 修改项" "" \
            1 "修改监听端口(当前: $PORT)" \
            2 "修改 UUID" \
            3 "重新选择伪装站点并重置 Reality 密钥" \
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
    ask "确认删除? 输入 yes 确认" "no"
    if [[ "$RESULT" != "yes" ]]; then
        info "已取消删除"; pause; return
    fi
    rm -f "$SB_CFG_DIR/$k.json" "$SB_ENV_DIR/$k.env" "$SB_BAK_DIR/$k.json.bak"
    ok "已删除 $k"
    # 若已无任何协议, 询问是否连服务/内核一起卸载
    if [[ -z "$(installed_keys)" ]]; then
        ask_choice "已无任何代理配置, 是否继续清理?" 1 \
            1 "同时停止并禁用服务(保留内核程序)" \
            2 "彻底卸载(服务+sing-box程序+所有配置)" \
            3 "什么都不做"
        case "$RESULT" in
            1) systemctl disable --now "$SERVICE_NAME" >/dev/null 2>&1; ok "服务已停止并禁用自启" ;;
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
        1) systemctl start "$SERVICE_NAME" && ok "已启动" ;;
        2) systemctl stop "$SERVICE_NAME" && ok "已停止" ;;
        3) svc_restart ;;
        4) systemctl status "$SERVICE_NAME" --no-pager -l 2>/dev/null | head -n 25 ;;
    esac
    pause
}

menu_logs() {
    title "查看日志(最近 60 行)"
    journalctl -u "$SERVICE_NAME" -n 60 --no-pager -e 2>/dev/null | sed 's/^/  /'
    info "持续跟踪: journalctl -u $SERVICE_NAME -f"
    pause
}

uninstall_core() {
    if [[ -f "$UNIT_PATH" ]]; then
        systemctl disable --now "$SERVICE_NAME" >/dev/null 2>&1
        rm -f "$UNIT_PATH"
        systemctl daemon-reload
    fi
    rm -f "$SB_BIN"
    ok "sing-box 内核与服务已卸载"
}

uninstall_all() {
    warn "该操作将删除: systemd 服务、sing-box 程序、/etc/sing-box 下全部配置与证书, 且不可恢复！"
    ask "请输入 uninstall 确认彻底卸载" "no"
    [[ "$RESULT" != "uninstall" ]] && { info "已取消"; return 1; }
    uninstall_core
    rm -rf "$SB_DIR"
    ok "已彻底清除 ProxyBox 相关数据"
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
    ok "迁移默认完成"
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
        printf '  %s3)%s '   "$BOLD" "$NC"; mark_installed "vless-rv"; echo "VLESS-Reality-Vision TCP, 最强抗封锁(推荐443)"
        printf '  %s4)%s '   "$BOLD" "$NC"; mark_installed "vless-rg"; echo "VLESS-Reality-gRPC   TCP, 伪装+grpc传输"
        printf '  %s5)%s '   "$BOLD" "$NC"; mark_installed "tuic";     echo "TUIC v5              UDP/QUIC, 0-RTT 低延迟"
        echo "  ${BOLD}0)${NC} 返回上级"
        info "提示: 相同端口只能被一个服务占用；TCP 与 UDP 可共存(如 Vision 用 TCP 443, Hysteria2 用 UDP 443)。"
        ask "请选择" "0"
        local key=""
        case "$RESULT" in
            1) key="ss2022" ;;
            2) key="hy2" ;;
            3) key="vless-rv" ;;
            4) key="vless-rg" ;;
            5) key="tuic" ;;
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
            tuic)     add_tuic ;;
        esac
        if [[ "$key" == "ss2022" || "$key" == "vless-rv" || "$key" == "vless-rg" ]]; then
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
        echo "  ${BOLD}0)${NC} 退出"
        hr
        ask "请选择" "1"
        case "$RESULT" in
            1) menu_install ;;
            2) menu_manage ;;
            3) menu_network ;;
            4) show_system_info; ensure_deps; pause ;;
            0) ok "再见!"; exit 0 ;;
            *) err "请输入正确编号" ;;
        esac
    done
}

#--------------------------------- 主入口 ------------------------------------------
main() {
    [[ $EUID -eq 0 ]] || die "请以 root 运行: sudo bash $0"
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
    check_systemd || true
    ensure_deps || true
    get_public_ip >/dev/null 2>&1 || true
    main_menu
}

# 检查 systemd 是否可用
check_systemd() {
    if ! command -v systemctl >/dev/null 2>&1; then
        warn "未检测到 systemctl / systemd，服务管理功能不可用。"
        return 1
    fi
    return 0
}

main "$@"
