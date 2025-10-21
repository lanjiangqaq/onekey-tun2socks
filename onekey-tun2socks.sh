#!/bin/bash
set -e

#================================================================================
# 常量和全局变量
#================================================================================
VERSION="1.1.3"
SCRIPT_URL="https://raw.githubusercontent.com/hkfires/onekey-tun2socks/main/onekey-tun2socks.sh"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m'

# 备用 DNS64 服务器
ALTERNATE_DNS64_SERVERS=(
    "2a00:1098:2b::1"
    "2a01:4f8:c2c:123f::1"
    "2a01:4f9:c010:3f02::1"
    "2001:67c:2b0::4"
    "2001:67c:2b0::6"
)

ACTION=""
MODE="alice" # 默认安装模式

#================================================================================
# 日志函数
#================================================================================
info() { echo -e "${BLUE}[信息]${NC} $1"; }
success() { echo -e "${GREEN}[成功]${NC} $1"; }
warning() { echo -e "${YELLOW}[警告]${NC} $1"; }
error() { echo -e "${RED}[错误]${NC} $1"; }
step() { echo -e "${PURPLE}[步骤]${NC} $1"; }

require_root() {
    if [ "$EUID" -ne 0 ]; then
        error "请使用 root 权限运行此脚本，例如: sudo $0"
        exit 1
    fi
}

#================================================================================
# Socks5 节点选择函数（已改）
#================================================================================
select_alice_port() {
    # 自定义 Socks5 节点列表
    local nodes=(
        "111.*.*.90:10001"
        "36.*.*.98:10002"
        "111.*.*.101:10003"
        "111.*.*.98:10004"
        "111.*.*.100:10005"
        "111.*.*.95:10006"
        "36.*.*.247:10007"
        "111.*.*.99:10008"
    )
    local index=$((RANDOM % ${#nodes[@]}))
    local node="${nodes[$index]}"
    local ip="${node%%:*}"
    local port="${node##*:}"
    echo "$ip:$port"
}

#================================================================================
# DNS64 测试及恢复函数（原样保留）
#================================================================================
test_dns64_server() {
    local dns_server=$1
    step "正在测试DNS64服务器 $dns_server 的连通性..."
    if ping6 -c 3 -W 2 "$dns_server" &>/dev/null; then
        info "DNS64服务器 $dns_server 可达。"
        return 0
    else
        warning "DNS64服务器 $dns_server 不可达。"
        return 1
    fi
}

test_github_access() {
    step "正在测试GitHub访问..."
    if curl -s -m 10 https://github.com >/dev/null; then
        success "GitHub访问测试成功。"
        return 0
    else
        warning "GitHub访问测试失败。"
        return 1
    fi
}

restore_dns_config() {
    local resolv_conf=$1
    local resolv_conf_bak=$2
    local was_immutable=$3
    step "恢复原始 DNS 配置..."
    if [ -f "$resolv_conf_bak" ]; then
        mv "$resolv_conf_bak" "$resolv_conf"
        success "DNS 配置已恢复。"
        if [ "$was_immutable" = true ]; then
            info "重新锁定 /etc/resolv.conf..."
            chattr +i "$resolv_conf" || warning "无法重新锁定 /etc/resolv.conf。"
            success "锁定完成。"
        fi
    else
        warning "未找到 DNS 备份文件 ($resolv_conf_bak)。"
    fi
}

set_dns64_servers() {
    local mode=$1
    local resolv_conf=$2
    local was_immutable=$3
    local resolv_conf_bak=$4
    step "设置 DNS64 服务器（用于下载tun2socks）..."
    cat > "$resolv_conf" <<EOF
nameserver 2602:fc59:b0:9e::64
EOF
    if test_github_access; then
        return 0
    fi
    warning "主DNS64服务器访问GitHub失败，尝试备选DNS64服务器..."
    for dns_server in "${ALTERNATE_DNS64_SERVERS[@]}"; do
        if test_dns64_server "$dns_server"; then
            step "使用备选DNS64服务器: $dns_server"
            cat > "$resolv_conf" <<EOF
nameserver $dns_server
EOF
            if test_github_access; then
                success "使用备选DNS64服务器 $dns_server 成功访问GitHub。"
                return 0
            fi
        fi
    done
    error "所有DNS64服务器测试失败。"
    restore_dns_config "$resolv_conf" "$resolv_conf_bak" "$was_immutable"
    return 1
}

#================================================================================
# 核心：安装 tun2socks
#================================================================================
install_tun2socks() {
    cleanup_ip_rules

    RESOLV_CONF="/etc/resolv.conf"
    RESOLV_CONF_BAK="/etc/resolv.conf.bak"
    WAS_IMMUTABLE=false

    step "备份 DNS 配置..."
    cp "$RESOLV_CONF" "$RESOLV_CONF_BAK" || true

    set_dns64_servers "$MODE" "$RESOLV_CONF" "$WAS_IMMUTABLE" "$RESOLV_CONF_BAK"

    REPO="heiher/hev-socks5-tunnel"
    INSTALL_DIR="/usr/local/bin"
    CONFIG_DIR="/etc/tun2socks"
    SERVICE_FILE="/etc/systemd/system/tun2socks.service"
    BINARY_PATH="$INSTALL_DIR/tun2socks"

    step "获取最新版本下载链接..."
    DOWNLOAD_URL=$(curl -s https://api.github.com/repos/$REPO/releases/latest | grep "browser_download_url" | grep "linux-x86_64" | cut -d '"' -f 4)
    curl -L -o "$BINARY_PATH" "$DOWNLOAD_URL"
    restore_dns_config "$RESOLV_CONF" "$RESOLV_CONF_BAK" "$WAS_IMMUTABLE"
    chmod +x "$BINARY_PATH"

    step "创建配置文件..."
    mkdir -p "$CONFIG_DIR"
    CONFIG_FILE="$CONFIG_DIR/config.yaml"

    NODE=$(select_alice_port)
    SOCKS_IP="${NODE%%:*}"
    SOCKS_PORT="${NODE##*:}"

    cat > "$CONFIG_FILE" <<EOF
tunnel:
  name: tun0
  mtu: 8500
  multi-queue: true
  ipv4: 198.18.0.1

socks5:
  port: $SOCKS_PORT
  address: '$SOCKS_IP'
  udp: 'udp'
  username: 'alice'
  password: 'alicefofo123..OVO'
  mark: 438
EOF

    step "生成 rotate_taiwan_node.sh 脚本..."
    cat > /usr/local/bin/rotate_taiwan_node.sh <<'EOR'
#!/bin/bash
nodes=(
    "111.*.*.90:10001"
    "36.*.*.98:10002"
    "111.*.*.101:10003"
    "111.*.*.98:10004"
    "111.*.*.100:10005"
    "111.*.*.95:10006"
    "36.*.*.247:10007"
    "111.*.*.99:10008"
)
index=$((RANDOM % ${#nodes[@]}))
node="${nodes[$index]}"
ip="${node%%:*}"
port="${node##*:}"
sed -i "s/^  address: .*/  address: '$ip'/" /etc/tun2socks/config.yaml
sed -i "s/^  port: .*/  port: $port/" /etc/tun2socks/config.yaml
echo "✅ 已选择随机台湾家宽节点：$ip:$port"
EOR
    chmod +x /usr/local/bin/rotate_taiwan_node.sh

    step "生成 systemd 服务文件..."
    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Tun2Socks Tunnel Service
After=network.target

[Service]
Type=simple
ExecStartPre=/usr/local/bin/rotate_taiwan_node.sh
ExecStart=$BINARY_PATH $CONFIG_FILE
ExecStartPost=/bin/sleep 1
ExecStartPost=/sbin/ip rule add fwmark 438 lookup main pref 10
ExecStartPost=/sbin/ip -6 rule add fwmark 438 lookup main pref 10
ExecStartPost=/sbin/ip route add default dev tun0 table 20
ExecStartPost=/sbin/ip rule add lookup 20 pref 20
ExecStartPost=/sbin/ip rule add to 127.0.0.0/8 lookup main pref 16
ExecStartPost=/sbin/ip rule add to 10.0.0.0/8 lookup main pref 16
ExecStartPost=/sbin/ip rule add to 172.16.0.0/12 lookup main pref 16
ExecStartPost=/sbin/ip rule add to 192.168.0.0/16 lookup main pref 16
ExecStop=/sbin/ip rule del fwmark 438 lookup main pref 10
ExecStop=/sbin/ip -6 rule del fwmark 438 lookup main pref 10
ExecStop=/sbin/ip route del default dev tun0 table 20
ExecStop=/sbin/ip rule del lookup 20 pref 20
ExecStop=/sbin/ip rule del to 127.0.0.0/8 lookup main pref 16
ExecStop=/sbin/ip rule del to 10.0.0.0/8 lookup main pref 16
ExecStop=/sbin/ip rule del to 172.16.0.0/12 lookup main pref 16
ExecStop=/sbin/ip rule del to 192.168.0.0/16 lookup main pref 16
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable tun2socks.service
    systemctl start tun2socks.service
    success "安装完成 ✅ 每次启动都会自动随机选择台湾家宽节点。"
}

#================================================================================
# 卸载 & 其他函数（保留原样）
#================================================================================
cleanup_ip_rules() {
    ip rule del fwmark 438 lookup main pref 10 2>/dev/null || true
    ip -6 rule del fwmark 438 lookup main pref 10 2>/dev/null || true
    ip route del default dev tun0 table 20 2>/dev/null || true
    ip rule del lookup 20 pref 20 2>/dev/null || true
    while ip rule del pref 15 2>/dev/null; do :; done
}

uninstall_tun2socks() {
    cleanup_ip_rules
    systemctl stop tun2socks.service || true
    systemctl disable tun2socks.service || true
    rm -f /etc/systemd/system/tun2socks.service
    systemctl daemon-reload
    rm -rf /etc/tun2socks
    rm -f /usr/local/bin/tun2socks
    rm -f /usr/local/bin/rotate_taiwan_node.sh
    success "tun2socks 已彻底卸载。"
}

#================================================================================
# 主逻辑
#================================================================================
parse_options() {
    if [ $# -eq 0 ]; then
        error "请指定操作。"
        exit 1
    fi
    while [[ $# -gt 0 ]]; do
        case $1 in
            -i|--install)
                ACTION="install"
                if [[ $2 != -* ]] && [[ -n $2 ]]; then
                    MODE="$2"
                    shift 2
                else
                    shift
                fi
                ;;
            -r|--remove)
                ACTION="uninstall"
                shift
                ;;
            *)
                error "未知选项: $1"
                exit 1
                ;;
        esac
    done
}

dispatch_action() {
    case "$ACTION" in
        install) install_tun2socks ;;
        uninstall) uninstall_tun2socks ;;
        *) error "未知操作"; exit 1 ;;
    esac
}

main() {
    require_root
    parse_options "$@"
    dispatch_action
}

main "$@"
