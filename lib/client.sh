#!/usr/bin/env bash
# lib/client.sh — 客户端物料导出

build_share_link() {
  local uuid="$1" ip="$2" port="$3" sni="$4" pub="$5" sid="$6" remark="$7"
  local enc host
  enc=$(urlencode "$remark")
  # IPv6 地址在 URL 里必须写成 [addr]:port，否则 vless://uuid@2001:db8::1:443 是非法 URL
  # → 客户端导入即废。detect_public_ip 允许返回 IPv6，所以这里必须处理。
  host="$ip"
  if [[ "$host" == *:* && "$host" != \[*\] ]]; then
    host="[$host]"
  fi
  # FLOW / FINGERPRINT 是全局状态（状态文件里也记着），不能在这里写死 ——
  # 写死就等于让状态文件里的这两个字段变成死状态。
  printf 'vless://%s@%s:%s?encryption=none&flow=%s&security=reality&sni=%s&fp=%s&pbk=%s&sid=%s&type=tcp&headerType=none#%s' \
    "$uuid" "$host" "$port" "${FLOW:-xtls-rprx-vision}" "$sni" "${FINGERPRINT:-chrome}" "$pub" "$sid" "$enc"
}

render_client_config() {
  local outfile="$1" uuid="$2" ip="$3" port="$4" sni="$5" pub="$6" sid="$7"
  # ── 入参白名单校验（必须【先做】）────────────────────────────
  # 本函数用【未加引号的 heredoc】渲染 JSON → 入参里的 $(...) / 反引号会被
  # 【真实执行】。控制器实证：把 '$(echo PWNED_UUID)' 传进 UUID、
  # '`echo PWNED_SNI`' 传进 SNI、'$(echo PWNED_PUB)' 传进公钥
  # —— 三个都被【真实执行】，执行结果被原样写进了 client.json。
  # 而且非法端口（"443; id"）会把 JSON 【直接写坏】→ 客户端拿到的是废文件。
  # 白名单让 6 个入参只可能含有安全字符，从根上关死注入面。
  [[ "$uuid" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] \
    || { tui_err "UUID 格式非法：$uuid"; return 1; }
  [[ "$port" =~ ^[0-9]{1,5}$ ]] && [[ "$port" -ge 1 && "$port" -le 65535 ]] \
    || { tui_err "端口非法：$port"; return 1; }
  [[ "$pub" =~ ^[A-Za-z0-9_-]{40,64}$ ]] \
    || { tui_err "REALITY 公钥格式非法（只允许 base64url 字符，长度 40-64）"; return 1; }
  [[ "$sid" =~ ^[0-9a-fA-F]{2,16}$ ]] \
    || { tui_err "ShortID 格式非法（只允许十六进制，长度 2-16）：$sid"; return 1; }
  validate_hostname "$sni" || { tui_err "SNI 主机名非法：$sni"; return 1; }
  is_valid_ip "$ip" || { tui_err "服务器地址非法：$ip"; return 1; }
  # 目标路径如果是【已存在的目录】：`mv -f "$tmp" "$outfile"` 会把文件移进目录里
  # → mv 返回 0（看起来成功）但配置根本没落到 outfile → 调用方以为渲染成功。
  [[ -d "$outfile" ]] && { tui_err "目标路径是目录，不能作为配置文件：$outfile"; return 1; }
  # 内部暂存名用 ".render" 后缀，与 write_config_atomic 的 ".new" 区分开，
  # 避免两者在同一条路径上撞名。
  local tmp="$outfile.render"
  # cat 的退出码必须检查：目标目录不存在时，重定向失败会漏出原始 bash 报错，
  # 用户看到的是「No such file or directory」而不是我们自己的提示。
  if ! cat >"$tmp" <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "tag": "socks-in",
      "port": 1080,
      "listen": "127.0.0.1",
      "protocol": "socks",
      "settings": {
        "udp": true
      }
    },
    {
      "tag": "http-in",
      "port": 1081,
      "listen": "127.0.0.1",
      "protocol": "http",
      "settings": {}
    }
  ],
  "outbounds": [
    {
      "tag": "proxy",
      "protocol": "vless",
      "settings": {
        "vnext": [
          {
            "address": "${ip}",
            "port": ${port},
            "users": [
              {
                "id": "${uuid}",
                "encryption": "none",
                "flow": "${FLOW:-xtls-rprx-vision}",
                "level": 0
              }
            ]
          }
        ]
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "fingerprint": "${FINGERPRINT:-chrome}",
          "serverName": "${sni}",
          "publicKey": "${pub}",
          "shortId": "${sid}",
          "spiderX": "/"
        }
      }
    },
    {
      "tag": "direct",
      "protocol": "freedom",
      "settings": {}
    }
  ],
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [
      {
        "type": "field",
        "outboundTag": "direct",
        "ip": [
          "127.0.0.0/8",
          "10.0.0.0/8",
          "172.16.0.0/12",
          "192.168.0.0/16",
          "fc00::/7",
          "fe80::/10"
        ]
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
  # 含 UUID 与公钥 → 600。必须在 mv 之前设好：
  # 否则「权限设置失败」时文件已经落位，函数却返回非零。
  chmod 600 "$tmp" || { tui_err "无法设置暂存文件权限：$tmp"; rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$outfile" || { tui_err "无法写入客户端配置：$outfile"; rm -f "$tmp"; return 1; }
}

export_client_artifacts() {
  local outdir="$1" uuid="$2" ip="$3" port="$4" sni="$5" pub="$6" sid="$7" remark="$8"
  # 目录与文件都含敏感信息（分享链接、UUID、公钥）→ 每一步失败都必须报错并返回非零，
  # 绝不能让「导出失败」看起来像「导出成功」。
  mkdir -p "$outdir" || { tui_err "无法创建客户端导出目录：$outdir"; return 1; }
  chmod 700 "$outdir" || { tui_err "无法设置客户端导出目录权限：$outdir"; return 1; }

  local link
  link=$(build_share_link "$uuid" "$ip" "$port" "$sni" "$pub" "$sid" "$remark")
  [[ -n "$link" ]] || { tui_err "分享链接生成为空"; return 1; }

  render_client_config "$outdir/client.json" "$uuid" "$ip" "$port" "$sni" "$pub" "$sid" || return 1

  {
    printf '# VLESS + REALITY 客户端信息\n\n'
    printf '生成时间: %s\n\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')"
    printf '地址: %s\n' "$ip"
    printf '端口: %s\n' "$port"
    printf 'UUID: %s\n' "$uuid"
    printf 'SNI: %s\n' "$sni"
    printf '公钥 (pbk): %s\n' "$pub"
    printf 'ShortID (sid): %s\n' "$sid"
    # 流控与指纹必须与分享链接、client.json 用的是【同一个】全局状态 ——
    # 写死就等于让这里显示的值与实际配置对不上（用户会照着显示的值去排查）。
    printf '流控 (flow): %s\n' "${FLOW:-xtls-rprx-vision}"
    printf '指纹 (fp): %s\n\n' "${FINGERPRINT:-chrome}"
    printf '分享链接:\n%s\n\n' "$link"
    printf '导入方式: v2rayN / v2rayNG / Clash Verge / Shadowrocket / Hiddify 均可直接粘贴该链接。\n'
  } >"$outdir/client.txt" || { tui_err "无法写入客户端信息文件：$outdir/client.txt"; return 1; }
  chmod 600 "$outdir/client.txt" || { tui_err "无法设置客户端信息文件权限：$outdir/client.txt"; return 1; }

  printf '%s' "$link" >"$outdir/link.txt" || { tui_err "无法写入分享链接文件：$outdir/link.txt"; return 1; }
  chmod 600 "$outdir/link.txt" || { tui_err "无法设置分享链接文件权限：$outdir/link.txt"; return 1; }

  # 二维码：缺 qrencode 时跳过，不影响主流程
  if have_cmd qrencode; then
    qrencode -t PNG -s 8 -o "$outdir/qrcode.png" "$link" 2>/dev/null && tui_ok "二维码已生成：$outdir/qrcode.png"
    qrencode -t ANSIUTF8 -o "$outdir/qrcode.txt" "$link" 2>/dev/null && tui_ok "终端二维码已生成：$outdir/qrcode.txt"
  else
    tui_warn "未安装 qrencode，跳过二维码生成。"
    tui_tip "可手动执行：apt-get install -y qrencode"
  fi

  tui_ok "客户端物料已导出：$outdir"
  return 0
}
