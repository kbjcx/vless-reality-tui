#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# VLESS + REALITY 一键部署工具 —— 单文件分发版
#
# 本文件由 build.sh 自动生成，请勿手工编辑。
# 修改请编辑 lib/ 下的源文件与 install.sh 后重新运行 build.sh。
#
# 构建版本: 1.1.1
#
# 注意：此处【不能】嵌入构建时间戳。CI 用
#   bash build.sh && git diff --exit-code dist/install.sh
# 来校验「dist 与源码同步」——一旦产物里带时间戳，每次构建都不同，
# 这条校验【永远失败】。构建时间以 git 提交时间为准。
#
# 用法: sudo bash install.sh [-y|--menu|--status|--uninstall|-h]
set -uo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# ==================== lib/tui.sh ====================
# lib/tui.sh — 零依赖 TUI 组件库
# 硬约束：本文件不得包含任何业务逻辑、文件写入或系统调用。
# （Task 2 的 tui_run 需要 mktemp 捕获命令输出，是这条约束的唯一例外。）

TUI_TTY=0; TUI_COLOR=0; TUI_WIDTH=80
# TUI_UNICODE 为空表示「自动探测」（由 tui_init 按 locale 判定）；
# 显式设为 1/0 可强制 Unicode / ASCII。留空而非写死 1，
# 否则下面 tui_init 里的显式覆盖分支恒真、locale 探测分支将永远不可达。
TUI_UNICODE="${TUI_UNICODE:-}"

C_RESET=''; C_BOLD=''; C_DIM=''
C_RED=''; C_GREEN=''; C_YELLOW=''; C_BLUE=''; C_CYAN=''; C_MAGENTA=''; C_WHITE=''; C_GRAY=''
C_OK=''; C_ERR=''; C_WARN=''; C_INFO=''; C_ACCENT=''

B_TL='╭'; B_TR='╮'; B_BL='╰'; B_BR='╯'; B_H='─'; B_V='│'
I_MARK='●'; I_ARROW='▸'; I_OK='✔'; I_ERR='✖'; I_WARN='▲'; I_INFO='ℹ'; I_TIP='▷'

tui_init() {
  [[ -t 1 && -t 0 ]] && TUI_TTY=1
  [[ "${TERM:-dumb}" != "dumb" && -t 1 && -z "${NO_COLOR:-}" ]] && TUI_COLOR=1

  # Unicode 能力判定（设计稿要求：Unicode 不可用时降级为 ASCII 制表符）
  #   - TUI_ASCII=1 / TUI_UNICODE=1 显式覆盖优先
  #   - locale 含 UTF-8 → Unicode
  #   - 三个 locale 变量都未设置 → 默认 Unicode（现代终端均可显示）
  #   - 其它情况（如 LANG=C）→ 降级 ASCII
  local loc="${LC_ALL:-${LC_CTYPE:-${LANG:-}}}"
  if [[ -n "${TUI_ASCII:-}" ]]; then
    TUI_UNICODE=0
  elif [[ "${TUI_UNICODE:-}" == "0" ]]; then
    TUI_UNICODE=0
  elif [[ -n "${TUI_UNICODE:-}" ]]; then
    TUI_UNICODE=1
  elif [[ "$loc" == *UTF-8* || "$loc" == *utf8* || "$loc" == *UTF8* ]]; then
    TUI_UNICODE=1
  elif [[ -z "$loc" ]]; then
    TUI_UNICODE=1
  else
    TUI_UNICODE=0
  fi
  if [[ $TUI_UNICODE -eq 0 ]]; then
    B_TL='+'; B_TR='+'; B_BL='+'; B_BR='+'; B_H='-'; B_V='|'
    I_MARK='*'; I_ARROW='>'; I_OK='[OK]'; I_ERR='[X]'; I_WARN='[!]'; I_INFO='[i]'; I_TIP='>'
  fi

  local cols
  cols=$(tput cols 2>/dev/null || printf '80')
  [[ "$cols" =~ ^[0-9]+$ ]] || cols=80
  (( cols < 46 )) && cols=46
  (( cols > 100 )) && cols=100
  TUI_WIDTH=$cols

  if [[ $TUI_COLOR -eq 1 ]]; then
    C_RESET=$'\033[0m';  C_BOLD=$'\033[1m';  C_DIM=$'\033[2m'
    C_RED=$'\033[38;5;203m';    C_GREEN=$'\033[38;5;114m'
    C_YELLOW=$'\033[38;5;179m'; C_BLUE=$'\033[38;5;110m'
    C_CYAN=$'\033[38;5;80m';    C_MAGENTA=$'\033[38;5;176m'
    C_WHITE=$'\033[38;5;253m';  C_GRAY=$'\033[38;5;244m'
    C_OK=$C_GREEN; C_ERR=$C_RED; C_WARN=$C_YELLOW; C_INFO=$C_BLUE; C_ACCENT=$C_CYAN
  fi
}

tui_repeat() {
  local ch="$1" n="$2" out='' i
  for ((i = 0; i < n; i++)); do out+="$ch"; done
  printf '%s' "$out"
}

# 显示宽度：CJK / 全角字符按 2 列，其余按 1 列。
#
# 实现要点（都是踩过的坑，勿简化）：
#   1. 必须【按字节】解码 UTF-8 后比较码点，不能依赖 locale：
#      ${#s} 在 C locale 下是字节数、否则是字符数；
#      case 区间 [$'\u1100'-...] 的匹配结果依赖 locale 排序规则。
#      方案：显式 `local LC_ALL=C`（与 lib/core.sh 的 urlencode 同一手法）后按字节解码，
#      保证在任何 locale（含 LANG 未设置的服务器、Git Bash 默认的 C locale）下结果一致。
#   2. 必须校验序列长度与续字节（0x80-0xBF），否则截断序列会越界读、
#      把残缺字节静默解成伪码点，导致宽度静默失真。
#   3. 必须跳过 ANSI 转义序列（ESC [ ... 终止字节），否则对带色字符串补白会错位。
tui_dwidth() {
  local s="$1" w=0 i len b1 b2 b3 b4 cp n j
  local LC_ALL=C
  len=${#s}
  i=0
  while (( i < len )); do
    printf -v b1 '%d' "'${s:$i:1}"

    # 跳过 ANSI 转义序列：ESC [ 参数... 终止字节(0x40-0x7E)
    if (( b1 == 27 )) && (( i + 1 < len )); then
      printf -v b2 '%d' "'${s:$((i+1)):1}"
      if (( b2 == 91 )); then   # '['
        j=$(( i + 2 ))
        while (( j < len )); do
          printf -v b3 '%d' "'${s:$j:1}"
          if (( b3 >= 0x40 && b3 <= 0x7E )); then
            i=$(( j + 1 ))
            break
          fi
          j=$(( j + 1 ))
        done
        (( j >= len )) && i=$len
        continue
      fi
    fi

    if (( b1 < 0x80 )); then
      cp=$b1; n=1
    elif (( b1 >= 0xC2 && b1 <= 0xDF )); then
      if (( i + 1 >= len )); then
        cp=$b1; n=1
      else
        printf -v b2 '%d' "'${s:$((i+1)):1}"
        if (( (b2 & 0xC0) != 0x80 )); then cp=$b1; n=1
        else cp=$(( (b1 & 0x1F) << 6 | (b2 & 0x3F) )); n=2; fi
      fi
    elif (( b1 >= 0xE0 && b1 <= 0xEF )); then
      if (( i + 2 >= len )); then
        cp=$b1; n=1
      else
        printf -v b2 '%d' "'${s:$((i+1)):1}"
        printf -v b3 '%d' "'${s:$((i+2)):1}"
        if (( (b2 & 0xC0) != 0x80 || (b3 & 0xC0) != 0x80 )); then cp=$b1; n=1
        else cp=$(( (b1 & 0x0F) << 12 | (b2 & 0x3F) << 6 | (b3 & 0x3F) )); n=3; fi
      fi
    elif (( b1 >= 0xF0 && b1 <= 0xF4 )); then
      if (( i + 3 >= len )); then
        cp=$b1; n=1
      else
        printf -v b2 '%d' "'${s:$((i+1)):1}"
        printf -v b3 '%d' "'${s:$((i+2)):1}"
        printf -v b4 '%d' "'${s:$((i+3)):1}"
        if (( (b2 & 0xC0) != 0x80 || (b3 & 0xC0) != 0x80 || (b4 & 0xC0) != 0x80 )); then cp=$b1; n=1
        else cp=$(( (b1 & 0x07) << 18 | (b2 & 0x3F) << 12 | (b3 & 0x3F) << 6 | (b4 & 0x3F) )); n=4; fi
      fi
    else
      cp=$b1; n=1
    fi
    i=$(( i + n ))

    if (( (cp >= 0x1100 && cp <= 0x115F) || (cp >= 0x2E80 && cp <= 0x303E) || (cp >= 0x3041 && cp <= 0x33FF) ||
          (cp >= 0x3400 && cp <= 0x4DBF) || (cp >= 0x4E00 && cp <= 0x9FFF) || (cp >= 0xA000 && cp <= 0xA4CF) ||
          (cp >= 0xAC00 && cp <= 0xD7A3) || (cp >= 0xF900 && cp <= 0xFAFF) || (cp >= 0xFE30 && cp <= 0xFE6F) ||
          (cp >= 0xFF00 && cp <= 0xFF60) || (cp >= 0xFFE0 && cp <= 0xFFE6) )); then
      w=$(( w + 2 ))
    else
      w=$(( w + 1 ))
    fi
  done
  printf '%s' "$w"
}

tui_pad() {
  local s="$1" width="$2" d
  d=$(tui_dwidth "$s")
  (( d < width )) && s+=$(tui_repeat ' ' $((width - d)))
  printf '%s' "$s"
}

# 去除 ANSI 序列后的纯文本。
# 注意：GNU sed 不认正则里的 \033（\0 是 NUL，后面只剩字面 "33"），必须把真实 ESC
# 字节放进模式里（ANSI-C 引用 $'...'），否则在 GNU sed / Debian 上完全剥不掉。
tui_strip() {
  printf '%s' "$1" | sed -e $'s/\033\\[[0-9;]*m//g'
}

# 边框几何：内容行统一为 "  │ " + 内容(TUI_WIDTH-6) + " │"，
# 上下边框为 "  ╭" + 横线(TUI_WIDTH-4) + "╮"，
# 带标题的顶边框为 "  ╭ " + 标题 + " " + 横线(TUI_WIDTH-6-标题宽) + "╮"。
# 这样每一种行渲染出来都恰好等于 TUI_WIDTH，框线才合得拢。
tui_content_width() {
  local w=$((TUI_WIDTH - 6))
  (( w < 10 )) && w=10
  printf '%s' "$w"
}

tui_border_len() {
  local n="$1"
  (( n < 0 )) && n=0
  printf '%s' "$n"
}

tui_banner() {
  local title="$1" subtitle="${2:-}"
  local cw rw
  cw=$(tui_content_width)
  rw=$(tui_border_len $((TUI_WIDTH - 4)))
  printf '\n'
  printf '  %s%s%s%s%s\n' "$C_CYAN" "$B_TL" "$(tui_repeat "$B_H" $rw)" "$B_TR" "$C_RESET"
  printf '  %s%s%s %s%s%s %s%s%s\n' "$C_CYAN" "$B_V" "$C_RESET" "$C_BOLD$C_WHITE" \
    "$(tui_pad "$title" $cw)" "$C_RESET" "$C_CYAN" "$B_V" "$C_RESET"
  if [[ -n "$subtitle" ]]; then
    printf '  %s%s%s %s%s%s %s%s%s\n' "$C_CYAN" "$B_V" "$C_RESET" "$C_GRAY" \
      "$(tui_pad "$subtitle" $cw)" "$C_RESET" "$C_CYAN" "$B_V" "$C_RESET"
  fi
  printf '  %s%s%s%s%s\n' "$C_CYAN" "$B_BL" "$(tui_repeat "$B_H" $rw)" "$B_BR" "$C_RESET"
}

tui_section() {
  local title="$1" rw
  rw=$(tui_border_len $((TUI_WIDTH - 4)))
  printf '\n  %s%s%s %s%s%s\n' "$C_ACCENT" "$I_MARK" "$C_RESET" "$C_BOLD" "$title" "$C_RESET"
  printf '  %s%s%s\n' "$C_GRAY" "$(tui_repeat "$B_H" $rw)" "$C_RESET"
}

tui_box() {
  local title="${1:-}" rw n
  rw=$(tui_border_len $((TUI_WIDTH - 4)))
  printf '\n'
  if [[ -n "$title" ]]; then
    n=$(tui_border_len $((TUI_WIDTH - 6 - $(tui_dwidth "$title"))))
    printf '  %s%s %s%s%s %s%s%s\n' "$C_ACCENT" "$B_TL" "$C_BOLD" "$title" "$C_RESET" \
      "$C_ACCENT" "$(tui_repeat "$B_H" $n)" "$B_TR$C_RESET"
  else
    printf '  %s%s%s%s\n' "$C_ACCENT" "$B_TL" "$(tui_repeat "$B_H" $rw)" "$B_TR$C_RESET"
  fi
}

tui_box_line() {
  local text="$1" color="${2:-$C_WHITE}" cw
  cw=$(tui_content_width)
  printf '  %s%s%s %s%s%s %s%s%s\n' "$C_ACCENT" "$B_V" "$C_RESET" "$color" \
    "$(tui_pad "$text" $cw)" "$C_RESET" "$C_ACCENT" "$B_V" "$C_RESET"
}

tui_box_end() {
  local rw
  rw=$(tui_border_len $((TUI_WIDTH - 4)))
  printf '  %s%s%s%s\n' "$C_ACCENT" "$B_BL" "$(tui_repeat "$B_H" $rw)" "$B_BR$C_RESET"
}

# 一个带标题的内容块：内容【放得下】就画框，【放不下】就整行输出。
# ⚠️ 为什么需要它：分享链接有 150+ 字符，而框内净宽只有 TUI_WIDTH-6（默认 74）→
#    硬塞进框里会把右边框顶出去，框线合不拢
#    （框线必须恰好等于 TUI_WIDTH 才对得齐，见 tui_box / tui_box_end 的注释）。
#    也不能把链接折成多行：用户要从终端复制这一行，折行后粘到客户端是废链接。
#    → 放不下时不开框，改用小节标题 + 整行输出；
#      终端的【软换行】只是显示效果，不会在内容里插入字符 → 复制出来仍是完整的一行。
tui_box_text() {
  local title="$1" text="$2" cw
  cw=$(tui_content_width)
  if (( $(tui_dwidth "$text") <= cw )); then
    tui_box "$title"
    tui_box_line "$text"
    tui_box_end
    return 0
  fi
  tui_section "$title"
  printf '  %s%s%s\n' "$C_WHITE" "$text" "$C_RESET"
}

tui_panel() {
  local title="$1"; shift
  local cw rw n vw entry k v
  cw=$(tui_content_width)
  rw=$(tui_border_len $((TUI_WIDTH - 4)))
  n=$(tui_border_len $((TUI_WIDTH - 6 - $(tui_dwidth "$title"))))
  vw=$((cw - 19)); (( vw < 1 )) && vw=1
  printf '\n  %s%s %s%s%s %s%s%s\n' "$C_ACCENT" "$B_TL" "$C_BOLD" "$title" "$C_RESET" \
    "$C_ACCENT" "$(tui_repeat "$B_H" $n)" "$B_TR$C_RESET"
  for entry in "$@"; do
    k="${entry%%|*}"; v="${entry#*|}"
    # 格式占位符个数必须与参数个数一致（11 个）：否则多出的分隔空格会落到
    # 右边框【之后】，使 │ 停在第 79 列、与上下角的 ╮/╯（第 80 列）对不齐。
    printf '  %s%s%s %s%s%s %s%s%s %s%s\n' "$C_ACCENT" "$B_V" "$C_RESET" "$C_GRAY" \
      "$(tui_pad "$k" 18)" "$C_RESET" "$C_WHITE" "$(tui_pad "$v" $vw)" "$C_RESET" \
      "$C_ACCENT$B_V" "$C_RESET"
  done
  printf '  %s%s%s%s\n' "$C_ACCENT" "$B_BL" "$(tui_repeat "$B_H" $rw)" "$B_BR$C_RESET"
}

tui_info() { printf '  %s%s%s %s\n' "$C_INFO" "$I_INFO" "$C_RESET" "$1"; }
tui_ok()   { printf '  %s%s%s %s\n' "$C_OK"   "$I_OK"   "$C_RESET" "$1"; }
tui_warn() { printf '  %s%s%s %s\n' "$C_WARN" "$I_WARN" "$C_RESET" "$1"; }
tui_err()  { printf '  %s%s%s %s\n' "$C_ERR"  "$I_ERR"  "$C_RESET" "$1"; }
tui_tip()  { printf '  %s%s%s %s\n' "$C_GRAY" "$I_TIP"  "$C_RESET" "$1"; }
tui_step() { printf '  %s%s%s %s\n' "$C_ACCENT" "$I_ARROW" "$C_RESET" "$1"; }

tui_kv() {
  local k="$1" v="$2" kw=$((TUI_WIDTH - 26))
  (( kw < 14 )) && kw=14
  printf '  %s%s%s %s\n' "$C_GRAY" "$(tui_pad "$k" $kw)" "$C_RESET" "$v"
}

# ═══════════════════════════════════════════════════════════════
# 交互层（Task 2）
#
# 约定（下游调用方必须遵守）：
#   * stdout 语义：凡是把「用户输入的值」交给调用方的函数
#     （tui_input / tui_input_secret），stdout 只承载该值，提示语走 stderr——
#     这样 val=$(tui_input "端口" "443") 拿到的才是干净的值。
#     tui_confirm 同理：提示走 stderr，它只通过【返回码】给值。
#   * tui_menu 的【整张菜单】（选项列表 + 提示行）都打到 stdout，
#     选中项也一并打印；但调用方必须用【返回码】取索引，不要捕获 stdout。
#     返回码本身就是 0-based 索引：0=第一项，1..n-1=第 n 项，255=用户取消。
#     注意 1..n-1 也是非零码，不能用 `cmd && a || b` 区分成功与取消。
#   * 非 TTY（nohup / CI / curl | bash）一律降级为编号列表，绝不挂死。
#   * 本段外部命令仅限：tui_run 用 mktemp/sed/rm 捕获命令输出，
#     spinner 用 sleep（lib/tui.sh 硬约束的唯一例外）。
# ═══════════════════════════════════════════════════════════════

# 带 spinner 的命令执行。签名固定为 tui_run <消息> <命令> [参数...]：
# lib/core.sh 的 apt_update_once / ensure_packages 按此形状调用，签名不符
# 会导致依赖静默不装而部署继续。
# 返回被调命令的退出码；失败时打印捕获到的输出。
tui_run() {
  local msg="$1"; shift
  local tmp rc=0

  tmp=$(mktemp 2>/dev/null || printf '/tmp/.tui.%s' "$$")
  # 临时文件：mktemp 失败时退回一个可预测路径，该路径可能不可写或已被占用。
  # 此时必须【仍然把命令跑起来】——不能因为捕获输出失败就不执行命令，
  # 否则用户只会看到一个没有原因的失败标记。
  # 注意：失败的重定向本身会把诊断写到 stderr，且发生在 2>/dev/null 生效之前，
  # 所以要用 { ...; } 2>/dev/null 把整条重定向包起来，不能只挂 2>/dev/null。
  if ! { : >"$tmp"; } 2>/dev/null; then
    tmp=''
  fi

  if [[ $TUI_TTY -eq 0 ]]; then
    # 非 TTY 不画 spinner，但仍然捕获输出：失败时必须让用户看到原因，
    # 否则「依赖没装上」会退化成静默故障。
    printf '  %s%s%s %s ... ' "$C_ACCENT" "$I_ARROW" "$C_RESET" "$msg"
    if [[ -n "$tmp" ]]; then
      "$@" >"$tmp" 2>&1
      rc=$?
    else
      "$@" >/dev/null 2>&1
      rc=$?
    fi
    if [[ $rc -eq 0 ]]; then
      printf '%s%s%s\n' "$C_OK" "$I_OK" "$C_RESET"
    else
      printf '%s%s%s\n' "$C_ERR" "$I_ERR" "$C_RESET"
      [[ -n "$tmp" && -s "$tmp" ]] && sed -e 's/^/      /' "$tmp"
    fi
    [[ -n "$tmp" ]] && { rm -f "$tmp" 2>/dev/null || true; }
    return $rc
  fi

  if [[ -n "$tmp" ]]; then
    "$@" >"$tmp" 2>&1 &
  else
    "$@" >/dev/null 2>&1 &
  fi
  local pid=$! i=0
  # spinner 帧必须逐【字符】取：用数组而不是 ${str:i:1}——后者在 C locale 下
  # 是按字节切，会把 3 字节的盲文点阵字符切成半个（服务器上 LANG 常未设置）。
  local -a frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
  while kill -0 "$pid" 2>/dev/null; do
    printf '\r  %s%s%s %s%s%s' "$C_ACCENT" "${frames[$((i % 10))]}" "$C_RESET" "$C_GRAY" "$msg" "$C_RESET"
    i=$((i + 1)); sleep 0.08
  done
  wait "$pid" || rc=$?

  if [[ $rc -eq 0 ]]; then
    printf '\r  %s%s%s %s%s%s\n' "$C_OK" "$I_OK" "$C_RESET" "$C_GRAY" "$msg" "$C_RESET"
  else
    printf '\r  %s%s%s %s%s%s\n' "$C_ERR" "$I_ERR" "$C_RESET" "$C_GRAY" "$msg" "$C_RESET"
    [[ -n "$tmp" && -s "$tmp" ]] && sed -e 's/^/      /' "$tmp"
  fi
  [[ -n "$tmp" ]] && { rm -f "$tmp" 2>/dev/null || true; }
  return $rc
}

# 确认：返回 0=是 / 1=否。第二个参数是默认值（y|n），默认 y。
# 提示语走 stderr（与 tui_input / tui_input_secret 保持一致）：
# 本函数只通过返回码给值，提示不应混进 stdout。
tui_confirm() {
  local prompt="$1" default="${2:-y}" ans hint
  if [[ "$default" == "y" || "$default" == "Y" ]]; then hint="Y/n"; else hint="y/N"; fi
  if [[ $TUI_TTY -eq 0 ]]; then
    printf '  %s%s%s %s [%s]: ' "$C_ACCENT" "$I_ARROW" "$C_RESET" "$prompt" "$hint" >&2
    # 用 `|| true` 而不是 `|| ans=''`：read 遇到没有换行符结尾的末行时
    # 返回 1，但变量里已经存着有效内容——`|| ans=''` 会把它抹掉。
    IFS= read -r ans || true
    ans=${ans%$'\r'}
    [[ -z "$ans" ]] && ans="$default"
    [[ "${ans,,}" == y* ]]
    return
  fi
  printf '  %s%s%s %s %s[%s]%s ' "$C_ACCENT" "$I_ARROW" "$C_RESET" "$prompt" "$C_GRAY" "$hint" "$C_RESET" >&2
  IFS= read -rsn1 ans || true
  # 终端回车可能是 CR，也可能被 read 当作行分隔符吞掉（此时 ans 为空）；
  # 两种情况都表示「直接回车」→ 落到默认值，而不是被判成「否」。
  ans=${ans//$'\r'/}
  ans=${ans//$'\n'/}
  # 收尾换行也走 stderr：否则 out=$(tui_confirm ...) 会多带一个空行
  printf '\n' >&2
  [[ -z "$ans" ]] && ans="$default"
  [[ "${ans,,}" == y* ]]
}

# 单行输入：stdout 输出用户输入（空输入回落默认值），提示语走 stderr。
tui_input() {
  local prompt="$1" def="${2:-}" hint="${3:-}" ans
  if [[ $TUI_TTY -eq 0 ]]; then
    if [[ -n "$hint" ]]; then
      printf '  %s%s%s %s (%s): ' "$C_ACCENT" "$I_ARROW" "$C_RESET" "$prompt" "$hint" >&2
    else
      printf '  %s%s%s %s: ' "$C_ACCENT" "$I_ARROW" "$C_RESET" "$prompt" >&2
    fi
    IFS= read -r ans || true
    ans=${ans%$'\r'}
    [[ -z "$ans" ]] && ans="$def"
    printf '%s' "$ans"; return
  fi
  if [[ -n "$hint" ]]; then
    printf '  %s%s%s %s %s(%s)%s ' "$C_ACCENT" "$I_ARROW" "$C_RESET" "$prompt" "$C_GRAY" "$hint" "$C_RESET" >&2
  else
    printf '  %s%s%s %s ' "$C_ACCENT" "$I_ARROW" "$C_RESET" "$prompt" >&2
  fi
  IFS= read -r ans || true
  ans=${ans%$'\r'}
  [[ -z "$ans" ]] && ans="$def"
  printf '%s' "$ans"
}

# 秘密输入：同 tui_input，但 TTY 下不回显。
tui_input_secret() {
  local prompt="$1" def="${2:-}" ans
  if [[ $TUI_TTY -eq 0 ]]; then
    printf '  %s%s%s %s: ' "$C_ACCENT" "$I_ARROW" "$C_RESET" "$prompt" >&2
    IFS= read -r ans || true
    ans=${ans%$'\r'}
    [[ -z "$ans" ]] && ans="$def"
    printf '%s' "$ans"; return
  fi
  printf '  %s%s%s %s ' "$C_ACCENT" "$I_ARROW" "$C_RESET" "$prompt" >&2
  IFS= read -rs ans || true
  ans=${ans%$'\r'}
  printf '\n'
  [[ -z "$ans" ]] && ans="$def"
  printf '%s' "$ans"
}

# 菜单：stdout 打印选中项；返回 0-based 索引，用户取消返回 255。
tui_menu() {
  local title="$1"; shift
  local -a items=("$@")
  local n=${#items[@]}
  local idx=${TUI_MENU_DEFAULT_INDEX:-0} buf=''

  (( n == 0 )) && return 255
  (( idx < 0 || idx >= n )) && idx=0

  if [[ $TUI_TTY -eq 0 ]]; then
    local i
    tui_section "$title"
    for ((i = 0; i < n; i++)); do
      printf '     %s%2d%s) %s\n' "$C_GRAY" "$((i + 1))" "$C_RESET" "${items[$i]}"
    done
    local sel=''
    printf '  %s请输入序号 [1-%d]: %s' "$C_ACCENT" "$n" "$C_RESET"
    IFS= read -r sel || true
    sel=${sel%$'\r'}
    [[ -z "$sel" ]] && return 255
    [[ "$sel" =~ ^[0-9]+$ ]] || return 255
    # 用 10# 前缀：裸算术会把 "08" 当八进制，直接报「value too great for base」。
    (( 10#$sel >= 1 && 10#$sel <= n )) || return 255
    printf '%s\n' "${items[$((10#$sel - 1))]}"
    return $((10#$sel - 1))
  fi

  tui_section "$title"
  local key seq
  while true; do
    local i
    for ((i = 0; i < n; i++)); do
      if (( i == idx )); then
        printf '     %s%s %s%s%s\n' "$C_ACCENT$C_BOLD" "$I_ARROW" "$C_RESET$C_BOLD" "${items[$i]}" "$C_RESET"
      else
        printf '       %s%s%s\n' "$C_GRAY" "${items[$i]}" "$C_RESET"
      fi
    done
    if [[ -n "$buf" ]]; then
      # 格式串的 %s 个数必须与实参个数严格相等（6 ↔ 6）。两种错法的机理不同：
      #   * 占位符【多于】实参：bash 只把缺的补成空串、并不会重复打印，
      #     但尾部那个空填充位会【静默吃掉新加的实参】——新加的内容落在结尾
      #     $C_RESET 的【后面】，行尾因此没有重置收尾，终端会残留该颜色。
      #   * 实参【多于】占位符（例如少写一个 %s）：bash 会【复用】格式串，
      #     提示行被打印两遍；重绘统一按 n+1 行回退 → 缓冲区非空时每次重绘
      #     少算一行，光标逐行下移、ESC[J 清不到上一行残留，菜单整体错位一行；
      #     同时第一遍的结尾颜色重置被顶掉，终端也会残留灰色。
      # 另外数字必须在光标【之前】：渲染成 "10_"，不是 "_10"。
      printf '     %s编号: %s%s%s_  %s↑↓ 移动 · Enter 确认 · q 取消%s\n' \
        "$C_GRAY" "$C_ACCENT$C_BOLD" "$buf" "$C_RESET" "$C_GRAY" "$C_RESET"
    else
      printf '     %s↑↓ 移动 · 数字直选 · Enter 确认 · q 取消%s\n' "$C_GRAY" "$C_RESET"
    fi

    key=''
    # 必须保留 read 的状态位：read -rsn1 遇回车(LF)返回【空串+rc=0】，
    # 遇 EOF/Ctrl-D 返回【空串+rc=1】。两者都靠状态位才能区分：
    # EOF 必须是「取消」(255)，不能当成回车去确认高亮项。
    local krc=0
    IFS= read -rsn1 key || krc=$?
    if (( krc > 0 )); then
      printf '\033[%dA\033[J' "$((n + 1))"
      printf '   %s已取消%s\n' "$C_GRAY" "$C_RESET"
      return 255
    fi
    # read -n1 碰到回车时返回的是【空串】（状态 0），不是 "\n"；
    # 终端也可能送 CR。两种情况都表示「用户按了回车」→ 统一成 "\n"，
    # 否则 Enter 会变成一个按下去没反应的死键。
    [[ -z "$key" ]] && key=$'\n'
    key=${key//$'\r'/$'\n'}

    if [[ $key == $'\e' ]]; then
      seq=''
      # ESC 已被上一条 read 吃掉，方向键只剩 "[A" / "[B" 2 个字节。
      # 必须用 -n2 精确读这 2 个字节：
      #   * -n3 会多吞一个字节——用户「按下方向键后立刻回车」时，那个回车
      #     会被当成方向键序列的第 3 字节吞掉，回车就丢了；
      #   * -n2 时两个字节齐备就立即返回，不会平白多等 -t 的超时，
      #     单独按 ESC 时才超时（此时 seq 为空 → 不移动，光标不动）。
      # ⚠️ 超时必须【可被环境变量覆盖】：
      #    0.2 秒是【墙钟截止点】，不是「等够 2 字节」的条件 →
      #    机器繁忙时写端还没把字节送进管道，读端已经等满 → 方向键读不到 →
      #    回车选中的是【高亮项(索引 0)】而不是期望的索引 → 断言随机变红。
      #    GitHub Actions 是共享 runner，负载不可控 → CI 上必然会有随机红。
      #    改成环境变量后，测试 helper（test/helpers/menu_tty.sh）可以把它放大到 2 秒，
      #    交互体验完全不变，CI 变成确定性的。
      IFS= read -rsn2 -t "${TUI_KEY_TIMEOUT:-0.2}" seq || true
      case "$seq" in
        '[A') idx=$(( (idx - 1 + n) % n )); buf='' ;;
        '[B') idx=$(( (idx + 1) % n )); buf='' ;;
      esac
    elif [[ $key == $'\n' || $key == $'\r' ]]; then
      if [[ -n "$buf" ]]; then
        # 缓冲区只允许数字：进算术前再守一道，避免 10# 触发 bash 算术错误
        if [[ ! "$buf" =~ ^[0-9]+$ ]]; then
          buf=''
          printf '\033[%dA\033[J' "$((n + 1))"
          continue
        fi
        local d=$((10#$buf - 1))
        if (( d >= 0 && d < n )); then
          printf '\033[%dA\033[J' "$((n + 1))"
          printf '   %s%s%s %s\n' "$C_OK" "$I_OK" "$C_RESET" "${items[$d]}"
          return $d
        fi
        buf=''
        printf '\033[%dA\033[J' "$((n + 1))"
        continue
      fi
      printf '\033[%dA\033[J' "$((n + 1))"
      printf '   %s%s%s %s\n' "$C_OK" "$I_OK" "$C_RESET" "${items[$idx]}"
      return $idx
    elif [[ $key == 'q' || $key == 'Q' ]]; then
      printf '\033[%dA\033[J' "$((n + 1))"
      printf '   %s已取消%s\n' "$C_GRAY" "$C_RESET"
      return 255
    elif [[ $key =~ ^[0-9]$ ]]; then
      buf+="$key"
      if (( 10#$buf >= 1 && 10#$buf <= n )); then
        local more=''
        # ⚠️ 同上：0.35 秒在繁忙机器上会把两位数输入（"10"）截成"1"，
        #    并且「编号」提示行一次都不打印 → 断言随机变红。
        IFS= read -rsn1 -t "${TUI_DIGIT_TIMEOUT:-0.35}" more || more=''
        if [[ -z "$more" ]]; then
          local d=$((10#$buf - 1))
          printf '\033[%dA\033[J' "$((n + 1))"
          printf '   %s%s%s %s\n' "$C_OK" "$I_OK" "$C_RESET" "${items[$d]}"
          return $d
        fi
        if [[ "$more" =~ ^[0-9]$ ]]; then
          buf+="$more"
        else
          # 非数字键绝不能进数字缓冲区：否则「1」之后按「q」会得到 buf="1q"，
          # 10#1q 触发 bash 算术错误 → d 为空 → 范围检查把空值当 0 通过
          # → 静默选中【第一项】并执行，等于把「取消」变成「继续执行」。
          buf=''
          if [[ "$more" == 'q' || "$more" == 'Q' ]]; then
            printf '\033[%dA\033[J' "$((n + 1))"
            printf '   %s已取消%s\n' "$C_GRAY" "$C_RESET"
            return 255
          fi
        fi
      fi
    fi
    printf '\033[%dA\033[J' "$((n + 1))"
  done
}

# 带默认项的菜单：默认高亮 default_item（找不到则默认第一项）。
tui_select() {
  local title="$1" def="$2"; shift 2
  local -a items=("$@")
  local i d=0
  # 空列表直接返回：bash 4.2/4.3 在 set -u 下展开空数组 ${items[@]} 会报
  # 「unbound variable」。
  (( ${#items[@]} == 0 )) && return 255
  for ((i = 0; i < ${#items[@]}; i++)); do
    if [[ "${items[$i]}" == "$def" ]]; then d=$i; break; fi
  done
  TUI_MENU_DEFAULT_INDEX=$d
  tui_menu "$title" "${items[@]}"
  local r=$?
  TUI_MENU_DEFAULT_INDEX=0
  return $r
}

# 等待回车：非 TTY 下直接返回，不得阻塞。
tui_pause() {
  [[ $TUI_TTY -eq 1 ]] || return 0
  printf '\n  %s按 Enter 键继续...%s' "$C_GRAY" "$C_RESET"
  IFS= read -r _ || true
  printf '\n'
}

# ==================== lib/core.sh ====================
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

# ==================== lib/client.sh ====================
# lib/client.sh — 客户端物料导出

build_share_link() {
  local uuid="$1" ip="$2" port="$3" sni="$4" pub="$5" sid="$6" remark="$7"
  local enc host
  enc=$(urlencode "$remark")
  # IPv6 地址在 URL 里必须写成 [addr]:port，否则 vless://uuid@2001:db8::1:443 是非法 URL
  # → 客户端导入即废。detect_public_ip 允许返回 IPv6，所以这里必须处理。
  host=$(host_for_url "$ip")
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

# ==================== lib/deploy.sh ====================
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
#   · 内部暂存名用 ".render" 后缀，与 write_config_atomic 的 ".new.<ext>" 区分开，
#     避免两者在同一条路径上撞名。
render_server_config() {
  local outfile="$1" uuid="$2" priv="$3" sni="$4" port="$5" sid="$6"
  # 监听地址：不能写死 "0.0.0.0"（IPv6-only 的机器上只听 IPv4 → 客户端连不上，
  # 见 core.sh 的 choose_listen_addr）。LISTEN_ADDR 可显式指定，否则自动判断。
  local listen_addr="${LISTEN_ADDR:-}"
  if [[ -z "$listen_addr" ]]; then
    listen_addr=$(choose_listen_addr)
  fi
  # 白名单：监听地址会被原样拼进 JSON → 只允许 IP 字面量
  is_valid_ip "$listen_addr" || { tui_err "监听地址非法：$listen_addr"; return 1; }
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
      "listen": "${listen_addr}",
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
      "settings": {},
      "sockopt": {
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

# 让【服务运行用户】能读到配置文件。
#
# ⚠️ 这里是真机踩过的坑：服务端配置含 REALITY 私钥，权限收紧到 root:600，
# 但 systemd unit 是 User=xray → xray 进程根本读不到配置：
#     Failed to start: main: failed to load config files: [/usr/local/etc/xray/config.json]
#     > open /usr/local/etc/xray/config.json: permission denied
# → 退出码 23 → 服务永远起不来。
# 而当时的脚本【还误报「xray 服务已运行」】（见 setup_systemd 的存活校验）。
# 早先的注释写的是「systemd unit 没有 User= → xray 以 root 运行 → 600 不会挡住它读配置」，
# 与实际写出来的 unit（User=xray）矛盾 —— 注释是错的，实现跟着错。
#
# 做法：属主仍留 root（root 永远能改），但把【属组】给服务运行用户 + 组读权限 640：
#   · 服务用户能读 → 服务能起；
#   · 其他用户读不到 → 私钥不外泄；
#   · root 属主 → root 随时可改（管理菜单的轮换密钥走的就是这条路）。
apply_config_ownership() {
  local f="$1" run_user grp
  [[ -f "$f" ]] || return 0
  run_user=$(service_run_user)
  if [[ -z "$run_user" || "$run_user" == 'root' ]]; then
    # 以 root 跑：600 就够了
    chmod 600 "$f" || return 1
    return 0
  fi
  grp=$(service_run_group)
  if [[ -n "$grp" ]] && chown "root:$grp" "$f" 2>/dev/null; then
    chmod 640 "$f" || return 1
  else
    # 拿不到组（用户不存在 / chown 失败）→ 退而求其次：属主给服务用户，
    # 权限同样收紧到 600 —— 服务能读到，其他人读不到。
    chown "$run_user" "$f" 2>/dev/null || true
    chmod 600 "$f" || return 1
  fi
  return 0
}

# 写临时文件 → 校验 → 原子替换。校验失败保留旧文件并输出 xray 报错。
# 用法: write_config_atomic <目标文件> <源文件>
#   源文件是刚渲染出来的配置（尚未落位）；本函数负责把它校验后原子替换到目标。
#   这条路径是【唯一】的写服务端配置入口 —— do_deploy 与 menu_rotate_keys 都必须走它，
#   不得各自手写「渲染 → 校验 → mv」。两处手写必然分叉：menu_rotate_keys 那份当年
#   就漏了输出 xray 的原始报错，用户只看到一句「新配置校验未通过」。
write_config_atomic() {
  local outfile="$1" src="$2"
  # ⚠️ 暂存名必须【保留原扩展名】—— 这是新版 Xray 的硬性要求。
  #
  # Xray 25+ 起改用「按扩展名决定配置格式」的加载器（core.ConfigFormat 注册表）：
  # .json/.jsonc → JSON，.yaml/.yml → YAML，.toml → TOML，.pb → protobuf。
  # 扩展名不在注册表里 → 直接拒绝加载：
  #     core: Failed to get format of /usr/local/etc/xray/config.json.new
  # 旧写法 "$outfile.new"（config.json.new）的扩展名是 "new" → 未注册 →
  # 新版 xray 一律拒绝，而配置本身完全正确（真机实证：Xray 26.10.21，
  # 用户侧表现为「配置校验未通过，已保留原有配置不变」+ 上面那行报错）。
  # 旧版 xray（只看内容不看扩展名）上这个写法是好的 → 属于典型的
  # 「本地测试全绿、真机必红」：CI 里没有真 xray 就永远发现不了。
  #
  # 改法：把标记放在扩展名【前面】—— config.json → config.new.json。
  #  · 扩展名仍是 json → 新旧 xray 都能加载；
  #  · 同目录 → mv 仍是同分区的原子替换；
  #  · 名字里仍带 "new" → 与 render 的 ".render" 不撞名，排查时一眼看得出是暂存文件。
  local base ext tmp
  if [[ "$outfile" == *.* ]]; then
    base="${outfile%.*}"; ext="${outfile##*.}"
  else
    base="$outfile"; ext="json"
  fi
  [[ -n "$base" && -n "$ext" ]] || { base="$outfile"; ext="json"; }
  tmp="$base.new.$ext"
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
  # 权限必须按【服务运行用户】来定，而不是一律 600 root：
  # unit 是 User=xray 时，600 root 的配置它读不到（真机事故：xray 启动即退出 23）。
  # 失败不阻断：setup_systemd 在真正启动前还会再执行一次，那一次是权威判定。
  apply_config_ownership "$outfile" || tui_warn "无法调整配置文件权限：$outfile"
  return 0
}
xray_installed() { [[ -x "$XRAY_BIN" ]]; }

xray_version() {
  "$XRAY_BIN" version 2>/dev/null | head -1 | tr -d '\r'
}

# ══════════════════════════════════════════════════════════════════════
# Xray 内核安装（自包含，不依赖上游安装脚本）
# ══════════════════════════════════════════════════════════════════════
# 为什么不再用上游 XTLS/Xray-install 的 install-release.sh：
#   上游的在线安装分支必须访问 api.github.com 拉版本列表，而 api.github.com
#   【只有 IPv4 地址】。没有公网 IPv4 的机器（IPv6-only，或落在
#   100.64.0.0/10 这类 CGNAT 网段）必然卡在这一步，报错是
#   "Failed to get release list, please check your network." —— 这句提示
#   把人引到「检查网络」的错误方向，而真实结论是「这台机器没有公网 IPv4」。
#   （本项目实测：IPv6 走 raw.githubusercontent.com 能通，api.github.com 通不了。）
#
# 现在的做法：整条链路不依赖上游脚本，也不碰 api.github.com。
#   ① 架构名 → release 资产名；
#   ② 资产压缩包多源回退下载（用户镜像 → 直连 → 内置镜像），可走代理；
#   ③ 用官方 .dgst 做 SHA-256 校验（校验文件优先从直连 GitHub 取）；
#   ④ 自己解压、自己装二进制、自己建 xray 用户、自己写 systemd unit。
# 于是「无 IPv4」「有代理」「完全离线（有 zip 就够）」三种环境都能装。

# 上游 release 资产名用的机器名（与 XTLS/Xray-install 的映射保持一致）
xray_asset_machine() {
  local m
  m=$(uname -m 2>/dev/null)
  case "$m" in
    x86_64|amd64)    printf '64\n' ;;
    i386|i686)       printf '32\n' ;;
    armv5tel)        printf 'arm32-v5\n' ;;
    armv6l)          if xray_cpu_has_vfp; then printf 'arm32-v6\n'; else printf 'arm32-v5\n'; fi ;;
    armv7|armv7l)    if xray_cpu_has_vfp; then printf 'arm32-v7a\n'; else printf 'arm32-v5\n'; fi ;;
    armv8|armv8l|aarch64) printf 'arm64-v8a\n' ;;
    mips)            printf 'mips32\n' ;;
    mipsle)          printf 'mips32le\n' ;;
    mips64)          printf 'mips64\n' ;;
    mips64le)        printf 'mips64le\n' ;;
    ppc64)           printf 'ppc64\n' ;;
    ppc64le)         printf 'ppc64le\n' ;;
    riscv64)         printf 'riscv64\n' ;;
    s390x)           printf 's390x\n' ;;
    *) return 1 ;;
  esac
  return 0
}

# ARM 机器是否带 vfp 指令（上游据此把 arm32-v6 / arm32-v7a 降级成 arm32-v5）
# 先把 Features 行整行收进变量再判断：写成 `grep ... | grep -q` 的话，
# 后面的 grep -q 命中即退出会给上游 grep 送来 SIGPIPE，管道状态变 141。
xray_cpu_has_vfp() {
  local features=''
  features=$(grep '^Features' /proc/cpuinfo 2>/dev/null || printf '')
  [[ "$features" == *vfp* ]]
}

# release 资产地址（latest 版本，不需要预先知道版本号）
xray_release_asset_url() {
  printf 'https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-%s.zip' "$1"
}

# 生成候选下载 URL（每行一个），按优先级排列。
# $1 = 原始 URL；$2 = 顺序：direct = 直连优先，mirror = 用户镜像优先
xray_download_candidates() {
  local url="$1" order="${2:-mirror}" prefix
  if [[ "$order" == 'direct' ]]; then
    printf '%s\n' "$url"
    if [[ -n "$GITHUB_MIRROR" ]]; then
      printf '%s\n' "${GITHUB_MIRROR%/}/${url}"
    fi
  else
    if [[ -n "$GITHUB_MIRROR" ]]; then
      printf '%s\n' "${GITHUB_MIRROR%/}/${url}"
    fi
    printf '%s\n' "$url"
  fi
  for prefix in "${BUILTIN_GITHUB_MIRRORS[@]}"; do
    printf '%s\n' "${prefix%/}/${url}"
  done
  return 0
}

# 按候选源依次尝试下载；成功返回 0，实际使用的源写进 DOWNLOAD_SOURCE_USED。
# $1 = URL；$2 = 输出路径；$3 = 顺序（direct|mirror）
xray_download_to() {
  local url="$1" out="$2" order="${3:-mirror}" src='' rc=0
  DOWNLOAD_SOURCE_USED=''
  while IFS= read -r src; do
    if [[ -z "$src" ]]; then
      continue
    fi
    if [[ -n "$XRAY_PROXY" ]]; then
      curl -fsSL --connect-timeout 10 --max-time 900 -x "$XRAY_PROXY" "$src" -o "$out"
      rc=$?
    else
      curl -fsSL --connect-timeout 10 --max-time 900 "$src" -o "$out"
      rc=$?
    fi
    if [[ $rc -eq 0 ]] && [[ -s "$out" ]]; then
      DOWNLOAD_SOURCE_USED="$src"
      return 0
    fi
    rm -f "$out"
    tui_warn "下载源不可用（curl rc=$rc）：$src"
  done < <(xray_download_candidates "$url" "$order")
  return 1
}

# 用官方 .dgst 校验安装包。
# 返回：0 = 校验通过；1 = 校验不通过（必须中止）；2 = 没有可比对的校验文件（只警告）
xray_verify_sha256() {
  local zip="$1" url="$2" dgst='' expect='' actual=''
  if ! have_cmd openssl; then
    tui_warn "openssl 不可用，跳过安装包 SHA-256 校验。"
    return 2
  fi
  dgst=$(mktemp 2>/dev/null) || return 2
  if [[ -z "$dgst" ]]; then
    return 2
  fi
  # .dgst 优先从【直连 GitHub】取：镜像站一旦被污染，它给的包与校验文件会一起被改，
  # 只有直连取到的校验文件才能真正发现篡改；直连取不到再退回同源。
  if ! xray_download_to "${url}.dgst" "$dgst" 'direct'; then
    rm -f "$dgst"
    tui_warn "取不到官方校验文件（.dgst），安装包未经校验。"
    return 2
  fi
  # 官方 .dgst 是 4 行：MD5= / SHA1= / SHA2-256= / SHA2-512=，
  # 这里只取 SHA2-256 那行（同时兼容单行排布的变体）。
  expect=$(sed -n 's/.*\(SHA2\{0,1\}-256\|SHA256\)=[^0-9a-fA-F]*\([0-9a-fA-F]\{64\}\).*/\2/p' "$dgst" 2>/dev/null)
  rm -f "$dgst"
  if [[ -z "$expect" ]]; then
    tui_warn "校验文件格式异常，安装包未经校验。"
    return 2
  fi
  actual=$(openssl dgst -sha256 "$zip" 2>/dev/null | awk '{print $NF}')
  if [[ -z "$actual" ]]; then
    tui_warn "无法计算安装包 SHA-256，跳过校验。"
    return 2
  fi
  if [[ "$expect" != "$actual" ]]; then
    tui_err "安装包 SHA-256 校验不通过（期望 $expect，实际 $actual）"
    return 1
  fi
  tui_ok "安装包 SHA-256 校验通过"
  return 0
}

# 下载彻底失败时给出的可操作方案（不能只说「请检查网络」）。
xray_download_hint() {
  tui_tip "三种绕开方式，任选其一："
  tui_tip "  1) 走代理：   bash install.sh --proxy http://127.0.0.1:7890"
  tui_tip "  2) 走镜像：   bash install.sh --mirror https://gh.llkk.cc/"
  tui_tip "  3) 离线包：   在能上网的机器上下载 Xray-linux-<架构>.zip，"
  tui_tip "               传到本机后执行 bash install.sh --local /root/Xray-linux-64.zip"
  tui_tip "常见根因：GitHub 主站与 release 资源只有 IPv4，IPv6-only 或 CGNAT 网段的机器到不了。"
}

# 建 xray 系统用户（systemd unit 以它运行）
xray_ensure_user() {
  if id xray >/dev/null 2>&1; then
    return 0
  fi
  if ! have_cmd groupadd || ! have_cmd useradd; then
    tui_warn "缺少 groupadd/useradd，无法创建 xray 用户，服务可能起不来。"
    return 1
  fi
  groupadd --system xray 2>/dev/null || true
  if ! useradd --system --gid xray --no-create-home --home-dir /var/lib/xray \
        --shell /usr/sbin/nologin xray 2>/dev/null; then
    tui_warn "创建 xray 用户失败，服务可能起不来。"
    return 1
  fi
  return 0
}

# 写 systemd unit（自己写，不依赖上游脚本）
xray_write_service_unit() {
  local unit="$XRAY_SERVICE_UNIT" tmp=''
  tmp=$(mktemp 2>/dev/null) || tmp=''
  if [[ -z "$tmp" ]]; then
    tui_err "无法创建临时文件，systemd unit 写入中止。"
    return 1
  fi
  # 这里的两个变量都是本项目自己的绝对路径（可被环境变量覆盖），
  # 不是用户输入，不存在 heredoc 注入问题。
  cat >"$tmp" <<EOF
[Unit]
Description=Xray Service
Documentation=https://xtls.github.io/
After=network.target nss-lookup.target

[Service]
User=xray
Group=xray
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
NoNewPrivileges=yes
UMask=0077
ExecStart=$XRAY_BIN run -config $XRAY_CONFIG
Restart=on-failure
RestartPreventExitStatus=23
LimitNPROC=10000
LimitNOFILE=1000000
RuntimeDirectory=xray
RuntimeDirectoryMode=0755

[Install]
WantedBy=multi-user.target
EOF
  if ! cp -f "$tmp" "$unit"; then
    rm -f "$tmp"
    tui_err "无法写入 systemd unit：$unit"
    return 1
  fi
  rm -f "$tmp"
  chmod 644 "$unit" 2>/dev/null || true
  # 单元文件刚被换过，systemd 手里还是旧的 → 必须重载，否则 enable/start 用的是旧版本。
  systemctl daemon-reload 2>/dev/null || true
  return 0
}

# 从安装包（zip）安装内核：解压 → 装二进制 → 建用户 → 写 unit → 自检
# $1 = zip 路径
xray_install_from_zip() {
  local zip="$1" workdir='' rc=0
  if [[ ! -f "$zip" ]] || [[ ! -s "$zip" ]]; then
    tui_err "安装包不存在或为空：$zip"
    return 1
  fi
  workdir=$(mktemp -d 2>/dev/null) || workdir=''
  if [[ -z "$workdir" ]]; then
    tui_err "无法创建临时目录，安装中止。"
    return 1
  fi
  tui_run "解压 Xray 安装包" unzip -o -q "$zip" -d "$workdir"
  rc=$?
  if [[ $rc -ne 0 ]] || [[ ! -f "$workdir/xray" ]]; then
    rm -rf "$workdir"
    tui_err "解压安装包失败（文件不是有效的 Xray 安装包？）"
    return 1
  fi
  if ! cp -f "$workdir/xray" "$XRAY_BIN"; then
    rm -rf "$workdir"
    tui_err "无法安装二进制到 $XRAY_BIN"
    return 1
  fi
  rm -rf "$workdir"
  chmod 755 "$XRAY_BIN" || { tui_err "无法设置二进制权限：$XRAY_BIN"; return 1; }
  # 二进制必须真的能跑：架构不匹配时 xray version 会直接失败，
  # 而那正是「装上了但服务起不来」最常见的原因。
  if ! "$XRAY_BIN" version >/dev/null 2>&1; then
    tui_err "安装的 xray 二进制无法执行（架构不匹配？）"
    return 1
  fi
  xray_ensure_user || true
  xray_write_service_unit || return 1
  if mkdir -p "$LOG_DIR" 2>/dev/null; then
    chown xray:xray "$LOG_DIR" 2>/dev/null || true
  fi
  return 0
}

# 下载并校验 release 压缩包；成功后路径写进 XRAY_FETCHED_ZIP，临时目录写进 XRAY_FETCHED_TMPDIR。
# $1 = 机器名（xray_asset_machine 的输出）
xray_fetch_release_zip() {
  local machine="$1" url='' zip='' tmpdir='' rc=0
  url=$(xray_release_asset_url "$machine")
  tmpdir=$(mktemp -d 2>/dev/null) || tmpdir=''
  if [[ -z "$tmpdir" ]]; then
    tui_err "无法创建临时目录，下载中止。"
    return 1
  fi
  zip="$tmpdir/Xray-linux-$machine.zip"
  tui_info "下载 Xray 安装包（$machine）…"
  if ! xray_download_to "$url" "$zip" 'mirror'; then
    rm -rf "$tmpdir"
    tui_err "无法下载 Xray 安装包。"
    xray_download_hint
    return 1
  fi
  tui_ok "安装包下载完成：$DOWNLOAD_SOURCE_USED"
  xray_verify_sha256 "$zip" "$url"
  rc=$?
  if [[ $rc -eq 1 ]]; then
    rm -rf "$tmpdir"
    tui_err "安装包校验未通过，已中止。"
    return 1
  fi
  XRAY_FETCHED_ZIP="$zip"
  XRAY_FETCHED_TMPDIR="$tmpdir"
  return 0
}

install_xray() {
  if xray_installed; then
    tui_ok "Xray 已安装：$(xray_version)"
    tui_tip "如需更新请使用管理菜单的「更新 Xray 内核」"
    return 0
  fi
  # 依赖装不上就必须中止：ensure_packages 会透传 apt 的失败码。
  ensure_packages curl ca-certificates || return 1
  # unzip 是解压安装包用的。必须【先】装好：否则后面报的是「解压失败」，
  # 而真实原因是系统里没有 unzip，与网络、与安装包都无关。
  ensure_packages unzip || { tui_err "缺少 unzip，无法安装 Xray。"; return 1; }

  local machine=''
  machine=$(xray_asset_machine) || {
    tui_err "不支持的 CPU 架构：$(uname -m 2>/dev/null || printf '未知')"
    return 1
  }

  # 路径 A：用户自带离线安装包（完全不联网）
  if [[ -n "$XRAY_LOCAL_FILE" ]]; then
    tui_info "使用离线安装包：$XRAY_LOCAL_FILE"
    xray_install_from_zip "$XRAY_LOCAL_FILE" || return 1
    tui_ok "Xray 安装完成：$(xray_version)"
    return 0
  fi

  # 路径 B：自己下载 release 压缩包（多源回退 + 代理 + SHA-256 校验）
  xray_fetch_release_zip "$machine" || return 1
  xray_install_from_zip "$XRAY_FETCHED_ZIP" || { rm -rf "$XRAY_FETCHED_TMPDIR"; return 1; }
  rm -rf "$XRAY_FETCHED_TMPDIR"
  tui_ok "Xray 安装完成：$(xray_version)"
  return 0
}

# 服务「真的活着」的判定。
#
# ⚠️ `systemctl start/restart` 返回 0 ≠ 服务活着：Type=simple 的 unit 在
# ExecStart 进程一启动就算 "active"，哪怕它 70ms 后就因为配置读不到而退出。
# 真机上正是这样：xray 进程 76ms 内以退出码 23 结束，
# 而脚本当时判定 `systemctl is-active --quiet xray` 为真 → 打印「xray 服务已运行」，
# 用户拿到一台【服务根本没起来】的服务器。
# 判定方法：启动后等一小会儿（让进程有机会死掉），再查 active 状态。
xray_service_alive() {
  local waited=0 sub
  # ⚠️ 不能「一看到 active 就返回」：Type=simple 的 unit 在 ExecStart 进程
  # 刚 fork 出来时就是 active，哪怕它 70ms 后就死了（真机：退出码 23）。
  # 所以先给一个「起不来就会死」的时间窗（2 秒），
  # 期间一旦 SubState 变成 failed 就立刻判失败；时间窗过后再查 active。
  # 用 SubState 而不是 `is-failed`：is-failed 在【任何】systemctl 返回 0 的
  # 情况下都算「failed」（单测里 systemctl 是整体 mock 的），SubState 才是状态本身。
  while (( waited < 8 )); do
    sub=$(systemctl show -p SubState --value xray 2>/dev/null || printf '')
    if [[ "$sub" == "failed" ]]; then
      return 1
    fi
    sleep 0.25
    waited=$((waited + 1))
  done
  systemctl is-active --quiet xray 2>/dev/null
}

setup_systemd() {
  if ! have_cmd systemctl; then
    tui_err "未找到 systemctl，systemd 不可用"
    return 1
  fi
  # ── 顺序很重要：先把服务启动【需要】的东西准备好，再启动服务 ──────────
  # ① 日志目录 + 日志文件：xray 以 xray 用户跑时写不了 root 属主的日志文件 →
  #    （真机事故：日志文件是 root:600，xray 起不来）
  # ② 配置文件属主：配置是 root:600 时，xray 用户读不到 → 退出码 23
  # 这两件事都必须【在 enable --now 之前】做完。
  local run_user svc_user svc_group
  run_user=$(service_run_user)
  if [[ "$run_user" != "root" ]]; then
    svc_user="$run_user"
    svc_group=$(service_run_group)
    # mkdir 的退出码必须检查：失败时后面仍然会打印「日志目录已授权」→ 谎报。
    # 目录建不出来时 xray 写不了日志，用户却以为一切正常。
    if ! mkdir -p "$LOG_DIR"; then
      tui_warn "无法创建日志目录 $LOG_DIR，xray 可能无法写入日志。"
    else
      if id "$svc_user" >/dev/null 2>&1; then
        chown -R "$svc_user${svc_group:+:$svc_group}" "$LOG_DIR" 2>/dev/null || true
      fi
      tui_tip "日志目录已授权给运行用户 $svc_user"
    fi
  fi
  # 配置文件的属主/权限：必须与【服务的运行用户】匹配。
  # unit 是 User=xray 时，root:600 的配置 xray 读不到 → 启动即退出 23。
  if [[ -f "$XRAY_CONFIG" ]]; then
    if ! apply_config_ownership "$XRAY_CONFIG"; then
      tui_err "无法设置配置文件权限，xray 可能读不到配置：$XRAY_CONFIG"
      return 1
    fi
    tui_tip "配置文件权限已按运行用户调整：$XRAY_CONFIG"
  fi

  # ⚠️ 必须用 enable + restart，不能用 `enable --now`：
  #   `systemctl enable --now xray` 在服务【已经运行】时是【空操作】——
  #   systemd 只保证「它在跑」，不会让它重新读取刚写好的配置。
  #   真机事故：用户在已有部署的机器上重跑安装器 → 新配置（端口 30356、
  #   新密钥）写进了文件、ufw 也放行了新端口，但跑着的还是旧进程
  #   （journal 里没有任何新的 "Started xray.service"）→ 客户端按新端口连，
  #   服务却还在监听旧端口 → 「连不上」，且服务端日志一片空白。
  #   restart 会停掉旧进程、用新配置重新拉起；服务没在跑时 restart 等于 start。
  tui_run "启用并启动 xray 服务" systemctl enable xray
  tui_run "重启 xray 服务（加载新配置）" systemctl restart xray
  # ⚠️ 必须用 xray_service_alive（带等待）而不是立刻 is-active ——
  # 进程「启动后立刻死掉」是这个场景的真凶。
  if ! xray_service_alive; then
    tui_err "xray 服务未能启动，最近日志如下："
    journalctl -u xray -n 30 --no-pager 2>/dev/null | sed -e 's/^/      /' || true
    return 1
  fi
  tui_ok "xray 服务已运行"
  return 0
}

restart_service() {
  tui_run "重启 xray 服务" systemctl restart xray
  if xray_service_alive; then
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
  local -a same_prefix=()   # 与本机同 /32 的目标（GFW 关联风险最低）
  while IFS='|' read -r host tls lat; do
    [[ -z "$host" ]] && continue
    hosts+=("$host")
    local mark=''
    if target_same_ipv6_prefix "$host"; then
      same_prefix+=("$host")
      mark='  同网段✔'
    fi
    if [[ "$tls" == 'ok' ]]; then
      labels+=("${host}    TLS1.3 ✔   ${lat}ms${mark}")
    else
      labels+=("${host}    TLS1.3 ✘   ${lat}ms${mark}")
    fi
  done <<<"$probe"

  # 用 ${OPT_YES:-0} 而不是 $OPT_YES：OPT_* 是 install.sh 的全局，
  # deploy.sh 单独被 source（单元测试 / helper）时它们可能根本没定义，
  # 在 `set -u` 下会直接报 unbound variable。
  if [[ ${OPT_YES:-0} -eq 1 ]]; then
    # 优先挑【与本机同 /32】且支持 TLS1.3 的目标：
    #   SNI 指向 CDN、连接目标却是小鸡 IP → GFW 的 DPI 会关联并掐断握手
    #   （真机事故：one.one.one.one + Vultr → TCP 通、REALITY 握手永远不返回；
    #     换成同网段的 api.vultr.com → 立刻通）。
    local pick='' host ph pt pl
    # ⚠️ 必须先判长度再展开：空数组在 set -u + bash 4.2/4.3 下展开会报 unbound variable。
    if (( ${#same_prefix[@]} > 0 )); then
      for host in "${same_prefix[@]}"; do
        while IFS='|' read -r ph pt pl; do
          if [[ "$ph" == "$host" && "$pt" == 'ok' ]]; then pick="$host"; break; fi
        done <<<"$probe"
        [[ -n "$pick" ]] && break
      done
    fi
    if [[ -z "$pick" ]]; then
      # 没有同网段目标 → 退回「第一个支持 TLS1.3 且延迟已知」的
      while IFS='|' read -r host tls lat; do
        if [[ "$tls" == 'ok' && "$lat" != '?' ]]; then pick="$host"; break; fi
      done <<<"$probe"
    fi
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
  # 默认选中第一个【同网段】目标（没有则用第一项）：
  # 同网段目标被 GFW 关联掐断的概率最低，应当是默认而非让用户自己猜。
  if (( ${#same_prefix[@]} > 0 )); then
    local first_same=''
    for i in "${!hosts[@]}"; do
      if [[ "${hosts[$i]}" == "${same_prefix[0]}" ]]; then first_same=$i; break; fi
    done
    [[ -n "$first_same" ]] && TUI_MENU_DEFAULT_INDEX=$first_same
  fi
  # 必须把 tui_menu 的输出重定向到 stderr：tui_menu 会把【整张菜单】打到 stdout，
  # 而调用方是 `SNI=$(choose_target)` —— 不重定向的话，SNI 会变成
  # 「菜单标题 + 选项列表 + 选中的 host」的多行字符串，随后被原样写进
  # config.json → JSON 非法 → xray run -test 失败 → 部署以一句看不懂的报错中止。
  # 选中项一律用【返回码】取，stdout 只留最后 printf 的那个 host。
  tui_menu "选择 REALITY 伪装目标（SNI）" "${labels[@]}" >&2 || rc=$?
  # 默认索引是全局变量 → 用完必须复位，否则会污染后面所有的菜单。
  TUI_MENU_DEFAULT_INDEX=0
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
    # ⚠️ 占用者就是【本工具自己部署的 xray 服务】→ 这不是「冲突」，是「重部署」：
    #   旧实例占着端口是正常的（它正跑着上一份配置）。
    #   正确做法：沿用同一个端口，部署末尾重启服务加载新配置。
    #   误判成冲突 → 自动改用随机端口 → 服务换到别的端口，
    #   而客户端还指着旧端口 → 「连不上」，服务端日志一条都没有（真机事故：
    #   重跑安装器后服务仍在 443、配置却写成 30356）。
    if port_owned_by_our_xray "$occ"; then
      tui_tip "端口 $PORT 正由本工具已部署的 xray 服务占用（重部署场景）"
      tui_tip "沿用该端口，部署末尾会重启服务以加载新配置。"
    else
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
  # ⚠️ SNI（伪装目标）必须与本机【同网段】才安全：
  #   SNI 指向 CDN（one.one.one.one / www.microsoft.com …）、连接目标却是
  #   一台小鸡的 IP → GFW 的 DPI 把两者一关联，REALITY 握手就被掐断
  #   （客户端表现：TCP 能连上、握手一直不返回、服务器日志一条没有）。
  #   同网段目标（Vultr → api.vultr.com）＝ 一次普通的 HTTPS 访问，不会被关联。
  #   --target 可以显式指定；不给就自动挑同网段的。
  SNI="${OPT_TARGET:-${OPT_SNI:-}}"
  if [[ -z "$SNI" ]]; then
    SNI=$(choose_target)
  fi
  TARGET="$SNI"
  [[ -z "$SNI" ]] && { tui_err "未确定伪装目标"; return 1; }
  tui_kv "伪装目标 (SNI)" "$SNI"
  # 非同网段 → 必须明确告知风险与解法（真机事故的根因就在这里）
  if ! target_same_ipv6_prefix "$SNI"; then
    tui_warn "伪装目标 $SNI 与本机不在同一 IPv6 /32 网段，存在被 GFW 关联掐断的风险。"
    tui_tip "同网段目标（Vultr → api.vultr.com、Ovh → api.ovh.com 等）可避免该问题。"
    tui_tip "如已知更合适的目标，可用 --target <域名> 显式指定。"
  fi

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
    "地址|$(host_for_url "$SERVER_IP"):$PORT" \
    "UUID|$UUID" \
    "SNI|$SNI" \
    "公钥 pbk|$PUBLIC_KEY" \
    "ShortID sid|$SHORT_ID" \
    "防火墙|$fw_row" \
    "客户端配置|$OUT_DIR/client.json" \
    "二维码|$OUT_DIR/qrcode.png"

  # 用 tui_box_text 而不是 tui_box/tui_box_line：分享链接有 150+ 字符，
  # 框内净宽只有 TUI_WIDTH-6 → 硬塞进框里会把右边框顶出去（框线合不拢）；
  # 也不能折行（用户要复制这一行，折行后粘到客户端是废链接）。
  tui_box_text "分享链接（可直接粘贴到客户端导入）" "$link"

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
    "地址|$(host_for_url "$SERVER_IP"):$PORT" \
    "UUID|$UUID" \
    "SNI|$SNI" \
    "公钥 pbk|$PUBLIC_KEY" \
    "ShortID sid|$SHORT_ID" \
    "备注|$REMARK"
  # 同上：分享链接超出框宽 → 用 tui_box_text 整行输出（不撑破边框、也不折行）。
  tui_box_text "分享链接" "$link"
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
  # 依赖装不上就必须停在这里：继续往下走会下载安装包、失败，
  # 报出来的却是「下载失败」——错误信息与真实原因无关。
  ensure_packages curl ca-certificates || { tui_err "依赖安装失败，无法更新 Xray。"; return 1; }
  ensure_packages unzip || { tui_err "缺少 unzip，无法更新 Xray。"; return 1; }
  local machine='' old_version='' new_version=''
  machine=$(xray_asset_machine) || { tui_err "不支持的 CPU 架构。"; return 1; }
  old_version=$(xray_version)

  # 与首次安装走【同一条下载链】：用户镜像 → 直连 → 内置镜像，可带代理，
  # 也支持 --local 的离线包。更新不能在网络受限时唯一下载失败。
  if [[ -n "$XRAY_LOCAL_FILE" ]]; then
    tui_info "使用离线安装包：$XRAY_LOCAL_FILE"
    xray_install_from_zip "$XRAY_LOCAL_FILE" || return 1
  else
    xray_fetch_release_zip "$machine" || return 1
    xray_install_from_zip "$XRAY_FETCHED_ZIP" || { rm -rf "$XRAY_FETCHED_TMPDIR"; return 1; }
    rm -rf "$XRAY_FETCHED_TMPDIR"
  fi

  new_version=$(xray_version)
  if [[ -n "$old_version" ]] && [[ "$old_version" == "$new_version" ]]; then
    tui_ok "Xray 已是最新版本：$new_version"
    return 0
  fi
  tui_ok "Xray 已更新：$old_version → $new_version"
  restart_service
  return $?
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
  # 用 -f 判定而不是 -x：`-x` 依赖执行位，而执行位【不可靠】——
  # 单文件分发版里根本没有 uninstall.sh，curl 下载来的文件也没有执行位
  # → -x 永远判成「没有」→ 卸载入口是死的。
  # 用 `exec bash` 显式执行 → 完全不依赖执行位。
  if [[ ! -f "$ROOT_DIR/uninstall.sh" ]]; then
    tui_warn "当前目录没有 uninstall.sh（单文件分发版不含卸载脚本）。"
    tui_tip "请手动执行：systemctl disable --now xray && rm -f $XRAY_CONFIG"
    return 1
  fi
  exec bash "$ROOT_DIR/uninstall.sh"
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

# ==================== 入口 (install.sh) ====================
# install.sh — VLESS + REALITY 一键部署工具（入口）
#
# 用法:
#   sudo bash install.sh              交互式向导
#   sudo bash install.sh -y           全自动（用默认值）
#   sudo bash install.sh --menu       进入管理菜单
#   sudo bash install.sh --status     查看运行状态
#   sudo bash install.sh --uninstall  卸载
#
# ⚠️ 用 `bash install.sh` 而不是 `./install.sh`：
#    单文件分发版是 `curl -o` 下载来的 → 那个文件【没有执行位】，
#    ./install.sh 会 Permission denied。
#    （仓库里的 install.sh 提交模式是 100755，clone 下来就带执行位；
#      但 `bash install.sh` 两种情况都成立。）



OPT_YES=0
OPT_MENU=0
OPT_STATUS=0
OPT_UNINSTALL=0
OPT_PORT=''
OPT_SNI=''
OPT_TARGET=''
OPT_NAME=''
OPT_UUID=''
OPT_ADDR=''
OPT_MIRROR=''
OPT_PROXY=''
OPT_LOCAL=''

usage() {
  cat <<EOF
${APP_NAME} v${APP_VERSION}

用法:
  sudo bash install.sh [选项]

选项:
  -y, --yes          全自动无交互，使用内置默认值
  -p, --port <端口>   指定监听端口（默认 443）
  -s, --sni <域名>    指定 REALITY 伪装目标
      --target <域名> 指定 REALITY 伪装目标（与 --sni 等价；优先用同网段的目标，
                     例：Vultr 选 api.vultr.com —— SNI 指向 CDN 而连接目标
                     是小鸡 IP 时，GFW 的 DPI 会关联并掐断 REALITY 握手）
  -n, --name <备注>   指定分享链接备注
      --uuid <UUID>   指定 UUID（默认自动生成）
      --addr <地址>   指定对外地址（NAT 后的服务器用；默认自动探测公网 IP）
      --mirror <前缀> GitHub 镜像前缀（例：https://gh.llkk.cc/）
      --proxy <地址>  下载走 HTTP/SOCKS5 代理（例：http://127.0.0.1:7890）
      --local <zip>   使用本地已有的 Xray 离线安装包（完全不联网）
  -m, --menu          直接进入管理菜单
      --status        查看运行状态并退出
      --uninstall     卸载并清理
  -h, --help          显示本帮助

网络受限时（GitHub 只有 IPv4、机器没有公网 IPv4）的三种走法：
  --proxy http://127.0.0.1:7890        走本机代理
  --mirror https://gh.llkk.cc/         走 GitHub 镜像
  --local /root/Xray-linux-64.zip      用事先下载好的离线安装包

文件位置:
  配置状态   $STATE_FILE
  客户端导出 $OUT_DIR
  服务端配置 $XRAY_CONFIG
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -y|--yes)      OPT_YES=1; shift ;;
      -m|--menu)     OPT_MENU=1; shift ;;
      --status)      OPT_STATUS=1; shift ;;
      --uninstall)   OPT_UNINSTALL=1; shift ;;
      -h|--help)     usage; exit 0 ;;
      -p|--port)     OPT_PORT="${2:-}"; [[ -n "$OPT_PORT" ]] || { tui_err "--port 缺少参数"; exit 1; }
                     # 端口范围必须在【参数解析口】就拦一次：只校验交互式输入那条路径不够，
                     # --port 99999 会被接受并写进 config.json → 部署晚一步才因 xray 报错而中止。
                     # 10# 前缀：用户输入 "08" 时不能被当成八进制。
                     if ! [[ "$OPT_PORT" =~ ^[0-9]+$ ]] || (( 10#$OPT_PORT < 1 || 10#$OPT_PORT > 65535 )); then
                       tui_err "--port 必须是 1-65535 之间的整数：$OPT_PORT"
                       exit 1
                     fi
                     shift 2 ;;
      -s|--sni)      OPT_SNI="${2:-}"; [[ -n "$OPT_SNI" ]] || { tui_err "--sni 缺少参数"; exit 1; }; shift 2 ;;
      --target)      OPT_TARGET="${2:-}"; [[ -n "$OPT_TARGET" ]] || { tui_err "--target 缺少参数"; exit 1; }
                     # 伪装目标会原样进入 config.json 的 target/serverNames → 必须是纯主机名。
                     if ! [[ "$OPT_TARGET" =~ ^[A-Za-z0-9.-]+$ ]]; then
                       tui_err "--target 只能是域名：$OPT_TARGET"
                       tui_tip "示例：--target api.vultr.com（与本机同网段的目标最不容易被 GFW 关联）"
                       exit 1
                     fi
                     shift 2 ;;
      -n|--name)     OPT_NAME="${2:-}"; [[ -n "$OPT_NAME" ]] || { tui_err "--name 缺少参数"; exit 1; }; shift 2 ;;
      --uuid)        OPT_UUID="${2:-}"; [[ -n "$OPT_UUID" ]] || { tui_err "--uuid 缺少参数"; exit 1; }; shift 2 ;;
      --addr)        OPT_ADDR="${2:-}"; [[ -n "$OPT_ADDR" ]] || { tui_err "--addr 缺少参数"; exit 1; }
                     # 地址会原样进入分享链接与客户端 JSON → 字符集必须受限：
                     # 只允许 IP 字面量与 DNS 主机名会用到的字符（字母数字 . : _ -），
                     # 引号/反斜杠/空格/$ 一律拒绝（否则破坏 JSON 与 URL）。
                     if ! [[ "$OPT_ADDR" =~ ^[A-Za-z0-9._:-]+$ ]]; then
                       tui_err "--addr 只能是 IP 地址或主机名：$OPT_ADDR"
                       tui_tip "示例：1.2.3.4 / example.com / 2001:db8::1"
                       exit 1
                     fi
                     shift 2 ;;
      --mirror)       OPT_MIRROR="${2:-}"; [[ -n "$OPT_MIRROR" ]] || { tui_err "--mirror 缺少参数"; exit 1; }
                     # 镜像前缀会被直接拼在下载 URL 前面 → 必须是 http(s) 绝对地址，
                     # 否则拼出来的地址根本不是 URL，报错会指向 curl 的语法错误，
                     # 而不是「镜像地址写错了」。
                     if ! [[ "$OPT_MIRROR" =~ ^https?://[^[:space:]]+$ ]]; then
                       tui_err "--mirror 必须是 http(s) 镜像地址：$OPT_MIRROR"
                       tui_tip "示例：https://gh.llkk.cc/"
                       exit 1
                     fi
                     shift 2 ;;
      --proxy)        OPT_PROXY="${2:-}"; [[ -n "$OPT_PROXY" ]] || { tui_err "--proxy 缺少参数"; exit 1; }
                     if ! [[ "$OPT_PROXY" =~ ^(https?|socks5h?|socks4)://[^[:space:]]+$ ]]; then
                       tui_err "--proxy 必须是 http/https/socks5 代理地址：$OPT_PROXY"
                       tui_tip "示例：http://127.0.0.1:7890 或 socks5://127.0.0.1:1080"
                       exit 1
                     fi
                     shift 2 ;;
      --local)        OPT_LOCAL="${2:-}"; [[ -n "$OPT_LOCAL" ]] || { tui_err "--local 缺少参数"; exit 1; }
                     # 离线包必须【当场】可用：不能等到下载失败之后才发现路径写错了。
                     if [[ ! -f "$OPT_LOCAL" ]] || [[ ! -r "$OPT_LOCAL" ]]; then
                       tui_err "--local 指定的安装包不存在或不可读：$OPT_LOCAL"
                       tui_tip "示例：--local /root/Xray-linux-64.zip"
                       exit 1
                     fi
                     shift 2 ;;
      *) tui_err "未知参数：$1"; usage; exit 1 ;;
    esac
  done
  # SNI 会在后续被原样写进 config.json 与分享链接 —— 在【参数解析口】校验，
  # 避免把带引号/反斜杠的字符串送进 JSON 渲染。
  if [[ -n "$OPT_SNI" ]] && ! validate_hostname "$OPT_SNI"; then
    tui_err "--sni 不是合法的主机名：$OPT_SNI"
    tui_tip "示例：www.microsoft.com（只允许字母、数字、连字符与点，且必须含点）"
    exit 1
  fi
  # 下载参数落到全局：命令行优先于环境变量（core.sh 里 GITHUB_MIRROR 等
  # 已经能用环境变量预设，这里是覆盖而不是清空）。
  # 必须放在 parse_args 里而不是 main 里：--menu 进管理菜单时同样要用得上，
  # 因为菜单里的「更新 Xray 内核」走的是同一条下载链。
  if [[ -n "$OPT_MIRROR" ]]; then
    GITHUB_MIRROR="$OPT_MIRROR"
  fi
  if [[ -n "$OPT_PROXY" ]]; then
    XRAY_PROXY="$OPT_PROXY"
  fi
  if [[ -n "$OPT_LOCAL" ]]; then
    XRAY_LOCAL_FILE="$OPT_LOCAL"
  fi
  return 0
}

require_root() {
  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    tui_err "需要 root 权限，请使用 sudo 重新执行。"
    return 1
  fi
  return 0
}

preflight() {
  local rc=0
  tui_section "环境预检"

  assert_debian || rc=1

  if have_cmd systemctl; then
    tui_ok "systemd 可用"
  else
    tui_err "未找到 systemctl，systemd 不可用"
    rc=1
  fi

  if have_cmd curl; then
    tui_ok "curl 可用"
  else
    tui_err "未找到 curl，无法下载安装脚本"
    rc=1
  fi

  # 依赖补齐
  ensure_packages openssl || rc=1
  if ! have_cmd qrencode; then
    ensure_packages qrencode || tui_tip "qrencode 安装失败，稍后仍可手动安装以生成二维码"
  fi

  # 下载通道：必须让用户看得见【实际走哪条路】，
  # 否则「装不上」时用户根本不知道自己是直连、镜像、代理还是离线包。
  if [[ -n "$XRAY_LOCAL_FILE" ]]; then
    tui_ok "下载通道：离线安装包 $XRAY_LOCAL_FILE"
  else
    if [[ -n "$XRAY_PROXY" ]]; then
      tui_ok "下载通道：代理 $XRAY_PROXY"
    else
      tui_ok "下载通道：直连（失败后自动回退内置镜像）"
    fi
    if [[ -n "$GITHUB_MIRROR" ]]; then
      tui_ok "下载镜像：$GITHUB_MIRROR"
    fi
  fi

  # 对外地址：优先用 --addr 指定的（NAT 后的服务器探测不到公网 IP，
  # 探测到的只是内网地址 → 分享链接里的主机名是内网 IP → 客户端根本连不上）。
  if [[ -n "${OPT_ADDR:-}" ]]; then
    SERVER_IP="$OPT_ADDR"
    tui_ok "使用指定的对外地址：$SERVER_IP"
  else
    SERVER_IP=$(detect_public_ip || true)
    if [[ -z "$SERVER_IP" ]]; then
      SERVER_IP=$(detect_local_ip || true)
      tui_warn "未能探测到公网 IP，回退使用本机地址：${SERVER_IP:-未知}"
      tui_tip "若服务器位于 NAT 后，请用 --addr 指定对外地址后再配置客户端。"
    else
      tui_ok "公网 IP：$SERVER_IP"
    fi
  fi

  return $rc
}

main() {
  parse_args "$@"
  tui_init

  if [[ $OPT_UNINSTALL -eq 1 ]]; then
    # 用 -f 判定而不是 -x：`-x` 依赖执行位，而执行位【不可靠】——
    # 单文件分发版里根本没有 uninstall.sh，curl 下载来的文件也没有执行位
    # → -x 永远判成「没有」→ 卸载入口是死的。
    # 用 `exec bash` 显式执行 → 完全不依赖执行位。
    if [[ -f "$ROOT_DIR/uninstall.sh" ]]; then
      exec bash "$ROOT_DIR/uninstall.sh"
    fi
    tui_warn "当前目录没有 uninstall.sh（单文件分发版不含卸载脚本）。"
    tui_tip "请手动执行：systemctl disable --now xray && rm -f $XRAY_CONFIG"
    exit 1
  fi

  if [[ $OPT_STATUS -eq 1 ]]; then
    # 只读操作，不要求 root —— 否则非 root 的 CI 环境会直接失败，
    # 与本任务「--status 退出码为 0」的测试断言相矛盾。
    load_state || true
    tui_banner "$APP_NAME" "状态自检"
    tui_section "服务状态"
    service_status
    exit 0
  fi

  if [[ $OPT_MENU -eq 1 ]]; then
    require_root || exit 1
    load_state || true
    if ! declare -F management_menu >/dev/null 2>&1; then
      tui_err "内部错误：management_menu 未定义，源码不完整。"
      exit 1
    fi
    management_menu
    exit 0
  fi

  require_root || exit 1
  tui_banner "$APP_NAME" "VLESS + REALITY 一键部署"
  if ! preflight; then
    tui_err "预检未通过，部署已中止。"
    exit 1
  fi
  if ! declare -F deploy_wizard >/dev/null 2>&1; then
    tui_err "内部错误：deploy_wizard 未定义，源码不完整。"
    exit 1
  fi
  deploy_wizard
}


# ── 只有【直接执行】时才跑主流程 ────────────────────────────
# 被 source 时（单元测试要 source 本文件来测 parse_args / preflight 等函数）
# 绝不执行 main —— 否则会真的开始部署。
# 两个条件缺一不可：
#   ① BASH_SOURCE[0] == $0 → 只有直接执行本文件时成立；
#      被 source 时 $0 是调用方（测试脚本）→ 不相等。
#   ② INSTALL_SH_NO_MAIN != 1 → 给测试一个显式开关。
if [[ "${BASH_SOURCE[0]}" == "${0}" ]] && [[ "${INSTALL_SH_NO_MAIN:-0}" != "1" ]]; then
  main "$@"
fi
