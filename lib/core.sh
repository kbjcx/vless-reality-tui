#!/usr/bin/env bash
# lib/core.sh — 环境探测与通用能力
# 本文件只放【纯函数】与【状态持久化】；网络探测类函数属于 Task 4。
# 注意：本文件【不是自包含】的 —— assert_debian / save_state / load_state 会调用
# lib/tui.sh 的 tui_err / tui_tip / tui_ok。按计划的「函数归属唯一」约定，
# core.sh 不主动 source tui.sh，由 install.sh 统一按 tui → core 的顺序引入。

APP_NAME='VLESS + REALITY 部署工具'
APP_VERSION='1.0.0'

LIB_DIR="${LIB_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)}"
STATE_DIR="${STATE_DIR:-/etc/vless-reality}"
STATE_FILE="${STATE_FILE:-$STATE_DIR/deploy.env}"
OUT_DIR="${OUT_DIR:-/root/vless-reality}"
XRAY_BIN="${XRAY_BIN:-/usr/local/bin/xray}"
XRAY_CONFIG="${XRAY_CONFIG:-/usr/local/etc/xray/config.json}"
LOG_DIR="${LOG_DIR:-/var/log/xray}"

# 全局部署状态：Task 5/7/9 赋值，Task 3 的 save_state 负责持久化。
# 必须显式声明：install.sh 跑在 `set -u` 下，未声明又未赋值的变量一旦被引用
# 就会触发 unbound variable（实测：--menu 路径不经过 preflight → SERVER_IP 从未
# 探测，deploy_wizard 引用 $SERVER_IP、menu_tune 引用 $PORT 都会直接崩掉，
# 而且没有 tui_err 提示，用户只看到一句 "SERVER_IP: unbound variable"）。
# 用 ${VAR:-默认} 而不是 VAR='' ：前者既定义了变量（set -u 安全），
# 又【保留调用方在 source 之前预设的值】，后者会把预设值清空。
PORT="${PORT:-}"; UUID="${UUID:-}"; SNI="${SNI:-}"; TARGET="${TARGET:-}"
PRIVATE_KEY="${PRIVATE_KEY:-}"; PUBLIC_KEY="${PUBLIC_KEY:-}"; SHORT_ID="${SHORT_ID:-}"
SERVER_IP="${SERVER_IP:-}"; REMARK="${REMARK:-}"
MODE="${MODE:-native}"; FLOW="${FLOW:-xtls-rprx-vision}"; FINGERPRINT="${FINGERPRINT:-chrome}"

REALITY_TARGETS=(
  'www.microsoft.com'
  'dl.google.com'
  'www.apple.com'
  'one.one.one.one'
  'www.cloudflare.com'
  'time.akamai.com'
  'addons.mozilla.org'
)

have_cmd() { command -v "$1" >/dev/null 2>&1; }

trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

urlencode() {
  local s="$1"
  if have_cmd python3; then
    # 必须用 sys.stdout.write 而不是 print：print 会多输出一个尾换行，
    # 而回退分支没有 —— 同一个函数的两个分支 stdout 字节不一致。
    python3 -c 'import sys,urllib.parse;sys.stdout.write(urllib.parse.quote(sys.argv[1],safe=""))' "$s" 2>/dev/null && return 0
  fi
  # 回退实现：必须按【字节】遍历，否则多字节字符只会编码首字节。
  # local LC_ALL=C 让 ${#s} 与 ${s:i:1} 都按字节切分。
  local out='' i c len
  local LC_ALL=C
  len=${#s}
  for ((i = 0; i < len; i++)); do
    c=${s:$i:1}
    case "$c" in
      [a-zA-Z0-9.~_-]) out+="$c" ;;
      # ' 与 \ 的编码写死：printf '%%%02X' "'$c" 依赖 bash 对「以 ' 开头的字符常量」
      # 的解释，这一点【未在本机文档中确认】（bash 5.3.9 实测给出 39/92，
      # 但 help printf 只列了 %b %q %Q %(fmt)T 四个扩展，未提该形式）。
      # 把这两个字节的数值写死后，任意 bash 4.2+ 上结果一致，
      # 输出与原写法逐字节相同（其余字节仍走原写法）。
      "'")  out+='%27' ;;
      '\')  out+='%5C' ;;
      *) out+=$(printf '%%%02X' "'$c") ;;
    esac
  done
  printf '%s' "$out"
}

random_hex() {
  local n="${1:-8}" out=''
  [[ "$n" =~ ^[0-9]+$ ]] || return 1
  # 必须【先捕获输出再判断】，不能用 `openssl ... | tr ...; return 0`：
  # 管道的退出码取自最后一个命令（tr），openssl 失败时 tr 仍返回 0 →
  # random_hex 会【返回 0 但输出空串】→ 空 SHORT_ID 被原样写进 config.json →
  # xray run -test 失败 → 部署中止，且报错与真实原因（取不到随机数）完全无关。
  if have_cmd openssl; then
    out=$(openssl rand -hex "$n" 2>/dev/null) || out=''
  fi
  if [[ ! "$out" =~ ^[0-9a-f]+$ ]]; then
    # openssl 不可用或输出不可用 → 退回 /dev/urandom（od 是 coreutils，几乎必然存在）
    out=$(od -An -tx1 -N "$n" /dev/urandom 2>/dev/null) || out=''
  fi
  # 空格与 CR 一起删：od 的输出用空格分隔；某些 openssl 构建（含本开发机的
  # MSYS2 版本）输出的是 \r\n，只删 LF 会残留一个 \r，而这个 \r 会混进
  # SHORT_ID / 密钥，随后被原样写进 config.json（JSON 字符串里不允许裸控制
  # 字符）→ 直接让部署失败。Debian 自带的 openssl 只输出 \n，多删一个 \r
  # 对其无影响。
  out=$(printf '%s' "$out" | tr -d ' \r\n')
  # 必须是纯小写十六进制：脏输出（错误文本、半截输出）若被原样写进 config.json，
  # 失败点会被推迟到 xray 校验，报错与真实原因完全无关。
  [[ -n "$out" && "$out" =~ ^[0-9a-f]+$ ]] || return 1
  printf '%s' "$out"
}

read_file() {
  local f="$1"
  [[ -f "$f" ]] || return 1
  trim "$(cat "$f" 2>/dev/null)"
}

detect_os() {
  local os_release="${1:-/etc/os-release}" id='' ver='' arch='' pair=''
  if [[ -r "$os_release" ]]; then
    # 只接受受信任路径：os-release 是 shell 片段，`.` 引入等价于执行代码。
    # 本函数只用于 /etc/os-release 与测试用临时文件，不接受用户可控输入。
    # 只 source 一次，同时取出 ID 与 VERSION_ID。
    pair=$(. "$os_release" 2>/dev/null; printf '%s|%s' "${ID:-}" "${VERSION_ID:-}")
    # 连 CR 一起删：CRLF 行尾的 os-release 会让 ID 变成 "debian\r" →
    # assert_debian 误判成「不是 Debian」。Debian 自带的 os-release 是 LF，
    # 但 /etc 里也可能存在被 CRLF 改写过的副本。
    id=$(printf '%s' "${pair%%|*}" | tr -d '\r')
    ver=$(printf '%s' "${pair#*|}" | tr -d '\r')
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
  local id ver
  IFS='|' read -r id ver _ <<<"$(detect_os)"
  if [[ "$id" != "debian" && "$id" != "raspbian" && "$id" != "ubuntu" ]]; then
    tui_err "当前系统为 ${id:-未知} ${ver:-}，本工具以 Debian 为目标系统。"
    tui_tip "Ubuntu 与 Debian 同源，一般可直接使用；其它发行版请自行核对 systemd 与防火墙差异。"
    return 1
  fi
  tui_ok "系统检测：$id $ver"
  return 0
}

# 校验 SNI：必须是纯 DNS 主机名。
# SNI 会【原样】进入服务端 config.json、客户端 client.json 与分享链接，
# 不校验等于把用户输入直接拼进 JSON —— 引号/反斜杠会让 JSON 失效
# （虽不会写坏已有配置：写入恒为「临时文件 → xray run -test → 原子替换」），
# 但会直接让部署失败。因此在【输入口】拦住，而不是在渲染口做转义。
validate_hostname() {
  local host="$1" label len
  [[ -n "$host" ]] || return 1
  [[ ${#host} -le 253 ]] || return 1
  [[ "$host" != *[[:space:]]* ]] || return 1
  [[ "$host" != *'"'* ]] || return 1
  [[ "$host" != *'\'* ]] || return 1
  [[ "$host" == *.* ]] || return 1
  # 尾点形式（"com."）在 DNS 里合法，但 SNI 永远不带尾点，
  # 且会被原样写进 config.json 的 "target" → 必须拒绝。
  if [[ "$host" == *. ]]; then return 1; fi
  local -a labels
  IFS='.' read -r -a labels <<<"$host"
  ((${#labels[@]} > 0)) || return 1
  for label in "${labels[@]}"; do
    len=${#label}
    [[ $len -ge 1 && $len -le 63 ]] || return 1
    [[ "$label" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]] || return 1
  done
  return 0
}

# 把任意文本转成可被 shell 安全求值的单引号字面量。
# 状态文件会被 load_state 用 `.`（source）引入执行，而 REMARK / SNI 来自
# 用户输入（--name / --sni），不转义等于让其中的 $(...) / 反引号在下次
# 读取状态时被执行。单引号包裹 + 内部单引号转义为 '\'' 是 POSIX 标准做法；
# 换行也能安全保留（bash 的单引号字符串允许跨行）。
state_quote() {
  local v="$1"
  printf "'%s'" "${v//\'/\'\\\'\'}"
}

save_state() {
  # 每一步都必须检查返回码：把「没写成功」伪装成「配置已保存」是最坏的失败模式
  # —— 状态没落盘，但用户以为成功了 → 之后 --status 显示未部署、卸载流程拿不到
  # 端口 → 防火墙规则被遗留。触发条件虽窄（root + 正常 /etc 时不会发生），
  # 但磁盘满、/etc 只读、STATE_DIR 配错都会触发。
  mkdir -p "$STATE_DIR" || { tui_err "无法创建状态目录：$STATE_DIR"; return 1; }
  chmod 700 "$STATE_DIR" || { tui_err "无法设置状态目录权限：$STATE_DIR"; return 1; }
  local tmp="$STATE_FILE.tmp"
  {
    printf '# %s v%s 部署状态（勿手工编辑）\n' "$APP_NAME" "$APP_VERSION"
    printf 'DEPLOYED_AT=%s\n' "$(state_quote "$(date '+%Y-%m-%d %H:%M:%S %Z')")"
    printf 'MODE=%s\n' "$(state_quote "${MODE:-native}")"
    printf 'PORT=%s\n' "$(state_quote "${PORT:-}")"
    printf 'UUID=%s\n' "$(state_quote "${UUID:-}")"
    printf 'SNI=%s\n' "$(state_quote "${SNI:-}")"
    printf 'TARGET=%s\n' "$(state_quote "${TARGET:-}")"
    printf 'PRIVATE_KEY=%s\n' "$(state_quote "${PRIVATE_KEY:-}")"
    printf 'PUBLIC_KEY=%s\n' "$(state_quote "${PUBLIC_KEY:-}")"
    printf 'SHORT_ID=%s\n' "$(state_quote "${SHORT_ID:-}")"
    printf 'SERVER_IP=%s\n' "$(state_quote "${SERVER_IP:-}")"
    printf 'REMARK=%s\n' "$(state_quote "${REMARK:-}")"
    printf 'FLOW=%s\n' "$(state_quote "${FLOW:-xtls-rprx-vision}")"
    printf 'FINGERPRINT=%s\n' "$(state_quote "${FINGERPRINT:-chrome}")"
  } >"$tmp" || { tui_err "无法写入状态临时文件：$tmp"; rm -f "$tmp"; return 1; }
  chmod 600 "$tmp" || { tui_err "无法设置状态文件权限：$tmp"; rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$STATE_FILE" || { tui_err "无法保存状态文件：$STATE_FILE"; rm -f "$tmp"; return 1; }
  tui_ok "配置已保存：$STATE_FILE"
}

load_state() {
  # 「读不到」与「格式错」必须分开报（复评 F-4）：
  # 早期写法是 [[ -f "$STATE_FILE" ]] || return 1 —— 静默返回，调用方无从判断
  # 是「还没部署过」还是「状态文件坏了」；而对「文件存在但不可读」的情况，
  # 子 shell 探测会把权限错误当成「格式错误」报出来，把人带偏。
  if [[ ! -f "$STATE_FILE" ]]; then
    tui_err "状态文件不存在：$STATE_FILE"
    return 1
  fi
  if [[ ! -r "$STATE_FILE" ]]; then
    tui_err "状态文件不可读：$STATE_FILE"
    return 1
  fi
  # 只【解析】不【执行】：用 bash -n 做语法检查。
  # 早期写法是在子 shell 里 source 一遍做「静默探测」，
  # 那会把状态文件【执行两次】（探测一次、正式读一次）——
  # 文件里一旦有副作用就会发生两次，且第一次的副作用对调用方不可见。
  # bash -n 只做语法分析、不执行任何语句，因此没有副作用
  # （实测：含 $(touch x) 的状态文件经 bash -n 之后副作用未发生）。
  # 实测：语法错误 → rc=2 且 stderr 有 "syntax error"；
  #       合法文件（含末条 false）→ rc=0 且 stderr 为空。
  local syntax_err=''
  syntax_err=$( "${BASH:-bash}" -n -- "$STATE_FILE" 2>&1 ) || true
  if [[ -n "$syntax_err" ]]; then
    tui_err "状态文件格式错误：$STATE_FILE"
    tui_tip "${syntax_err%%$'\n'*}"
    return 1
  fi
  # shellcheck disable=SC1090
  # 这里的返回码【不作为失败判据】：状态文件最后一条命令返回非零是合法的
  # （例如末尾是一条返回 1 的语句），真正坏掉的文件已在上面的语法检查里被拦下。
  . "$STATE_FILE" || true
  return 0
}

state_exists() { [[ -f "$STATE_FILE" ]]; }
