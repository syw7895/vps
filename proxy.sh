#!/usr/bin/env bash
# ============================================================
# VPS proxy helper for Debian / Ubuntu
# 功能：Hysteria2 + VLESS REALITY（安装/卸载/查看配置/查看状态）
# ============================================================

set -Eeuo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

HY2_BIN="/usr/local/bin/hysteria"
HY2_CMD="/usr/local/bin/hy2"
HY2_DIR="/etc/hysteria"
HY2_CONFIG="${HY2_DIR}/config.yaml"
HY2_STATE="${HY2_DIR}/hy2-install.env"
HY2_CERT="${HY2_DIR}/server.crt"
HY2_KEY="${HY2_DIR}/server.key"
HY2_SERVICE="hysteria-server"
HY2_RULE_COMMENT="hy2-port-hop"
DEFAULT_MASQUERADE_URL="https://www.bing.com"
DEFAULT_SNI="www.bing.com"

XRAY_CONFIG="/usr/local/etc/xray/config.json"
XRAY_STATE="/etc/xray-reality.env"
XRAY_SERVICE="xray"
XRAY_DEFAULT_PORT="443"
XRAY_DEFAULT_SNI="www.microsoft.com"
XRAY_DEFAULT_TARGET="www.microsoft.com:443"

info()    { echo -e "${CYAN}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

on_error() {
    local line="$1"
    local code="$2"
    error "脚本在第 ${line} 行失败，退出码：${code}"
}
trap 'on_error "$LINENO" "$?"' ERR

usage() {
    cat <<'EOF'
VPS 代理综合管理脚本（Hysteria2 + VLESS REALITY）

用法：
  sudo bash proxy.sh                    打开交互菜单
  sudo bash proxy.sh --install-hy2      安装或重装 Hysteria2
  sudo bash proxy.sh --uninstall-hy2    卸载 Hysteria2
  sudo bash proxy.sh --view-hy2         查看 Hysteria2 配置
  sudo bash proxy.sh --status-hy2       查看 Hysteria2 状态

  sudo bash proxy.sh --install-xray     安装或重装 VLESS REALITY
  sudo bash proxy.sh --uninstall-xray   卸载 VLESS REALITY
  sudo bash proxy.sh --view-xray        查看 VLESS REALITY 配置
  sudo bash proxy.sh --status-xray      查看 VLESS REALITY 状态

  bash proxy.sh --help                  查看帮助

说明：
  - 支持 Debian / Ubuntu。
  - Hysteria2 端口跳跃通过 iptables REDIRECT 实现。
EOF
}

require_root() {
    [[ "${EUID}" -eq 0 ]] || error "请用 root 用户运行此脚本"
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

check_os() {
    if [[ ! -r /etc/os-release ]]; then
        warn "无法识别系统版本，将继续尝试运行。"
        return
    fi

    # shellcheck disable=SC1091
    source /etc/os-release
    case "${ID:-}" in
        debian|ubuntu)
            ;;
        *)
            warn "当前系统是 ${PRETTY_NAME:-未知系统}，脚本主要适配 Debian / Ubuntu。"
            ;;
    esac
}

require_commands() {
    local missing=()
    local cmd

    for cmd in awk curl grep ip iptables openssl sed sort systemctl; do
        command_exists "$cmd" || missing+=("$cmd")
    done

    if ((${#missing[@]} > 0)); then
        error "缺少必要命令：${missing[*]}。请先安装后再运行。"
    fi
}

validate_port() {
    local value="$1"
    [[ "$value" =~ ^[0-9]+$ ]] || return 1
    ((value >= 1 && value <= 65535))
}

validate_port_range() {
    local start="$1"
    local end="$2"
    local listen_port="$3"

    validate_port "$start" || return 1
    validate_port "$end" || return 1
    ((start < end)) || return 1

    if ((listen_port >= start && listen_port <= end)); then
        return 1
    fi

    return 0
}

validate_sni() {
    local value="$1"
    [[ ${#value} -le 253 ]] || return 1
    [[ "$value" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$ ]]
}

yaml_single_quote() {
    printf "'%s'" "$(printf '%s' "$1" | sed "s/'/''/g")"
}

generate_password() {
    openssl rand -base64 18 | tr -dc 'A-Za-z0-9' | head -c 18
}

generate_sni() {
    local token
    token=$(openssl rand -hex 4)
    printf 'www.%s.com' "$token"
}

get_public_ip() {
    local ip=""

    ip=$(curl -fsS4 --max-time 8 https://api.ipify.org 2>/dev/null || true)
    if [[ -z "$ip" ]]; then
        ip=$(curl -fsS4 --max-time 8 https://ifconfig.me 2>/dev/null || true)
    fi

    printf '%s' "$ip"
}

get_default_nic() {
    local nic=""

    nic=$(ip route get 8.8.8.8 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -n 1)
    printf '%s' "${nic:-eth0}"
}

install_shortcut() {
    local script_path

    script_path=$(readlink -f "$0")
    if [[ "$script_path" != "$HY2_CMD" ]]; then
        install -m 0755 "$script_path" "$HY2_CMD"
        success "全局快捷命令已生效：输入 ${YELLOW}hy2${NC} 即可打开菜单。"
    fi
}

download_and_install_hysteria() {
    local installer

    installer=$(mktemp)
    info "下载 Hysteria 2 官方安装脚本..."
    curl -fsSL https://get.hy2.sh/ -o "$installer" || {
        rm -f "$installer"
        error "下载安装脚本失败，请检查网络或稍后重试。"
    }

    info "安装 Hysteria 2 核心组件..."
    bash "$installer" || {
        rm -f "$installer"
        error "Hysteria 2 安装失败。"
    }

    rm -f "$installer"
}

write_config() {
    local port="$1"
    local password="$2"
    local sni="$3"
    local password_yaml

    password_yaml=$(yaml_single_quote "$password")
    install -d -m 0755 "$HY2_DIR"

    openssl req -x509 -nodes -newkey ec \
        -pkeyopt ec_paramgen_curve:P-256 \
        -keyout "$HY2_KEY" \
        -out "$HY2_CERT" \
        -days 3650 \
        -subj "/CN=${sni}" >/dev/null 2>&1

    chown hysteria:hysteria "$HY2_KEY" "$HY2_CERT" 2>/dev/null || true
    chmod 644 "$HY2_CERT"
    chmod 600 "$HY2_KEY"

    cat > "$HY2_CONFIG" <<EOF
listen: :${port}
tls:
  cert: ${HY2_CERT}
  key: ${HY2_KEY}
auth:
  type: password
  password: ${password_yaml}
masquerade:
  type: proxy
  proxy:
    url: ${DEFAULT_MASQUERADE_URL}
    rewriteHost: true
quic:
  initStreamReceiveWindow: 26843545
  maxStreamReceiveWindow: 26843545
  initConnReceiveWindow: 67108864
  maxConnReceiveWindow: 67108864
EOF

    chown hysteria:hysteria "$HY2_CONFIG" 2>/dev/null || true
    chmod 640 "$HY2_CONFIG"
}

write_state() {
    local port="$1"
    local hop_start="$2"
    local hop_end="$3"
    local password="$4"
    local nic="$5"
    local sni="$6"

    {
        printf 'PORT=%q\n' "$port"
        printf 'HOP_START=%q\n' "$hop_start"
        printf 'HOP_END=%q\n' "$hop_end"
        printf 'PASSWORD=%q\n' "$password"
        printf 'NIC=%q\n' "$nic"
        printf 'SNI=%q\n' "$sni"
    } > "$HY2_STATE"

    chmod 600 "$HY2_STATE"
}

cleanup_hy2_iptables_rules() {
    local line

    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        iptables -t nat -D PREROUTING "$line" >/dev/null 2>&1 || true
    done < <(
        iptables -t nat -L PREROUTING --line-numbers -n -v 2>/dev/null |
            awk -v comment="$HY2_RULE_COMMENT" '$0 ~ comment {print $1}' |
            sort -rn
    )
}

add_hy2_iptables_rule() {
    local nic="$1"
    local hop_start="$2"
    local hop_end="$3"
    local port="$4"

    cleanup_hy2_iptables_rules

    iptables -t nat -A PREROUTING \
        -i "$nic" \
        -p udp \
        --dport "${hop_start}:${hop_end}" \
        -m comment --comment "$HY2_RULE_COMMENT" \
        -j REDIRECT --to-ports "$port"
}

save_iptables_rules() {
    if ! command_exists netfilter-persistent; then
        command_exists apt-get || {
            warn "未找到 apt-get，无法自动安装 iptables-persistent。"
            return
        }

        info "安装 iptables-persistent 用于保存端口跳跃规则..."
        DEBIAN_FRONTEND=noninteractive apt-get update >/dev/null
        DEBIAN_FRONTEND=noninteractive apt-get install -y iptables-persistent >/dev/null
    fi

    netfilter-persistent save >/dev/null 2>&1 || warn "iptables 规则保存失败，重启后可能失效。"
}

configure_firewall() {
    local port="$1"
    local hop_start="$2"
    local hop_end="$3"

    info "配置系统防火墙..."
    if command_exists ufw; then
        ufw allow "${port}/udp" >/dev/null 2>&1 || true
        ufw allow "${hop_start}:${hop_end}/udp" >/dev/null 2>&1 || true
        ufw reload >/dev/null 2>&1 || true
    elif command_exists firewall-cmd; then
        firewall-cmd --permanent --add-port="${port}/udp" >/dev/null 2>&1 || true
        firewall-cmd --permanent --add-port="${hop_start}-${hop_end}/udp" >/dev/null 2>&1 || true
        firewall-cmd --reload >/dev/null 2>&1 || true
    else
        warn "未检测到 ufw 或 firewalld，已跳过系统防火墙放行。"
    fi
}

install_hy2() {
    local rand_port port hop_start hop_end password nic sni default_sni

    echo -e "\n${CYAN}>>> 开始执行安装流程...${NC}\n"

    rand_port=$(shuf -i 10000-65535 -n 1 2>/dev/null || echo 30000)
    read -r -p "请输入主监听端口（建议 10000-65535，回车默认随机 ${rand_port}）: " port
    port=${port:-$rand_port}
    validate_port "$port" || error "主监听端口无效，范围必须是 1-65535。"

    read -r -p "请输入端口跳跃范围起始（回车默认 20000）: " hop_start
    hop_start=${hop_start:-20000}
    read -r -p "请输入端口跳跃范围结束（回车默认 40000）: " hop_end
    hop_end=${hop_end:-40000}
    validate_port_range "$hop_start" "$hop_end" "$port" || error "跳跃范围无效：需为 1-65535，起始小于结束，且不能包含主监听端口。"

    read -r -p "请输入认证密码（回车随机生成，仅建议字母数字）: " password
    if [[ -z "$password" ]]; then
        password=$(generate_password)
        info "已随机生成密码：$password"
    fi

    default_sni="${DEFAULT_SNI}"
    info "SNI/证书域名支持自定义；如果暂时只是测试，直接回车即可。"
    read -r -p "请输入 SNI/证书域名 [默认: ${default_sni}]: " sni
    sni=${sni:-$default_sni}
    validate_sni "$sni" || error "SNI/证书域名格式无效，请输入类似 example.com 或 www.example.com 的域名。"

    download_and_install_hysteria

    info "生成证书并写入配置..."
    write_config "$port" "$password" "$sni"

    configure_firewall "$port" "$hop_start" "$hop_end"

    info "配置 iptables 端口跳跃规则..."
    nic=$(get_default_nic)
    add_hy2_iptables_rule "$nic" "$hop_start" "$hop_end" "$port"
    save_iptables_rules
    write_state "$port" "$hop_start" "$hop_end" "$password" "$nic" "$sni"

    systemctl enable --now "$HY2_SERVICE" >/dev/null 2>&1
    sleep 2

    if systemctl is-active --quiet "$HY2_SERVICE"; then
        success "Hysteria 2 启动成功！"
        warn "如果使用云服务器，请在云服务商安全组中放行 UDP ${port} 以及 UDP ${hop_start}-${hop_end}。"
    else
        error "启动失败，请运行 journalctl -u ${HY2_SERVICE} -f 查看日志。"
    fi

    view_config
}

uninstall_hy2() {
    local confirm

    echo -e "\n${YELLOW}>>> 警告：准备执行彻底卸载清理！${NC}"
    read -r -p "确认卸载吗？(y/N): " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        info "已取消卸载。"
        return
    fi

    info "停止并禁用服务..."
    systemctl stop "$HY2_SERVICE" >/dev/null 2>&1 || true
    systemctl disable "$HY2_SERVICE" >/dev/null 2>&1 || true
    rm -f "/etc/systemd/system/${HY2_SERVICE}.service"
    systemctl daemon-reload >/dev/null 2>&1 || true

    info "只清理本脚本创建的 iptables 规则..."
    cleanup_hy2_iptables_rules
    if command_exists netfilter-persistent; then
        netfilter-persistent save >/dev/null 2>&1 || true
    fi

    info "清理二进制文件与配置..."
    rm -f "$HY2_BIN"
    rm -rf "$HY2_DIR"

    info "移除全局命令 hy2..."
    rm -f "$HY2_CMD"

    success "Hysteria 2 及其全局命令已卸载清理。"
}

load_state_if_exists() {
    if [[ -f "$HY2_STATE" ]]; then
        # shellcheck disable=SC1090
        source "$HY2_STATE"
    fi
}

parse_config_value() {
    local key="$1"
    grep -E "^[[:space:]]*${key}:" "$HY2_CONFIG" | head -n 1 | awk -F': ' '{print $2}' | sed "s/^'//; s/'$//; s/''/'/g"
}

parse_cert_cn() {
    [[ -f "$HY2_CERT" ]] || return 0
    openssl x509 -noout -subject -in "$HY2_CERT" 2>/dev/null |
        sed -n 's/.*CN[[:space:]]*=[[:space:]]*\([^,/]*\).*/\1/p' |
        head -n 1
}

view_config() {
    local server_ip port password sni hop_range port_str mport_str

    echo -e "\n${CYAN}>>> 正在读取当前配置...${NC}"

    if [[ ! -f "$HY2_CONFIG" ]]; then
        warn "未检测到 Hysteria 2 配置文件，系统可能尚未安装。"
        return
    fi

    load_state_if_exists

    port="${PORT:-$(grep '^listen:' "$HY2_CONFIG" | tr -dc '0-9')}"
    password="${PASSWORD:-$(parse_config_value password)}"
    sni="${SNI:-$(parse_cert_cn)}"
    sni="${sni:-请填写安装时使用的 SNI}"

    if [[ -n "${HOP_START:-}" && -n "${HOP_END:-}" ]]; then
        hop_range="${HOP_START}-${HOP_END}"
    else
        hop_range=$(iptables -t nat -S PREROUTING 2>/dev/null |
            grep -- "$HY2_RULE_COMMENT" |
            awk '{for(i=1;i<=NF;i++) if($i=="--dport") print $(i+1)}' |
            head -n 1 |
            tr ':' '-' || true)
    fi

    if [[ -n "$hop_range" ]]; then
        port_str="${port},${hop_range}"
        mport_str="/?mport=${hop_range}&"
    else
        hop_range="未开启或解析失败"
        port_str="${port}"
        mport_str="/?"
    fi

    server_ip=$(get_public_ip)
    if [[ -z "$server_ip" ]]; then
        server_ip="请手动填写服务器公网 IP"
    fi

    echo -e "\n${GREEN}================================================${NC}"
    echo -e "${GREEN}           Hysteria 2 节点配置信息${NC}"
    echo -e "${GREEN}================================================${NC}"
    echo -e "  ${CYAN}服务器 IP  :${NC} ${server_ip}"
    echo -e "  ${CYAN}主端口     :${NC} ${port}"
    echo -e "  ${CYAN}跳跃范围   :${NC} ${hop_range}"
    echo -e "  ${CYAN}密码       :${NC} ${password}"
    echo -e "  ${CYAN}SNI        :${NC} ${sni}"
    echo -e "\n${YELLOW}[推荐] 一键导入链接（复制后在 v2rayN 按 Ctrl+O）：${NC}"
    echo -e "hysteria2://${password}@${server_ip}:${port}${mport_str}insecure=1&sni=${sni}#Hytron-Hy2"
    echo -e "\n${YELLOW}V2RayN 手动填写方式：${NC}"
    echo -e "  地址(address)      -> ${server_ip}"
    echo -e "  端口(port)         -> ${port_str}"
    echo -e "  密码(password)     -> ${password}"
    echo -e "  SNI                -> ${sni}"
    echo -e "  跳过证书验证       -> ${RED}勾选${NC}"
    echo -e "${GREEN}================================================${NC}\n"
}

view_status() {
    local active_status enabled_status listen_info recent_logs

    echo -e "\n${CYAN}>>> 正在检查 Hysteria 2 运行状态...${NC}"

    if ! command_exists systemctl; then
        warn "当前系统不支持 systemctl，无法查看服务状态。"
        return
    fi

    if ! systemctl list-unit-files | grep -q "^${HY2_SERVICE}\.service"; then
        warn "未检测到 ${HY2_SERVICE} 服务，系统可能尚未安装。"
        return
    fi

    active_status=$(systemctl is-active "$HY2_SERVICE" 2>/dev/null || true)
    enabled_status=$(systemctl is-enabled "$HY2_SERVICE" 2>/dev/null || true)
    listen_info=$(ss -lunp 2>/dev/null | grep 'hysteria' || true)
    recent_logs=$(journalctl -u "$HY2_SERVICE" -n 8 --no-pager 2>/dev/null || true)

    echo -e "\n${GREEN}================================================${NC}"
    echo -e "${GREEN}           Hysteria 2 运行状态${NC}"
    echo -e "${GREEN}================================================${NC}"
    echo -e "  ${CYAN}服务状态    :${NC} ${active_status:-unknown}"
    echo -e "  ${CYAN}开机自启    :${NC} ${enabled_status:-unknown}"

    if [[ -f "$HY2_CONFIG" ]]; then
        echo -e "  ${CYAN}配置文件    :${NC} 已找到 (${HY2_CONFIG})"
    else
        echo -e "  ${CYAN}配置文件    :${NC} 未找到"
    fi

    echo -e "\n${YELLOW}监听信息：${NC}"
    if [[ -n "$listen_info" ]]; then
        echo "$listen_info"
    else
        echo "未检测到 hysteria 监听端口。"
    fi

    if [[ -n "$recent_logs" ]]; then
        echo -e "\n${YELLOW}最近日志：${NC}"
        echo "$recent_logs"
    fi

    echo -e "${GREEN}================================================${NC}\n"
}

download_and_install_xray() {
    info "安装/更新 Xray Core..."
    bash -c "$(curl -LfsS https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install || {
        error "Xray 安装失败。"
    }
}

random_uuid() {
    if command_exists xray; then
        xray uuid
    elif command_exists uuidgen; then
        uuidgen
    elif [[ -r /proc/sys/kernel/random/uuid ]]; then
        cat /proc/sys/kernel/random/uuid
    else
        error "无法生成 UUID。"
    fi
}

generate_reality_keys() {
    local key_output private_key public_key
    key_output="$(xray x25519)"
    private_key="$(printf '%s\n' "$key_output" | awk -F': ' '/PrivateKey|Private key/ {print $2; exit}')"
    public_key="$(printf '%s\n' "$key_output" | awk -F': ' '/Password \(PublicKey\)|Public key/ {print $2; exit}')"
    [[ -n "$private_key" && -n "$public_key" ]] || error "REALITY 密钥生成失败。"
    printf '%s\n%s\n' "$private_key" "$public_key"
}

random_short_id() {
    openssl rand -hex 8
}

configure_firewall_xray() {
    local port="$1"
    if command_exists ufw; then
        ufw allow "${port}/tcp" >/dev/null 2>&1 || true
        ufw reload >/dev/null 2>&1 || true
    elif command_exists firewall-cmd; then
        firewall-cmd --permanent --add-port="${port}/tcp" >/dev/null 2>&1 || true
        firewall-cmd --reload >/dev/null 2>&1 || true
    else
        warn "未检测到 ufw 或 firewalld，已跳过 Xray 防火墙放行。"
    fi
}

write_xray_state() {
    local port="$1"
    local uuid="$2"
    local sni="$3"
    local target="$4"
    local public_key="$5"
    local short_id="$6"
    local server_ip="$7"
    {
        printf 'XRAY_PORT=%q\n' "$port"
        printf 'XRAY_UUID=%q\n' "$uuid"
        printf 'XRAY_SNI=%q\n' "$sni"
        printf 'XRAY_TARGET=%q\n' "$target"
        printf 'XRAY_PUBLIC_KEY=%q\n' "$public_key"
        printf 'XRAY_SHORT_ID=%q\n' "$short_id"
        printf 'XRAY_SERVER_IP=%q\n' "$server_ip"
    } > "$XRAY_STATE"
    chmod 600 "$XRAY_STATE"
}

load_xray_state_if_exists() {
    if [[ -f "$XRAY_STATE" ]]; then
        # shellcheck disable=SC1090
        source "$XRAY_STATE"
    fi
}

install_xray_reality() {
    local port sni target uuid short_id keys private_key public_key server_ip link

    echo -e "\n${CYAN}>>> 开始安装 VLESS + REALITY...${NC}\n"

    read -r -p "请输入 Xray 监听端口（默认 ${XRAY_DEFAULT_PORT}）: " port
    port="${port:-$XRAY_DEFAULT_PORT}"
    validate_port "$port" || error "Xray 端口无效，范围必须是 1-65535。"

    read -r -p "请输入 REALITY SNI [默认: ${XRAY_DEFAULT_SNI}]: " sni
    sni="${sni:-$XRAY_DEFAULT_SNI}"
    validate_sni "$sni" || error "SNI 格式无效。"

    read -r -p "请输入 REALITY target [默认: ${XRAY_DEFAULT_TARGET}]: " target
    target="${target:-$XRAY_DEFAULT_TARGET}"
    [[ "$target" == *:* ]] || error "target 格式无效，应为 host:port。"

    download_and_install_xray

    uuid="$(random_uuid)"
    short_id="$(random_short_id)"
    keys="$(generate_reality_keys)"
    private_key="$(printf '%s\n' "$keys" | sed -n '1p')"
    public_key="$(printf '%s\n' "$keys" | sed -n '2p')"
    server_ip="$(get_public_ip)"
    [[ -n "$server_ip" ]] || server_ip="请手动填写服务器公网 IP"

    info "写入 Xray REALITY 配置..."
    cat > "$XRAY_CONFIG" <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "tag": "vless-reality",
      "listen": "0.0.0.0",
      "port": ${port},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${uuid}",
            "flow": "xtls-rprx-vision",
            "email": "user"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "raw",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "target": "${target}",
          "xver": 0,
          "serverNames": [
            "${sni}"
          ],
          "privateKey": "${private_key}",
          "shortIds": [
            "${short_id}"
          ]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls",
          "quic"
        ]
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    },
    {
      "protocol": "blackhole",
      "tag": "block"
    }
  ]
}
EOF

    xray run -test -config "$XRAY_CONFIG" || error "Xray 配置测试失败。"
    systemctl enable --now "$XRAY_SERVICE" >/dev/null 2>&1 || error "Xray 服务启动失败。"
    configure_firewall_xray "$port"
    write_xray_state "$port" "$uuid" "$sni" "$target" "$public_key" "$short_id" "$server_ip"

    link="vless://${uuid}@${server_ip}:${port}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${sni}&fp=chrome&pbk=${public_key}&sid=${short_id}&type=tcp&headerType=none#Xray-Reality"

    echo -e "\n${GREEN}================================================${NC}"
    echo -e "${GREEN}        VLESS + REALITY 节点配置信息${NC}"
    echo -e "${GREEN}================================================${NC}"
    echo -e "  ${CYAN}服务器 IP  :${NC} ${server_ip}"
    echo -e "  ${CYAN}端口        :${NC} ${port}"
    echo -e "  ${CYAN}UUID        :${NC} ${uuid}"
    echo -e "  ${CYAN}SNI         :${NC} ${sni}"
    echo -e "  ${CYAN}Target      :${NC} ${target}"
    echo -e "  ${CYAN}Public Key  :${NC} ${public_key}"
    echo -e "  ${CYAN}Short ID    :${NC} ${short_id}"
    echo -e "\n${YELLOW}[推荐] 一键导入链接：${NC}"
    echo -e "${link}"
    echo -e "${GREEN}================================================${NC}\n"
}

uninstall_xray_reality() {
    local confirm
    echo -e "\n${YELLOW}>>> 警告：准备卸载 Xray！${NC}"
    read -r -p "确认卸载吗？(y/N): " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        info "已取消卸载。"
        return
    fi

    load_xray_state_if_exists
    if [[ -n "${XRAY_PORT:-}" ]]; then
        if command_exists ufw; then
            ufw delete allow "${XRAY_PORT}/tcp" >/dev/null 2>&1 || true
        elif command_exists firewall-cmd; then
            firewall-cmd --permanent --remove-port="${XRAY_PORT}/tcp" >/dev/null 2>&1 || true
            firewall-cmd --reload >/dev/null 2>&1 || true
        fi
    fi

    bash -c "$(curl -LfsS https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ remove --purge || true
    rm -f "$XRAY_STATE"
    success "Xray REALITY 已卸载。"
}

view_xray_config() {
    local port uuid sni target public_key short_id server_ip link
    load_xray_state_if_exists

    port="${XRAY_PORT:-}"
    uuid="${XRAY_UUID:-}"
    sni="${XRAY_SNI:-}"
    target="${XRAY_TARGET:-}"
    public_key="${XRAY_PUBLIC_KEY:-}"
    short_id="${XRAY_SHORT_ID:-}"
    server_ip="${XRAY_SERVER_IP:-$(get_public_ip)}"

    if [[ -z "$port" || -z "$uuid" || -z "$public_key" ]]; then
        warn "未找到 Xray 节点信息，请先安装。"
        return
    fi

    link="vless://${uuid}@${server_ip}:${port}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${sni}&fp=chrome&pbk=${public_key}&sid=${short_id}&type=tcp&headerType=none#Xray-Reality"

    echo -e "\n${GREEN}================================================${NC}"
    echo -e "${GREEN}        VLESS + REALITY 节点配置信息${NC}"
    echo -e "${GREEN}================================================${NC}"
    echo -e "  ${CYAN}服务器 IP  :${NC} ${server_ip}"
    echo -e "  ${CYAN}端口        :${NC} ${port}"
    echo -e "  ${CYAN}UUID        :${NC} ${uuid}"
    echo -e "  ${CYAN}SNI         :${NC} ${sni}"
    echo -e "  ${CYAN}Target      :${NC} ${target}"
    echo -e "  ${CYAN}Public Key  :${NC} ${public_key}"
    echo -e "  ${CYAN}Short ID    :${NC} ${short_id}"
    echo -e "\n${YELLOW}[推荐] 一键导入链接：${NC}"
    echo -e "${link}"
    echo -e "${GREEN}================================================${NC}\n"
}

view_xray_status() {
    local active_status enabled_status listen_info recent_logs

    echo -e "\n${CYAN}>>> 正在检查 VLESS REALITY（Xray）运行状态...${NC}"
    if ! command_exists systemctl; then
        warn "当前系统不支持 systemctl，无法查看服务状态。"
        return
    fi

    if ! systemctl list-unit-files | grep -q "^${XRAY_SERVICE}\.service"; then
        warn "未检测到 ${XRAY_SERVICE} 服务，系统可能尚未安装。"
        return
    fi

    active_status=$(systemctl is-active "$XRAY_SERVICE" 2>/dev/null || true)
    enabled_status=$(systemctl is-enabled "$XRAY_SERVICE" 2>/dev/null || true)
    listen_info=$(ss -lntp 2>/dev/null | grep 'xray' || true)
    recent_logs=$(journalctl -u "$XRAY_SERVICE" -n 8 --no-pager 2>/dev/null || true)

    echo -e "\n${GREEN}================================================${NC}"
    echo -e "${GREEN}           VLESS REALITY 运行状态${NC}"
    echo -e "${GREEN}================================================${NC}"
    echo -e "  ${CYAN}服务状态    :${NC} ${active_status:-unknown}"
    echo -e "  ${CYAN}开机自启    :${NC} ${enabled_status:-unknown}"
    if [[ -f "$XRAY_CONFIG" ]]; then
        echo -e "  ${CYAN}配置文件    :${NC} 已找到 (${XRAY_CONFIG})"
    else
        echo -e "  ${CYAN}配置文件    :${NC} 未找到"
    fi

    echo -e "\n${YELLOW}监听信息：${NC}"
    if [[ -n "$listen_info" ]]; then
        echo "$listen_info"
    else
        echo "未检测到 xray 监听端口。"
    fi

    if [[ -n "$recent_logs" ]]; then
        echo -e "\n${YELLOW}最近日志：${NC}"
        echo "$recent_logs"
    fi
    echo -e "${GREEN}================================================${NC}\n"
}

show_menu() {
    local choice

    clear
    install_shortcut

    echo -e "${CYAN}================================================${NC}"
    echo -e "      ${GREEN}代理综合管理脚本（HY2 + VLESS REALITY）${NC}"
    echo -e "${CYAN}================================================${NC}"
    echo -e "  ${YELLOW}1.${NC} 安装/重装 Hysteria 2"
    echo -e "  ${YELLOW}2.${NC} 卸载 Hysteria 2"
    echo -e "  ${YELLOW}3.${NC} 查看 Hysteria 2 节点信息"
    echo -e "  ${YELLOW}4.${NC} 查看 Hysteria 2 运行状态"
    echo -e "  ${YELLOW}5.${NC} 安装/重装 VLESS + REALITY"
    echo -e "  ${YELLOW}6.${NC} 卸载 VLESS + REALITY"
    echo -e "  ${YELLOW}7.${NC} 查看 VLESS + REALITY 节点信息"
    echo -e "  ${YELLOW}8.${NC} 查看 VLESS + REALITY 运行状态"
    echo -e "  ${YELLOW}0.${NC} 退出脚本"
    echo -e "${CYAN}================================================${NC}"
    read -r -p "请输入数字选择功能: " choice

    case "$choice" in
        1)
            install_hy2
            read -r -p "按回车键返回主菜单..."
            show_menu
            ;;
        2)
            uninstall_hy2
            read -r -p "按回车键返回主菜单..."
            show_menu
            ;;
        3)
            view_config
            read -r -p "按回车键返回主菜单..."
            show_menu
            ;;
        4)
            view_status
            read -r -p "按回车键返回主菜单..."
            show_menu
            ;;
        5)
            install_xray_reality
            read -r -p "按回车键返回主菜单..."
            show_menu
            ;;
        6)
            uninstall_xray_reality
            read -r -p "按回车键返回主菜单..."
            show_menu
            ;;
        7)
            view_xray_config
            read -r -p "按回车键返回主菜单..."
            show_menu
            ;;
        8)
            view_xray_status
            read -r -p "按回车键返回主菜单..."
            show_menu
            ;;
        0)
            info "退出脚本。"
            ;;
        *)
            warn "输入错误，请重新输入。"
            sleep 1
            show_menu
            ;;
    esac
}

main() {
    case "${1:-}" in
        -h|--help)
            usage
            ;;
        --install|--install-hy2)
            require_root
            check_os
            require_commands
            install_hy2
            ;;
        --uninstall|--uninstall-hy2)
            require_root
            require_commands
            uninstall_hy2
            ;;
        --view|--view-hy2)
            require_root
            require_commands
            view_config
            ;;
        --status|--status-hy2)
            require_root
            require_commands
            view_status
            ;;
        --install-xray)
            require_root
            check_os
            require_commands
            install_xray_reality
            ;;
        --uninstall-xray)
            require_root
            require_commands
            uninstall_xray_reality
            ;;
        --view-xray)
            require_root
            require_commands
            view_xray_config
            ;;
        --status-xray)
            require_root
            require_commands
            view_xray_status
            ;;
        "")
            require_root
            check_os
            require_commands
            show_menu
            ;;
        *)
            usage
            error "未知参数：$1"
            ;;
    esac
}

main "$@"
