#!/usr/bin/env bash
# lib/deploy.sh — Xray 安装、配置生成、systemd、防火墙、BBR

# 解析 xray x25519 的输出，兼容多种版本格式。
# 旧版: "Private key: <priv>" / "Public key: <pub>"
# 新版: "PrivateKey: <priv>"  / "Password: <pub>"
# 输出: "<priv>|<pub>"，任一缺失则对应位置为空
xray_parse_keys() {
  local raw="$1" priv='' pub='' line key val
  while IFS= read -r line; do
    # 兼容 "key: value" 与 "key=value" 两种写法
    if [[ "$line" == *=* && "$line" != *:* ]]; then
      key="${line%%=*}"
      val="${line#*=}"
    elif [[ "$line" == *:* ]]; then
      key="${line%%:*}"
      val="${line#*:}"
    else
      # 既无 ':' 也无 '=' 的行：上面两种取法都会把整行当成 key 和 val，
      # 例如单独一行 "PrivateKey" 会被误判成私钥 "PrivateKey" → 必须跳过。
      continue
    fi
    key=$(trim "$key")
    val=$(trim "$val")
    [[ -z "$val" ]] && continue
    case "${key,,}" in
      *private*)  [[ -z "$priv" ]] && priv="$val" ;;
      *public*|*password*) [[ -z "$pub" ]] && pub="$val" ;;
    esac
  done <<<"$raw"

  [[ -z "$priv" && -z "$pub" ]] && return 1
  printf '%s|%s' "$priv" "$pub"
  return 0
}

# 调用 xray 生成 REALITY 密钥对、UUID 与 shortId
gen_keys() {
  local raw
  raw=$("$XRAY_BIN" x25519 2>/dev/null) || { tui_err "执行 xray x25519 失败"; return 1; }
  local parsed
  parsed=$(xray_parse_keys "$raw") || { tui_err "无法解析 xray x25519 输出：$raw"; return 1; }
  PRIVATE_KEY="${parsed%%|*}"
  PUBLIC_KEY="${parsed#*|}"
  [[ -z "$PRIVATE_KEY" ]] && { tui_err "未能取得 REALITY 私钥"; return 1; }
  [[ -z "$PUBLIC_KEY" ]] && { tui_err "未能取得 REALITY 公钥"; return 1; }
  UUID=$("$XRAY_BIN" uuid 2>/dev/null | tr -d '[:space:]')
  [[ -z "$UUID" ]] && { tui_err "执行 xray uuid 失败"; return 1; }
  # UUID 必须是规范形态：xray uuid 失败时可能把错误信息写进 stdout，
  # 那样会被原样写进 config.json → 失败点被推迟到 xray 校验，
  # 报错与真实原因完全无关。
  [[ "$UUID" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] \
    || { tui_err "xray uuid 输出的 UUID 格式非法：$UUID"; return 1; }

  # random_hex 失败时返回非零（且输出可能为空）→ 必须检查，否则空 SHORT_ID
  # 会被原样写进 config.json，xray 校验失败时报错与真实原因无关。
  SHORT_ID=$(random_hex 4) || { tui_err "生成 ShortID 失败（openssl / od 不可用？）"; return 1; }
  [[ -n "$SHORT_ID" ]] || { tui_err "生成的 ShortID 为空"; return 1; }
  tui_ok "密钥对已生成"
  tui_kv "公钥 (pbk)" "$PUBLIC_KEY"
  tui_kv "ShortID (sid)" "$SHORT_ID"
  tui_kv "UUID" "$UUID"
  return 0
}

# 渲染服务端 config.json
#
# 契约（重要，Task 5 修订轮 1 补明）：
#   · 本函数只把配置写到【调用方指定的路径】并 chmod 600，**不做 xray 校验**；
#     校验与落位到正式路径由 write_config_atomic 负责。
#   · 调用方**必须**传一个【暂存路径】（例如 mktemp 出来的文件），
#     绝不能把正式配置路径直接传进来 —— 那会绕过 xray run -test 校验。
#   · 内部暂存名用 ".render" 后缀，与 write_config_atomic 的 ".new" 区分开，
#     避免两者在同一条路径上撞名。
render_server_config() {
  local outfile="$1" uuid="$2" priv="$3" sni="$4" port="$5" sid="$6"
  # ── 入参白名单校验（必须【先做】）────────────────────────────
  # 本函数用【未加引号的 heredoc】渲染 JSON → 入参里的 $(...) / 反引号会被
  # 【真实执行】。控制器实证：把 '$(echo PWNED)' 传进 ShortID 或 SNI，
  # 该命令被执行并把结果写进了 config.json。
  # 当前所有调用方恰好都校验过输入（Task 8 校验 --sni/--port，向导校验端口），
  # 但「安全性靠调用方自觉」不是函数契约 —— 下面的白名单让 5 个入参
  # 只可能含有安全字符，从根上关死注入面。
  [[ "$uuid" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] \
    || { tui_err "UUID 格式非法：$uuid"; return 1; }
  [[ "$priv" =~ ^[A-Za-z0-9_-]{40,64}$ ]] \
    || { tui_err "REALITY 私钥格式非法（只允许 base64url 字符，长度 40-64）"; return 1; }
  [[ "$port" =~ ^[0-9]{1,5}$ ]] && [[ "$port" -ge 1 && "$port" -le 65535 ]] \
    || { tui_err "端口非法：$port"; return 1; }
  [[ "$sid" =~ ^[0-9a-fA-F]{2,16}$ ]] \
    || { tui_err "ShortID 格式非法（只允许十六进制，长度 2-16）：$sid"; return 1; }
  validate_hostname "$sni" || { tui_err "SNI 主机名非法：$sni"; return 1; }

  # 目标路径如果是【已存在的目录】：后面的 `mv -f "$tmp" "$outfile"` 会把文件
  # 【移进目录里】而不是替换目标 → mv 返回 0（看起来成功）但配置根本没落到
  # outfile → 调用方以为渲染成功，实际拿到的不是配置。必须先挡住。
  [[ -d "$outfile" ]] && { tui_err "目标路径是目录，不能作为配置文件：$outfile"; return 1; }
  local tmp="$outfile.render"
  # cat 的退出码必须检查：目标目录不存在时，重定向失败会漏出原始 bash 报错，
  # 用户看到的是「No such file or directory」而不是我们自己的提示。
  if ! cat >"$tmp" <<EOF
{
  "log": {
    "loglevel": "warning",
    "access": "/var/log/xray/access.log",
    "error": "/var/log/xray/error.log"
  },
  "inbounds": [
    {
      "tag": "vless-reality-in",
      "listen": "0.0.0.0",
      "port": ${port},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${uuid}",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "target": "${sni}:443",
          "xver": 0,
          "serverNames": [
            "${sni}"
          ],
          "privateKey": "${priv}",
          "shortIds": [
            "${sid}"
          ]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls",
          "quic"
        ],
        "routeOnly": false
      }
    }
  ],
  "outbounds": [
    {
      "tag": "direct",
      "protocol": "freedom",
      "settings": {
        "domainStrategy": "UseIP"
      }
    },
    {
      "tag": "block",
      "protocol": "blackhole",
      "settings": {
        "response": {
          "type": "http"
        }
      }
    }
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      {
        "type": "field",
        "ip": [
          "127.0.0.0/8",
          "10.0.0.0/8",
          "172.16.0.0/12",
          "192.168.0.0/16",
          "fc00::/7",
          "fe80::/10"
        ],
        "outboundTag": "block"
      }
    ]
  }
}
EOF
  then
    tui_err "无法写入配置暂存文件：$tmp"
    rm -f "$tmp"
    return 1
  fi
  # 含 REALITY 私钥 → 600。必须在 mv 之前设好：
  # 否则「权限设置失败」时文件已经落位，函数却返回非零 → 调用方以为失败而重试，
  # 留下一份权限不对的正式配置。
  chmod 600 "$tmp" || { tui_err "无法设置暂存文件权限：$tmp"; rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$outfile" || { tui_err "无法写入配置：$outfile"; rm -f "$tmp"; return 1; }
}

# 判断一段 xray 报错是不是「这个写法不被支持」而不是「配置本身有问题」。
# 只认 -c 的旧版本上，`xray run -test -config f` 报 "unknown flag: -test"；
# 现代版本上 `xray -test -config f` 报同类错 —— 它们只说明【我们试的写法不对】，
# 对用户毫无价值。用户要看的永远是「配置本身有问题」的那条。
xray_err_is_unsupported() {
  case "$1" in
    *"unknown flag"*|*"flag provided but not defined"*|*"unknown shorthand flag"*|\
    *"unknown command"*|*"invalid command"*|*"unknown syntax"*|*"unrecognized"*)
      return 0 ;;
  esac
  return 1
}

# 校验配置可用。兼容不同 xray 版本的子命令写法。
# 失败时把【最有信息量】的 stderr 留在 XRAY_TEST_ERR 里 ——
# 写配置失败时要把 xray 的原始报错给用户看，而不同版本认的子命令不同。
# 关键：三种写法依次尝试时必须区分两种失败 ——
#   ①「这个写法不被支持」（unknown flag / unknown command 等）
#   ②「配置本身有问题」（failed to parse config: ...）
# 用户要看的永远是 ②。① 只说明我们试的写法不对。
# 旧实现只保留【最后一次】尝试的报错 → 现代 xray 上最后一次用的是旧语法
# → 必然报 "unknown flag: -test" / "unknown command" → 用户看到的是
# 完全无关的误导性报错（控制器独立复评 D1 实证）。
XRAY_TEST_ERR=''
xray_test_config() {
  local cfg="$1" e='' first=''
  XRAY_TEST_ERR=''
  # 注意：stderr 必须用【命令替换】捕获，不能写成 2>"$XRAY_TEST_ERR" ——
  # 变量为空时那是一次「重定向到空文件名」，bash 报的是
  # "No such file or directory"（看起来像命令找不到，真相是重定向失败），
  # 而且命令根本没被执行。控制器实测踩过。
  e=$( { "$XRAY_BIN" run -test -config "$cfg" >/dev/null; } 2>&1 )
  if [[ $? -eq 0 ]]; then XRAY_TEST_ERR="$e"; return 0; fi
  first="$e"
  # 判定条件是【有内容】且【不是「写法不被支持」】才停在这里：
  #   · stderr 为空 → 这一种写法没给出任何信息 → 必须继续试下一种，
  #     否则「只认 -c 的版本」上第 1 种写法失败就直接返回 1 → 后面两种根本没试。
  #   · stderr 是「写法不被支持」→ 同理，继续试下一种。
  # 只有「确实有内容、且说的是配置本身有问题」才停 —— 那才是用户要看的。
  if [[ -n "$e" ]] && ! xray_err_is_unsupported "$e"; then XRAY_TEST_ERR="$e"; return 1; fi
  e=$( { "$XRAY_BIN" run -test -c "$cfg" >/dev/null; } 2>&1 )
  if [[ $? -eq 0 ]]; then XRAY_TEST_ERR="$e"; return 0; fi
  if [[ -n "$e" ]] && ! xray_err_is_unsupported "$e"; then XRAY_TEST_ERR="$e"; return 1; fi
  e=$( { "$XRAY_BIN" -test -config "$cfg" >/dev/null; } 2>&1 )
  if [[ $? -eq 0 ]]; then XRAY_TEST_ERR="$e"; return 0; fi
  if [[ -n "$e" ]] && ! xray_err_is_unsupported "$e"; then XRAY_TEST_ERR="$e"; return 1; fi
  # 三种写法都不被支持 → 只能给出第一次的报错（至少证明我们试过）
  XRAY_TEST_ERR="$first"
  return 1
}

# 写临时文件 → 校验 → 原子替换。校验失败保留旧文件并输出 xray 报错。
# 用法: write_config_atomic <目标文件> <源文件>
#   源文件是刚渲染出来的配置（尚未落位）；本函数负责把它校验后原子替换到目标。
#   这条路径是【唯一】的写服务端配置入口 —— do_deploy 与 menu_rotate_keys 都必须走它，
#   不得各自手写「渲染 → 校验 → mv」。两处手写必然分叉：menu_rotate_keys 那份当年
#   就漏了输出 xray 的原始报错，用户只看到一句「新配置校验未通过」。
write_config_atomic() {
  local outfile="$1" src="$2"
  local tmp="$outfile.new"
  [[ -f "$src" ]] || { tui_err "源配置不存在：$src"; return 1; }
  # 同 render_server_config：目标路径是【已存在的目录】时，
  # `mv -f "$tmp" "$outfile"` 会把文件移进目录里 → mv 返回 0（看起来成功）
  # 但配置根本没落位。必须先挡住。
  [[ -d "$outfile" ]] && { tui_err "目标路径是目录，不能作为配置文件：$outfile"; return 1; }
  # cp 失败时必须清理【半截的】临时文件：cp 可能已经写出了一部分内容，
  # 留着它会让下一次写配置的校验去校验一份残缺文件。
  cp "$src" "$tmp" || { tui_err "无法写入临时文件：$tmp"; rm -f "$tmp"; return 1; }
  # 服务端配置含 REALITY 私钥 → 权限必须 600（计划里其余含密文件一律 600）。
  # systemd unit 没有 User= → xray 以 root 运行 → 600 不会挡住它读配置。
  chmod 600 "$tmp" || { tui_err "无法设置临时文件权限：$tmp"; rm -f "$tmp"; return 1; }
  if ! xray_test_config "$tmp"; then
    tui_err "配置校验未通过，已保留原有配置不变。"
    # 全局约束要求【原样输出】xray 的报错 → 这里不加任何缩进/改写。
    # 早先的实现在这里加了 6 个空格的缩进（sed 's/^/      /'），
    # 与约束的字面要求不一致（控制器独立复评 D4）。
    if [[ -n "$XRAY_TEST_ERR" ]]; then
      printf '%s\n' "$XRAY_TEST_ERR"
    else
      "$XRAY_BIN" run -test -config "$tmp" 2>&1 || true
    fi
    rm -f "$tmp"
    return 1
  fi
  mv -f "$tmp" "$outfile" || { tui_err "无法写入配置文件：$outfile"; rm -f "$tmp"; return 1; }
  chmod 600 "$outfile" || { tui_err "无法设置配置文件权限：$outfile"; return 1; }
  return 0
}
xray_installed() { [[ -x "$XRAY_BIN" ]]; }

xray_version() {
  "$XRAY_BIN" version 2>/dev/null | head -1 | tr -d '\r'
}

install_xray() {
  if xray_installed; then
    tui_ok "Xray 已安装：$(xray_version)"
    tui_tip "如需更新请使用管理菜单的「更新 Xray 内核」"
    return 0
  fi
  # 依赖装不上就必须中止：ensure_packages 会透传 apt 的失败码。
  ensure_packages curl ca-certificates || return 1
  local installer
  installer=$(mktemp 2>/dev/null)
  # mktemp 必须有空值守卫：失败时 installer 为空 → curl -o "" 失败，
  # 报错会指向「网络」而真实原因是 mktemp 不可用。
  if [[ -z "$installer" ]]; then
    tui_err "无法创建临时文件，Xray 安装中止。"
    return 1
  fi
  if ! curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh -o "$installer"; then
    tui_err "下载 Xray 安装脚本失败，请检查网络连通性"
    rm -f "$installer"
    return 1
  fi
  chmod +x "$installer"
  tui_run "安装 Xray 内核" bash "$installer" install
  local rc=$?
  rm -f "$installer"
  if [[ $rc -ne 0 ]] || ! xray_installed; then
    tui_err "Xray 安装失败"
    return 1
  fi
  tui_ok "Xray 安装完成：$(xray_version)"
  return 0
}

setup_systemd() {
  if ! have_cmd systemctl; then
    tui_err "未找到 systemctl，systemd 不可用"
    return 1
  fi
  tui_run "启用并启动 xray 服务" systemctl enable --now xray
  if ! systemctl is-active --quiet xray; then
    tui_err "xray 服务未能启动，最近日志如下："
    journalctl -u xray -n 30 --no-pager 2>/dev/null | sed -e 's/^/      /' || true
    return 1
  fi
  # 依据实际运行用户授权日志目录
  local run_user svc_user
  run_user=$(service_run_user)
  if [[ "$run_user" != "root" ]]; then
    svc_user="$run_user"
    # mkdir 的退出码必须检查：失败时后面仍然会打印「日志目录已授权」→ 谎报。
    # 目录建不出来时 xray 写不了日志，用户却以为一切正常。
    if ! mkdir -p "$LOG_DIR"; then
      tui_warn "无法创建日志目录 $LOG_DIR，xray 可能无法写入日志。"
    else
      if id "$svc_user" >/dev/null 2>&1; then
        chown -R "$svc_user" "$LOG_DIR" 2>/dev/null || true
      fi
      tui_tip "日志目录已授权给运行用户 $svc_user"
    fi
  fi
  tui_ok "xray 服务已运行"
  return 0
}

restart_service() {
  tui_run "重启 xray 服务" systemctl restart xray
  if systemctl is-active --quiet xray; then
    tui_ok "xray 服务重启成功"
    return 0
  fi
  tui_err "xray 服务重启后未处于运行状态"
  journalctl -u xray -n 30 --no-pager 2>/dev/null | sed -e 's/^/      /' || true
  return 1
}

open_firewall() {
  local port="$1"
  # ufw 的状态检测【不能】写成 `ufw status | grep -q ...`：
  # grep -q 命中即退出 → 上游 ufw 收到 SIGPIPE(141) → set -o pipefail 下整条管道
  # 的退出码变成 141 → 条件判假 → 【ufw 明明是 active 也不会走 ufw 分支】，
  # 静默降级到 iptables / nft 分支（与 Task 4 的 F4-1 同一个坑）。
  # 修法与 F4-1 一致：先把整段输出收进变量，再对变量做匹配
  # （链路上没有任何会早退的管道 → 不可能有 SIGPIPE）。
  if have_cmd ufw; then
    local ufw_status
    ufw_status=$(ufw status 2>/dev/null || printf '')
    if [[ "$ufw_status" == *"Status: active"* ]]; then
      tui_run "放行端口 $port/tcp (ufw)" ufw allow "$port/tcp"
      return $?
    fi
  fi
  if have_cmd iptables; then
    if iptables -C INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null; then
      tui_ok "iptables 规则已存在，无需重复添加"
      return 0
    fi
    tui_run "放行端口 $port/tcp (iptables)" iptables -I INPUT -p tcp --dport "$port" -j ACCEPT
    return $?
  fi
  if have_cmd nft; then
    nft list table inet filter >/dev/null 2>&1 || {
      nft add table inet filter 2>/dev/null || true
      nft add chain inet filter input '{ type filter hook input priority 0; policy accept; }' 2>/dev/null || true
    }
    if nft list chain inet filter input 2>/dev/null | grep -q "tcp dport $port"; then
      tui_ok "nftables 规则已存在，无需重复添加"
    else
      # 失败必须传播出去：原来这一分支不管 nft insert 成功与否都 return 0，
      # 调用方（do_deploy）会以为端口已放行。
      tui_run "放行端口 $port/tcp (nftables)" nft insert rule inet filter input tcp dport "$port" ct state new counter accept || return 1
    fi
    if have_cmd systemctl && systemctl is-enabled nftables >/dev/null 2>&1; then
      tui_tip "nftables 规则由 nftables.service 管理，重启后可能丢失；建议同步写入 /etc/nftables.conf"
    fi
    return 0
  fi
  tui_warn "未检测到 ufw / iptables / nftables，未改动防火墙。"
  tui_tip "请自行放行端口：$port/tcp"
  return 0
}

enable_bbr() {
  local avail
  avail=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || printf '')
  if [[ "$avail" != *bbr* ]]; then
    tui_warn "当前内核未提供 bbr 拥塞控制，跳过网络调优。"
    tui_tip "可用算法：${avail:-未知}"
    return 1
  fi
  # 配置路径可被环境变量覆盖 —— 仅为让单元测试能在【不碰宿主机内核参数】的前提下
  # 覆盖成功路径；生产环境不要设置它。
  local conf="${VLESS_REALITY_SYSCTL_CONF:-/etc/sysctl.d/99-vless-reality-bbr.conf}"
  local bbr_conf
  bbr_conf='net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_fastopen = 3
net.core.somaxconn = 4096
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_slow_start_after_idle = 0'
  # 写失败必须报错并返回非零：原来 `cat >"$conf"` 的失败被后面的 `|| true` 吃掉，
  # 函数照样 tui_ok「已启用 bbr」并返回 0 —— 失败被伪装成成功。
  if ! printf '%s\n' "$bbr_conf" >"$conf"; then
    tui_err "无法写入 sysctl 配置：$conf"
    tui_tip "可能缺少 root 权限，或该目录不可写。"
    return 1
  fi
  if ! sysctl -p "$conf" >/dev/null 2>&1 && ! sysctl --system >/dev/null 2>&1; then
    tui_err "内核参数应用失败：$conf"
    tui_tip "可能缺少 root 权限。"
    return 1
  fi
  tui_ok "已启用 bbr 拥塞控制与 fq 队列（$conf）"
  return 0
}

service_status() {
  if have_cmd systemctl; then
    local active enabled
    # 必须用 `|| true` 而不是 `|| printf 'unknown'`：
    # systemctl is-active 在服务停止时【会输出 "inactive" 并返回非零】，
    # `|| printf 'unknown'` 会把 unknown 追加到后面 → 状态显示成两行
    # （"inactive\nunknown"），界面上看着像出了两个状态。
    # 正确做法是保留 systemctl 的输出，只在它【一个字都没输出】时才回落到 unknown。
    active=$(systemctl is-active xray 2>/dev/null || true)
    [[ -n "$active" ]] || active='unknown'
    enabled=$(systemctl is-enabled xray 2>/dev/null || true)
    [[ -n "$enabled" ]] || enabled='unknown'
    tui_kv "服务状态" "$active"
    tui_kv "开机自启" "$enabled"
    tui_kv "内核版本" "$(xray_version 2>/dev/null || printf '未安装')"
  fi
  if have_cmd ss && [[ -n "${PORT:-}" ]]; then
    if port_in_use "$PORT"; then
      tui_kv "端口 $PORT" "监听中"
    else
      tui_kv "端口 $PORT" "未监听"
    fi
  fi
}
# 并发探测候选伪装目标：TLS1.3 支持 + 连通延迟，按延迟升序输出 "host|tls|latency"
# 未知延迟（'?'）视为最大，排在最后
probe_targets() {
  local host tmp sortkey h t l pid
  tmp=$(mktemp)
  # mktemp 失败时 tmp 为空 → 后面会写出 ".<host>" 污染当前目录 → 必须守卫。
  if [[ -z "$tmp" ]]; then
    # ⚠️ 诊断信息必须走 stderr：调用方是 `probe=$(probe_targets)` ——
    #    tui_err 默认写 stdout → 这条报错会被当成【探测数据】吞进 probe，
    #    于是 choose_target 拿到的是一段错误文本而不是空串 → 解析出垃圾主机名。
    tui_err "无法创建临时文件，目标探测中止" >&2
    return 1
  fi
  local -a pids=() hosts=()
  for host in "${REALITY_TARGETS[@]}"; do
    (
      t='fail'
      target_supports_tls13 "$host" && t='ok'
      l=$(target_latency_ms "$host")
      printf '%s|%s|%s\n' "$host" "$t" "$l" >"$tmp.$host"
    ) &
    pids+=($!)
    hosts+=("$host")
  done
  # 循环变量是 PID，不是主机名 —— 名字写错会让人以为 wait 的是 host。
  for pid in "${pids[@]}"; do wait "$pid" 2>/dev/null || true; done
  for host in "${hosts[@]}"; do
    [[ -f "$tmp.$host" ]] || continue
    IFS='|' read -r h t l <"$tmp.$host"
    sortkey="$l"
    [[ -z "$sortkey" || "$sortkey" == '?' ]] && sortkey=999999
    printf '%s|%s|%s|%s\n' "$sortkey" "$h" "$t" "$l"
    rm -f "$tmp.$host"
  done | sort -t'|' -k1,1n -k2,2 | cut -d'|' -f2-
  rm -f "$tmp"
}

choose_target() {
  local probe line host tls lat
  probe=$(probe_targets)
  if [[ -z "$probe" ]]; then
    # ⚠️ 提示语必须走 stderr：调用方是 `SNI=$(choose_target)` ——
    #    tui_warn 默认写 stdout → 这条提示会被当成【主机名】吞进去，
    #    SNI 变成「提示文本 + 主机名」的多行串 → 写进 config.json 就是废配置。
    tui_warn "目标探测不可用，回退默认：www.microsoft.com" >&2
    printf 'www.microsoft.com'; return 0
  fi
  local -a labels=() hosts=()
  while IFS='|' read -r host tls lat; do
    [[ -z "$host" ]] && continue
    hosts+=("$host")
    if [[ "$tls" == 'ok' ]]; then
      labels+=("${host}    TLS1.3 ✔   ${lat}ms")
    else
      labels+=("${host}    TLS1.3 ✘   ${lat}ms")
    fi
  done <<<"$probe"

  # 用 ${OPT_YES:-0} 而不是 $OPT_YES：OPT_* 是 install.sh 的全局，
  # deploy.sh 单独被 source（单元测试 / helper）时它们可能根本没定义，
  # 在 `set -u` 下会直接报 unbound variable。
  if [[ ${OPT_YES:-0} -eq 1 ]]; then
    # 自动挑选第一个支持 TLS1.3 且延迟已知的目标
    local pick=''
    while IFS='|' read -r host tls lat; do
      if [[ "$tls" == 'ok' && "$lat" != '?' ]]; then pick="$host"; break; fi
    done <<<"$probe"
    [[ -z "$pick" ]] && pick="${hosts[0]}"
    printf '%s' "$pick"; return 0
  fi

  # 交由 tui_menu 统一渲染，避免重复打印列表
  # tui_menu 把整张菜单打到 stdout，【不能】用 $(...) 捕获——那样拿到的是菜单文本。
  # 必须用返回码取选中项。注意返回码本身就是 0-based 索引：
  #   0  = 选中第一项（成功）
  #   1..n-1 = 选中第 n 项（成功，但也是非零码，不能用 && || 区分）
  #   255 = 用户取消
  local sel=0 rc=0
  # 必须把 tui_menu 的输出重定向到 stderr：tui_menu 会把【整张菜单】打到 stdout，
  # 而调用方是 `SNI=$(choose_target)` —— 不重定向的话，SNI 会变成
  # 「菜单标题 + 选项列表 + 选中的 host」的多行字符串，随后被原样写进
  # config.json → JSON 非法 → xray run -test 失败 → 部署以一句看不懂的报错中止。
  # 选中项一律用【返回码】取，stdout 只留最后 printf 的那个 host。
  tui_menu "选择 REALITY 伪装目标（SNI）" "${labels[@]}" >&2 || rc=$?
  if (( rc == 255 )); then
    # ⚠️ 提示语必须走 stderr：调用方是 `SNI=$(choose_target)` ——
    #    tui_warn 默认写 stdout → 这条提示会被当成【主机名】吞进去。
    tui_warn "未选择伪装目标，回退到第一项" >&2
    sel=0
  else
    sel=$rc
  fi
  printf '%s' "${hosts[$sel]}"
}

do_deploy() {
  tui_section "执行部署"

  tui_step "① 安装 Xray 内核"
  install_xray || { tui_err "Xray 安装失败，部署中止"; return 1; }

  tui_step "② 生成 REALITY 密钥与 UUID"
  gen_keys || { tui_err "密钥生成失败，部署中止"; return 1; }
  [[ -n "${OPT_UUID:-}" ]] && UUID="${OPT_UUID:-}"

  tui_step "③ 生成服务端配置"
  mkdir -p "$(dirname "$XRAY_CONFIG")" || { tui_err "无法创建配置目录：$(dirname "$XRAY_CONFIG")"; return 1; }
  local cfg
  # mktemp 必须有空值守卫：失败时 cfg 为空 → render_server_config 会写到 ".new"
  # 污染当前目录（还可能在仓库里），而 mv 会因为空路径而失败。
  cfg=$(mktemp 2>/dev/null)
  if [[ -z "$cfg" ]]; then
    tui_err "无法创建临时文件，部署中止。"
    return 1
  fi
  render_server_config "$cfg" "$UUID" "$PRIVATE_KEY" "$SNI" "$PORT" "$SHORT_ID" || { rm -f "$cfg"; return 1; }
  # 写服务端配置【必须】走 write_config_atomic（复制到临时文件 → xray 校验 → 原子替换），
  # 不要在这里手写「校验 + 替换」：两处手写会分叉（menu_rotate_keys 当年就漏了
  # 输出 xray 的原始报错），而且手写版本漏掉了 mv/chmod 的失败检查。
  write_config_atomic "$XRAY_CONFIG" "$cfg" || { rm -f "$cfg"; return 1; }
  rm -f "$cfg"
  tui_ok "服务端配置已写入：$XRAY_CONFIG"

  tui_step "④ 配置 systemd 服务"
  setup_systemd || { tui_err "systemd 配置失败，部署中止"; return 1; }

  tui_step "⑤ 放行防火墙端口 $PORT/tcp"
  # 防火墙放行失败【不中止】部署（用户可能用云安全组/云防火墙管端口），
  # 但必须把失败状态带进最终的「部署完成」面板 ——
  # 否则用户看到「部署完成」就以为端口通了，实际客户端连不上。
  FIREWALL_OK=1
  if ! open_firewall "$PORT"; then
    tui_warn "防火墙放行未成功，请手工确认"
    FIREWALL_OK=0
  fi

  tui_step "⑥ 网络调优"
  enable_bbr || tui_tip "已跳过网络调优（非致命）"

  tui_ok "部署完成"
  return 0
}

deploy_wizard() {
  tui_section "部署参数"

  # 端口
  PORT="${OPT_PORT:-443}"
  # ⚠️ 端口探测不可用时必须提示：
  #    port_in_use 在【既没有 ss 也没有 netstat】时恒返回 1（= 端口空闲）
  #    → 用户以为端口干净 → 部署走到 systemd 阶段才炸，
  #    而且首句报错是「systemd 配置失败」，与真正原因（端口被占）无关。
  if ! have_cmd ss && ! have_cmd netstat; then
    tui_warn "无法确认端口是否空闲（系统缺少 ss 与 netstat）"
    tui_tip "若部署时报端口被占用，请用 --port 指定其它端口。"
  fi
  if port_in_use "$PORT"; then
    local occ
    occ=$(port_occupant "$PORT")
    tui_warn "端口 $PORT 已被占用${occ:+（$occ）}"
    if [[ ${OPT_YES:-0} -eq 1 ]]; then
      PORT=$(random_free_port)
      # ⚠️ random_free_port 的兜底端口 44321 从未校验过是否被占用
      #    → 这里【必须】再验一次，否则会把一个占用端口写进 config.json，
      #    直到 systemd 阶段才以「address already in use」失败。
      [[ -n "$PORT" ]] || { tui_err "找不到空闲端口，部署中止。"; return 1; }
      if port_in_use "$PORT"; then
        tui_err "端口 $PORT 仍被占用，部署中止。"
        return 1
      fi
      tui_tip "已自动改用空闲端口：$PORT"
    else
      # 同上：用返回码取选中项，不要用 $(...) 捕获 stdout
      local choice=0 crc=0
      tui_menu "如何处理端口冲突？" \
        "改用随机空闲端口" \
        "我手动指定其它端口" \
        "取消部署" || crc=$?
      if (( crc == 255 )); then
        choice=2
      else
        choice=$crc
      fi
      case $choice in
        0) PORT=$(random_free_port)
            [[ -n "$PORT" ]] || { tui_err "找不到空闲端口，部署中止。"; return 1; }
            if port_in_use "$PORT"; then
              tui_err "端口 $PORT 仍被占用，部署中止。"
              return 1
            fi
            tui_tip "已改用端口 $PORT" ;;
        1) PORT=$(tui_input "请输入新端口" "$PORT" "1-65535")
            # 用 10# 前缀：裸算术会把 "08" 当八进制，直接报「value too great for base」。
            # ⚠️ 必须是 10#$PORT（带 $）：bash 不会在 10# 后解析【变量名】，
            #    10#PORT 会被当成「以 10 为基的数字 PORT」→ 直接报
            #    "value too great for base" → 用户手动指定的端口【必然】被判非法。
            [[ "$PORT" =~ ^[0-9]+$ ]] && (( 10#$PORT > 0 && 10#$PORT < 65536 )) || { tui_err "端口非法"; return 1; }
            # 手动指定的端口同样必须复查占用：只校验范围不校验占用 →
            # 用户会一路走到 systemd 才炸，首句报错是「systemd 配置失败」，
            # 与真实原因（端口被占）完全无关 —— 正是本轮修掉的 T9-7 抱怨过的那类错。
            if port_in_use "$PORT"; then
              tui_err "端口 $PORT 已被占用，请另选一个。"
              return 1
            fi ;;
        *) tui_info "已取消部署"; return 1 ;;
      esac
    fi
  fi

  # SERVER_IP 由 preflight 负责探测，但 --menu 路径【不经过 preflight】
  # （install.sh 的 --menu 分支只有 require_root + load_state + management_menu）。
  # 未部署时 load_state 什么都没赋值 → SERVER_IP 未绑定：
  #   · 引用它 → set -u 下 bash 直接退出，用户只看到 "SERVER_IP: unbound variable"；
  #   · 即使补了全局声明，空的 SERVER_IP 也会让分享链接变成 "vless://uuid@:443?..."
  #     → 主机名为空 → 客户端导入即废。
  # 所以这里必须自己兜底探测一次。
  if [[ -n "${OPT_ADDR:-}" ]]; then
    # 用户手工指定了对外地址 → 优先用它（NAT 后的服务器探测到的只是内网 IP）
    SERVER_IP="$OPT_ADDR"
  elif [[ -z "${SERVER_IP:-}" ]]; then
    SERVER_IP=$(detect_public_ip 2>/dev/null || true)
    [[ -n "$SERVER_IP" ]] || SERVER_IP=$(detect_local_ip 2>/dev/null || true)
    if [[ -z "$SERVER_IP" ]]; then
      tui_err "无法探测到本机地址，部署中止。"
      tui_tip "可用 --addr 手工指定对外地址，或检查出网是否正常。"
      return 1
    fi
    tui_warn "未能自动探测到公网地址，已回退使用本机地址：$SERVER_IP"
  fi

  # 伪装目标
  SNI="${OPT_SNI:-}"
  if [[ -z "$SNI" ]]; then
    SNI=$(choose_target)
  fi
  TARGET="$SNI"
  [[ -z "$SNI" ]] && { tui_err "未确定伪装目标"; return 1; }
  tui_kv "伪装目标 (SNI)" "$SNI"

  # 备注
  REMARK="${OPT_NAME:-$SNI}"

  # 确认
  tui_panel "即将应用的配置" \
    "服务器地址|$SERVER_IP" \
    "监听端口|$PORT" \
    "伪装目标|$SNI" \
    "备注|$REMARK" \
    "UUID|${OPT_UUID:-自动生成}" \
    "REALITY 密钥|自动生成" \
    "内核|原生二进制 + systemd"

  if [[ ${OPT_YES:-0} -eq 0 ]]; then
    tui_confirm "确认开始部署？" "y" || { tui_info "已取消"; return 1; }
  fi

  do_deploy || return 1

  # 保存状态
  MODE='native'
  FLOW='xtls-rprx-vision'
  FINGERPRINT='chrome'
  # 状态没落盘就必须停在这里：继续往下走会打印「部署完成」面板，
  # 而 --status 会显示未部署、卸载流程拿不到端口 → 防火墙规则被遗留。
  save_state || { tui_err "状态保存失败，部署状态未落盘。"; return 1; }

  # 客户端物料
  tui_section "客户端物料"
  # 同理：物料导出失败必须报错退出，不能让「部署完成」面板指向不存在的 client.json。
  export_client_artifacts "$OUT_DIR" "$UUID" "$SERVER_IP" "$PORT" "$SNI" "$PUBLIC_KEY" "$SHORT_ID" "$REMARK" \
    || { tui_err "客户端物料导出失败。"; return 1; }

  local link
  link=$(build_share_link "$UUID" "$SERVER_IP" "$PORT" "$SNI" "$PUBLIC_KEY" "$SHORT_ID" "$REMARK")
  # 生成为空说明参数不全（缺 UUID/公钥/地址）→ 空的分享链接框用户会直接复制走，
  # 粘到客户端就是一条废链接。必须报错退出。
  [[ -n "$link" ]] || { tui_err "分享链接生成为空，部署结果不可用。"; return 1; }
  # 防火墙那一行必须如实反映 do_deploy ⑤ 的结果。
  local fw_row="已放行 $PORT/tcp"
  [[ "${FIREWALL_OK:-1}" -eq 1 ]] || fw_row="放行失败，请手工放行 $PORT/tcp"
  tui_panel "部署完成" \
    "地址|$SERVER_IP:$PORT" \
    "UUID|$UUID" \
    "SNI|$SNI" \
    "公钥 pbk|$PUBLIC_KEY" \
    "ShortID sid|$SHORT_ID" \
    "防火墙|$fw_row" \
    "客户端配置|$OUT_DIR/client.json" \
    "二维码|$OUT_DIR/qrcode.png"

  tui_box "分享链接（可直接粘贴到客户端导入）"
  tui_box_line "$link"
  tui_box_end

  if [[ -f "$OUT_DIR/qrcode.txt" ]]; then
    tui_section "终端二维码"
    cat "$OUT_DIR/qrcode.txt"
  fi

  # ⚠️ 已经在管理菜单里就【不要】再开一层：
  #    管理菜单的第 0 项「重新部署」会调 deploy_wizard，
  #    而这里又会调 management_menu → 用户在菜单里选一次「重新部署」，
  #    部署完就掉进第二层菜单，再选一次「重新部署」就是第三层。
  #    用 IN_MENU 标志位把这条回路掐断。
  #    用 ${IN_MENU:-0} 读：deploy.sh 被单独 source（单元测试 / helper）时
  #    它可能根本没定义，在 set -u 下直接引用会报 unbound variable。
  if [[ ${OPT_YES:-0} -eq 0 && "${IN_MENU:-0}" -eq 0 ]]; then
    tui_pause
    management_menu
  fi
  return 0
}
menu_show_client() {
  if ! state_exists; then
    tui_warn "尚未部署，无客户端信息可显示。"
    return 1
  fi
  load_state || return 1
  local link
  link=$(build_share_link "$UUID" "$SERVER_IP" "$PORT" "$SNI" "$PUBLIC_KEY" "$SHORT_ID" "$REMARK")
  # 生成为空说明参数有问题（缺 UUID/公钥/地址）→ 必须报错，不能展示一片空白。
  [[ -n "$link" ]] || { tui_err "分享链接生成为空，状态文件可能不完整。"; return 1; }
  tui_panel "当前节点" \
    "地址|$SERVER_IP:$PORT" \
    "UUID|$UUID" \
    "SNI|$SNI" \
    "公钥 pbk|$PUBLIC_KEY" \
    "ShortID sid|$SHORT_ID" \
    "备注|$REMARK"
  tui_box "分享链接"
  tui_box_line "$link"
  tui_box_end
  if [[ -f "$OUT_DIR/qrcode.txt" ]]; then
    tui_section "终端二维码"
    cat "$OUT_DIR/qrcode.txt"
  fi
  return 0
}

menu_restart() {
  restart_service
}

menu_logs() {
  tui_info "实时日志输出，Ctrl+C 退出"
  # -f 是跟随模式，会一直挂着直到用户 Ctrl+C。
  # 非 TTY（CI / 单元测试）下必须由调用方 mock 掉，否则会永久阻塞。
  journalctl -u xray -f --no-pager
}

menu_update_xray() {
  # 依赖装不上就必须停在这里：继续往下走会下载安装脚本、失败，
  # 报出来的却是「下载失败」——错误信息与真实原因无关。
  ensure_packages curl ca-certificates || { tui_err "依赖安装失败，无法更新 Xray。"; return 1; }
  local installer
  # mktemp 可能失败（磁盘满 / 目录不可写）→ 拿到空路径后 curl -o "" 会失败，
  # 而且 rm -f "" 会报 "cannot remove ''"。必须先守卫。
  installer=$(mktemp 2>/dev/null)
  if [[ -z "$installer" ]]; then
    tui_err "无法创建临时文件，更新中止。"
    return 1
  fi
  curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh -o "$installer" || {
    tui_err "下载安装脚本失败"; rm -f "$installer"; return 1; }
  chmod +x "$installer" || { tui_err "无法设置安装脚本权限"; rm -f "$installer"; return 1; }
  tui_run "更新 Xray 内核" bash "$installer" install
  local rc=$?
  rm -f "$installer"
  [[ $rc -eq 0 ]] && restart_service
  return $rc
}

menu_tune() {
  # 必须先确认「已部署」：未部署时 $PORT 是【空串】（core.sh 给的全局默认值），
  # 此时 open_firewall "" 会去执行 `ufw allow "/tcp"` / `iptables --dport ""` /
  # `nft ... tcp dport ""` —— 三条全部报错，而且报出来的错与真实原因
  # （压根没部署、根本没有端口）完全无关。
  # menu_show_client 与 menu_rotate_keys 都有这道守卫，menu_tune 原来漏了。
  state_exists || { tui_warn "尚未部署，无端口可放行，无法调优。"; return 1; }
  load_state || { tui_err "状态文件读取失败，无法调优。"; return 1; }
  # 不能用 `|| true` 吞掉失败：防火墙没放行、BBR 没开，
  # 用户却只看到 service_status 的输出 → 以为调优成功了。
  # 两个动作互相独立，所以各自报错、最后统一返回。
  local rc=0
  open_firewall "$PORT" || { tui_err "防火墙放行失败，请检查 ufw/iptables/nft。"; rc=1; }
  enable_bbr || { tui_warn "BBR 未启用（内核不支持或权限不足），不影响部署可用性。"; }
  service_status
  return $rc
}

menu_rotate_keys() {
  state_exists || { tui_warn "尚未部署，无密钥可轮换"; return 1; }
  # load_state 自 Task 3 修复轮 1 起会对损坏的状态文件返回非零 → 必须检查，
  # 否则会用空值渲染出一份非法配置，再被 xray 校验拒绝，报错与真实原因无关。
  load_state || { tui_err "状态文件读取失败，无法轮换密钥。"; return 1; }
  tui_confirm "轮换密钥与 UUID 会使所有旧客户端失效，继续？" "n" || { tui_info "已取消"; return 0; }
  gen_keys || return 1
  local cfg
  cfg=$(mktemp 2>/dev/null)
  if [[ -z "$cfg" ]]; then
    tui_err "无法创建临时文件，密钥轮换中止。"
    return 1
  fi
  render_server_config "$cfg" "$UUID" "$PRIVATE_KEY" "$SNI" "$PORT" "$SHORT_ID" || { rm -f "$cfg"; return 1; }
  # 与 do_deploy 走同一个入口：write_config_atomic（校验 → 原子替换 → 600）
  write_config_atomic "$XRAY_CONFIG" "$cfg" || { rm -f "$cfg"; return 1; }
  rm -f "$cfg"
  # ⚠️ 这一步失败时，服务端配置【已经】换成新密钥了，而状态文件还是旧的
  #    （旧 UUID / 旧公钥）→ 分享链接里的公钥与服务端实际公钥对不上 →
  #    客户端导入后连不上，而用户只看到一句「状态保存失败」。
  #    所以提示里必须如实说明「配置已换、状态没落盘」，并给出补救动作。
  save_state || { tui_err "状态保存失败：服务端配置已更新为新密钥，但状态文件未落盘。"; tui_tip "请用 install.sh --status 核对，或重新执行一次部署。"; return 1; }
  restart_service || return 1
  # 物料导出失败必须报错：否则「密钥已轮换」这条提示会让人以为
  # client.json / link.txt 已经是新的，实际还是旧的（甚至根本没生成）。
  export_client_artifacts "$OUT_DIR" "$UUID" "$SERVER_IP" "$PORT" "$SNI" "$PUBLIC_KEY" "$SHORT_ID" "$REMARK" \
    || { tui_err "客户端物料导出失败，密钥已轮换但客户端文件未更新。"; return 1; }
  tui_ok "密钥已轮换，请使用新的分享链接更新客户端"
}

menu_uninstall() {
  # 单文件分发版（dist/install.sh）里没有 uninstall.sh → exec 会失败并让菜单崩掉。
  if [[ ! -x "$ROOT_DIR/uninstall.sh" ]]; then
    tui_warn "当前目录没有 uninstall.sh（单文件分发版不含卸载脚本）。"
    tui_tip "请手动执行：systemctl disable --now xray && rm -f $XRAY_CONFIG"
    return 1
  fi
  exec "$ROOT_DIR/uninstall.sh"
}

management_menu() {
  # ⚠️ 防止「管理菜单 ↔ deploy_wizard」互相递归：
  #    菜单第 0 项「重新部署」会调 deploy_wizard，而 deploy_wizard 末尾又会调
  #    management_menu → 用户在菜单里选一次「重新部署」，部署完就掉进第二层菜单，
  #    再选一次「重新部署」就是第三层。
  #    用全局标志位告诉 deploy_wizard「现在已经在菜单里了，别再开一层」。
  #    用 ${IN_MENU:-0} 读：deploy.sh 被单独 source（单元测试 / helper）时它可能没定义，
  #    在 set -u 下直接引用会报 unbound variable。
  IN_MENU=1
  while true; do
    tui_banner "$APP_NAME" "管理菜单"
    if ! state_exists; then
      tui_warn "尚未部署。选「重新部署」开始，或直接退出。"
    fi
    local choice=0 crc=0
    # 菜单必须渲染到 stderr：tui_menu 把整张菜单打到 stdout，而 deploy_wizard
    # 末尾会调 management_menu —— 一旦有人用 $(...) 捕获它，菜单文本就会被
    # 当成返回值吞进去。与 choose_target 是同一个坑。
    tui_menu "请选择操作" \
      "重新部署（重跑向导）" \
      "查看配置 / 分享链接 / 二维码" \
      "重启服务" \
      "实时日志（tail -f）" \
      "更新 Xray 内核" \
      "网络调优（BBR / 防火墙）" \
      "轮换密钥与 UUID" \
      "卸载" \
      "退出" >&2 || crc=$?
    if (( crc == 255 )); then
      tui_info "已退出"
      return 0
    fi
    choice=$crc
    case "$choice" in
      0) deploy_wizard ;;
      1) menu_show_client ;;
      2) menu_restart ;;
      3) menu_logs ;;
      4) menu_update_xray ;;
      5) menu_tune ;;
      6) menu_rotate_keys ;;
      7) menu_uninstall ;;
      8) tui_info "已退出"; return 0 ;;
      *) return 0 ;;
    esac
    tui_pause
  done
}
