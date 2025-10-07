#!/bin/bash
set -e

#================================================================================
# 常量和全局变量
#================================================================================
VERSION="1.1.2"
SCRIPT_URL="https://raw.githubusercontent.com/hkfires/onekey-tun2socks/main/onekey-tun2socks.sh"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m'

# 备用 DNS64 服务器 - 保持所有地址 (不移除第一个)
ALTERNATE_DNS64_SERVERS=(
    "2a00:1098:2b::1"
    "2a01:4f8:c2c:123f::1"
    "2a01:4f9:c010:3f02::1"
    "2001:67c:2b0::4"
    "2001:67c:2b0::6"
)

# 脚本操作的全局变量
ACTION=""
MODE="alice" # 默认安装模式

#================================================================================
# 日志和工具函数
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

show_usage() {
    echo -e "${CYAN}使用方法:${NC} $0 [选项]"
    echo -e "${CYAN}选项:${NC}"
    echo -e "  ${GREEN}-i, --install${NC}   安装 tun2socks (可选参数: alice, legend, 或 custom)"
    echo -e "  ${GREEN}-r, --remove${NC}    卸载 tun2socks"
    echo -e "  ${GREEN}-s, --switch${NC}    切换 Alice 模式的 Socks5 端口 (如果已安装)"
    echo -e "  ${GREEN}-u, --update${NC}    检查并更新脚本"
    echo -e "  ${GREEN}-h, --help${NC}      显示此帮助信息"
    echo
    echo -e "${CYAN}示例:${NC}"
    echo -e "  $0 -i alice   安装 Alice 版本的 tun2socks"
    echo -e "  $0 -i legend  安装 Legend 版本的 tun2socks"
    echo -e "  $0 -i custom  使用自定义出口节点安装 tun2socks"
    echo -e "  $0 -r         卸载 tun2socks"
    echo -e "  $0 -s         切换 Alice 模式的 Socks5 端口"
    echo -e "  $0 -u         检查脚本更新"
}

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
        warning "未找到 DNS 备份文件 ($resolv_conf_bak)，无法自动恢复。"
        if [ "$was_immutable" = true ]; then
             warning "尝试锁定当前的 /etc/resolv.conf (注意：内容可能不是原始配置)..."
             chattr +i "$resolv_conf" || warning "无法锁定 /etc/resolv.conf。"
        fi
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
    
    error "所有DNS64服务器测试失败，无法访问GitHub。"
    
    restore_dns_config "$resolv_conf" "$resolv_conf_bak" "$was_immutable"
    
    return 1
}

#================================================================================
# 核心逻辑函数
#================================================================================

check_for_updates() {
    step "正在检查脚本更新..."
    
    REMOTE_SCRIPT_CONTENT=$(curl -s "$SCRIPT_URL")
    if [ -z "$REMOTE_SCRIPT_CONTENT" ]; then
        error "无法从 $SCRIPT_URL 获取脚本内容。请检查网络连接或 URL 是否正确。"
        exit 1
    fi

    REMOTE_VERSION=$(echo "$REMOTE_SCRIPT_CONTENT" | grep -m 1 '^VERSION=' | cut -d '"' -f 2 | tr -d '\r')

    if [ -z "$REMOTE_VERSION" ]; then
        error "无法从远程脚本中提取版本号。"
        exit 1
    fi

    info "当前版本: $VERSION"
    info "最新版本: $REMOTE_VERSION"

    if [ "$REMOTE_VERSION" = "$VERSION" ]; then
        success "您的脚本已是最新版本。"
        exit 0
    fi

    if [ "$(printf '%s\n' "$REMOTE_VERSION" "$VERSION" | sort -V | head -n1)" = "$REMOTE_VERSION" ]; then
        success "您的脚本版本 ($VERSION) 高于远程版本 ($REMOTE_VERSION)，无需更新。"
        exit 0
    fi

    warning "发现新版本 ($REMOTE_VERSION)。"
    read -r -p "您想现在更新吗? (y/N): " response
    if [[ ! "$response" =~ ^([yY][eE][sS]|[yY])$ ]]; then
        info "更新已取消。"
        exit 0
    fi

    step "正在下载新版本..."
    TEMP_FILE="/tmp/onekey-tun2socks.sh.new"
    if ! curl -L -o "$TEMP_FILE" "$SCRIPT_URL"; then
        error "下载新版本失败。"
        rm -f "$TEMP_FILE"
        exit 1
    fi

    if ! head -n 1 "$TEMP_FILE" | grep -q "bin/bash"; then
        error "下载的文件似乎不是一个有效的脚本。更新已中止以确保安全。"
        rm -f "$TEMP_FILE"
        exit 1
    fi

    step "正在替换旧脚本..."
    SCRIPT_PATH=$(realpath "$0")
    if ! mv "$TEMP_FILE" "$SCRIPT_PATH"; then
        error "替换脚本失败。请检查权限。"
        rm -f "$TEMP_FILE"
        exit 1
    fi

    step "设置执行权限..."
    if ! chmod +x "$SCRIPT_PATH"; then
        warning "无法为新脚本设置执行权限。您可能需要手动执行 'chmod +x $SCRIPT_PATH'。"
    fi

    success "脚本已成功更新到版本 $REMOTE_VERSION。"
    info "请重新运行脚本以使用新版本: $SCRIPT_PATH"
    exit 0
}

get_custom_server_config() {
    info "进入自定义出口节点配置模式..." >&2
    
    local address port username password
    
    while true; do
        read -r -p "请输入Socks5服务器地址 (例如: 2001:db8::1 或 1.2.3.4): " address
        if [ -n "$address" ]; then
            break
        else
            error "服务器地址不能为空。" >&2
        fi
    done
    
    while true; do
        read -r -p "请输入Socks5服务器端口 (例如: 1080): " port
        if [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]; then
            break
        else
            error "无效的端口号，请输入 1 到 65535 之间的数字。" >&2
        fi
    done
    
    read -r -p "请输入用户名 (可选，留空则不使用): " username
    
    if [ -n "$username" ]; then
        read -r -p "请输入密码 (可选，留空则不使用): " password
    else
        password=""
    fi
    
    echo "$address"
    echo "$port"
    echo "$username"
    echo "$password"
}

select_alice_port() {
    # 移除 10001 端口，统一描述为“台湾家宽”，移除弃用标记和警告
    local options=(
        "台湾家宽:20000"
        "台湾家宽:30000"
        "台湾家宽:40000"
        "台湾家宽:50000"
    )
    echo >&2
    echo -e "${GREEN}=========================================================${NC}" >&2
    info "请为 Alice 模式选择 Socks5 出口端口 (统一描述为台湾家宽):" >&2
    echo -e "${GREEN}=========================================================${NC}" >&2
    echo >&2
    
    for i in "${!options[@]}"; do
        local option_text="${options[$i]%%:*}"
        local port="${options[$i]#*:}"
        # 所有选项使用正常颜色 (绿色) 打印
        printf "  %s) ${GREEN}%s (端口: %s)${NC}\n" "$((i+1))" "$option_text" "$port" >&2
    done

    local choice
    while true; do
        # 默认值仍为 1，现在对应端口 20000
        read -r -p "请输入选项 (1-${#options[@]}，默认为1): " choice
        choice=${choice:-1}
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le ${#options[@]} ]; then
            local selected_option="${options[$((choice-1))]}"
            local port="${selected_option#*:}"
            info "已选择端口: $port (${selected_option%%:*})" >&2
            echo "$port"
            return
        else
            error "无效的选择，请输入 1 到 ${#options[@]} 之间的数字。" >&2
        fi
    done
}

cleanup_ip_rules() {
    step "正在清理残留的 IP 规则和路由..."

    ip rule del fwmark 438 lookup main pref 10 2>/dev/null || true
    ip -6 rule del fwmark 438 lookup main pref 10 2>/dev/null || true
    ip route del default dev tun0 table 20 2>/dev/null || true
    ip rule del lookup 20 pref 20 2>/dev/null || true
    ip rule del to 127.0.0.0/8 lookup main pref 16 2>/dev/null || true
    ip rule del to 10.0.0.0/8 lookup main pref 16 2>/dev/null || true
    ip rule del to 172.16.0.0/12 lookup main pref 16 2>/dev/null || true
    ip rule del to 192.168.0.0/16 lookup main pref 16 2>/dev/null || true

    info "正在循环清理优先级为 15 的规则..."
    while ip rule del pref 15 2>/dev/null; do
        info "删除了一条优先级为 15 的规则。"
    done

    success "IP 规则和路由清理完成。"
}

uninstall_tun2socks() {
    cleanup_ip_rules

    SERVICE_FILE="/etc/systemd/system/tun2socks.service"
    CONFIG_DIR="/etc/tun2socks"
    BINARY_PATH="/usr/local/bin/tun2socks"

    step "正在停止并禁用 tun2socks 服务..."
    if systemctl is-active --quiet tun2socks.service; then
        systemctl stop tun2socks.service
        success "tun2socks 服务已停止。"
    else
        info "tun2socks 服务未在运行。"
    fi

    if systemctl is-enabled --quiet tun2socks.service 2>/dev/null; then
        systemctl disable tun2socks.service
        success "tun2socks 服务已禁用开机自启。"
    else
        info "tun2socks 服务未设置开机自启。"
    fi

    step "正在移除 systemd 服务文件..."
    if [ -f "$SERVICE_FILE" ]; then
        rm -f "$SERVICE_FILE"
        success "systemd 服务文件 ($SERVICE_FILE) 已删除。"
        info "重新加载 systemd 配置..."
        systemctl daemon-reload
        info "重置服务失败状态 (如果存在)..."
        systemctl reset-failed tun2socks.service &>/dev/null || true
    else
        warning "systemd 服务文件 ($SERVICE_FILE) 未找到。"
    fi

    step "正在移除配置文件和目录..."
    if [ -d "$CONFIG_DIR" ]; then
        rm -rf "$CONFIG_DIR"
        success "配置文件目录 ($CONFIG_DIR) 已删除。"
    else
        warning "配置文件目录 ($CONFIG_DIR) 未找到。"
    fi

    step "正在移除 tun2socks 二进制文件..."
    if [ -f "$BINARY_PATH" ]; then
        rm -f "$BINARY_PATH"
        success "tun2socks 二进制文件 ($BINARY_PATH) 已删除。"
    else
        warning "tun2socks 二进制文件 ($BINARY_PATH) 未找到。"
    fi

    success "卸载完成。"
}

install_tun2socks() {
    cleanup_ip_rules

    step "检查 tun2socks 服务当前状态 (准备安装)..."
    if systemctl is-active --quiet tun2socks.service; then
        info "tun2socks 服务正在运行，将在安装前停止它。"
        if systemctl stop tun2socks.service; then
            success "tun2socks 服务已成功停止。"
        else
            warning "尝试停止 tun2socks 服务失败，安装将继续，但可能遇到问题。"
        fi
    else
        info "tun2socks 服务当前未运行。"
    fi

    RESOLV_CONF="/etc/resolv.conf"
    RESOLV_CONF_BAK="/etc/resolv.conf.bak"
    WAS_IMMUTABLE=false

    step "检查 /etc/resolv.conf 锁定状态..."
    if lsattr -d "$RESOLV_CONF" 2>/dev/null | grep -q -- '-i-'; then
        info "/etc/resolv.conf 文件当前被锁定 (immutable)，尝试解锁..."
        chattr -i "$RESOLV_CONF" || { error "无法解锁 /etc/resolv.conf，请检查权限。"; exit 1; }
        WAS_IMMUTABLE=true
        success "解锁成功。"
    else
        info "/etc/resolv.conf 未被锁定。"
    fi

    step "备份当前 DNS 配置..."
    cp "$RESOLV_CONF" "$RESOLV_CONF_BAK" || { warning "备份 DNS 配置失败，可能文件不存在或权限不足。"; }

    if ! set_dns64_servers "$MODE" "$RESOLV_CONF" "$WAS_IMMUTABLE" "$RESOLV_CONF_BAK"; then
        exit 1
    fi

    REPO="heiher/hev-socks5-tunnel"
    INSTALL_DIR="/usr/local/bin"
    CONFIG_DIR="/etc/tun2socks"
    SERVICE_FILE="/etc/systemd/system/tun2socks.service"
    BINARY_PATH="$INSTALL_DIR/tun2socks"

    step "获取最新版本下载链接..."
    DOWNLOAD_URL=$(curl -s https://api.github.com/repos/$REPO/releases/latest | grep "browser_download_url" | grep "linux-x86_64" | cut -d '"' -f 4)

    if [ -z "$DOWNLOAD_URL" ]; then
        error "未找到适用于 linux-x86_64 的二进制文件下载链接，请检查网络或手动下载。"
        
        restore_dns_config "$RESOLV_CONF" "$RESOLV_CONF_BAK" "$WAS_IMMUTABLE"
        
        exit 1
    fi

    step "正在下载最新二进制文件："
    info "$DOWNLOAD_URL"
    cleanup_on_fail() {
        trap - INT TERM EXIT
        warning "操作被中断或失败，正在执行清理..."
        restore_dns_config "$RESOLV_CONF" "$RESOLV_CONF_BAK" "$WAS_IMMUTABLE"
        exit 1
    }
    trap cleanup_on_fail INT TERM EXIT
    curl -L -o "$BINARY_PATH" "$DOWNLOAD_URL"
    trap - INT TERM EXIT

    restore_dns_config "$RESOLV_CONF" "$RESOLV_CONF_BAK" "$WAS_IMMUTABLE"

    chmod +x "$BINARY_PATH"

    step "创建配置文件..."
    mkdir -p "$CONFIG_DIR"
    CONFIG_FILE="$CONFIG_DIR/config.yaml"

    if [ "$MODE" = "alice" ]; then
        SOCKS_PORT=$(select_alice_port)

        cat > "$CONFIG_FILE" <<EOF
tunnel:
  name: tun0
  mtu: 8500
  multi-queue: true
  ipv4: 198.18.0.1

socks5:
  port: $SOCKS_PORT
  address: '2a14:67c0:116::1'
  udp: 'udp'
  username: 'alice'
  password: 'alicefofo123..OVO'
  mark: 438
EOF
    elif [ "$MODE" = "custom" ]; then
        get_custom_server_config | {
            IFS= read -r SOCKS_ADDRESS
            IFS= read -r SOCKS_PORT
            IFS= read -r SOCKS_USERNAME
            IFS= read -r SOCKS_PASSWORD

            cat > "$CONFIG_FILE" <<EOF
tunnel:
  name: tun0
  mtu: 8500
  multi-queue: true
  ipv4: 198.18.0.1

socks5:
  port: $(echo "$SOCKS_PORT" | tr -d '\r')
  address: '$(echo "$SOCKS_ADDRESS" | tr -d '\r')'
  udp: 'udp'
$( [ -n "$SOCKS_USERNAME" ] && echo "  username: '$(echo "$SOCKS_USERNAME" | tr -d '\r')'" )
$( [ -n "$SOCKS_PASSWORD" ] && echo "  password: '$(echo "$SOCKS_PASSWORD" | tr -d '\r')'" )
  mark: 438
EOF
        }
    else
        cat > "$CONFIG_FILE" <<'EOF'
tunnel:
  name: tun0
  mtu: 8500
  multi-queue: true
  ipv4: 198.18.0.1

socks5:
  port: 8888
  address: '2001:db8:1234::6666'
  udp: 'udp'
  mark: 438
EOF
    fi

    step "生成 systemd 服务文件 (tun2socks.service)..."
    
    if [ "$MODE" = "alice" ]; then
        MAIN_IP=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}')
        RULE_ADD_FROM_MAIN_IP=""
        RULE_DEL_FROM_MAIN_IP=""

        if [ -n "$MAIN_IP" ]; then
            info "检测到 IPv4 地址: $MAIN_IP"
            info "将添加规则以允许源 IP 为 $MAIN_IP 的流量通过主路由表。"
            RULE_ADD_FROM_MAIN_IP="ExecStartPost=/sbin/ip rule add from $MAIN_IP lookup main pref 15"
            RULE_DEL_FROM_MAIN_IP="ExecStop=/sbin/ip rule del from $MAIN_IP lookup main pref 15"
        fi
    fi

    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Tun2Socks Tunnel Service
After=network.target

[Service]
Type=simple
ExecStart=$BINARY_PATH $CONFIG_FILE
ExecStartPost=/bin/sleep 1

ExecStartPost=/sbin/ip rule add fwmark 438 lookup main pref 10
ExecStartPost=/sbin/ip -6 rule add fwmark 438 lookup main pref 10
ExecStartPost=/sbin/ip route add default dev tun0 table 20
ExecStartPost=/sbin/ip rule add lookup 20 pref 20
${RULE_ADD_FROM_MAIN_IP}
ExecStartPost=/sbin/ip rule add to 127.0.0.0/8 lookup main pref 16
ExecStartPost=/sbin/ip rule add to 10.0.0.0/8 lookup main pref 16
ExecStartPost=/sbin/ip rule add to 172.16.0.0/12 lookup main pref 16
ExecStartPost=/sbin/ip rule add to 192.168.0.0/16 lookup main pref 16

ExecStop=/sbin/ip rule del fwmark 438 lookup main pref 10
ExecStop=/sbin/ip -6 rule del fwmark 438 lookup main pref 10
ExecStop=/sbin/ip route del default dev tun0 table 20
ExecStop=/sbin/ip rule del lookup 20 pref 20
${RULE_DEL_FROM_MAIN_IP}
ExecStop=/sbin/ip rule del to 127.0.0.0/8 lookup main pref 16
ExecStop=/sbin/ip rule del to 10.0.0.0/8 lookup main pref 16
ExecStop=/sbin/ip rule del to 172.16.0.0/12 lookup main pref 16
ExecStop=/sbin/ip rule del to 192.168.0.0/16 lookup main pref 16

Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

    step "重新加载 systemd 配置..."
    systemctl daemon-reload

    step "设置服务开机自启动..."
    systemctl enable tun2socks.service 2>/dev/null

    step "启动服务..."
    systemctl start tun2socks.service

    success "安装完成！"
    echo
    info "服务管理命令："
    echo -e "  ${GREEN}查看状态${NC}：systemctl status tun2socks.service"
    echo -e "  ${GREEN}启动服务${NC}：systemctl start tun2socks.service"
    echo -e "  ${GREEN}停止服务${NC}：systemctl stop tun2socks.service"
    echo -e "  ${GREEN}重启服务${NC}：systemctl restart tun2socks.service"
    echo -e "  ${GREEN}查看日志${NC}：journalctl -u tun2socks.service"
    echo -e "  ${GREEN}实时查看日志${NC}：journalctl -u tun2socks.service -f"
    echo
    info "配置文件位置："
    echo -e "  ${GREEN}服务配置${NC}：/etc/systemd/system/tun2socks.service"
    echo -e "  ${GREEN}程序配置${NC}：/etc/tun2socks/config.yaml"
    echo -e "  ${GREEN}程序位置${NC}：/usr/local/bin/tun2socks"
    echo
    info "如需卸载，请运行：$0 -r"
}

switch_alice_port() {
    CONFIG_FILE="/etc/tun2socks/config.yaml"
    step "开始切换 Alice 模式 Socks5 端口..."

    if [ ! -f "$CONFIG_FILE" ]; then
        error "配置文件 $CONFIG_FILE 未找到。请先运行安装命令。"
        exit 1
    fi

    if ! grep -q "username: 'alice'" "$CONFIG_FILE"; then
        error "此切换功能仅适用于 Alice 模式的配置。"
        info "Legend 和 Custom 模式的配置需要手动修改: $CONFIG_FILE"
        exit 1
    fi

    current_port=$(grep -oP 'port: \K[0-9]+' "$CONFIG_FILE" | head -n 1)
    if [ -z "$current_port" ]; then
        error "无法从配置文件中读取当前端口。"
        exit 1
    fi
    info "当前 Socks5 端口: $current_port"

    NEW_SOCKS_PORT=$(select_alice_port)

    if [ "$NEW_SOCKS_PORT" = "$current_port" ]; then
        info "选择的端口 ($NEW_SOCKS_PORT) 与当前配置相同，无需更改。"
        exit 0
    fi

    step "正在停止 tun2socks 服务..."
    if systemctl stop tun2socks.service; then
        success "tun2socks 服务已停止。"
    else
        error "停止 tun2socks 服务失败。请检查服务状态。"
    fi

    step "正在更新配置文件 $CONFIG_FILE ..."
    # 使用 \b 确保只替换整个单词/数字，避免误伤其他配置
    sed -i "s/\bport: $current_port\b/port: $NEW_SOCKS_PORT/" "$CONFIG_FILE"
    if grep -q "port: $NEW_SOCKS_PORT" "$CONFIG_FILE"; then
        success "配置文件已更新，新端口为: $NEW_SOCKS_PORT"
    else
        error "更新配置文件失败。请检查 $CONFIG_FILE 文件。"
        warning "正在尝试以旧配置重启服务..."
        systemctl start tun2socks.service
        exit 1
    fi
    
    step "正在启动 tun2socks 服务..."
    if systemctl start tun2socks.service; then
        success "tun2socks 服务已启动。"
        success "Socks5 端口已成功切换至 $NEW_SOCKS_PORT。"
    else
        error "启动 tun2socks 服务失败。请使用 'systemctl status tun2socks.service' 和 'journalctl -u tun2socks.service' 查看详情。"
        error "配置文件可能已更新为新端口 $NEW_SOCKS_PORT，但服务启动失败。"
        exit 1
    fi
}

#================================================================================
# 主执行逻辑
#================================================================================

parse_options() {
    local option_count=0
    
    if [ $# -eq 0 ]; then
        error "请指定一个操作。使用 -h 或 --help 查看帮助。"
        exit 1
    fi

    while [[ $# -gt 0 ]]; do
        case $1 in
            -i|--install)
                option_count=$((option_count + 1))
                ACTION="install"
                if [[ $2 != -* ]] && [[ -n $2 ]]; then
                    MODE="$2"
                    shift 2
                else
                    shift
                fi
                ;;
            -r|--remove)
                option_count=$((option_count + 1))
                ACTION="uninstall"
                shift
                ;;
            -s|--switch)
                option_count=$((option_count + 1))
                ACTION="switch"
                shift
                ;;
            -u|--update)
                option_count=$((option_count + 1))
                ACTION="update"
                shift
                ;;
            -h|--help)
                show_usage
                exit 0
                ;;
            *)
                error "未知选项: $1"
                show_usage
                exit 1
                ;;
        esac
    done

    if [ "$option_count" -gt 1 ]; then
        error "请仅指定一个主要操作: 安装 (-i), 卸载 (-r), 切换端口 (-s), 或更新 (-u)"
        show_usage
        exit 1
    fi
}

dispatch_action() {
    case "$ACTION" in
        install)
            if [ "$MODE" != "alice" ] && [ "$MODE" != "legend" ] && [ "$MODE" != "custom" ]; then
                error "无效的安装模式 '$MODE'，请使用 'alice', 'legend' 或 'custom'"
                exit 1
            fi
            install_tun2socks
            ;;
        uninstall)
            uninstall_tun2socks
            ;;
        switch)
            switch_alice_port
            ;;
        update)
            check_for_updates
            ;;
        *)
            error "没有指定操作或操作无效。"
            show_usage
            exit 1
            ;;
    esac
}

main() {
    require_root
    parse_options "$@"
    dispatch_action
}

# 脚本入口点
main "$@"
