# shellcheck shell=bash
# 节点：REALITY / VLESS-WS / Hysteria2 的参数、配置生成、分享链接、服务管理

NODE_TYPES=(reality ws hy2)
# 都实测过能用作 REALITY 目标。www.microsoft.com 握手失败；apple / icloud 会被 Xray 警告易被封
REALITY_SNIS=(www.nvidia.com www.amazon.com www.tesla.com www.samsung.com)
HY2_DEFAULT_SNI=www.bing.com

node_label() { case $1 in reality) echo REALITY ;; ws) echo VLESS-WS ;; hy2) echo Hysteria2 ;; esac; }
node_core()  { if [[ $1 == hy2 ]]; then echo hy2; else echo xray; fi; }
node_proto() { if [[ $1 == hy2 ]]; then echo udp; else echo tcp; fi; }
node_file()  { echo "$NODE_DIR/$1.env"; }
node_exists() { [[ -f $NODE_DIR/$1.env ]]; }

node_check_type() {
  case ${1:-} in
    reality | ws | hy2) ;;
    *) die "节点类型只能是 reality / ws / hy2" ;;
  esac
}

nodes_all() {
  local n
  for n in "${NODE_TYPES[@]}"; do
    if node_exists "$n"; then echo "$n"; fi
  done
}

nodes_of() {
  local n
  for n in "${NODE_TYPES[@]}"; do
    if node_exists "$n" && [[ $(node_core "$n") == "$1" ]]; then echo "$n"; fi
  done
}

# ---------- 端口 ----------
# 本工具自己占用的端口（节点端口 + 本机统计接口端口），排除节点 self
port_ours() {
  local port=$1 proto=$2 self=$3 n
  for n in "${NODE_TYPES[@]}"; do
    [[ $n == "$self" ]] && continue
    node_exists "$n" || continue
    if [[ $(node_proto "$n") == "$proto" && $(kv_get "$(node_file "$n")" PORT) == "$port" ]]; then
      return 0
    fi
  done
  if [[ $proto == tcp ]]; then
    [[ $(setting XRAY_API_PORT) == "$port" ]] && return 0
    [[ $(kv_get "$(node_file hy2)" STATS_PORT) == "$port" ]] && return 0
  fi
  return 1
}

# port_ok 端口 协议 节点 原端口：检查端口能否给该节点用
port_ok() {
  is_port "$1" || die "端口无效: $1（1-65535）"
  port_ours "$1" "$2" "$3" && die "端口 $1/$2 已被本工具的其他节点使用"
  if [[ $1 != "${4:-}" ]] && port_busy "$1" "$2"; then
    die "端口 $1/$2 已被其他程序占用"
  fi
  return 0
}

# pick_port 协议 节点 [首选端口...]：首选端口都不可用时随机选
pick_port() {
  local proto=$1 self=$2 p
  shift 2
  for p in "$@"; do
    if ! port_ours "$p" "$proto" "$self" && ! port_busy "$p" "$proto"; then
      echo "$p"
      return 0
    fi
  done
  for _ in {1..50}; do
    p=$(rand_port)
    if ! port_ours "$p" "$proto" "$self" && ! port_busy "$p" "$proto"; then
      echo "$p"
      return 0
    fi
  done
  die "找不到空闲端口，请手动指定"
}

# 本机统计接口用的端口
pick_local_port() { pick_port tcp "" ; }

# 端口变化后调整防火墙
port_moved() {
  local old=$1 new=$2 proto=$3
  [[ $old == "$new" ]] && return 0
  fw_open "$new" "$proto"
  if [[ -n $old ]]; then fw_close "$old" "$proto"; fi
  if [[ -z $(fw_kind) ]]; then
    note "如果服务商有安全组 / 云防火墙，请放行 $new/$proto"
  fi
}

# ---------- 证书 ----------
cert_dir() { echo "$CERT_DIR/$1"; }

cert_perms() {
  local d
  d=$(cert_dir "$1")
  chmod 750 "$d"
  chmod 644 "$d/cert.pem"
  chmod 640 "$d/key.pem"
  chown -R "root:$SVC_USER" "$d" 2>/dev/null || true
}

# cert_selfsigned 节点 SAN 名称：生成 10 年自签 EC 证书
cert_selfsigned() {
  local d
  d=$(cert_dir "$1")
  install -d -m 750 "$d"
  (
    umask 077
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -sha256 -days 3650 \
      -subj "/CN=$3" -addext "subjectAltName=$2" \
      -keyout "$d/key.pem" -out "$d/cert.pem" >/dev/null 2>&1
  ) || die "生成自签证书失败"
  cert_perms "$1"
}

# 证书 SHA-256 指纹（DER，十六进制），Xray pcs 和 Hysteria pinSHA256 都用这个
cert_pin() {
  openssl x509 -in "$(cert_dir "$1")/cert.pem" -outform der 2>/dev/null | sha256sum | awk '{print $1}'
}

cert_has_name() {
  local san
  [[ -f $(cert_dir "$1")/cert.pem ]] || return 1
  san=$(openssl x509 -in "$(cert_dir "$1")/cert.pem" -noout -ext subjectAltName 2>/dev/null) || return 1
  # 整项比较：bing.com 不能匹配 www.bing.com
  san=" $(tr ',\n' '  ' <<<"$san") "
  [[ $san == *" $2 "* ]]
}

cert_copy_le() {
  local src=$LE_DIR/live/$1 d
  d=$(cert_dir ws)
  [[ -r $src/fullchain.pem && -r $src/privkey.pem ]] || die "找不到证书文件: $src"
  install -d -m 750 "$d"
  install -m 644 "$src/fullchain.pem" "$d/cert.pem"
  install -m 640 "$src/privkey.pem" "$d/key.pem"
  cert_perms ws
}

# cert_acme 域名 邮箱：certbot 独立模式申请，续期由 certbot 定时器负责
cert_acme() {
  local domain=$1 email=$2 out
  local args=(certonly --standalone --non-interactive --agree-tos --keep-until-expiring
    -d "$domain" --deploy-hook "/usr/local/bin/vps _certhook")
  need_pkg certbot certbot
  if port_busy 80 tcp; then
    die "申请证书要临时用 80 端口，但它被其他程序占着（如 nginx），请先停掉再试"
  fi
  fw_open 80 tcp
  if [[ -n $email ]]; then args+=(-m "$email"); else args+=(--register-unsafely-without-email); fi
  say "申请 Let's Encrypt 证书：$domain ..."
  if ! out=$(certbot "${args[@]}" 2>&1); then
    printf '%s\n' "$out" | tail -n 6 | sed 's/^/    /' >&2
    die "证书申请失败：请确认域名已解析到本机，且外网能访问 80 端口"
  fi
  cert_copy_le "$domain"
}

cert_acme_delete() {
  [[ -n $1 ]] || return 0
  if have certbot; then
    certbot delete --cert-name "$1" --non-interactive >/dev/null 2>&1 || true
  fi
}

# ---------- 配置生成 ----------
blocking_on() { [[ $(setting BLOCK_CN 0) == 1 || $(setting BLOCK_ADS 0) == 1 ]]; }

render_xray_base() {
  local api=$1 strategy=AsIs rules=()
  if [[ $(setting BLOCK_ADS 0) == 1 ]]; then
    rules+=('{"type": "field", "domain": ["geosite:category-ads-all"], "outboundTag": "block"}')
  fi
  if [[ $(setting BLOCK_CN 0) == 1 ]]; then
    strategy=IPIfNonMatch
    rules+=('{"type": "field", "domain": ["geosite:cn"], "outboundTag": "block"}')
    rules+=('{"type": "field", "ip": ["geoip:cn"], "outboundTag": "block"}')
  fi
  local joined="" r
  for r in "${rules[@]}"; do joined+="${joined:+,$'\n'}      $r"; done
  cat <<EOF
{
  "log": {"loglevel": "warning"},
  "api": {"tag": "api", "listen": "127.0.0.1:$api", "services": ["StatsService"]},
  "stats": {},
  "policy": {"system": {"statsInboundUplink": true, "statsInboundDownlink": true}},
  "outbounds": [
    {"tag": "direct", "protocol": "freedom"},
    {"tag": "block", "protocol": "blackhole"}
  ],
  "routing": {
    "domainStrategy": "$strategy",
    "rules": [
$joined
    ]
  }
}
EOF
}

render_reality() {
  local -A N
  kv_load "$(node_file reality)" N
  cat <<EOF
{
  "inbounds": [{
    "tag": "reality",
    "port": ${N[PORT]},
    "protocol": "vless",
    "settings": {
      "clients": [{"id": "${N[UUID]}", "flow": "xtls-rprx-vision", "email": "reality"}],
      "decryption": "none"
    },
    "streamSettings": {
      "network": "raw",
      "security": "reality",
      "realitySettings": {
        "target": "${N[SNI]}:443",
        "serverNames": ["${N[SNI]}"],
        "privateKey": "${N[PRIVATE_KEY]}",
        "shortIds": ["${N[SHORT_ID]}"]
      }
    },
    "sniffing": {"enabled": true, "destOverride": ["http", "tls", "quic"], "routeOnly": true}
  }]
}
EOF
}

render_ws() {
  local -A N
  local d=${CERT_DIR#"$RT"}/ws
  kv_load "$(node_file ws)" N
  cat <<EOF
{
  "inbounds": [{
    "tag": "ws",
    "port": ${N[PORT]},
    "protocol": "vless",
    "settings": {
      "clients": [{"id": "${N[UUID]}", "email": "ws"}],
      "decryption": "none"
    },
    "streamSettings": {
      "network": "ws",
      "security": "tls",
      "tlsSettings": {
        "alpn": ["http/1.1"],
        "certificates": [{"certificateFile": "$d/cert.pem", "keyFile": "$d/key.pem"}]
      },
      "wsSettings": {"path": "${N[WSPATH]}"}
    },
    "sniffing": {"enabled": true, "destOverride": ["http", "tls", "quic"], "routeOnly": true}
  }]
}
EOF
}

# 禁止通过代理访问本机和内网（Xray 内核默认已拦截，Hysteria2 需要显式规则）
PRIVATE_NETS=(0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16 172.16.0.0/12
  192.168.0.0/16 ::1/128 fc00::/7 fe80::/10)

render_hy2() {
  local -A N
  local d=${CERT_DIR#"$RT"}/hy2 share=${SHARE_DIR#"$RT"} net
  kv_load "$(node_file hy2)" N
  cat <<EOF
listen: :${N[PORT]}
tls:
  cert: $d/cert.pem
  key: $d/key.pem
auth:
  type: password
  password: ${N[PASSWORD]}
masquerade:
  type: proxy
  proxy:
    url: ${N[MASQ]}
    rewriteHost: true
trafficStats:
  listen: 127.0.0.1:${N[STATS_PORT]}
  secret: ${N[STATS_SECRET]}
acl:
  inline:
EOF
  for net in "${PRIVATE_NETS[@]}"; do printf '    - reject(%s)\n' "$net"; done
  if [[ $(setting BLOCK_ADS 0) == 1 ]]; then printf '    - reject(geosite:category-ads-all)\n'; fi
  if [[ $(setting BLOCK_CN 0) == 1 ]]; then
    printf '    - reject(geosite:cn)\n    - reject(geoip:cn)\n'
  fi
  if blocking_on; then
    printf '  geoip: %s/geoip.dat\n  geosite: %s/geosite.dat\n' "$share" "$share"
  fi
}

unit_common() {
  cat <<EOF
User=$SVC_USER
Group=$SVC_USER
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
LimitNOFILE=1048576
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
}

unit_xray() {
  cat <<EOF
[Unit]
Description=vps: Xray (REALITY / VLESS-WS)
After=network-online.target
Wants=network-online.target

[Service]
Environment=XRAY_LOCATION_ASSET=${SHARE_DIR#"$RT"}
ExecStart=${BIN_DIR#"$RT"}/xray run -confdir ${XRAY_DIR#"$RT"}
$(unit_common)
EOF
}

unit_hy2() {
  cat <<EOF
[Unit]
Description=vps: Hysteria2
After=network-online.target
Wants=network-online.target

[Service]
Environment=HYSTERIA_LOG_LEVEL=warn
Environment=HYSTERIA_DISABLE_UPDATE_CHECK=1
ExecStart=${BIN_DIR#"$RT"}/hysteria server -c ${HY2_DIR#"$RT"}/config.yaml
$(unit_common)
EOF
}

ensure_user() {
  getent passwd "$SVC_USER" >/dev/null 2>&1 && return 0
  useradd --system --user-group --no-create-home --shell /usr/sbin/nologin "$SVC_USER" >/dev/null 2>&1 ||
    die "创建系统用户 $SVC_USER 失败"
}

journal_tail() {
  journalctl -u "$1" -n 8 --no-pager -o cat 2>/dev/null | sed 's/^/    /' >&2 || true
}

ensure_geo() {
  if blocking_on && ! geo_ready; then
    say "下载屏蔽规则文件 ..."
    geo_update || return 1
  fi
  return 0
}

# 按当前参数重新生成 Xray 配置并重启；失败时恢复原配置，返回 1
apply_xray() {
  local nodes=() n bin tmpd out api
  mapfile -t nodes < <(nodes_of xray)
  if ((${#nodes[@]} == 0)); then
    stats_sample || true
    remove_unit vps-xray.service
    units_reload
    rm -rf "$XRAY_DIR"
    core_remove xray
    return 0
  fi
  core_install xray
  ensure_user
  ensure_geo || return 1
  api=$(setting XRAY_API_PORT)
  if ! is_port "$api"; then
    api=$(pick_local_port)
    setting_set XRAY_API_PORT "$api"
  fi
  mkdir -p "$ETC"
  tmpd=$(mktemp -d "$ETC/.xray.XXXXXX")
  render_xray_base "$api" >"$tmpd/00-base.json"
  for n in "${nodes[@]}"; do
    case $n in
      reality) render_reality >"$tmpd/10-reality.json" ;;
      ws) render_ws >"$tmpd/20-ws.json" ;;
    esac
  done
  chmod 750 "$tmpd"
  chmod 640 "$tmpd"/*.json
  chown -R "root:$SVC_USER" "$tmpd" 2>/dev/null || true
  bin=$(core_bin xray)
  if ! out=$(xray_test "$bin" "$tmpd"); then
    rm -rf "$tmpd"
    warn "Xray 配置校验失败："
    printf '%s\n' "$out" | tail -n 5 | sed 's/^/    /' >&2
    return 1
  fi
  write_unit vps-xray.service "$(unit_xray)"
  units_reload
  if [[ -d $XRAY_DIR ]] && diff -rq "$tmpd" "$XRAY_DIR" >/dev/null 2>&1 && svc_active vps-xray; then
    rm -rf "$tmpd"
    return 0
  fi
  rm -rf "$XRAY_DIR.old"
  if [[ -d $XRAY_DIR ]]; then mv "$XRAY_DIR" "$XRAY_DIR.old"; fi
  mv "$tmpd" "$XRAY_DIR"
  stats_sample || true
  if svc_restart vps-xray; then
    rm -rf "$XRAY_DIR.old"
    return 0
  fi
  warn "Xray 启动失败："
  journal_tail vps-xray
  rm -rf "$XRAY_DIR"
  if [[ -d $XRAY_DIR.old ]]; then
    mv "$XRAY_DIR.old" "$XRAY_DIR"
    svc_restart vps-xray || true
  fi
  return 1
}

hy2_sysctl() {
  local f=$SYSCTL_DIR/90-vps-hy2.conf
  local want=$'# vps: Hysteria2 UDP 缓冲区\nnet.core.rmem_max = 16777216\nnet.core.wmem_max = 16777216'
  if [[ -f $f && $(<"$f") == "$want" ]]; then return 0; fi
  mkdir -p "$SYSCTL_DIR"
  printf '%s\n' "$want" >"$f"
  sysctl -q -p "$f" >/dev/null 2>&1 || true
}

apply_hy2() {
  local cfg=$HY2_DIR/config.yaml tmp
  if ! node_exists hy2; then
    stats_sample || true
    remove_unit vps-hy2.service
    units_reload
    rm -rf "$HY2_DIR"
    rm -f "$SYSCTL_DIR/90-vps-hy2.conf"
    core_remove hy2
    return 0
  fi
  core_install hy2
  ensure_user
  ensure_geo || return 1
  hy2_sysctl
  mkdir -p "$HY2_DIR"
  chmod 750 "$HY2_DIR"
  chown "root:$SVC_USER" "$HY2_DIR" 2>/dev/null || true
  tmp=$(mktemp "$HY2_DIR/.config.XXXXXX")
  render_hy2 >"$tmp"
  chmod 640 "$tmp"
  chown "root:$SVC_USER" "$tmp" 2>/dev/null || true
  write_unit vps-hy2.service "$(unit_hy2)"
  units_reload
  if [[ -f $cfg ]] && cmp -s "$tmp" "$cfg" && svc_active vps-hy2; then
    rm -f "$tmp"
    return 0
  fi
  rm -f "$cfg.old"
  if [[ -f $cfg ]]; then cp -p "$cfg" "$cfg.old"; fi
  mv -f "$tmp" "$cfg"
  stats_sample || true
  if svc_restart vps-hy2; then
    rm -f "$cfg.old"
    return 0
  fi
  warn "Hysteria2 启动失败："
  journal_tail vps-hy2
  if [[ -f $cfg.old ]]; then
    mv -f "$cfg.old" "$cfg"
    svc_restart vps-hy2 || true
  else
    rm -f "$cfg"
  fi
  return 1
}

apply_core() {
  case $1 in
    xray) apply_xray ;;
    hy2) apply_hy2 ;;
  esac
}

apply_all() {
  local rc=0
  apply_xray || rc=1
  apply_hy2 || rc=1
  return "$rc"
}

# 修改节点前的快照（参数 + 证书），生效失败时用来恢复
NODE_SNAP=""

node_snapshot() {
  NODE_SNAP=$(mktemp -d)
  if [[ -f $(node_file "$1") ]]; then cp -p "$(node_file "$1")" "$NODE_SNAP/state"; fi
  if [[ -d $(cert_dir "$1") ]]; then cp -a "$(cert_dir "$1")" "$NODE_SNAP/certs"; fi
}

# node_commit 节点 参数数组名：保存参数并生效，失败时恢复原状
node_commit() {
  local node=$1 file
  file=$(node_file "$node")
  [[ -n $NODE_SNAP ]] || node_snapshot "$node"
  kv_save "$file" "$2"
  if apply_core "$(node_core "$node")"; then
    rm -rf "$NODE_SNAP"
    NODE_SNAP=""
    tick_sync
    return 0
  fi
  if [[ -f $NODE_SNAP/state ]]; then cp -p "$NODE_SNAP/state" "$file"; else rm -f "$file"; fi
  if [[ -d $NODE_SNAP/certs ]]; then
    rm -rf "$(cert_dir "$node")"
    cp -a "$NODE_SNAP/certs" "$(cert_dir "$node")"
  fi
  rm -rf "$NODE_SNAP"
  NODE_SNAP=""
  apply_core "$(node_core "$node")" >/dev/null 2>&1 || true
  die "$(node_label "$node") 未能生效，已恢复原状"
}

reality_keys() {
  local -n __rk=$1
  local out
  out=$("$(core_bin xray)" x25519 2>/dev/null) || die "生成 REALITY 密钥失败"
  __rk[PRIVATE_KEY]=$(awk -F': *' '/^Private ?[Kk]ey/ {print $2; exit}' <<<"$out")
  __rk[PUBLIC_KEY]=$(awk -F': *' '/^(Public ?[Kk]ey|Password)/ {print $2; exit}' <<<"$out")
  [[ -n ${__rk[PRIVATE_KEY]} && -n ${__rk[PUBLIC_KEY]} ]] || die "无法解析 xray x25519 的输出"
}

# ---------- 添加 / 修改 ----------
need_value() { [[ -n ${2:-} ]] || die "$1 需要一个值"; }

node_add_reality() {
  local port="" sni="" old_port
  local -A N
  while (($#)); do
    case $1 in
      --port) need_value "$1" "${2:-}"; port=$2; shift 2 ;;
      --sni) need_value "$1" "${2:-}"; sni=$2; shift 2 ;;
      *) die "未知参数: $1" ;;
    esac
  done
  kv_load "$(node_file reality)" N
  old_port=${N[PORT]:-}
  [[ -n $sni ]] || sni=${N[SNI]:-${REALITY_SNIS[RANDOM % ${#REALITY_SNIS[@]}]}}
  is_domain "$sni" || die "SNI 必须是域名: $sni"
  if [[ $port == random ]]; then
    port=$(pick_port tcp reality)
  elif [[ -n $port ]]; then
    port_ok "$port" tcp reality "$old_port"
  else
    port=${old_port:-$(pick_port tcp reality 443)}
  fi
  core_install xray
  N[PORT]=$port
  N[SNI]=$sni
  [[ -n ${N[UUID]:-} ]] || N[UUID]=$(rand_uuid)
  if [[ -z ${N[PRIVATE_KEY]:-} || -z ${N[PUBLIC_KEY]:-} ]]; then reality_keys N; fi
  [[ -n ${N[SHORT_ID]:-} ]] || N[SHORT_ID]=$(rand_hex 8)
  node_commit reality N
  port_moved "$old_port" "$port" tcp
  ok "REALITY 已就绪"
  node_card reality
}

node_add_ws() {
  local port="" path="" email="" domain="" set_domain=0 old_port old_domain host
  local -A N
  while (($#)); do
    case $1 in
      --port) need_value "$1" "${2:-}"; port=$2; shift 2 ;;
      --path) need_value "$1" "${2:-}"; path=$2; shift 2 ;;
      --email) need_value "$1" "${2:-}"; email=$2; shift 2 ;;
      --domain) need_value "$1" "${2:-}"; domain=$2; set_domain=1; shift 2 ;;
      --no-domain) domain=""; set_domain=1; shift ;;
      *) die "未知参数: $1" ;;
    esac
  done
  kv_load "$(node_file ws)" N
  old_port=${N[PORT]:-}
  old_domain=${N[DOMAIN]:-}
  ((set_domain)) || domain=$old_domain
  domain=${domain,,}
  if [[ -n $domain ]]; then is_domain "$domain" || die "域名格式不正确: $domain"; fi
  [[ -n $email ]] || email=${N[EMAIL]:-}
  if [[ -n $email ]]; then is_email "$email" || die "邮箱格式不正确: $email"; fi
  [[ -n $path ]] || path=${N[WSPATH]:-/$(rand_hex 6)}
  [[ $path == /* ]] || path=/$path
  is_ws_path "$path" || die "路径只能包含字母、数字和 . _ ~ -，例如 /chat"
  if [[ $port == random ]]; then
    port=$(pick_port tcp ws)
  elif [[ -n $port ]]; then
    port_ok "$port" tcp ws "$old_port"
  else
    port=${old_port:-$(pick_port tcp ws 443 8443)}
  fi
  core_install xray
  ensure_user
  node_snapshot ws
  if [[ -n $domain ]]; then
    cert_acme "$domain" "$email"
    N[PIN]=""
  else
    host=$(share_host)
    local san="DNS:$host" name="DNS:$host"
    if is_ipv4 "$host" || is_ipv6 "$host"; then san="IP:$host"; name="IP Address:$host"; fi
    if [[ -n $old_domain ]] || ! cert_has_name ws "$name"; then
      cert_selfsigned ws "$san" "$host"
    fi
    N[PIN]=$(cert_pin ws)
  fi
  N[PORT]=$port
  N[UUID]=${N[UUID]:-$(rand_uuid)}
  N[WSPATH]=$path
  N[DOMAIN]=$domain
  N[EMAIL]=$email
  node_commit ws N
  if [[ -n $old_domain && $old_domain != "$domain" ]]; then cert_acme_delete "$old_domain"; fi
  port_moved "$old_port" "$port" tcp
  ok "VLESS-WS 已就绪"
  node_card ws
}

node_add_hy2() {
  local port="" sni="" masq="" old_port
  local -A N
  while (($#)); do
    case $1 in
      --port) need_value "$1" "${2:-}"; port=$2; shift 2 ;;
      --sni) need_value "$1" "${2:-}"; sni=$2; shift 2 ;;
      --masq) need_value "$1" "${2:-}"; masq=$2; shift 2 ;;
      *) die "未知参数: $1" ;;
    esac
  done
  kv_load "$(node_file hy2)" N
  old_port=${N[PORT]:-}
  [[ -n $sni ]] || sni=${N[SNI]:-$HY2_DEFAULT_SNI}
  is_domain "$sni" || die "SNI 必须是域名: $sni"
  [[ -n $masq ]] || masq=${N[MASQ]:-https://$HY2_DEFAULT_SNI}
  is_url "$masq" || die "伪装网址格式不正确: $masq（例如 https://www.bing.com）"
  if [[ $port == random ]]; then
    port=$(pick_port udp hy2)
  elif [[ -n $port ]]; then
    port_ok "$port" udp hy2 "$old_port"
  else
    port=${old_port:-$(pick_port udp hy2 443)}
  fi
  core_install hy2
  ensure_user
  node_snapshot hy2
  if ! cert_has_name hy2 "DNS:$sni"; then cert_selfsigned hy2 "DNS:$sni" "$sni"; fi
  N[PORT]=$port
  N[SNI]=$sni
  N[MASQ]=$masq
  N[PIN]=$(cert_pin hy2)
  N[PASSWORD]=${N[PASSWORD]:-$(rand_hex 16)}
  N[STATS_SECRET]=${N[STATS_SECRET]:-$(rand_hex 16)}
  [[ -n ${N[STATS_PORT]:-} ]] || N[STATS_PORT]=$(pick_local_port)
  node_commit hy2 N
  port_moved "$old_port" "$port" udp
  ok "Hysteria2 已就绪"
  node_card hy2
}

node_add() {
  local type=${1:-}
  node_check_type "$type"
  shift
  "node_add_$type" "$@"
}

node_need() {
  node_check_type "$1"
  node_exists "$1" || die "$(node_label "$1") 还没有添加（vps add $1）"
}

# node_port 节点 端口|random
node_port() {
  local node=$1 want=${2:-} proto old new
  local -A N
  node_need "$node"
  [[ -n $want ]] || die "用法: vps port $node <端口|random>"
  proto=$(node_proto "$node")
  kv_load "$(node_file "$node")" N
  old=${N[PORT]}
  if [[ $want == random ]]; then
    new=$(pick_port "$proto" "$node")
  else
    port_ok "$want" "$proto" "$node" "$old"
    new=$((10#$want))
  fi
  if [[ $new == "$old" ]]; then
    say "端口没有变化（$old）"
    return 0
  fi
  N[PORT]=$new
  node_commit "$node" N
  port_moved "$old" "$new" "$proto"
  ok "$(node_label "$node") 端口：$old → $new（旧链接已失效）"
  printf '\n  %s\n' "$(node_link "$node")"
}

# node_reset 节点：重新生成密码 / UUID / 密钥
node_reset() {
  local node=$1
  local -A N
  node_need "$node"
  kv_load "$(node_file "$node")" N
  case $node in
    reality)
      N[UUID]=$(rand_uuid)
      N[SHORT_ID]=$(rand_hex 8)
      reality_keys N
      ;;
    ws)
      N[UUID]=$(rand_uuid)
      N[WSPATH]=/$(rand_hex 6)
      ;;
    hy2) N[PASSWORD]=$(rand_hex 16) ;;
  esac
  node_commit "$node" N
  ok "$(node_label "$node") 已重置，旧链接已失效"
  printf '\n  %s\n' "$(node_link "$node")"
}

node_del() {
  local node=$1
  local -A N
  node_check_type "$node"
  if ! node_exists "$node"; then
    say "$(node_label "$node") 不存在"
    return 0
  fi
  kv_load "$(node_file "$node")" N
  rm -f "$(node_file "$node")"
  apply_core "$(node_core "$node")" || warn "重新生成配置失败，请检查其他节点"
  fw_close "${N[PORT]}" "$(node_proto "$node")"
  if [[ $node == ws ]]; then cert_acme_delete "${N[DOMAIN]:-}"; fi
  rm -rf "$(cert_dir "$node")"
  stats_forget "$node"
  tick_sync
  ok "$(node_label "$node") 已删除"
}

# ---------- 展示 ----------
node_link() {
  local node=$1 host name
  local -A N
  kv_load "$(node_file "$node")" N
  host=$(share_host)
  name="$(node_label "$node")-$host"
  case $node in
    reality)
      printf 'vless://%s@%s:%s?encryption=none&flow=xtls-rprx-vision&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=tcp#%s' \
        "${N[UUID]}" "$(url_host "$host")" "${N[PORT]}" "${N[SNI]}" "${N[PUBLIC_KEY]}" "${N[SHORT_ID]}" "$name"
      ;;
    ws)
      local path=${N[WSPATH]//\//%2F}
      if [[ -n ${N[DOMAIN]} ]]; then
        printf 'vless://%s@%s:%s?encryption=none&security=tls&sni=%s&fp=chrome&alpn=http%%2F1.1&type=ws&host=%s&path=%s#%s' \
          "${N[UUID]}" "${N[DOMAIN]}" "${N[PORT]}" "${N[DOMAIN]}" "${N[DOMAIN]}" "$path" "VLESS-WS-${N[DOMAIN]}"
      else
        printf 'vless://%s@%s:%s?encryption=none&security=tls&fp=chrome&alpn=http%%2F1.1&pcs=%s&type=ws&path=%s#%s' \
          "${N[UUID]}" "$(url_host "$host")" "${N[PORT]}" "${N[PIN]}" "$path" "$name"
      fi
      ;;
    hy2)
      printf 'hysteria2://%s@%s:%s/?sni=%s&insecure=1&pinSHA256=%s#%s' \
        "${N[PASSWORD]}" "$(url_host "$host")" "${N[PORT]}" "${N[SNI]}" "${N[PIN]}" "$name"
      ;;
  esac
}

node_state() {
  if svc_active "$(core_unit "$(node_core "$1")")"; then
    printf '%s● 运行中%s' "$CG" "$C0"
  else
    printf '%s○ 已停止%s' "$CY" "$C0"
  fi
}

kv_line() { printf '  %s%s%s%s\n' "$CD" "$(pad "$1" 10)" "$C0" "$2"; }

node_card() {
  local node=$1 host up down
  local -A N
  kv_load "$(node_file "$node")" N
  host=$(share_host)
  printf '\n  %s%s%s%s  %s  %s/%s\n' "$C1" "$CC" "$(node_label "$node")" "$C0" "$(node_state "$node")" \
    "${N[PORT]}" "$(node_proto "$node")"
  rule
  case $node in
    reality)
      kv_line 地址 "$host"
      kv_line UUID "${N[UUID]}"
      kv_line SNI "${N[SNI]}"
      kv_line 公钥 "${N[PUBLIC_KEY]}"
      kv_line ShortID "${N[SHORT_ID]}"
      ;;
    ws)
      if [[ -n ${N[DOMAIN]} ]]; then
        kv_line 地址 "${N[DOMAIN]}"
        kv_line 证书 "Let's Encrypt（自动续期）"
      else
        kv_line 地址 "$host"
        kv_line 证书 "自签证书（指纹已写入链接，客户端需支持 pcs）"
      fi
      kv_line UUID "${N[UUID]}"
      kv_line 路径 "${N[WSPATH]}"
      ;;
    hy2)
      kv_line 地址 "$host"
      kv_line 密码 "${N[PASSWORD]}"
      kv_line SNI "${N[SNI]}"
      kv_line 伪装 "${N[MASQ]}"
      ;;
  esac
  read -r up down < <(stats_get "$node")
  kv_line 本期流量 "↑ $(human "$up")  ↓ $(human "$down")"
  printf '\n  %s分享链接（整段复制到客户端导入）%s\n  %s\n' "$CD" "$C0" "$(node_link "$node")"
}

node_show() {
  local nodes=() n
  if [[ -n ${1:-} ]]; then
    node_need "$1"
    nodes=("$1")
  else
    mapfile -t nodes < <(nodes_all)
  fi
  if ((${#nodes[@]} == 0)); then
    say "还没有节点。添加：vps add reality | ws | hy2"
    return 0
  fi
  for n in "${nodes[@]}"; do node_card "$n"; done
  printf '\n'
}

# 一行一个节点的概览（菜单用）
node_summary() {
  local n up down
  for n in "${NODE_TYPES[@]}"; do
    if node_exists "$n"; then
      read -r up down < <(stats_get "$n")
      printf '  %-10s %s  %-11s %s↑ %-9s  ↓ %s%s\n' "$(node_label "$n")" "$(node_state "$n")" \
        "$(kv_get "$(node_file "$n")" PORT)/$(node_proto "$n")" "$CD" "$(human "$up")" "$(human "$down")" "$C0"
    else
      printf '  %-10s %s- 未添加%s\n' "$(node_label "$n")" "$CD" "$C0"
    fi
  done
}

# ---------- 服务管理 ----------
# svc_cmd 动作 [xray|hy2|节点名]
svc_cmd() {
  local action=${1:-status} target=${2:-} cores=() c unit
  case $target in
    "")
      if [[ -n $(nodes_of xray) ]]; then cores+=(xray); fi
      if node_exists hy2; then cores+=(hy2); fi
      ;;
    xray | reality | ws) cores=(xray) ;;
    hy2) cores=(hy2) ;;
    *) die "服务只能是 xray / hy2" ;;
  esac
  ((${#cores[@]})) || { say "还没有节点"; return 0; }
  case $action in
    start | restart)
      stats_sample || true
      for c in "${cores[@]}"; do
        unit=$(core_unit "$c")
        if svc_restart "$unit"; then ok "$(core_name "$c") 运行中"; else warn "$(core_name "$c") 启动失败："; journal_tail "$unit"; fi
      done
      ;;
    stop)
      stats_sample || true
      for c in "${cores[@]}"; do
        systemctl disable --now "$(core_unit "$c")" >/dev/null 2>&1 || true
        ok "$(core_name "$c") 已停止（开机也不会自动启动，用 vps start 恢复）"
      done
      ;;
    status) node_summary ;;
    log)
      local args=()
      for c in "${cores[@]}"; do args+=(-u "$(core_unit "$c")"); done
      journalctl "${args[@]}" -n 50 --no-pager -o short-iso 2>/dev/null || say "没有日志"
      ;;
    *) die "未知操作: $action" ;;
  esac
}

# 把 certbot 续期后的新证书同步给 Xray（续期钩子和定时任务都会调用）
cert_sync_ws() {
  local domain src
  domain=$(kv_get "$(node_file ws)" DOMAIN)
  [[ -n $domain ]] || return 0
  src=$LE_DIR/live/$domain/fullchain.pem
  [[ -r $src ]] || return 0
  cmp -s "$src" "$(cert_dir ws)/cert.pem" && return 0
  cert_copy_le "$domain"
  if svc_active vps-xray; then
    stats_sample || true
    svc_restart vps-xray || warn "证书已更新，但 Xray 重启失败"
  fi
}

# certbot 续期成功后调用；本工具正在操作时跳过（首次申请时由调用方自己复制）
cmd_certhook() {
  lock --nowait
  cert_sync_ws
}
