#!/bin/sh
# ================================================================
#  Xray + SS2022 通用一键安装脚本
#
#  支持系统:
#    - OpenWrt  21.02 / 22.03 / 23.05 / 24.10
#    - Debian   10 / 11 / 12
#    - Ubuntu   20.04 / 22.04 / 24.04
#    - CentOS   7 / 8 / Stream
#    - RHEL     8 / 9 / AlmaLinux / Rocky Linux
#    - Fedora   36+
#    - Alpine   3.x
#    - Armbian  (基于 Debian/Ubuntu)
#    - Raspberry Pi OS
#
#  用途: 境外落地节点 / 透明代理网关 / SOCKS5 代理
# ================================================================

# -------- 颜色 --------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# -------- 全局变量 --------
XRAY_BIN="/usr/bin/xray"
XRAY_CONF="/etc/xray/config.json"
XRAY_GEODATA_DIR="/usr/share/xray"
TPROXY_PORT=7891
SOCKS_PORT=7890
HTTP_PORT=7892
DNS_PORT=5353
OS_TYPE=""        # openwrt / debian / redhat / alpine
FW_TYPE=""        # nftables / iptables / none
INIT_TYPE=""      # procd / systemd / openrc / sysv
FW_VERSION=""     # openwrt firewall: 3 or 4

# ================================================================
# 工具函数
# ================================================================
info()  { echo -e "${GREEN}[INFO]${NC}  $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }
step()  { echo -e "\n${CYAN}${BOLD}▶ $1${NC}"; }
title() {
    echo -e "\n${CYAN}╔══════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║  ${BOLD}$1${NC}${CYAN}║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════╝${NC}"
}
ask()   { printf "${YELLOW}[?]${NC} $1 "; }
hr()    { echo -e "${CYAN}──────────────────────────────────────────${NC}"; }

check_root() {
    [ "$(id -u)" != "0" ] && error "请使用 root 权限运行此脚本 (sudo su 或 sudo sh install.sh)"
}

# ================================================================
# 系统检测
# ================================================================
detect_os() {
    step "检测操作系统"

    # OpenWrt
    if [ -f /etc/openwrt_release ]; then
        OS_TYPE="openwrt"
        . /etc/openwrt_release
        OS_NAME="OpenWrt"
        OS_VER="$DISTRIB_RELEASE"
        info "系统: $DISTRIB_DESCRIPTION"

        # OpenWrt 防火墙版本
        if command -v fw4 >/dev/null 2>&1; then
            FW_VERSION="4"
            FW_TYPE="nftables"
            info "防火墙: firewall4 (nftables)"
        else
            FW_VERSION="3"
            FW_TYPE="iptables"
            info "防火墙: firewall3 (iptables)"
        fi
        INIT_TYPE="procd"
        return
    fi

    # 读取标准 os-release
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS_NAME="$NAME"
        OS_VER="$VERSION_ID"
    elif [ -f /etc/lsb-release ]; then
        . /etc/lsb-release
        OS_NAME="$DISTRIB_ID"
        OS_VER="$DISTRIB_RELEASE"
    fi

    case "$ID" in
        debian|ubuntu|raspbian|armbian|linuxmint|kali)
            OS_TYPE="debian"
            ;;
        centos|rhel|almalinux|rocky|fedora|ol)
            OS_TYPE="redhat"
            ;;
        alpine)
            OS_TYPE="alpine"
            ;;
        *)
            # 基于 ID_LIKE 再判断
            case "$ID_LIKE" in
                *debian*|*ubuntu*) OS_TYPE="debian" ;;
                *rhel*|*fedora*)   OS_TYPE="redhat" ;;
                *)
                    warn "未能识别发行版 ($ID)，尝试按 Debian 方式处理"
                    OS_TYPE="debian"
                    ;;
            esac
            ;;
    esac

    info "系统: $OS_NAME $OS_VER ($OS_TYPE)"

    # 检测 init 系统
    if command -v systemctl >/dev/null 2>&1 && systemctl --version >/dev/null 2>&1; then
        INIT_TYPE="systemd"
        info "Init: systemd"
    elif [ -f /sbin/openrc ] || command -v rc-update >/dev/null 2>&1; then
        INIT_TYPE="openrc"
        info "Init: OpenRC"
    else
        INIT_TYPE="sysv"
        info "Init: SysV"
    fi

    # 检测防火墙
    if command -v nft >/dev/null 2>&1; then
        FW_TYPE="nftables"
        info "防火墙: nftables"
    elif command -v iptables >/dev/null 2>&1; then
        FW_TYPE="iptables"
        info "防火墙: iptables"
    else
        FW_TYPE="none"
        warn "未检测到防火墙工具"
    fi
}

# ================================================================
# 包管理器封装
# ================================================================
pkg_update() {
    case "$OS_TYPE" in
        openwrt) opkg update 2>/dev/null || true ;;
        debian)  apt-get update -qq ;;
        redhat)
            if command -v dnf >/dev/null 2>&1; then dnf makecache -q
            else yum makecache -q; fi
            ;;
        alpine)  apk update -q ;;
    esac
}

pkg_install() {
    local pkgs="$*"
    info "安装依赖: $pkgs"
    case "$OS_TYPE" in
        openwrt) opkg install $pkgs 2>/dev/null || warn "部分包安装失败: $pkgs" ;;
        debian)  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq $pkgs ;;
        redhat)
            if command -v dnf >/dev/null 2>&1; then dnf install -y -q $pkgs
            else yum install -y -q $pkgs; fi
            ;;
        alpine)  apk add -q $pkgs ;;
    esac
}

# ================================================================
# 安装基础依赖
# ================================================================
install_deps() {
    step "安装基础依赖"

    # 列出各系统将要安装的包
    local pkg_list=""
    local pkg_mgr=""
    case "$OS_TYPE" in
        openwrt) pkg_list="wget-ssl ca-bundle unzip curl";           pkg_mgr="opkg" ;;
        debian)  pkg_list="wget curl unzip ca-certificates iproute2"; pkg_mgr="apt" ;;
        redhat)  pkg_list="wget curl unzip ca-certificates iproute";  pkg_mgr="dnf/yum" ;;
        alpine)  pkg_list="wget curl unzip ca-certificates iproute2"; pkg_mgr="apk" ;;
    esac

    echo ""
    echo "  将通过 ${pkg_mgr} 安装以下依赖包:"
    echo ""
    for pkg in $pkg_list; do
        echo "    • $pkg"
    done
    echo ""
    ask "确认安装以上依赖? (y/N):"
    read DEP_CONFIRM
    [ "${DEP_CONFIRM:-n}" != "y" ] && [ "${DEP_CONFIRM:-n}" != "Y" ] && \
        error "已取消。如已手动安装依赖，请重新运行脚本。"

    pkg_update
    pkg_install $pkg_list
}

# ================================================================
# 架构映射 -> Xray GitHub Release 文件名
# ================================================================
get_xray_arch() {
    local arch
    arch=$(uname -m)
    case "$arch" in
        x86_64|amd64)        echo "64" ;;
        i686|i386)           echo "32" ;;
        aarch64|arm64)       echo "arm64-v8a" ;;
        armv7l|armv7)        echo "arm32-v7a" ;;
        armv6l|armv6)        echo "arm32-v6" ;;
        armv5l|armv5)        echo "arm32-v5" ;;
        mips)
            # 检测软硬浮点
            if grep -q "FPU" /proc/cpuinfo 2>/dev/null; then echo "mips32"
            else echo "mips32"; fi
            ;;
        mipsel|mipsle)       echo "mips32le" ;;
        mips64)              echo "mips64" ;;
        mips64el|mips64le)   echo "mips64le" ;;
        riscv64)             echo "riscv64" ;;
        s390x)               echo "s390x" ;;
        ppc64le)             echo "ppc64le" ;;
        *)
            warn "未知架构: $arch，尝试 x86_64"
            echo "64"
            ;;
    esac
}

# ================================================================
# 安装 Xray
# ================================================================
install_xray() {
    step "安装 Xray-core"

    # OpenWrt 优先 opkg
    if [ "$OS_TYPE" = "openwrt" ]; then
        if opkg list 2>/dev/null | grep -q "^xray-core "; then
            info "从 opkg 官方源安装 xray-core..."
            opkg install xray-core && {
                install_geodata_openwrt
                return
            }
        fi
        info "opkg 源中无 xray-core，改用手动下载..."
    fi

    # Alpine 尝试 apk
    if [ "$OS_TYPE" = "alpine" ]; then
        if apk search xray 2>/dev/null | grep -q "^xray"; then
            apk add xray 2>/dev/null && {
                info "Alpine apk 安装 xray 成功"
                install_geodata_generic
                return
            }
        fi
    fi

    # 通用: 从 GitHub Releases 下载
    install_xray_github
}

install_xray_github() {
    local xray_arch
    xray_arch=$(get_xray_arch)
    info "CPU 架构: $(uname -m) -> xray_linux_${xray_arch}"

    # 获取最新版本
    local latest_ver=""
    info "查询 Xray 最新版本..."
    latest_ver=$(wget -qO- --timeout=10 \
        "https://api.github.com/repos/XTLS/Xray-core/releases/latest" 2>/dev/null \
        | grep '"tag_name"' | head -1 | sed 's/.*"tag_name": *"\([^"]*\)".*/\1/')

    # 备用版本（API 失败时）
    [ -z "$latest_ver" ] && latest_ver="v25.3.6"
    info "Xray 版本: $latest_ver"

    local filename="Xray-linux-${xray_arch}.zip"
    local dl_url="https://github.com/XTLS/Xray-core/releases/download/${latest_ver}/${filename}"
    local tmp_zip="/tmp/xray_install.zip"
    local tmp_dir="/tmp/xray_extract"

    info "下载: $dl_url"
    wget -O "$tmp_zip" "$dl_url" --timeout=60 --tries=3 \
        || error "下载失败，请检查网络或手动下载后放置到 $XRAY_BIN"

    mkdir -p "$tmp_dir"
    unzip -o "$tmp_zip" xray -d "$tmp_dir" \
        || error "解压失败，请确保已安装 unzip"

    mkdir -p "$(dirname $XRAY_BIN)"
    mv "$tmp_dir/xray" "$XRAY_BIN"
    chmod +x "$XRAY_BIN"
    rm -rf "$tmp_zip" "$tmp_dir"

    info "Xray 安装完成: $($XRAY_BIN version 2>/dev/null | head -1)"
    install_geodata_generic
}

install_geodata_openwrt() {
    info "安装 GeoData (opkg)..."
    opkg install v2ray-geoip v2ray-geosite 2>/dev/null \
    || opkg install xray-geodata 2>/dev/null \
    || warn "GeoData 安装失败，分流中的 geosite/geoip 规则将不可用"
}

install_geodata_generic() {
    mkdir -p "$XRAY_GEODATA_DIR"
    # 检查是否已存在
    if [ -f "$XRAY_GEODATA_DIR/geoip.dat" ] && [ -f "$XRAY_GEODATA_DIR/geosite.dat" ]; then
        info "GeoData 已存在，跳过下载"
        return
    fi
    info "下载 GeoData..."
    local base="https://github.com/v2fly/v2ray-core/releases/latest/download"
    wget -qO "$XRAY_GEODATA_DIR/geoip.dat"   "$base/geoip.dat"   --timeout=30 \
        || warn "geoip.dat 下载失败"
    wget -qO "$XRAY_GEODATA_DIR/geosite.dat" "$base/geosite.dat" --timeout=30 \
        || warn "geosite.dat 下载失败"
}

# ================================================================
# 安装透明代理防火墙依赖
# ================================================================
install_tproxy_deps() {
    # 只有需要 TProxy 的模式才安装内核模块
    case "$PROXY_MODE" in
        tproxy|tproxy_socks) ;;
        *) return ;;
    esac
    step "安装透明代理内核模块"

    case "$OS_TYPE" in
        openwrt)
            if [ "$FW_VERSION" = "4" ]; then
                pkg_install kmod-nft-tproxy
            else
                pkg_install iptables-mod-tproxy kmod-ipt-tproxy
            fi
            ;;
        debian)
            # 现代内核已内置 tproxy，确保 iproute2 存在
            pkg_install iproute2
            if [ "$FW_TYPE" = "iptables" ]; then
                pkg_install iptables
            fi
            ;;
        redhat)
            pkg_install iproute
            if [ "$FW_TYPE" = "iptables" ]; then
                pkg_install iptables iptables-services
            fi
            ;;
        alpine)
            pkg_install iproute2
            ;;
    esac
}

# ================================================================
# 用户交互配置
# ================================================================
collect_config() {
    title "配置 SS2022 服务器参数"

    ask "服务器 IP 或域名:"
    read SS_SERVER
    [ -z "$SS_SERVER" ] && error "服务器地址不能为空"

    ask "服务器端口 [默认 8388]:"
    read SS_PORT
    SS_PORT="${SS_PORT:-8388}"

    echo ""
    echo "  加密方式:"
    echo "    1) 2022-blake3-aes-128-gcm       (推荐, 适合有 AES 硬件加速的设备)"
    echo "    2) 2022-blake3-aes-256-gcm       (更高强度)"
    echo "    3) 2022-blake3-chacha20-poly1305 (适合无 AES 加速: MIPS/旧 ARM)"
    ask "选择加密方式 [默认 1]:"
    read METHOD_CHOICE
    case "${METHOD_CHOICE:-1}" in
        2) SS_METHOD="2022-blake3-aes-256-gcm" ;;
        3) SS_METHOD="2022-blake3-chacha20-poly1305" ;;
        *) SS_METHOD="2022-blake3-aes-128-gcm" ;;
    esac
    info "加密方式: $SS_METHOD"

    ask "服务器密码 [回车自动生成]:"
    read SS_PASSWORD
    if [ -z "$SS_PASSWORD" ]; then
        SS_PASSWORD=$(gen_ss2022_password "$SS_METHOD")
        warn "自动生成密码: $SS_PASSWORD"
        warn ">> 请确保此密码与服务端完全一致！"
    fi

    echo ""
    echo "  代理模式:"
    echo "    1) 透明代理 TProxy     - 自动拦截局域网全部流量，适合路由器/网关"
    echo "    2) SOCKS5 + HTTP       - 提供代理端口，设备手动配置，适合单机"
    echo "    3) TProxy + SOCKS5     - 透明代理 + 额外 SOCKS5 端口，两者并存"
    echo "    4) Dokodemo 端口转发   - 将本地端口流量转发到指定目标，适合端口映射"
    echo "    5) 仅安装不配置代理    - 只装 Xray，自行编辑配置文件"
    ask "选择代理模式 [默认 1]:"
    read PROXY_MODE_CHOICE
    case "${PROXY_MODE_CHOICE:-1}" in
        2) PROXY_MODE="socks" ;;
        3) PROXY_MODE="tproxy_socks" ;;
        4) PROXY_MODE="dokodemo" ;;
        5) PROXY_MODE="none" ;;
        *) PROXY_MODE="tproxy" ;;
    esac

    # 端口转发模式需要额外参数
    if [ "$PROXY_MODE" = "dokodemo" ]; then
        echo ""
        ask "转发目标地址 (例: 8.8.8.8):"
        read DOKO_TARGET_ADDR
        [ -z "$DOKO_TARGET_ADDR" ] && DOKO_TARGET_ADDR="8.8.8.8"
        ask "转发目标端口 (例: 53):"
        read DOKO_TARGET_PORT
        [ -z "$DOKO_TARGET_PORT" ] && DOKO_TARGET_PORT="53"
        ask "本地监听端口 (例: 5300):"
        read DOKO_LOCAL_PORT
        [ -z "$DOKO_LOCAL_PORT" ] && DOKO_LOCAL_PORT="5300"
        ask "转发协议 tcp/udp/tcp,udp [默认 tcp,udp]:"
        read DOKO_NETWORK
        DOKO_NETWORK="${DOKO_NETWORK:-tcp,udp}"
        info "端口转发: 本机:$DOKO_LOCAL_PORT -> $DOKO_TARGET_ADDR:$DOKO_TARGET_PORT ($DOKO_NETWORK)"
    fi

    # SOCKS5 认证选项（模式2/3时询问）
    if [ "$PROXY_MODE" = "socks" ] || [ "$PROXY_MODE" = "tproxy_socks" ]; then
        echo ""
        ask "SOCKS5 是否启用用户名密码认证? (y/N):"
        read SOCKS_AUTH_CHOICE
        if [ "${SOCKS_AUTH_CHOICE:-n}" = "y" ] || [ "${SOCKS_AUTH_CHOICE:-n}" = "Y" ]; then
            SOCKS_AUTH="password"
            ask "SOCKS5 用户名:"
            read SOCKS_USER
            [ -z "$SOCKS_USER" ] && SOCKS_USER="user"
            ask "SOCKS5 密码:"
            read SOCKS_PASS
            [ -z "$SOCKS_PASS" ] && SOCKS_PASS="password"
            info "SOCKS5 认证: $SOCKS_USER / $SOCKS_PASS"
        else
            SOCKS_AUTH="noauth"
            SOCKS_USER=""
            SOCKS_PASS=""
        fi
    else
        SOCKS_AUTH="noauth"
        SOCKS_USER=""
        SOCKS_PASS=""
    fi

    echo ""
    echo "  分流模式:"
    echo "    1) 全局模式  - 所有流量走代理 (境外落地推荐)"
    echo "    2) GFW 模式  - 中国大陆直连，其余走代理 (墙内翻墙用)"
    echo "    3) 直连模式  - 暂不代理，仅完成安装"
    ask "选择分流模式 [默认 1]:"
    read ROUTE_MODE_CHOICE
    case "${ROUTE_MODE_CHOICE:-1}" in
        2) ROUTE_MODE="gfw" ;;
        3) ROUTE_MODE="direct" ;;
        *) ROUTE_MODE="global" ;;
    esac

    echo ""
    hr
    echo "  服务器:    $SS_SERVER:$SS_PORT"
    echo "  加密:      $SS_METHOD"
    echo "  密码:      $SS_PASSWORD"
    echo "  代理模式:  $PROXY_MODE"
    [ "$PROXY_MODE" = "dokodemo" ] && \
    echo "  端口转发:  本机:$DOKO_LOCAL_PORT -> $DOKO_TARGET_ADDR:$DOKO_TARGET_PORT"
    [ "$SOCKS_AUTH" = "password" ] && \
    echo "  SOCKS认证: $SOCKS_USER / $SOCKS_PASS"
    echo "  分流模式:  $ROUTE_MODE"
    hr
    ask "确认以上配置并开始安装? (y/N):"
    read CONFIRM
    [ "${CONFIRM:-n}" != "y" ] && [ "${CONFIRM:-n}" != "Y" ] && error "已取消"
}

gen_ss2022_password() {
    local method="$1"
    local key_len
    case "$method" in
        2022-blake3-aes-128-gcm)       key_len=16 ;;
        2022-blake3-aes-256-gcm)       key_len=32 ;;
        2022-blake3-chacha20-poly1305) key_len=32 ;;
        *) key_len=16 ;;
    esac
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -base64 $key_len
    else
        dd if=/dev/urandom bs=$key_len count=1 2>/dev/null | base64 | tr -d '\n'
    fi
}

# ================================================================
# 生成 Xray 配置文件
# ================================================================
generate_config() {
    step "生成 Xray 配置文件"
    mkdir -p /etc/xray "$XRAY_GEODATA_DIR"

    # ---- 路由规则 ----
    case "$ROUTE_MODE" in
        gfw)
            ROUTING_JSON='"routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      { "type": "field", "outboundTag": "direct",
        "ip": ["geoip:private", "geoip:cn"] },
      { "type": "field", "outboundTag": "direct",
        "domain": ["geosite:cn", "geosite:private"] },
      { "type": "field", "outboundTag": "proxy",
        "network": "tcp,udp" }
    ]
  },'
            ;;
        direct)
            ROUTING_JSON='"routing": {
    "rules": [
      { "type": "field", "outboundTag": "direct", "network": "tcp,udp" }
    ]
  },'
            ;;
        *)  # global
            ROUTING_JSON='"routing": {
    "rules": [
      { "type": "field", "outboundTag": "direct",
        "ip": ["geoip:private"] },
      { "type": "field", "outboundTag": "proxy",
        "network": "tcp,udp" }
    ]
  },'
            ;;
    esac

    # ---- Inbound ----
    # 构建 SOCKS5 认证段
    if [ "$SOCKS_AUTH" = "password" ] && [ -n "$SOCKS_USER" ]; then
        SOCKS_AUTH_JSON='"auth": "password",
        "accounts": [{ "user": "'"$SOCKS_USER"'", "pass": "'"$SOCKS_PASS"'" }],'
    else
        SOCKS_AUTH_JSON='"auth": "noauth",'
    fi

    case "$PROXY_MODE" in
        tproxy)
            # 纯透明代理
            INBOUND_JSON='{
      "tag": "tproxy-in",
      "port": '"$TPROXY_PORT"',
      "protocol": "dokodemo-door",
      "settings": { "network": "tcp,udp", "followRedirect": true },
      "streamSettings": { "sockopt": { "tproxy": "tproxy", "mark": 255 } },
      "sniffing": { "enabled": true, "destOverride": ["http","tls"] }
    }'
            ;;

        socks)
            # 纯 SOCKS5 + HTTP 代理
            INBOUND_JSON='{
      "tag": "socks-in",
      "port": '"$SOCKS_PORT"',
      "listen": "0.0.0.0",
      "protocol": "socks",
      "settings": {
        '"$SOCKS_AUTH_JSON"'
        "udp": true
      }
    },
    {
      "tag": "http-in",
      "port": '"$HTTP_PORT"',
      "listen": "0.0.0.0",
      "protocol": "http"
    }'
            ;;

        tproxy_socks)
            # 透明代理 + SOCKS5 并存
            INBOUND_JSON='{
      "tag": "tproxy-in",
      "port": '"$TPROXY_PORT"',
      "protocol": "dokodemo-door",
      "settings": { "network": "tcp,udp", "followRedirect": true },
      "streamSettings": { "sockopt": { "tproxy": "tproxy", "mark": 255 } },
      "sniffing": { "enabled": true, "destOverride": ["http","tls"] }
    },
    {
      "tag": "socks-in",
      "port": '"$SOCKS_PORT"',
      "listen": "0.0.0.0",
      "protocol": "socks",
      "settings": {
        '"$SOCKS_AUTH_JSON"'
        "udp": true
      }
    },
    {
      "tag": "http-in",
      "port": '"$HTTP_PORT"',
      "listen": "0.0.0.0",
      "protocol": "http"
    }'
            ;;

        dokodemo)
            # 端口转发模式
            INBOUND_JSON='{
      "tag": "dokodemo-in",
      "port": '"$DOKO_LOCAL_PORT"',
      "listen": "0.0.0.0",
      "protocol": "dokodemo-door",
      "settings": {
        "address": "'"$DOKO_TARGET_ADDR"'",
        "port": '"$DOKO_TARGET_PORT"',
        "network": "'"$DOKO_NETWORK"'"
      }
    },
    {
      "tag": "socks-in",
      "port": '"$SOCKS_PORT"',
      "listen": "0.0.0.0",
      "protocol": "socks",
      "settings": { "auth": "noauth", "udp": true }
    }'
            ;;

        none)
            # 仅安装，留一个 SOCKS5 占位，用户自行修改
            INBOUND_JSON='{
      "tag": "socks-in",
      "port": '"$SOCKS_PORT"',
      "listen": "127.0.0.1",
      "protocol": "socks",
      "settings": { "auth": "noauth", "udp": true }
    }'
            ;;

        *)
            # 兜底: TProxy
            INBOUND_JSON='{
      "tag": "tproxy-in",
      "port": '"$TPROXY_PORT"',
      "protocol": "dokodemo-door",
      "settings": { "network": "tcp,udp", "followRedirect": true },
      "streamSettings": { "sockopt": { "tproxy": "tproxy", "mark": 255 } },
      "sniffing": { "enabled": true, "destOverride": ["http","tls"] }
    }'
            ;;
    esac

    # ---- 写入配置 ----
    cat > "$XRAY_CONF" << EOF
{
  "log": {
    "loglevel": "warning",
    "access": "/var/log/xray-access.log",
    "error":  "/var/log/xray-error.log"
  },
  "dns": {
    "servers": [
      {
        "address": "https+local://1.1.1.1/dns-query",
        "domains": ["geosite:geolocation-!cn"]
      },
      {
        "address": "223.5.5.5",
        "domains": ["geosite:cn", "geosite:private"]
      },
      "8.8.8.8",
      "localhost"
    ]
  },
  $ROUTING_JSON
  "inbounds": [
    $INBOUND_JSON
  ],
  "outbounds": [
    {
      "tag": "proxy",
      "protocol": "shadowsocks",
      "settings": {
        "servers": [{
          "address":  "$SS_SERVER",
          "port":     $SS_PORT,
          "method":   "$SS_METHOD",
          "password": "$SS_PASSWORD",
          "uot": true
        }]
      },
      "streamSettings": {
        "sockopt": { "mark": 255 }
      }
    },
    {
      "tag": "direct",
      "protocol": "freedom",
      "settings": { "domainStrategy": "UseIPv4" },
      "streamSettings": {
        "sockopt": { "mark": 255 }
      }
    },
    {
      "tag": "block",
      "protocol": "blackhole"
    }
  ]
}
EOF
    info "配置文件: $XRAY_CONF"
}

# ================================================================
# 创建系统服务 (多 init 系统适配)
# ================================================================
create_service() {
    step "创建系统服务 ($INIT_TYPE)"

    case "$INIT_TYPE" in
        procd)   create_service_procd ;;
        systemd) create_service_systemd ;;
        openrc)  create_service_openrc ;;
        sysv)    create_service_sysv ;;
    esac
}

# ---- OpenWrt procd ----
create_service_procd() {
    cat > /etc/init.d/xray << 'EOF'
#!/bin/sh /etc/rc.common
START=99
STOP=10
USE_PROCD=1

start_service() {
    procd_open_instance
    procd_set_param command /usr/bin/xray run -config /etc/xray/config.json
    procd_set_param respawn 3600 5 5
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_set_param pidfile /var/run/xray.pid
    procd_close_instance
}

stop_service() { killall xray 2>/dev/null; return 0; }
reload_service() { stop; start; }
EOF
    chmod +x /etc/init.d/xray
    /etc/init.d/xray enable
    info "procd 服务已创建"
}

# ---- systemd ----
create_service_systemd() {
    cat > /etc/systemd/system/xray.service << EOF
[Unit]
Description=Xray Service (SS2022)
Documentation=https://github.com/XTLS/Xray-core
After=network.target nss-lookup.target

[Service]
User=root
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=false
ExecStart=$XRAY_BIN run -config $XRAY_CONF
Restart=on-failure
RestartPreventExitStatus=23
LimitNPROC=10000
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable xray
    info "systemd 服务已创建"
}

# ---- OpenRC (Alpine) ----
create_service_openrc() {
    cat > /etc/init.d/xray << EOF
#!/sbin/openrc-run

name="xray"
description="Xray Service (SS2022)"
command="$XRAY_BIN"
command_args="run -config $XRAY_CONF"
command_background=true
pidfile="/run/xray.pid"
output_log="/var/log/xray-access.log"
error_log="/var/log/xray-error.log"

depend() {
    need net
    after firewall
}
EOF
    chmod +x /etc/init.d/xray
    rc-update add xray default
    info "OpenRC 服务已创建"
}

# ---- SysV ----
create_service_sysv() {
    cat > /etc/init.d/xray << EOF
#!/bin/sh
### BEGIN INIT INFO
# Provides:          xray
# Required-Start:    \$network
# Required-Stop:     \$network
# Default-Start:     2 3 4 5
# Default-Stop:      0 1 6
# Short-Description: Xray SS2022
### END INIT INFO

DAEMON=$XRAY_BIN
ARGS="run -config $XRAY_CONF"
PIDFILE=/var/run/xray.pid
NAME=xray

case "\$1" in
    start)
        echo "Starting \$NAME"
        start-stop-daemon --start --background --make-pidfile \
            --pidfile \$PIDFILE --exec \$DAEMON -- \$ARGS
        ;;
    stop)
        echo "Stopping \$NAME"
        start-stop-daemon --stop --pidfile \$PIDFILE
        rm -f \$PIDFILE
        ;;
    restart) \$0 stop; sleep 1; \$0 start ;;
    status)
        if [ -f \$PIDFILE ] && kill -0 \$(cat \$PIDFILE) 2>/dev/null; then
            echo "\$NAME is running"
        else
            echo "\$NAME is not running"
        fi
        ;;
    *) echo "Usage: \$0 {start|stop|restart|status}"; exit 1 ;;
esac
EOF
    chmod +x /etc/init.d/xray
    update-rc.d xray defaults 2>/dev/null || true
    info "SysV 服务已创建"
}

# ================================================================
# 透明代理防火墙规则
# ================================================================
setup_tproxy() {
    case "$PROXY_MODE" in
        tproxy|tproxy_socks) ;;
        *) return ;;
    esac
    step "配置透明代理规则 ($FW_TYPE)"

    # 创建通用 tproxy 规则脚本
    if [ "$FW_TYPE" = "nftables" ]; then
        create_tproxy_nft
    else
        create_tproxy_ipt
    fi

    # 应用规则
    sh /etc/xray/tproxy-start.sh

    # 开机自动执行
    install_tproxy_autostart
}

create_tproxy_nft() {
    cat > /etc/xray/tproxy-start.sh << NFTEOF
#!/bin/sh
# Xray TProxy - nftables
set -e
TPROXY_PORT=${TPROXY_PORT}
MARK=0xff

nft delete table inet xray 2>/dev/null || true
nft add table inet xray
nft add chain inet xray prerouting '{ type filter hook prerouting priority mangle; policy accept; }'

# 跳过 Xray 自身流量
nft add rule inet xray prerouting meta mark ${MARK} return

# 跳过私有/回环地址
nft add rule inet xray prerouting ip daddr {
  127.0.0.0/8, 10.0.0.0/8, 172.16.0.0/12,
  192.168.0.0/16, 169.254.0.0/16,
  224.0.0.0/4, 240.0.0.0/4
} return

# TCP/UDP TProxy
nft add rule inet xray prerouting meta l4proto tcp \\
    tproxy ip to 127.0.0.1:${TPROXY_PORT} meta mark set ${MARK}
nft add rule inet xray prerouting meta l4proto udp \\
    tproxy ip to 127.0.0.1:${TPROXY_PORT} meta mark set ${MARK}

# 路由策略
ip rule add fwmark ${MARK} table 100 2>/dev/null || true
ip route add local default dev lo table 100 2>/dev/null || true

echo "[xray] nftables TProxy 规则已应用"
NFTEOF

    cat > /etc/xray/tproxy-stop.sh << EOF
#!/bin/sh
nft delete table inet xray 2>/dev/null || true
ip rule del fwmark 0xff table 100 2>/dev/null || true
ip route del local default dev lo table 100 2>/dev/null || true
echo "[xray] nftables TProxy 规则已清除"
EOF
    chmod +x /etc/xray/tproxy-start.sh /etc/xray/tproxy-stop.sh
}

create_tproxy_ipt() {
    cat > /etc/xray/tproxy-start.sh << IPTEOF
#!/bin/sh
# Xray TProxy - iptables
TPROXY_PORT=${TPROXY_PORT}
MARK=0xff

# 清理旧链
iptables -t mangle -D PREROUTING -j XRAY_TP 2>/dev/null || true
iptables -t mangle -F XRAY_TP 2>/dev/null || true
iptables -t mangle -X XRAY_TP 2>/dev/null || true

iptables -t mangle -N XRAY_TP

# 跳过 Xray 自身流量
iptables -t mangle -A XRAY_TP -m mark --mark \${MARK} -j RETURN

# 跳过私有地址
for net in 0.0.0.0/8 10.0.0.0/8 127.0.0.0/8 \
           169.254.0.0/16 172.16.0.0/12 192.168.0.0/16 \
           224.0.0.0/4 240.0.0.0/4; do
    iptables -t mangle -A XRAY_TP -d \$net -j RETURN
done

# TCP/UDP TProxy
iptables -t mangle -A XRAY_TP -p tcp -j TPROXY \
    --on-port \${TPROXY_PORT} --tproxy-mark \${MARK}
iptables -t mangle -A XRAY_TP -p udp -j TPROXY \
    --on-port \${TPROXY_PORT} --tproxy-mark \${MARK}

iptables -t mangle -A PREROUTING -j XRAY_TP

# 路由策略
ip rule add fwmark \${MARK} table 100 2>/dev/null || true
ip route add local default dev lo table 100 2>/dev/null || true

echo "[xray] iptables TProxy 规则已应用"
IPTEOF

    cat > /etc/xray/tproxy-stop.sh << EOF
#!/bin/sh
iptables -t mangle -D PREROUTING -j XRAY_TP 2>/dev/null || true
iptables -t mangle -F XRAY_TP 2>/dev/null || true
iptables -t mangle -X XRAY_TP 2>/dev/null || true
ip rule del fwmark 0xff table 100 2>/dev/null || true
ip route del local default dev lo table 100 2>/dev/null || true
echo "[xray] iptables TProxy 规则已清除"
EOF
    chmod +x /etc/xray/tproxy-start.sh /etc/xray/tproxy-stop.sh
}

install_tproxy_autostart() {
    case "$INIT_TYPE" in
        procd)
            # OpenWrt hotplug
            mkdir -p /etc/hotplug.d/iface
            cat > /etc/hotplug.d/iface/30-xray-tproxy << 'EOF'
#!/bin/sh
[ "$ACTION" = "ifup" ] && [ "$INTERFACE" = "wan" ] && {
    sleep 2
    sh /etc/xray/tproxy-start.sh
}
EOF
            chmod +x /etc/hotplug.d/iface/30-xray-tproxy
            ;;
        systemd)
            # 在 xray.service 加入 ExecStartPost
            sed -i '/ExecStart=/a ExecStartPost=/bin/sh /etc/xray/tproxy-start.sh' \
                /etc/systemd/system/xray.service
            sed -i '/ExecStart=/i ExecStop=/bin/sh /etc/xray/tproxy-stop.sh' \
                /etc/systemd/system/xray.service
            systemctl daemon-reload
            ;;
        openrc)
            sed -i '/^command_background/a start_post() { sh /etc/xray/tproxy-start.sh; }' \
                /etc/init.d/xray
            sed -i '/^command_background/a stop_post()  { sh /etc/xray/tproxy-stop.sh;  }' \
                /etc/init.d/xray
            ;;
        sysv)
            # 在 start/stop 段插入
            sed -i '/start-stop-daemon --start/a\\t\tsh /etc/xray/tproxy-start.sh' \
                /etc/init.d/xray
            ;;
    esac
    info "TProxy 开机自启已配置"
}

# ================================================================
# 服务启停封装
# ================================================================
service_start() {
    case "$INIT_TYPE" in
        procd)   /etc/init.d/xray start ;;
        systemd) systemctl start xray ;;
        openrc)  rc-service xray start ;;
        sysv)    /etc/init.d/xray start ;;
    esac
}

service_stop() {
    case "$INIT_TYPE" in
        procd)   /etc/init.d/xray stop ;;
        systemd) systemctl stop xray ;;
        openrc)  rc-service xray stop ;;
        sysv)    /etc/init.d/xray stop ;;
    esac
}

service_restart() {
    case "$INIT_TYPE" in
        procd)   /etc/init.d/xray restart ;;
        systemd) systemctl restart xray ;;
        openrc)  rc-service xray restart ;;
        sysv)    /etc/init.d/xray restart ;;
    esac
}

service_status() {
    case "$INIT_TYPE" in
        procd)   /etc/init.d/xray status ;;
        systemd) systemctl status xray --no-pager ;;
        openrc)  rc-service xray status ;;
        sysv)    /etc/init.d/xray status ;;
    esac
}

# ================================================================
# 管理脚本
# ================================================================
create_manager() {
    step "创建管理脚本 /usr/bin/xray-manager"

    # 把运行时变量写入管理脚本
    cat > /usr/bin/xray-manager << MGEOF
#!/bin/sh
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
info() { echo -e "\${GREEN}[INFO]\${NC} \$1"; }
warn() { echo -e "\${YELLOW}[WARN]\${NC} \$1"; }
hr()  { echo -e "\${CYAN}──────────────────────────────────\${NC}"; }

INIT_TYPE="${INIT_TYPE}"
XRAY_BIN="${XRAY_BIN}"
XRAY_CONF="${XRAY_CONF}"
TPROXY_START="/etc/xray/tproxy-start.sh"
TPROXY_STOP="/etc/xray/tproxy-stop.sh"

svc_cmd() {
    case "\$INIT_TYPE" in
        procd)   /etc/init.d/xray \$1 ;;
        systemd) systemctl \$1 xray ;;
        openrc)  rc-service xray \$1 ;;
        sysv)    /etc/init.d/xray \$1 ;;
    esac
}

show_status() {
    echo ""
    hr
    if pgrep -f "xray run" >/dev/null 2>&1; then
        echo -e "  Xray 状态: \${GREEN}运行中 ✓\${NC}  PID: \$(pgrep -f 'xray run' | head -1)"
    else
        echo -e "  Xray 状态: \${RED}未运行 ✗\${NC}"
    fi
    echo "  版本: \$(\$XRAY_BIN version 2>/dev/null | head -1)"
    echo ""
    echo "  代理端口:"
    echo "    SOCKS5  : 0.0.0.0:${SOCKS_PORT}"
    echo "    HTTP    : 0.0.0.0:${HTTP_PORT}"
    echo "    TProxy  : ${TPROXY_PORT} (透明代理)"
    hr
}

show_config() {
    echo ""
    grep -E '"address"|"port"|"method"|"password"|"outboundTag"' \
        \$XRAY_CONF | head -30
    echo ""
}

show_menu() {
    echo ""
    echo -e "\${CYAN}\${BOLD}╔══════════════════════════════════════╗\${NC}"
    echo -e "\${CYAN}\${BOLD}║      Xray SS2022 管理菜单            ║\${NC}"
    echo -e "\${CYAN}\${BOLD}╠══════════════════════════════════════╣\${NC}"
    echo -e "\${CYAN}║\${NC}  1. 启动 Xray                        \${CYAN}║\${NC}"
    echo -e "\${CYAN}║\${NC}  2. 停止 Xray                        \${CYAN}║\${NC}"
    echo -e "\${CYAN}║\${NC}  3. 重启 Xray                        \${CYAN}║\${NC}"
    echo -e "\${CYAN}║\${NC}  4. 查看运行状态                     \${CYAN}║\${NC}"
    echo -e "\${CYAN}║\${NC}  5. 查看当前配置摘要                 \${CYAN}║\${NC}"
    echo -e "\${CYAN}║\${NC}  6. 查看实时错误日志                 \${CYAN}║\${NC}"
    echo -e "\${CYAN}║\${NC}  7. 应用 TProxy 防火墙规则           \${CYAN}║\${NC}"
    echo -e "\${CYAN}║\${NC}  8. 清除 TProxy 防火墙规则           \${CYAN}║\${NC}"
    echo -e "\${CYAN}║\${NC}  9. 编辑配置文件 (vi)                \${CYAN}║\${NC}"
    echo -e "\${CYAN}║\${NC}  s. 显示 SS 分享链接                 \${CYAN}║\${NC}"
    echo -e "\${CYAN}║\${NC}  0. 退出                             \${CYAN}║\${NC}"
    echo -e "\${CYAN}\${BOLD}╚══════════════════════════════════════╝\${NC}"
    printf "请输入选项: "
}

while true; do
    show_menu
    read choice
    case "\$choice" in
        1) svc_cmd start   && info "Xray 已启动" ;;
        2) svc_cmd stop    && info "Xray 已停止" ;;
        3) svc_cmd restart && info "Xray 已重启" ;;
        4) show_status ;;
        5) show_config ;;
        6) tail -f /var/log/xray-error.log ;;
        7) [ -f "\$TPROXY_START" ] && sh "\$TPROXY_START" || warn "未找到 TProxy 脚本" ;;
        8) [ -f "\$TPROXY_STOP"  ] && sh "\$TPROXY_STOP"  || warn "未找到 TProxy 脚本" ;;
        9) vi \$XRAY_CONF ;;
        s|S)
            echo ""
            if [ -f /etc/xray/ss-link.txt ]; then
                echo -e "  \${CYAN}SS 分享链接:\${NC}"
                echo ""
                cat /etc/xray/ss-link.txt
                echo ""
            else
                warn "未找到 SS 链接文件 /etc/xray/ss-link.txt"
            fi
            ;;
        0) exit 0 ;;
        *) warn "无效选项" ;;
    esac
done
MGEOF
    chmod +x /usr/bin/xray-manager
    info "管理脚本已创建: xray-manager"
}

# ================================================================
# 启动
# ================================================================
start_xray() {
    step "启动 Xray 服务"
    service_start
    sleep 2
    if pgrep -f "xray run" >/dev/null 2>&1; then
        info "Xray 启动成功 ✓  PID: $(pgrep -f 'xray run' | head -1)"
    else
        warn "Xray 可能未成功启动，请查看日志:"
        warn "  cat /var/log/xray-error.log"
    fi
}

# ================================================================
# 安装总结
# ================================================================
print_summary() {
    echo ""
    echo -e "${CYAN}${BOLD}╔══════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}${BOLD}║           安 装 完 成  ✓                ║${NC}"
    echo -e "${CYAN}${BOLD}╚══════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  ${GREEN}系统:${NC}       $OS_NAME $OS_VER  ($INIT_TYPE / $FW_TYPE)"
    echo -e "  ${GREEN}服务器:${NC}     $SS_SERVER:$SS_PORT"
    echo -e "  ${GREEN}加密方式:${NC}   $SS_METHOD"
    echo -e "  ${GREEN}密码:${NC}       $SS_PASSWORD"
    echo -e "  ${GREEN}分流模式:${NC}   $ROUTE_MODE"
    echo ""

    # ---- 生成 SS 链接 (SIP002 标准) ----
    # userinfo = base64( method : password )
    local userinfo ss_link
    userinfo=$(printf '%s:%s' "$SS_METHOD" "$SS_PASSWORD" | base64 | tr -d '\n=')
    # 服务器地址：若含冒号（IPv6）则加方括号
    local ss_host="$SS_SERVER"
    echo "$SS_SERVER" | grep -q ":" && ss_host="[$SS_SERVER]"
    ss_link="ss://${userinfo}@${ss_host}:${SS_PORT}#SS2022-$(echo "$SS_SERVER" | sed 's/[^a-zA-Z0-9]/-/g')"

    echo -e "  ${CYAN}${BOLD}── SS 分享链接 ──${NC}"
    echo ""
    echo -e "  ${GREEN}${ss_link}${NC}"
    echo ""
    echo "  (可直接导入 v2rayN / Shadowrocket / sing-box 等客户端)"
    echo ""
    # 同时保存到文件
    echo "$ss_link" > /etc/xray/ss-link.txt
    echo -e "  链接已保存至: ${YELLOW}/etc/xray/ss-link.txt${NC}"
    echo ""
    echo -e "  ${CYAN}${BOLD}── 代理端口 ──${NC}"
    case "$PROXY_MODE" in
        tproxy)
            echo -e "  ${CYAN}透明代理 TProxy:${NC}  端口 $TPROXY_PORT (自动拦截局域网流量)"
            echo -e "  ${YELLOW}提示:${NC} 将下游设备网关指向本机 IP 即可透明代理"
            ;;
        socks)
            echo -e "  ${CYAN}SOCKS5 代理:${NC}  0.0.0.0:$SOCKS_PORT"
            echo -e "  ${CYAN}HTTP  代理:${NC}   0.0.0.0:$HTTP_PORT"
            [ "$SOCKS_AUTH" = "password" ] && \
            echo -e "  ${CYAN}SOCKS认证:${NC}    用户: $SOCKS_USER  密码: $SOCKS_PASS"
            echo -e "  ${YELLOW}提示:${NC} 在浏览器/系统代理设置中填写上述地址和端口"
            ;;
        tproxy_socks)
            echo -e "  ${CYAN}透明代理 TProxy:${NC}  端口 $TPROXY_PORT"
            echo -e "  ${CYAN}SOCKS5 代理:${NC}      0.0.0.0:$SOCKS_PORT"
            echo -e "  ${CYAN}HTTP  代理:${NC}        0.0.0.0:$HTTP_PORT"
            [ "$SOCKS_AUTH" = "password" ] && \
            echo -e "  ${CYAN}SOCKS认证:${NC}         用户: $SOCKS_USER  密码: $SOCKS_PASS"
            ;;
        dokodemo)
            echo -e "  ${CYAN}端口转发:${NC}  本机:$DOKO_LOCAL_PORT  ->  $DOKO_TARGET_ADDR:$DOKO_TARGET_PORT  ($DOKO_NETWORK)"
            echo -e "  ${CYAN}SOCKS5:${NC}    0.0.0.0:$SOCKS_PORT"
            echo -e "  ${YELLOW}提示:${NC} 访问本机 $DOKO_LOCAL_PORT 端口将转发到目标地址"
            ;;
        none)
            echo -e "  ${YELLOW}代理未配置${NC} - 请手动编辑配置文件后重启服务"
            echo -e "  ${CYAN}配置文件:${NC}  $XRAY_CONF"
            ;;
    esac
    echo ""
    echo -e "  ${YELLOW}常用命令:${NC}"
    echo "    xray-manager                 # 管理菜单"
    echo "    cat /var/log/xray-error.log  # 查看日志"
    echo "    sh $0 uninstall              # 卸载"
    echo ""
}

# ================================================================
# 卸载
# ================================================================
uninstall() {
    title "卸载 Xray SS2022"
    printf "确认卸载? (y/N): "
    read CONFIRM
    [ "${CONFIRM:-n}" != "y" ] && [ "${CONFIRM:-n}" != "Y" ] && exit 0

    detect_os

    service_stop 2>/dev/null || true

    case "$INIT_TYPE" in
        procd)
            /etc/init.d/xray disable 2>/dev/null || true
            rm -f /etc/init.d/xray
            rm -f /etc/hotplug.d/iface/30-xray-tproxy
            ;;
        systemd)
            systemctl disable xray 2>/dev/null || true
            rm -f /etc/systemd/system/xray.service
            systemctl daemon-reload
            ;;
        openrc)
            rc-update del xray default 2>/dev/null || true
            rm -f /etc/init.d/xray
            ;;
        sysv)
            update-rc.d xray remove 2>/dev/null || true
            rm -f /etc/init.d/xray
            ;;
    esac

    # 清除防火墙规则
    [ -f /etc/xray/tproxy-stop.sh ] && sh /etc/xray/tproxy-stop.sh 2>/dev/null || true

    # 删除文件
    rm -rf /etc/xray
    rm -f /usr/bin/xray-manager
    rm -f /var/log/xray-*.log

    info "卸载完成 (xray 二进制保留于 $XRAY_BIN，如需删除: rm $XRAY_BIN)"
}

# ================================================================
# 完整安装流程（从菜单调用）
# ================================================================
do_install() {
    check_root
    detect_os
    install_deps
    collect_config
    install_xray
    install_tproxy_deps
    generate_config
    create_service
    setup_tproxy
    create_manager
    start_xray
    print_summary
}

# ================================================================
# 更新配置（重新收集参数并重写配置文件）
# ================================================================
do_reconfig() {
    check_root
    detect_os
    [ ! -f "$XRAY_BIN" ] && error "Xray 尚未安装，请先执行安装"
    collect_config
    generate_config
    setup_tproxy
    service_restart
    info "配置已更新并重启服务"
    print_summary
}

# ================================================================
# 检测当前安装状态
# ================================================================
get_install_status() {
    XRAY_INSTALLED=0
    XRAY_RUNNING=0
    [ -f "$XRAY_BIN" ] && XRAY_INSTALLED=1
    pgrep -f "xray run" >/dev/null 2>&1 && XRAY_RUNNING=1
}

show_status_line() {
    get_install_status
    local install_str run_str
    if [ "$XRAY_INSTALLED" = "1" ]; then
        install_str="${GREEN}已安装${NC}"
    else
        install_str="${RED}未安装${NC}"
    fi
    if [ "$XRAY_RUNNING" = "1" ]; then
        run_str="${GREEN}运行中${NC}"
    else
        run_str="${RED}未运行${NC}"
    fi
    echo -e " 当前状态：$install_str  |  服务：$run_str"
}

# ================================================================
# 显示主菜单
# ================================================================
show_main_menu() {
    clear
    echo -e "${CYAN}${BOLD}"
    echo " ============================================"
    echo "       Xray + SS2022 管理脚本"
    echo "   OpenWrt / Debian / Ubuntu / CentOS"
    echo "   Alpine  / Armbian / Raspberry Pi OS"
    echo " ============================================"
    echo -e "${NC}"
    echo " ─────────────────────────────────────────"
    echo -e "  ${YELLOW}0.${NC} 更新脚本"
    echo " ─────────────────────────────────────────"
    echo -e "  ${YELLOW}1.${NC} 安装 Xray (SS2022)"
    echo -e "  ${YELLOW}2.${NC} 更新 Xray 核心"
    echo -e "  ${YELLOW}3.${NC} 卸载 Xray"
    echo " ─────────────────────────────────────────"
    echo -e "  ${YELLOW}4.${NC} 启动服务"
    echo -e "  ${YELLOW}5.${NC} 停止服务"
    echo -e "  ${YELLOW}6.${NC} 重启服务"
    echo " ─────────────────────────────────────────"
    echo -e "  ${YELLOW}7.${NC} 修改配置"
    echo -e "  ${YELLOW}8.${NC} 查看配置"
    echo -e "  ${YELLOW}9.${NC} 查看运行状态 / 日志"
    echo -e "  ${YELLOW}s.${NC} 显示 SS 分享链接"
    echo " ─────────────────────────────────────────"
    echo -e "  ${YELLOW}11.${NC} 中国大陆 IP 屏蔽 (切换)"
    echo -e "  ${YELLOW}12.${NC} 退出脚本"
    echo " ─────────────────────────────────────────"
    echo ""
    show_status_line
    echo ""
    printf " 请输入数字 [0-12 / s]: "
}

# ================================================================
# 更新 Xray 核心二进制
# ================================================================
do_update_xray() {
    check_root
    detect_os
    [ ! -f "$XRAY_BIN" ] && error "Xray 尚未安装，请先执行安装 (选项 1)"
    info "停止服务..."
    service_stop 2>/dev/null || true
    info "重新下载最新版本..."
    install_xray_github
    info "重启服务..."
    service_start
    info "更新完成: $($XRAY_BIN version 2>/dev/null | head -1)"
}

# ================================================================
# 查看详细状态和日志
# ================================================================
do_status() {
    detect_os
    echo ""
    hr
    get_install_status
    if [ "$XRAY_INSTALLED" = "1" ]; then
        echo -e "  Xray 版本: $($XRAY_BIN version 2>/dev/null | head -1)"
    fi
    if [ "$XRAY_RUNNING" = "1" ]; then
        echo -e "  运行状态: ${GREEN}运行中 ✓${NC}  PID: $(pgrep -f 'xray run' | head -1)"
    else
        echo -e "  运行状态: ${RED}未运行 ✗${NC}"
    fi
    hr
    echo ""
    echo "  最近 20 行错误日志:"
    echo ""
    if [ -f /var/log/xray-error.log ]; then
        tail -20 /var/log/xray-error.log
    else
        echo "  (日志文件不存在)"
    fi
    echo ""
    printf "  按 f 实时跟踪日志，其他键返回菜单: "
    read LOG_CHOICE
    [ "$LOG_CHOICE" = "f" ] || [ "$LOG_CHOICE" = "F" ] && \
        tail -f /var/log/xray-error.log
}

# ================================================================
# 查看配置
# ================================================================
do_show_config() {
    [ ! -f "$XRAY_CONF" ] && { warn "配置文件不存在: $XRAY_CONF"; return; }
    echo ""
    hr
    echo "  配置文件: $XRAY_CONF"
    hr
    # 只显示关键字段，不输出整个 JSON
    echo ""
    local server method password
    server=$(grep -o '"address": *"[^"]*"' "$XRAY_CONF" | grep -v "127\|0\.0\.0\|1\.1\.1\|8\.8\|223\." | head -1 | sed 's/.*"\([^"]*\)"/\1/')
    method=$(grep -o '"method": *"[^"]*"' "$XRAY_CONF" | head -1 | sed 's/.*"\([^"]*\)"/\1/')
    password=$(grep -o '"password": *"[^"]*"' "$XRAY_CONF" | head -1 | sed 's/.*"\([^"]*\)"/\1/')
    local sport
    sport=$(grep -A5 '"protocol": *"shadowsocks"' "$XRAY_CONF" | grep '"port"' | head -1 | grep -o '[0-9]*')
    echo -e "  ${CYAN}服务器:${NC}   $server"
    echo -e "  ${CYAN}端口:${NC}     $sport"
    echo -e "  ${CYAN}加密:${NC}     $method"
    echo -e "  ${CYAN}密码:${NC}     $password"
    echo ""
    # SS 链接
    if [ -f /etc/xray/ss-link.txt ]; then
        echo -e "  ${CYAN}SS 链接:${NC}"
        echo "  $(cat /etc/xray/ss-link.txt)"
    fi
    echo ""
    hr
    printf "  按 e 编辑配置文件，其他键返回: "
    read EDIT_CHOICE
    [ "$EDIT_CHOICE" = "e" ] || [ "$EDIT_CHOICE" = "E" ] && {
        vi "$XRAY_CONF"
        detect_os
        service_restart
        info "配置已重载"
    }
}

# ================================================================
# 中国大陆 IP 屏蔽切换
# ================================================================
do_toggle_cn_block() {
    [ ! -f "$XRAY_CONF" ] && { warn "配置文件不存在，请先安装"; return; }

    # 检测当前是否已有 cn 屏蔽规则
    if grep -q '"geoip:cn"' "$XRAY_CONF" && grep -q '"block"' "$XRAY_CONF"; then
        # 当前已开启 -> 关闭（把 cn block 规则删除）
        echo ""
        warn "当前已开启大陆 IP 屏蔽，是否关闭? (y/N):"
        read TOGGLE_CONFIRM
        [ "${TOGGLE_CONFIRM:-n}" != "y" ] && [ "${TOGGLE_CONFIRM:-n}" != "Y" ] && return
        # 用 Python/sed 移除 cn block 规则行
        sed -i '/geoip:cn.*block\|block.*geoip:cn/d' "$XRAY_CONF"
        # 移除对应 block outbound（保守做法：仅提示用户）
        info "已从路由规则中移除大陆 IP 屏蔽"
    else
        # 当前未开启 -> 开启
        echo ""
        info "将在路由规则中添加：中国大陆 IP -> block（直接丢弃）"
        ask "确认开启? (y/N):"
        read TOGGLE_CONFIRM
        [ "${TOGGLE_CONFIRM:-n}" != "y" ] && [ "${TOGGLE_CONFIRM:-n}" != "Y" ] && return
        # 在 routing.rules 第一条插入 cn block 规则
        # 使用临时 Python 脚本处理 JSON（如有），否则用 sed 注入
        local rule='      { "type": "field", "outboundTag": "block", "ip": ["geoip:cn"] },'
        sed -i '/"rules": \[/a\'"$rule" "$XRAY_CONF"
        info "已添加大陆 IP 屏蔽规则"
    fi

    detect_os
    service_restart
    info "服务已重启，规则生效"
}

# ================================================================
# 更新脚本自身
# ================================================================
do_self_update() {
    local script_path
    script_path=$(readlink -f "$0")
    info "尝试更新脚本: $script_path"
    local tmp_new="/tmp/xray-install-new.sh"
    # 这里填写你托管脚本的 URL，默认留空提示用户
    local UPDATE_URL=""
    if [ -z "$UPDATE_URL" ]; then
        warn "未配置更新地址 UPDATE_URL，请手动替换脚本文件"
        warn "脚本路径: $script_path"
        return
    fi
    wget -O "$tmp_new" "$UPDATE_URL" --timeout=30 || { warn "下载失败"; return; }
    chmod +x "$tmp_new"
    mv "$tmp_new" "$script_path"
    info "脚本已更新，请重新运行"
    exit 0
}

# ================================================================
# 主入口
# ================================================================
main() {
    check_root
    detect_os

    while true; do
        show_main_menu
        read MENU_CHOICE
        echo ""
        case "$MENU_CHOICE" in
            0)  do_self_update ;;
            1)  do_install ;;
            2)  do_update_xray ;;
            3)  uninstall ;;
            4)  service_start   && info "服务已启动" ;;
            5)  service_stop    && info "服务已停止" ;;
            6)  service_restart && info "服务已重启" ;;
            7)  do_reconfig ;;
            8)  do_show_config ;;
            9)  do_status ;;
            s|S)
                echo ""
                if [ -f /etc/xray/ss-link.txt ]; then
                    echo -e "  ${CYAN}SS 分享链接:${NC}"
                    echo ""
                    echo -e "  ${GREEN}$(cat /etc/xray/ss-link.txt)${NC}"
                    echo ""
                else
                    warn "尚未生成 SS 链接，请先完成安装"
                fi
                ;;
            11) do_toggle_cn_block ;;
            12) echo ""; info "退出"; exit 0 ;;
            *)  warn "无效选项: $MENU_CHOICE" ;;
        esac
        echo ""
        printf " 按回车键继续..."
        read _PAUSE
    done
}

main "$@"
