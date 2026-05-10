#!/usr/bin/env bash
set -Eeuo pipefail

# ==========================================
# 全局防退出异常处理 (恢复光标与颜色)
# ==========================================
trap 'printf "\033[?25h\033[0m\n"' EXIT INT TERM

# ==========================================
# 颜色与图标语义定义 (Minimal Terminal UI)
# ==========================================
C_RESET='\033[0m'
C_BOLD='\033[1m'
C_DIM='\033[2m'
C_RED='\033[31m'
C_GREEN='\033[32m'
C_YELLOW='\033[33m'
C_CYAN='\033[36m'

I_INFO="➤"
I_SUCC="✔"
I_ERR="✘"
I_WARN="⚠"
I_RUN="▶"

# ==========================================
# 变量与大厂域名池
# ==========================================
# [删除] APP_NAME 从未使用，已移除
CONFIG_DIR="/root/proxy-info"

BIG_TECH_DOMAINS=(
  "www.bing.com"
  "www.microsoft.com"
  "www.apple.com"
  "www.amazon.com"
  "www.cloudflare.com"
)

# ==========================================
# UI 原语函数 (核心美化)
# ==========================================
hr() {
  printf '%b━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━%b\n' "${C_DIM}" "${C_RESET}"
}

msg_info() { printf "  %b%s%b  %s\n" "${C_CYAN}" "${I_INFO}" "${C_RESET}" "$*"; }
msg_succ() { printf "  %b%s%b  %s\n" "${C_GREEN}" "${I_SUCC}" "${C_RESET}" "$*"; }
# [修复 Bug] 将 >&2 移至 printf 末尾，确保错误信息正确输出到 stderr
msg_err()  { printf "  %b%s%b  %s\n" "${C_RED}" "${I_ERR}" "${C_RESET}" "$*" >&2; exit 1; }
msg_warn() { printf "  %b%s%b  %s\n" "${C_YELLOW}" "${I_WARN}" "${C_RESET}" "$*"; }

# 动态 Spinner 动画 (过滤一切杂乱输出，兼容 set -e)
run_cmd() {
  local text="$1"
  shift
  "$@" >/dev/null 2>&1 &
  local pid=$!
  local frames=("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏")
  local i=0
  printf "\033[?25l" # 隐藏光标
  while kill -0 $pid 2>/dev/null; do
    printf "\r  %b%s%b  %s" "${C_CYAN}" "${frames[i]}" "${C_RESET}" "$text"
    # [优化] 使用数组长度替代硬编码的魔法数字 10
    i=$(( (i + 1) % ${#frames[@]} ))
    sleep 0.1
  done
  printf "\033[?25h\r\033[K" # 恢复光标并清空当前行

  if wait "$pid" 2>/dev/null; then
    msg_succ "$text"
  else
    printf "  %b%s%b  %s (Failed)\n" "${C_RED}" "${I_ERR}" "${C_RESET}" "$text" >&2
    exit 1
  fi
}

prompt_default() {
  local label="$1"
  local default_value="$2"
  local value
  printf "  %b%s%b %s [%b%s%b]: " "${C_CYAN}" "${I_INFO}" "${C_RESET}" "$label" "${C_DIM}" "$default_value" "${C_RESET}"
  read -r value
  printf '%s' "${value:-$default_value}"
}

# ==========================================
# 核心网络与端口检测
# ==========================================
require_root() {
  [[ "${EUID}" -eq 0 ]] || msg_err "请使用 root 用户运行。"
}

install_base_deps() {
  run_cmd "更新软件包列表" apt-get update
  # 注入 DEBIAN_FRONTEND=noninteractive 防 iptables-persistent 弹窗卡死
  run_cmd "安装必要组件 (curl, openssl, iptables, iproute2等)" \
    env DEBIAN_FRONTEND=noninteractive apt-get install -y \
    curl ca-certificates openssl sed grep gawk coreutils unzip iptables iptables-persistent iproute2
}

ensure_dirs() {
  install -d -m 700 "$CONFIG_DIR"
}

# [新增] 将安装前置步骤提取为公共函数，避免在每个安装函数中重复
install_prelude() {
  require_root
  install_base_deps
  ensure_dirs
}

server_ip() {
  local ip=""
  ip="$(curl -4fsSL --max-time 3 https://api.ipify.org || curl -6fsSL --max-time 3 https://api64.ipify.org || true)"
  if [[ -z "$ip" ]]; then
    ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  fi
  [[ -n "$ip" ]] || ip="YOUR_SERVER_IP"
  printf '%s' "$ip"
}

# [优化] 简化函数体，bash 自动返回最后命令的退出码，无需显式 return 0/1
check_port_in_use() {
  ss -tuln 2>/dev/null | grep -qE ":${1}\b"
}

generate_safe_port() {
  local hop_start=${1:-0}
  local hop_end=${2:-0}
  local rand_port
  while true; do
    rand_port=$(shuf -i 10000-65535 -n 1)
    # 检查是否在跳跃范围内
    if [[ $hop_start -ne 0 && $hop_end -ne 0 ]]; then
      if (( rand_port >= hop_start && rand_port <= hop_end )); then
        continue
      fi
    fi
    # 检查是否被占用
    if ! check_port_in_use "$rand_port"; then
      # [优化] 统一使用 printf，与全脚本风格一致
      printf '%s\n' "$rand_port"
      break
    fi
  done
}

# [优化] 省略末尾多余的 return 0，bash 正则匹配成功即返回 0
validate_domain() {
  [[ "$1" =~ ^([a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]]
}

# [新增] 提取重复的 IPv6 地址格式化逻辑
format_ip() {
  local ip="$1"
  if [[ "$ip" =~ ":" ]]; then
    printf '[%s]' "$ip"
  else
    printf '%s' "$ip"
  fi
}

# [新增] 提取重复的 UFW 端口更新逻辑 (删除旧规则 → 添加新规则)
# 用法: ufw_update_port <旧端口文件> <新端口或范围> <协议>
ufw_update_port() {
  local old_file="$1" new_port="$2" proto="$3"
  command -v ufw >/dev/null 2>&1 || return 0
  if [[ -f "$old_file" ]]; then
    ufw delete allow "$(<"$old_file")/${proto}" >/dev/null 2>&1 || true
  fi
  ufw allow "${new_port}/${proto}" >/dev/null 2>&1 || true
}

# ==========================================
# 安装逻辑: Xray VLESS + REALITY
# ==========================================
install_xray_reality() {
  printf '\n'
  hr
  printf '  %b安装 Xray VLESS + REALITY%b\n' "${C_BOLD}" "${C_RESET}"
  hr

  # [优化] 使用 install_prelude 替代三行重复调用
  install_prelude

  local port
  port=$(generate_safe_port)
  port=$(prompt_default '设置 Xray TCP 端口' "$port")
  if check_port_in_use "$port"; then msg_err "端口 $port 已被占用，请更换。"; fi

  local sni
  sni=$(prompt_default 'REALITY 伪装域名 SNI' "www.microsoft.com")
  local target
  target=$(prompt_default 'REALITY 回落目标' "${sni}:443")

  run_cmd "下载并部署 Xray Core" bash -c "$(curl -LfsS https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install

  local uuid short_id keys private_key public_key ip link info_file ip_format
  uuid="$(cat /proc/sys/kernel/random/uuid)"
  short_id="$(openssl rand -hex 8)"
  keys="$(xray x25519)"
  private_key="$(printf '%s\n' "$keys" | awk -F': ' '/PrivateKey|Private key/ {print $2; exit}')"
  public_key="$(printf '%s\n' "$keys" | awk -F': ' '/Password \(PublicKey\)|Public key/ {print $2; exit}')"
  ip="$(server_ip)"

  cat >/usr/local/etc/xray/config.json <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [{
    "listen": "0.0.0.0",
    "port": ${port},
    "protocol": "vless",
    "settings": {
      "clients": [{ "id": "${uuid}", "flow": "xtls-rprx-vision" }],
      "decryption": "none"
    },
    "streamSettings": {
      "network": "raw",
      "security": "reality",
      "realitySettings": {
        "show": false,
        "dest": "${target}",
        "xver": 0,
        "serverNames": [ "${sni}" ],
        "privateKey": "${private_key}",
        "shortIds": [ "${short_id}" ]
      }
    },
    "sniffing": { "enabled": true, "destOverride": ["http", "tls", "quic"] }
  }],
  "outbounds": [{ "protocol": "freedom" }]
}
EOF

  # 测试配置有效性
  run_cmd "测试 Xray 配置文件" xray run -test -config /usr/local/etc/xray/config.json

  run_cmd "重启并应用 Xray 服务" systemctl restart xray
  systemctl enable xray >/dev/null 2>&1

  # [优化] 使用 ufw_update_port 替代重复的 UFW 检查逻辑
  ufw_update_port "${CONFIG_DIR}/.xray_port" "${port}" "tcp"
  printf '%s\n' "$port" > "${CONFIG_DIR}/.xray_port"

  # [优化] 使用 format_ip 函数替代内联的 IPv6 格式化代码
  ip_format="$(format_ip "$ip")"
  link="vless://${uuid}@${ip_format}:${port}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${sni}&fp=chrome&pbk=${public_key}&sid=${short_id}&type=tcp&headerType=none#Xray-Reality"
  info_file="${CONFIG_DIR}/xray-reality.txt"

  cat >"$info_file" <<EOF
  地址      : ${ip}
  端口      : ${port}
  UUID      : ${uuid}
  SNI       : ${sni}
  目标      : ${target}
  PublicKey : ${public_key}
  ShortId   : ${short_id}

  分享链接:
  ${link}
EOF
  printf '\n'
  msg_succ "Xray 部署完毕！配置如下："
  hr
  cat "$info_file"
  hr
}

# ==========================================
# 安装逻辑: Hysteria2 (含大厂域名/跳跃避让)
# ==========================================
install_hysteria2() {
  printf '\n'
  hr
  printf '  %b安装 Hysteria2%b\n' "${C_BOLD}" "${C_RESET}"
  hr

  # [优化] 使用 install_prelude 替代三行重复调用
  install_prelude

  # 1. 端口跳跃范围设置
  local hop_start hop_end
  hop_start=$(prompt_default '设置跳跃起始端口' "20000")
  hop_end=$(prompt_default '设置跳跃结束端口' "40000")

  if ! [[ "$hop_start" =~ ^[0-9]+$ && "$hop_end" =~ ^[0-9]+$ ]] || ! ((hop_start < hop_end)); then
    msg_err "跳跃范围无效 (需为纯数字且起始 < 结束)"
  fi

  # 2. 生成安全的主端口 (避让跳跃范围与占用)
  local safe_port
  safe_port=$(generate_safe_port "$hop_start" "$hop_end")
  local port
  port=$(prompt_default "设置 Hysteria2 主端口 (已自动避让 ${hop_start}-${hop_end})" "$safe_port")

  if check_port_in_use "$port"; then msg_err "端口 $port 已占用"; fi
  if (( port >= hop_start && port <= hop_end )); then msg_err "主端口不能在跳跃范围内！"; fi

  # 3. 域名设置 (空白则使用随机大厂)
  local custom_domain domain masquerade
  printf "  %b%s%b 伪装域名/SNI (留空将随机使用大厂域名): " "${C_CYAN}" "${I_INFO}" "${C_RESET}"
  read -r custom_domain

  if [[ -z "$custom_domain" ]]; then
    domain=${BIG_TECH_DOMAINS[$RANDOM % ${#BIG_TECH_DOMAINS[@]}]}
    msg_info "未填写域名，已随机分配大厂域名: ${C_GREEN}${domain}${C_RESET}"
  else
    if ! validate_domain "$custom_domain"; then
      msg_err "自定义域名格式不合法: $custom_domain"
    fi
    domain=$custom_domain
  fi
  masquerade="https://${domain}"

  run_cmd "下载并部署 Hysteria2 Core" bash -c "$(curl -fsSL https://get.hy2.sh/)"

  local pass ip config_file cert_dir link info_file ip_format
  pass="$(openssl rand -hex 16)"
  ip="$(server_ip)"
  config_file="/etc/hysteria/config.yaml"
  cert_dir="/etc/hysteria/certs"

  install -d -m 755 /etc/hysteria
  install -d -m 755 "$cert_dir"

  run_cmd "生成 [${domain}] 伪装自签证书" openssl req -x509 -newkey rsa:2048 -keyout "${cert_dir}/server.key" -out "${cert_dir}/server.crt" -days 3650 -nodes -subj "/CN=${domain}"

  # 修复私钥权限
  chmod 600 "${cert_dir}/server.key"
  chmod 644 "${cert_dir}/server.crt"

  cat >"$config_file" <<EOF
listen: :${port}
tls:
  cert: ${cert_dir}/server.crt
  key: ${cert_dir}/server.key
auth:
  type: password
  password: ${pass}
masquerade:
  type: proxy
  proxy:
    url: ${masquerade}
    rewriteHost: true
EOF

  chown -R hysteria:hysteria /etc/hysteria 2>/dev/null || true

  # 4. 配置端口跳跃 Iptables
  local nic
  nic=$(ip route get 8.8.8.8 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -1 || echo "eth0")
  # [优化] 不再通过 run_cmd 静默吞掉 iptables 错误，改为直接执行并保留警告
  { iptables-save | grep -v "hy2-hop" | iptables-restore; } 2>/dev/null \
    || msg_warn "清理旧 hy2-hop iptables 规则时出现问题，已跳过"
  iptables -t nat -A PREROUTING -i "$nic" -p udp --dport "${hop_start}:${hop_end}" -m comment --comment "hy2-hop" -j REDIRECT --to-ports "$port"
  netfilter-persistent save >/dev/null 2>&1 || true

  run_cmd "重启并应用 Hysteria2 服务" systemctl restart hysteria-server.service
  systemctl enable hysteria-server.service >/dev/null 2>&1

  # [优化] 使用 ufw_update_port 替代重复的 UFW 检查逻辑
  ufw_update_port "${CONFIG_DIR}/.hy2_port" "${port}" "udp"
  ufw_update_port "${CONFIG_DIR}/.hy2_hop"  "${hop_start}:${hop_end}" "udp"
  printf '%s\n' "$port" > "${CONFIG_DIR}/.hy2_port"
  printf '%s\n' "${hop_start}:${hop_end}" > "${CONFIG_DIR}/.hy2_hop"

  # [优化] 使用 format_ip 函数替代内联的 IPv6 格式化代码
  ip_format="$(format_ip "$ip")"
  link="hysteria2://${pass}@${ip_format}:${port}/?insecure=1&sni=${domain}#Hysteria2"
  info_file="${CONFIG_DIR}/hysteria2.txt"

  cat >"$info_file" <<EOF
  地址      : ${ip}
  主端口    : ${port}
  跳跃端口  : ${hop_start}-${hop_end} (填写 ${port},${hop_start}-${hop_end})
  密码      : ${pass}
  SNI       : ${domain}
  伪装网站  : ${masquerade}

  分享链接:
  ${link}
EOF
  printf '\n'
  msg_succ "Hysteria2 部署完毕！配置如下："
  hr
  cat "$info_file"
  hr
}

# ==========================================
# 卸载与清理
# ==========================================
uninstall_xray() {
  printf '\n'
  if [[ -f "${CONFIG_DIR}/.xray_port" ]] && command -v ufw >/dev/null 2>&1; then
    ufw delete allow "$(<"${CONFIG_DIR}/.xray_port")/tcp" >/dev/null 2>&1 || true
    rm -f "${CONFIG_DIR}/.xray_port"
  fi
  run_cmd "清理 Xray 服务及文件" bash -c "$(curl -LfsS https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ remove --purge
  rm -f "${CONFIG_DIR}/xray-reality.txt"
}

uninstall_hy2() {
  printf '\n'
  if command -v ufw >/dev/null 2>&1; then
    [[ -f "${CONFIG_DIR}/.hy2_port" ]] && ufw delete allow "$(<"${CONFIG_DIR}/.hy2_port")/udp" >/dev/null 2>&1 || true
    [[ -f "${CONFIG_DIR}/.hy2_hop" ]]  && ufw delete allow "$(<"${CONFIG_DIR}/.hy2_hop")/udp"  >/dev/null 2>&1 || true
  fi
  rm -f "${CONFIG_DIR}/.hy2_port" "${CONFIG_DIR}/.hy2_hop"

  # [优化] 不再通过 run_cmd 静默吞掉 iptables 错误，改为直接执行并保留警告
  msg_info "清理 Hysteria2 Iptables 规则..."
  if { iptables-save | grep -v 'hy2-hop' | iptables-restore; } 2>/dev/null; then
    msg_succ "清理 Hysteria2 Iptables 规则"
  else
    msg_warn "iptables 规则清理失败，请手动执行: iptables-save | grep -v 'hy2-hop' | iptables-restore"
  fi
  netfilter-persistent save >/dev/null 2>&1 || true

  run_cmd "清理 Hysteria2 服务及文件" bash <(curl -fsSL https://get.hy2.sh/) --remove
  rm -f "${CONFIG_DIR}/hysteria2.txt"
}

# ==========================================
# 状态与展示
# ==========================================
show_info() {
  printf '\n'
  hr
  printf '  %b已保存的节点信息%b\n' "${C_BOLD}" "${C_RESET}"
  hr
  if [[ -f "${CONFIG_DIR}/xray-reality.txt" ]]; then
    printf "  %b[Xray VLESS+REALITY]%b\n" "${C_CYAN}" "${C_RESET}"
    cat "${CONFIG_DIR}/xray-reality.txt"
    printf '\n'
  fi
  if [[ -f "${CONFIG_DIR}/hysteria2.txt" ]]; then
    printf "  %b[Hysteria2]%b\n" "${C_CYAN}" "${C_RESET}"
    cat "${CONFIG_DIR}/hysteria2.txt"
    printf '\n'
  fi
  if [[ ! -f "${CONFIG_DIR}/xray-reality.txt" && ! -f "${CONFIG_DIR}/hysteria2.txt" ]]; then
    msg_warn "没有找到已保存的节点信息。"
  fi
  hr
}

service_status_label() {
  local service="$1"
  local binary="$2"
  if systemctl is-active --quiet "$service" 2>/dev/null; then
    printf '%s✔ 运行中%s' "$C_GREEN" "$C_RESET"
  elif command -v "$binary" >/dev/null 2>&1; then
    printf '%s✘ 已停止%s' "$C_RED" "$C_RESET"
  else
    printf '%s- 未安装%s' "$C_DIM" "$C_RESET"
  fi
}

pause_menu() {
  local ignored
  printf '\n'
  read -r -p "按回车返回菜单..." ignored
}

# ==========================================
# 主菜单
# ==========================================
main_menu() {
  while true; do
    clear 2>/dev/null || true
    printf '\n'
    printf '  %b%s%b\n' "${C_BOLD}${C_CYAN}" "V P S   P R O X Y   T O O L" "${C_RESET}"
    printf '  %bMinimal Terminal UI%b\n' "${C_DIM}" "${C_RESET}"
    hr
    printf '  %b1.%b 安装/重装 Xray (VLESS+REALITY)\n' "${C_BOLD}" "${C_RESET}"
    printf '  %b2.%b 安装/重装 Hysteria2 (智能防冲突+跳跃)\n' "${C_BOLD}" "${C_RESET}"
    printf '  %b3.%b 查看节点与运行信息\n' "${C_CYAN}" "${C_RESET}"
    printf '  %b4.%b 卸载 Xray\n' "${C_YELLOW}" "${C_RESET}"
    printf '  %b5.%b 卸载 Hysteria2\n' "${C_YELLOW}" "${C_RESET}"
    printf '  %b0.%b 退出\n' "${C_DIM}" "${C_RESET}"
    hr

    printf '  %b%s 实时运行大盘%b\n' "${C_BOLD}" "${I_RUN}" "${C_RESET}"
    printf '    Xray      : %b\n' "$(service_status_label xray xray)"
    printf '    Hysteria2 : %b\n' "$(service_status_label hysteria-server hysteria)"
    printf '\n'

    printf "  %b%s%b " "${C_CYAN}" "${I_INFO}" "${C_RESET}"
    read -r -p "请选择操作 [0-5]: " choice
    case "$choice" in
      1) install_xray_reality; pause_menu;;
      2) install_hysteria2; pause_menu;;
      3) show_info; pause_menu;;
      4) uninstall_xray; pause_menu;;
      5) uninstall_hy2; pause_menu;;
      0) printf '\n  %bGoodbye!%b\n\n' "${C_CYAN}" "${C_RESET}"; exit 0 ;;
      *) msg_warn "无效选项"; sleep 1 ;;
    esac
  done
}

main_menu
