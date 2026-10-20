#!/usr/bin/env bash
# 节点：添加 / 修改 / 换端口 / 重置 / 删除，配置文件与分享链接
source "$(dirname "$0")/lib.sh"

echo "== REALITY"
setup
release_xray v25.9.11
vps add reality
check "添加成功" rc_is 0
check "默认用 443" [ "$(node_val reality PORT)" = 443 ]
check "Xray 已安装" test -x "$VPS_ROOT/usr/local/lib/vps/bin/xray"
check "服务已启动" active vps-xray
check "服务开机自启" enabled vps-xray
check "以非 root 用户运行" file_has "$VPS_ROOT/etc/systemd/system/vps-xray.service" "User=vps-proxy"
check "配置是合法 JSON" json_ok "$VPS_ROOT/etc/vps/xray/10-reality.json"
check "配置里有私钥" file_has "$VPS_ROOT/etc/vps/xray/10-reality.json" "\"privateKey\": \"$(node_val reality PRIVATE_KEY)\""
check "统计接口只监听本机" file_has "$VPS_ROOT/etc/vps/xray/00-base.json" '"listen": "127.0.0.1:'
check "链接格式" has "$OUT" "vless://$(node_val reality UUID)@203.0.113.10:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$(node_val reality SNI)&fp=chrome&pbk=$(node_val reality PUBLIC_KEY)&sid=$(node_val reality SHORT_ID)&type=tcp#REALITY-203.0.113.10"
check "参数文件权限 600" [ "$(stat -c %a "$VPS_ROOT/etc/vps/nodes/reality.env")" = 600 ]
check "定时统计已启用" enabled vps-tick.timer
uuid=$(node_val reality UUID) key=$(node_val reality PRIVATE_KEY)
vps add reality --sni www.apple.com
check "修改 SNI" [ "$(node_val reality SNI)" = www.apple.com ]
check "修改时保留 UUID 和密钥" [ "$(node_val reality UUID)/$(node_val reality PRIVATE_KEY)" = "$uuid/$key" ]
vps add reality --sni not_a_domain
check "拒绝非法 SNI" rc_is 1
vps port reality 2053
check "换端口" [ "$(node_val reality PORT)" = 2053 ]
check "配置随之更新" file_has "$VPS_ROOT/etc/vps/xray/10-reality.json" '"port": 2053'
vps port reality 70000
check "拒绝非法端口" rc_is 1
echo 9999 >"$VPS_ROOT/.stub/busy-tcp"
vps port reality 9999
check "拒绝被占用的端口" has "$OUT" "已被其他程序占用"
vps reset reality
check "重置后 UUID 变化" [ "$(node_val reality UUID)" != "$uuid" ]
check "重置后密钥变化" [ "$(node_val reality PRIVATE_KEY)" != "$key" ]
vps del reality
check "删除成功" rc_is 0
check "参数文件已删" test ! -e "$VPS_ROOT/etc/vps/nodes/reality.env"
check "没有 Xray 节点后停掉服务" test ! -e "$VPS_ROOT/etc/systemd/system/vps-xray.service"
check "删掉 Xray 内核" test ! -e "$VPS_ROOT/usr/local/lib/vps/bin/xray"
check "没有节点后停掉定时统计" test ! -e "$VPS_ROOT/etc/systemd/system/vps-tick.timer"

echo "== 端口自动选择"
setup
release_xray v25.9.11
echo 443 >"$VPS_ROOT/.stub/busy-tcp"
vps add reality
check "443 被占用时换随机端口" [ "$(node_val reality PORT)" != 443 ]
vps add ws
check "WS 不和 REALITY 冲突" [ "$(node_val ws PORT)" = 8443 ]
vps add ws --port "$(node_val reality PORT)"
check "手动指定其他节点的端口会被拒绝" has "$OUT" "其他节点使用"

echo "== VLESS-WS 无域名"
setup
release_xray v25.9.11
vps add ws
check "添加成功" rc_is 0
pin=$(openssl x509 -in "$VPS_ROOT/etc/vps/certs/ws/cert.pem" -outform der | sha256sum | awk '{print $1}')
check "指纹与证书一致" [ "$(node_val ws PIN)" = "$pin" ]
check "证书带 IP" has "$(openssl x509 -in "$VPS_ROOT/etc/vps/certs/ws/cert.pem" -noout -ext subjectAltName)" "IP Address:203.0.113.10"
check "链接带 pcs 指纹" has "$OUT" "pcs=$pin"
check "链接不带 allowInsecure" lacks "$OUT" "allowInsecure"
check "链接路径已编码" has "$OUT" "path=%2F$(node_val ws WSPATH | tr -d /)"
check "配置用 ws + tls" file_has "$VPS_ROOT/etc/vps/xray/20-ws.json" '"network": "ws"'
check "私钥权限 640" [ "$(stat -c %a "$VPS_ROOT/etc/vps/certs/ws/key.pem")" = 640 ]
vps add ws
check "再次运行不换证书" [ "$(node_val ws PIN)" = "$pin" ]

echo "== VLESS-WS 有域名"
setup
release_xray v25.9.11
vps add ws --domain Proxy.Example.com --email me@example.com
check "添加成功" rc_is 0
check "调用 certbot" called "certbot certonly --standalone"
check "续期后自动复制证书" called "--deploy-hook /usr/local/bin/vps _certhook"
check "域名转小写" [ "$(node_val ws DOMAIN)" = proxy.example.com ]
check "证书已复制" cmp -s "$VPS_ROOT/etc/letsencrypt/live/proxy.example.com/fullchain.pem" "$VPS_ROOT/etc/vps/certs/ws/cert.pem"
check "链接用域名" has "$OUT" "@proxy.example.com:443?encryption=none&security=tls&sni=proxy.example.com"
check "链接不带 pcs" lacks "$OUT" "pcs="
# 续期钩子
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 90 -subj /CN=x \
  -keyout "$VPS_ROOT/etc/letsencrypt/live/proxy.example.com/privkey.pem" \
  -out "$VPS_ROOT/etc/letsencrypt/live/proxy.example.com/fullchain.pem" >/dev/null 2>&1
RENEWED_DOMAINS="proxy.example.com" vps _certhook
check "续期后证书已更新" cmp -s "$VPS_ROOT/etc/letsencrypt/live/proxy.example.com/fullchain.pem" "$VPS_ROOT/etc/vps/certs/ws/cert.pem"
vps add ws --no-domain
check "改为无域名" [ -z "$(node_val ws DOMAIN)" ]
check "删除旧域名证书" called "certbot delete --cert-name proxy.example.com"
check "改为自签证书" [ -n "$(node_val ws PIN)" ]
echo 80 >"$VPS_ROOT/.stub/busy-tcp"
vps add ws --domain other.example.com
check "80 端口被占用时提示" has "$OUT" "80 端口"
check "失败后保持原状" [ -z "$(node_val ws DOMAIN)" ]
rm -f "$VPS_ROOT/.stub/busy-tcp"
touch "$VPS_ROOT/.stub/certbot-fail"
vps add ws --domain other.example.com
check "证书申请失败给出原因" has "$OUT" "域名已解析到本机"

echo "== Hysteria2"
setup
release_hy2 v2.6.4
vps add hy2
check "添加成功" rc_is 0
check "默认 443/udp" [ "$(node_val hy2 PORT)" = 443 ]
cfg=$VPS_ROOT/etc/vps/hy2/config.yaml
check "配置有密码" file_has "$cfg" "password: $(node_val hy2 PASSWORD)"
check "禁止访问本机" file_has "$cfg" "reject(127.0.0.0/8)"
check "统计接口只监听本机" file_has "$cfg" "listen: 127.0.0.1:$(node_val hy2 STATS_PORT)"
check "伪装网站" file_has "$cfg" "url: https://www.bing.com"
check "链接带指纹和 insecure" has "$OUT" "hysteria2://$(node_val hy2 PASSWORD)@203.0.113.10:443/?sni=www.bing.com&insecure=1&pinSHA256=$(node_val hy2 PIN)#"
check "UDP 缓冲区调优" test -f "$VPS_ROOT/etc/sysctl.d/90-vps-hy2.conf"
pass_old=$(node_val hy2 PASSWORD)
vps add hy2 --sni www.yahoo.com
check "换 SNI 后重新签证书" has "$(openssl x509 -in "$VPS_ROOT/etc/vps/certs/hy2/cert.pem" -noout -ext subjectAltName)" "www.yahoo.com"
check "密码不变" [ "$(node_val hy2 PASSWORD)" = "$pass_old" ]
vps add hy2 --sni yahoo.com
check "SNI 整项比较（yahoo.com 不算 www.yahoo.com）" has "$(openssl x509 -in "$VPS_ROOT/etc/vps/certs/hy2/cert.pem" -noout -ext subjectAltName)" "DNS:yahoo.com"
check "证书目录 750" [ "$(stat -c %a "$VPS_ROOT/etc/vps/certs/hy2")" = 750 ]
vps add hy2 --masq ftp://bad
check "拒绝非法伪装网址" rc_is 1
vps reset hy2
check "重置密码" [ "$(node_val hy2 PASSWORD)" != "$pass_old" ]
vps del hy2
check "删除后清掉 sysctl" test ! -e "$VPS_ROOT/etc/sysctl.d/90-vps-hy2.conf"
check "删除 Hysteria2 服务" test ! -e "$VPS_ROOT/etc/systemd/system/vps-hy2.service"

echo "== 失败回滚"
setup
release_xray v25.9.11
vps add reality --sni www.microsoft.com
port=$(node_val reality PORT)
touch "$VPS_ROOT/.stub/fail-vps-xray"
vps port reality 2096
check "启动失败时报错" rc_is 1
check "参数恢复原值" [ "$(node_val reality PORT)" = "$port" ]
check "配置恢复原值" file_has "$VPS_ROOT/etc/vps/xray/10-reality.json" "\"port\": $port"
rm -f "$VPS_ROOT/.stub/fail-vps-xray"
touch "$VPS_ROOT/.stub/xray-test-fail"
vps add reality --sni www.amazon.com
check "配置校验失败时报错" has "$OUT" "配置校验失败"
check "参数未改" [ "$(node_val reality SNI)" != www.amazon.com ]
rm -f "$VPS_ROOT/.stub/xray-test-fail"

echo "== 防火墙"
setup
release_xray v25.9.11
touch "$VPS_ROOT/.stub/ufw-active"
vps add reality --port 2443
check "ufw 放行新端口" called "ufw allow 2443/tcp"
vps port reality 3443
check "ufw 放行换后的端口" called "ufw allow 3443/tcp"
check "ufw 关闭旧端口" called "ufw delete allow 2443/tcp"
vps del reality
check "删除节点时关闭端口" called "ufw delete allow 3443/tcp"

echo "== 服务管理"
setup
release_xray v25.9.11
release_hy2 v2.6.4
vps add reality
vps add hy2
vps stop
check "停止全部" bash -c '! [ -f "$VPS_ROOT/.stub/systemd/vps-xray.active" ] && ! [ -f "$VPS_ROOT/.stub/systemd/vps-hy2.active" ]'
check "停止后取消开机自启" bash -c '! [ -f "$VPS_ROOT/.stub/systemd/vps-xray.enabled" ]'
vps status
check "状态显示已停止" has "$OUT" "已停止"
vps start hy2
check "只启动 Hysteria2" bash -c '[ -f "$VPS_ROOT/.stub/systemd/vps-hy2.active" ] && ! [ -f "$VPS_ROOT/.stub/systemd/vps-xray.active" ]'
vps restart
check "重启全部" active vps-xray
vps log
check "查看日志" called "journalctl -u vps-xray -u vps-hy2"
vps start nothing
check "拒绝未知服务" rc_is 1

echo "== 分享地址"
setup
release_xray v25.9.11
vps add reality
vps host 2001:db8::1
vps show reality
check "IPv6 地址加方括号" has "$OUT" "@[2001:db8::1]:"
vps host proxy.example.com
vps show reality
check "可以用域名" has "$OUT" "@proxy.example.com:"
vps host 'bad host'
check "拒绝非法地址" rc_is 1

summary
