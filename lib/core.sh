#!/usr/bin/env bash
# shellcheck shell=bash
#
# lib/core.sh — 环境探测与通用能力
#
# 提供：系统检测、公网 IP 探测、端口检查、随机密钥、状态持久化、
#       URL 编码、软件包安装、路径常量等。

# ─────────────────────────────────────────────────────────────
# 路径常量
# ─────────────────────────────────────────────────────────────

APP_NAME='VLESS + REALITY 部署工具'
APP_VERSION='1.2.0'

LIB_DIR="${LIB_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)}"
STATE_DIR="${STATE_DIR:-/etc/vless-reality}"
STATE_FILE="$STATE_DIR/deploy.env"
OUT_DIR="${OUT_DIR:-/root/vless-reality}"
XRAY_BIN="${XRAY_BIN:-/usr/local/bin/xray}"
XRAY_CONFIG="${XRAY_CONFIG:-/usr/local/etc/xray/config.json}"
LOG_DIR="${LOG_DIR:-/var/log/xray}"

# REALITY 伪装目标候选（要求支持 TLS 1.3 + H2，且与本机不同 ASN 效果更好）
REALITY_TARGETS=(
  'www.microsoft.com'
  'dl.google.com'
  'www.apple.com'
  'one.one.one.one'
  'www.cloudflare.com'
  'time.akamai.com'
  'addons.mozilla.org'
)

# ─────────────────────────────────────────────────────────────
# 通用工具
# ─────────────────────────────────────────────────────────────

have_cmd() { command -v "$1" >/dev/null 2>&1; }

trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

# URL 编码（优先用 python3，退化到 bash 实现）
urlencode() {
  local s="$1"
  if have_cmd python3; then
    python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1],safe=""))' "$s" 2>/dev/null && return 0
  fi
  local out='' i c
  for ((i = 0; i < ${#s}; i++)); do
    c=${s:$i:1}
    case "$c" in
      [a-zA-Z0-9.~_-]) out+="$c" ;;
      *) out+=$(LC_ALL=C printf '%%%02X' "'$c") ;;
    esac
  done
  printf '%s' "$out"
}

# 随机十六进制字符串（n 字节）
random_hex() {
  local n="${1:-8}"
  if have_cmd openssl; then
    openssl rand -hex "$n" 2>/dev/null | tr -d '\n'
    return 0
  fi
  od -An -tx1 -N "$n" /dev/urandom 2>/dev/null | tr -d ' \n'
}

# 读取文件并 trim（兼容无尾换行）
read_file() {
  local f="$1"
  [[ -f "$f" ]] || return 1
  local c
  c=$(cat "$f" 2>/dev/null)
  trim "$c"
}

# ─────────────────────────────────────────────────────────────
# 系统检测
# ─────────────────────────────────────────────────────────────

require_root() {
  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    tui_err "本操作需要 root 权限，请使用 sudo 重新执行。"
    exit 1
  fi
}

# 输出一行键值，供调用方 eval 或直接阅读
detect_os() {
  local id='' ver='' arch=''
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    id=$(. /etc/os-release; printf '%s' "${ID:-}")
    ver=$(. /etc/os-release; printf '%s' "${VERSION_ID:-}")
  fi
  case "$(uname -m)" in
    x86_64|amd64)  arch='amd64' ;;
    aarch64|arm64) arch='arm64' ;;
    armv7l)        arch='armv7' ;;
    s390x)         arch='s390x' ;;
    *)             arch=$(uname -m) ;;
  esac
  printf '%s|%s|%s' "$id" "$ver" "$arch"
}

assert_debian() {
  local id ver arch
  IFS='|' read -r id ver arch <<<"$(detect_os)"
  if [[ "$id" != "debian" && "$id" != "raspbian" && "$id" != "ubuntu" ]]; then
    tui_err "当前系统为 ${id:-未知} ${ver:-}，本工具以 Debian 为目标系统。"
    tui_tip "Ubuntu 与 Debian 同源，一般可直接使用；其它发行版请自行核对 systemd 与防火墙差异。"
    return 1
  fi
  tui_ok "系统检测：$id $ver ($arch)"
  return 0
}

# Debian 12+ 才有 nftables 默认规则集，这里只做提示
is_modern_debian() {
  local ver
  ver=$(detect_os | cut -d'|' -f2)
  [[ "$ver" =~ ^[0-9]+$ ]] && (( ver >= 12 ))
}

# ─────────────────────────────────────────────────────────────
# 网络探测
# ─────────────────────────────────────────────────────────────

# 探测公网 IPv4/IPv6
detect_public_ip() {
  local ip
  local urls=(
    'https://api.ipify.org'
    'https://ifconfig.me/ip'
    'https://icanhazip.com'
    'https://ipinfo.io/ip'
    'https://myip.ipip.net'
  )
  for u in "${urls[@]}"; do
    ip=$(curl -fsS --max-time 8 "$u" 2>/dev/null | tr -d '[:space:]')
    if [[ "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ || "$ip" =~ ^[0-9a-fA-F:]+$ ]]; then
      printf '%s' "$ip"
      return 0
    fi
  done
  return 1
}

# 探测本机主 IP（用于挑选内网/出口地址）
detect_local_ip() {
  local ip
  ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')
  [[ -z "$ip" ]] && ip=$(hostname -I 2>/dev/null | awk '{print $1}')
  printf '%s' "$ip"
}

# 端口是否已被占用
port_in_use() {
  local port="$1"
  if have_cmd ss; then
    ss -ltn "sport = :$port" 2>/dev/null | grep -q ":$port" && return 0
    return 1
  fi
  if have_cmd netstat; then
    netstat -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]$port\$" && return 0
    return 1
  fi
  return 1
}

# 找出占用该端口的服务名（若有）
port_occupant() {
  local port="$1"
  if have_cmd ss; then
    ss -ltnp "sport = :$port" 2>/dev/null | awk 'NR>1{print $NF}' | head -1
    return 0
  fi
  printf ''
}

# 随机挑一个空闲高位端口
random_free_port() {
  local p
  for _ in $(seq 1 40); do
    p=$(( ( RANDOM % 20000 ) + 20000 ))
    if ! port_in_use "$p"; then printf '%s' "$p"; return 0; fi
  done
  printf '%s' 44321
}

# 目标站点是否支持 TLS 1.3
target_supports_tls13() {
  local host="$1"
  have_cmd openssl || return 1
  local out
  out=$(timeout 12 openssl s_client -connect "${host}:443" -servername "$host" -tls1_3 </dev/null 2>&1)
  grep -qE 'TLSv1\.3|Cipher is (TLS_AES|TLS_CHACHA)' <<<"$out"
}

# 目标站点连通延迟（毫秒）
target_latency_ms() {
  local host="$1"
  have_cmd curl || { printf '?'; return 0; }
  local t
  t=$(curl -o /dev/null -sS --max-time 10 -w '%{time_connect}' "https://${host}/" 2>/dev/null)
  if [[ -z "$t" || "$t" == '0' || "$t" == '0.000000' ]]; then
    printf '?'
  else
    awk -v t="$t" 'BEGIN{printf "%d", t*1000}'
  fi
}

# ─────────────────────────────────────────────────────────────
# 软件包
# ─────────────────────────────────────────────────────────────

apt_update_once() {
  [[ -f /var/lib/vless-reality/apt-updated ]] && return 0
  tui_run "更新软件源索引 (apt update)" apt-get update -y -o Acquire::Retries=3
  if [[ $? -eq 0 ]]; then
    mkdir -p /var/lib/vless-reality
    touch /var/lib/vless-reality/apt-updated
  fi
}

# ensure_packages pkg...
ensure_packages() {
  local missing=()
  local p
  for p in "$@"; do
    have_cmd "$p" || missing+=("$p")
  done
  ((${#missing[@]} == 0)) && return 0

  apt_update_once
  tui_run "安装依赖：${missing[*]}" env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${missing[@]}"
}

# ─────────────────────────────────────────────────────────────
# 状态持久化
# ─────────────────────────────────────────────────────────────

save_state() {
  mkdir -p "$STATE_DIR"
  chmod 700 "$STATE_DIR"
  local tmp="$STATE_FILE.tmp"
  {
    printf '# %s v%s 部署状态（勿手工编辑）\n' "$APP_NAME" "$APP_VERSION"
    printf 'DEPLOYED_AT=%s\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')"
    printf 'MODE=%s\n' "${MODE:-native}"
    printf 'PORT=%s\n' "${PORT:-}"
    printf 'UUID=%s\n' "${UUID:-}"
    printf 'SNI=%s\n' "${SNI:-}"
    printf 'TARGET=%s\n' "${TARGET:-}"
    printf 'PRIVATE_KEY=%s\n' "${PRIVATE_KEY:-}"
    printf 'PUBLIC_KEY=%s\n' "${PUBLIC_KEY:-}"
    printf 'SHORT_ID=%s\n' "${SHORT_ID:-}"
    printf 'SERVER_IP=%s\n' "${SERVER_IP:-}"
    printf 'REMARK=%s\n' "${REMARK:-}"
    printf 'FLOW=%s\n' "${FLOW:-xtls-rprx-vision}"
    printf 'FINGERPRINT=%s\n' "${FINGERPRINT:-chrome}"
  } >"$tmp"
  chmod 600 "$tmp"
  mv -f "$tmp" "$STATE_FILE"
  tui_ok "配置已保存：$STATE_FILE"
}

load_state() {
  [[ -f "$STATE_FILE" ]] || return 1
  # shellcheck disable=SC1090
  . "$STATE_FILE"
  return 0
}

state_exists() { [[ -f "$STATE_FILE" ]]; }

# ─────────────────────────────────────────────────────────────
# systemd
# ─────────────────────────────────────────────────────────────

# 读取服务运行用户（用于日志目录授权）
service_run_user() {
  local u
  u=$(systemctl show xray -p User --value 2>/dev/null || printf '')
  [[ -z "$u" || "$u" == '0' ]] && u='root'
  printf '%s' "$u"
}
