#!/usr/bin/env bash
# lib/core.sh — 环境探测与通用能力
# 本文件只放【纯函数】与【状态持久化】；网络探测类函数属于 Task 4。
# 注意：本文件【不是自包含】的 —— assert_debian / save_state / load_state 会调用
# lib/tui.sh 的 tui_err / tui_tip / tui_ok。按计划的「函数归属唯一」约定，
# core.sh 不主动 source tui.sh，由 install.sh 统一按 tui → core 的顺序引入。

APP_NAME='VLESS + REALITY 部署工具'
APP_VERSION='1.1.1'

LIB_DIR="${LIB_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)}"
STATE_DIR="${STATE_DIR:-/etc/vless-reality}"
STATE_FILE="${STATE_FILE:-$STATE_DIR/deploy.env}"
OUT_DIR="${OUT_DIR:-/root/vless-reality}"
XRAY_BIN="${XRAY_BIN:-/usr/local/bin/xray}"
XRAY_CONFIG="${XRAY_CONFIG:-/usr/local/etc/xray/config.json}"
XRAY_SERVICE_UNIT="${XRAY_SERVICE_UNIT:-/etc/systemd/system/xray.service}"
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

# ── 受限网络环境的下载参数 ─────────────────────────────────
# 三个参数都可以用环境变量预设，也可以用命令行覆盖（install.sh --mirror/--proxy/--local）：
#   GITHUB_MIRROR   镜像前缀（例：https://gh.llkk.cc/），拼在原始 URL 前面
#   XRAY_PROXY      HTTP/SOCKS5 代理（例：http://127.0.0.1:7890）
#   XRAY_LOCAL_FILE 本地已有的 Xray 离线安装包（zip）路径
# 背景：上游 install-release.sh 安装时必须访问 api.github.com 拉版本列表，
# 而 api.github.com 只有 IPv4 —— 没有公网 IPv4 的机器（IPv6-only / CGNAT 网段）
# 必然失败（"Failed to get release list, please check your network."）。
# 这里的做法是【我们自己】把 release 压缩包取回来，再交给上游走纯离线分支。
GITHUB_MIRROR="${GITHUB_MIRROR:-}"
XRAY_PROXY="${XRAY_PROXY:-}"
XRAY_LOCAL_FILE="${XRAY_LOCAL_FILE:-}"

# 下载链的运行期状态：实际用到的源、下载到本地待安装的包、它的临时目录。
# 必须显式声明：install.sh 跑在 set -u 下，未声明又未赋值就会被当成未绑定变量。
DOWNLOAD_SOURCE_USED="${DOWNLOAD_SOURCE_USED:-}"
XRAY_FETCHED_ZIP="${XRAY_FETCHED_ZIP:-}"
XRAY_FETCHED_TMPDIR="${XRAY_FETCHED_TMPDIR:-}"

# 内置镜像：直连 GitHub 失败时按顺序尝试。
# 全部是第三方站点，只用于取【安装包】；取到的包会用官方 .dgst 做 SHA-256 校验，
# 校验文件优先从直连 GitHub 取（镜像同时被污染时不会一起被骗）。
# 想固定用哪个镜像，用 GITHUB_MIRROR / --mirror 覆盖即可。
BUILTIN_GITHUB_MIRRORS=(
  'https://gh.llkk.cc/'
  'https://gh-proxy.com/'
)

REALITY_TARGETS=(
  'www.microsoft.com'
  'dl.google.com'
  'www.apple.com'
  'one.one.one.one'
  'www.cloudflare.com'
  'time.akamai.com'
  'addons.mozilla.org'
  # ↓ 同机房/同供应商的 API 域名：解析结果与本机落在同一个 /32，
  #   REALITY 握手在 GFW 眼里就是「连向一个真实网站」，
  #   不会因为「SNI 指向 CDN、目标 IP 却是小鸡」而被关联掐断。
  'api.vultr.com'
  'api.hetzner.com'
  'api.ovh.com'
)

have_cmd() { command -v "$1" >/dev/null 2>&1; }

# 本机的全球 IPv6 地址（去掉 /prefix）
#
# 用途：判断 REALITY 的伪装目标是否与本机【同网段】。
# 真机事故（Vultr / IPv6-only）：伪装目标选的是 one.one.one.one（解析到
# Cloudflare），而本机在 Vultr 的 2001:19f0::/32 —— SNI 指向 CDN、连接的却是
# 一台小鸡的 IP，GFW 的 DPI 据此关联，握手被掐断（客户端表现为
# 「TCP 能连上、REALITY 握手一直不返回」；换同网段目标后立刻通）。
# 伪装目标与本机同 /32 → 流量在 GFW 眼里就是一次普通的 HTTPS 访问。
server_global_ipv6() {
  # 缓存：一次部署里要对 10 个候选目标各判断一次同网段，
  # 每次都跑一遍 `ip -6 addr` 是纯浪费（本机地址在一次运行内不会变）。
  if [[ -n "${SRV_GLOBAL_IPV6:-}" ]]; then
    printf '%s' "$SRV_GLOBAL_IPV6"
    return 0
  fi
  local out
  out=$(ip -6 addr show scope global 2>/dev/null | awk '/inet6 /{print $2}' | head -1)
  out="${out%%/*}"
  SRV_GLOBAL_IPV6="$out"
  printf '%s' "$out"
}

# 本机有没有 IPv4 出口。
#
# 判据是「有没有 IPv4 默认路由」而不是「能不能 ping 通某个站点」：
# 后者依赖具体站点是否可达（Google 在国内被墙、1.1.1.1 在部分网络不通），
# 拿来当判据会误报；默认路由则是本机自己的网络配置，稳定可查。
#
# 为什么它重要（真机事故）：IPv6-only 的服务器（Vultr 的 IPv6-only 套餐等）
# 只能访问有 AAAA 记录的站点。github.com / api.github.com 只有 IPv4 →
# 经代理访问它们必然失败；而 raw.githubusercontent.com 有 AAAA → 能通 →
# 看起来像「时好时坏」，用户很难自己定位。
ipv4_egress_available() {
  local routes
  # 有 IPv4 默认路由 → 基本可以认为有出口，不必联网探测。
  # ⚠️ 不用 `ip ... | grep -q`：grep 命中即退出 → 上游 ip 收到 SIGPIPE(141)
  #    → set -o pipefail 下整条管道的退出码变成 141 → 条件恒为假。
  routes=$(ip -4 route show default 2>/dev/null || printf '')
  [[ -n "$routes" ]] && return 0
  # 没有默认路由，但也可能【有】出口：WARP/MASQUE 这类隧道就不建 IPv4 默认路由
  # （实测：WARP 连上后 `ip -4 route` 里没有 default，IPv4 却完全可用）。
  # 所以这里实际探测一次（最多 4 秒；真·无 IPv4 时会立刻失败，不会白等）。
  if curl -4 -s -o /dev/null --max-time 4 https://1.1.1.1/ 2>/dev/null; then
    return 0
  fi
  if curl -4 -s -o /dev/null --max-time 4 https://www.cloudflare.com/ 2>/dev/null; then
    return 0
  fi
  return 1
}

# 某个域名解析出的 IPv6 是否与本机同 /32（前两组十六进制相同）
target_same_ipv6_prefix() {
  local domain="$1" srv tgt s1 s2 t1 t2
  srv=$(server_global_ipv6)
  [[ -n "$srv" ]] || return 1
  tgt=$(getent ahostsv6 "$domain" 2>/dev/null | awk 'NR==1{print $1}')
  [[ -n "$tgt" ]] || return 1
  s1="${srv%%:*}"; s2="${srv#*:}"; s2="${s2%%:*}"
  t1="${tgt%%:*}"; t2="${tgt#*:}"; t2="${t2%%:*}"
  [[ "$s1" == "$t1" && "$s2" == "$t2" ]]
}

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

# SC2120: 本函数【确实】接受一个可选参数（os-release 路径）——
#   生产路径调用它时不传参（用默认的 /etc/os-release），
#   单元测试则传入临时构造的 os-release 文件。
#   静态检查工具只看本文件内有没有「传参调用」，看不到测试文件里的调用 →
#   误报「参数永远不会被传」。这里显式关掉该条检查。
# 下面这行必须写成指令形式；注释里任何以「shellcheck」开头的行都会被当成指令解析。
# shellcheck disable=SC2120
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

# 本机有没有全局 IPv6 地址。
# 不用 `ip ... | grep -q`：grep 命中即退出 → 上游 ip 收到 SIGPIPE(141) →
# set -o pipefail 下整条管道的退出码变成 141 → 条件判假（同一个坑见 open_firewall）。
have_global_ipv6() {
  local out
  out=$(ip -6 addr show scope global 2>/dev/null || printf '')
  [[ "$out" == *"inet6 "* ]]
}

# 决定 inbound 监听哪个地址。
#
# 真机事故（IPv6-only 的 Vultr 机器，IPv4 只有 CGNAT 地址、无 IPv4 出口）：
# 模板把 listen 写死成 "0.0.0.0" → 只听 IPv4，而分享链接给的是
# [2001:db8::1]:443 → 客户端的 IPv6 连接被直接拒绝 →
# 服务「起来了、面板也显示已运行」，但客户端连不上。
# 规则：
#   · 对外地址是 IPv6 → 必须监听 "::"（否则 IPv6 客户端根本连不上）
#   · 对外地址是 IPv4，但本机有全局 IPv6 且系统是双栈（bindv6only=0）
#     → "::" 一次覆盖 IPv4/IPv6（IPv4 以映射地址进来）
#   · 其余 → "0.0.0.0"
choose_listen_addr() {
  local pub="${SERVER_IP:-}" bindv6only
  if [[ "$pub" == *:* ]]; then
    printf '::'
    return 0
  fi
  bindv6only=$(cat /proc/sys/net/ipv6/bindv6only 2>/dev/null || printf '0')
  if [[ "$bindv6only" == "0" ]] && have_global_ipv6; then
    printf '::'
    return 0
  fi
  printf '0.0.0.0'
}

# 判定一个字符串是不是可用的对外地址。
# 存在的理由：旧的判定 `^[0-9a-fA-F:]+$` 太宽 —— HTTP 状态码响应体
# （代理/网关常返回 "404" / "403" / "200" 当正文）和 "cafebabe" / "12345"
# 这类纯十六进制串都会被当成 IP → 写进分享链接与配置后客户端必然连不上，
# 而用户完全看不出是「探测错了」而不是「服务没起来」。
is_valid_ip() {
  local ip="$1" o
  # IPv4：4 段十进制，每段 0-255
  if [[ "$ip" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]]; then
    for o in "${BASH_REMATCH[@]:1:4}"; do
      # 必须用 10# 前缀：裸算术会把 "08" 当八进制，直接报「value too great for base」。
      if (( 10#$o > 255 )); then return 1; fi
    done
    return 0
  fi
  # IPv6：必须含 ':'（否则 "404" 这类纯数字/纯十六进制串会被误收）。
  # 还必须是像样的 IPv6 形态：含 "::" 压缩写法，或至少 3 段十六进制组 ——
  # 否则 "dead:beef" / "cafe:babe" 这类只有两段的串会被误收成 IP。
  if [[ "$ip" == *"::"* ]]; then
    [[ "$ip" =~ ^[0-9a-fA-F:]+$ ]] && return 0
    return 1
  fi
  if [[ "$ip" =~ ^([0-9a-fA-F]{1,4}:){2,7}[0-9a-fA-F]{1,4}$ ]]; then
    return 0
  fi
  return 1
}

detect_public_ip() {
  local ip u
  # 候选源说明：
  #   · 故意【不】用 https://myip.ipip.net —— 它返回中文正文
  #     （「当前 IP：1.2.3.4 来自于：中国」），is_valid_ip 永远不可能接受 →
  #     该源【永远失败】，而且排在最后，只在前面全失败时才白等一次超时。
  #   · --max-time 取 5 秒：4 个源最坏合计 20 秒（旧的 5 源 × 8 秒 = 40 秒，
  #     在无网环境下预检会静默卡住近一分钟）。
  local urls=(
    'https://api.ipify.org'
    'https://ifconfig.me/ip'
    'https://icanhazip.com'
    'https://ipinfo.io/ip'
  )
  for u in "${urls[@]}"; do
    # tr -d '[:space:]' 是【承重逻辑】：真实 IP 服务返回的正文都带尾随 "\n"，
    # 而 bash 的 =~ 锚点不匹配尾随换行 → 不剥掉就一定判不出 IP。
    ip=$(curl -fsS --max-time 5 "$u" 2>/dev/null | tr -d '[:space:]')
    if is_valid_ip "$ip"; then
      printf '%s' "$ip"; return 0
    fi
  done
  return 1
}

detect_local_ip() {
  local ip
  ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')
  [[ -z "$ip" ]] && ip=$(hostname -I 2>/dev/null | awk '{print $1}')
  # 两个来源都没给出地址 → 必须返回非零：rc=0 却输出空串会让调用方
  # 分不清「探测到了空地址」和「探测成功」。
  if [[ -z "$ip" ]]; then
    tui_err "无法探测本机地址（ip 与 hostname 都不可用）"
    return 1
  fi
  printf '%s' "$ip"
}

port_in_use() {
  local port="$1" rows
  if have_cmd ss; then
    # 先把整段输出【收进变量】再匹配，不能写成 `ss | awk | grep -q`：
    # 管道里 grep -q 命中即退出 → 上游 awk 收到 SIGPIPE（141）→
    # 在 set -o pipefail 下整条管道的退出码变成 141 → `&& return 0` 不成立 →
    # 一个【已占用】的端口被误判成【空闲】→ 向导选了这个端口 →
    # 部署到一半才报 "address in use"，且错误信息与真实原因无关。
    # 改成「先收进变量、再对变量 grep」后，grep 读的是 here-string（临时文件），
    # 整条链路上没有任何会早退的管道 → 不可能有 SIGPIPE。
    #
    # 仍必须按【字段】精确匹配，不能对整行 grep ":$port"：
    # ":8080" 这个字符串里就含 ":80" → 全行 grep 会把 8080 误判成 80 已被占用，
    # 于是向导会以为端口 80 被占而改选别的端口。NR>1 跳过 ss 的表头行。
    rows=$(ss -ltn "sport = :$port" 2>/dev/null | awk 'NR>1{print $4}')
    [[ -n "$rows" ]] || return 1
    grep -qE "[:.]$port\$" <<<"$rows" && return 0
    return 1
  fi
  if have_cmd netstat; then
    # netstat 的输出【不受端口过滤】，行数可能很大 → 同样不能把 grep -q 接在管道上。
    rows=$(netstat -ltn 2>/dev/null | awk '{print $4}')
    [[ -n "$rows" ]] || return 1
    grep -qE "[:.]$port\$" <<<"$rows" && return 0
    return 1
  fi
  return 1
}

port_occupant() {
  local port="$1" rows
  if have_cmd ss; then
    # 用纯 bash 取首行，不用 `| head -1`：head 命中即退出会让上游 awk 收到
    # SIGPIPE（141）。原写法其实【输出是对的】（head 先读走第一行才退出，
    # 且函数末尾显式 return 0 覆盖了管道状态），改成纯 bash 后不再有任何管道，
    # 行为不变但不再依赖那个时序。
    rows=$(ss -ltnp "sport = :$port" 2>/dev/null | awk 'NR>1{print $NF}')
    rows="${rows%%$'\n'*}"
    printf '%s' "$rows"
    return 0
  fi
  printf ''
}

port_owned_by_our_xray() {
  # $1 = port_occupant 的输出（形如 users:(("xray",pid=123,fd=3))）
  # 判定「这个被占用的端口，是本工具自己部署的 xray 服务占着的」→
  # 即「重部署」场景 → 应当沿用同一个端口，而不是改用随机端口。
  local occ="$1"
  [[ "$occ" == *xray* ]] && [[ -f "$XRAY_SERVICE_UNIT" ]]
}

random_free_port() {
  local p
  for _ in $(seq 1 40); do
    p=$(( (RANDOM % 20000) + 20000 ))
    if ! port_in_use "$p"; then printf '%s' "$p"; return 0; fi
  done
  printf '%s' 44321
}

target_supports_tls13() {
  local host="$1"
  have_cmd openssl || return 1
  local out
  out=$(timeout 12 openssl s_client -connect "${host}:443" -servername "$host" -tls1_3 </dev/null 2>&1)
  grep -qE 'TLSv1\.3|Cipher is (TLS_AES|TLS_CHACHA)' <<<"$out"
}

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

apt_update_once() {
  [[ -f /var/lib/vless-reality/apt-updated ]] && return 0
  tui_run "更新软件源索引 (apt update)" apt-get update -y -o Acquire::Retries=3
  local rc=$?
  # 必须显式判失败并返回非零：若写成
  #   if [[ $? -eq 0 ]]; then ...; fi
  # 则 apt update 失败时走假分支，而【无 else 的 if 在条件为假时返回 0】——
  # apt_update_once 于是「成功」返回，ensure_packages 继续装依赖，
  # 依赖装不上却没人知道。
  if (( rc != 0 )); then
    tui_err "apt update 失败（退出码 $rc），无法继续安装依赖"
    return 1
  fi
  mkdir -p /var/lib/vless-reality
  # 用 `: >` 而不是 touch：touch 不在运行时白名单里，而 `: >` 是 shell 重定向，
  # 不调用任何外部命令（效果等同「创建或清空该文件」）。
  : > /var/lib/vless-reality/apt-updated
  return 0
}

ensure_packages() {
  local missing=() p
  for p in "$@"; do
    have_cmd "$p" || missing+=("$p")
  done
  ((${#missing[@]} == 0)) && return 0
  # apt update 失败必须中止，否则依赖静默装不上而部署继续往下走。
  apt_update_once || return 1
  # tui_run 是最后一条语句 → 其退出码就是本函数的退出码（透传给调用方）。
  tui_run "安装依赖：${missing[*]}" env DEBIAN_FRONTEND=noninteractive \
    apt-get install -y --no-install-recommends "${missing[@]}"
}

service_run_user() {
  local u
  u=$(systemctl show xray -p User --value 2>/dev/null || printf '')
  [[ -z "$u" || "$u" == '0' ]] && u='root'
  printf '%s' "$u"
}

# 服务实际以哪个【组】运行（读 unit 的 Group=，没有就取该用户的默认组）
service_run_group() {
  local run_user g
  run_user=$(service_run_user)
  [[ -z "$run_user" || "$run_user" == 'root' ]] && { printf ''; return 0; }
  g=$(systemctl show xray -p Group --value 2>/dev/null || printf '')
  [[ -z "$g" || "$g" == '0' ]] && g=$(id -gn "$run_user" 2>/dev/null || printf '')
  printf '%s' "$g"
}

# IPv6 地址在 URL/「地址:端口」这种写法里必须加方括号，
# 否则 2001:db8::1:443 会被解析成「地址 2001:db8::1、端口 443」以外的歧义值，
# 客户端导入即废。真机部署（IPv6-only 的 Vultr 机器）上出现过这种显示。
host_for_url() {
  local host="$1"
  if [[ "$host" == *:* && "$host" != \[*\] ]]; then
    host="[$host]"
  fi
  printf '%s' "$host"
}
