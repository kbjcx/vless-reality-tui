#!/usr/bin/env bash
# lib/tui.sh — 零依赖 TUI 组件库
# 硬约束：本文件不得包含任何业务逻辑、文件写入（tui_run 捕获输出除外）或系统调用。

TUI_TTY=0; TUI_COLOR=0; TUI_WIDTH=80; TUI_UNICODE=1

C_RESET=''; C_BOLD=''; C_DIM=''
C_RED=''; C_GREEN=''; C_YELLOW=''; C_BLUE=''; C_CYAN=''; C_MAGENTA=''; C_WHITE=''; C_GRAY=''
C_OK=''; C_ERR=''; C_WARN=''; C_INFO=''; C_ACCENT=''

B_TL='╭'; B_TR='╮'; B_BL='╰'; B_BR='╯'; B_H='─'; B_V='│'
I_MARK='●'; I_ARROW='▸'; I_OK='✔'; I_ERR='✖'; I_WARN='▲'; I_INFO='ℹ'; I_TIP='▷'

tui_init() {
  [[ -t 1 && -t 0 ]] && TUI_TTY=1
  [[ "${TERM:-dumb}" != "dumb" && -t 1 && -z "${NO_COLOR:-}" ]] && TUI_COLOR=1

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
# 按【字节】解码 UTF-8 后比较码点，不依赖 locale：
#   - ${#s} 在 C locale 下是字节数，否则是字符数；
#   - case 区间 [$'\u1100'-...] 的匹配结果依赖 locale 的排序规则。
# 因此这里显式 local LC_ALL=C（与 lib/core.sh 的 urlencode 同一手法）后按字节解码，
# 保证在任何 locale（含 LANG 未设置的服务器与 Git Bash 默认的 C locale）下结果一致。
# 码点区段与设计稿一致：CJK 符号、中日韩符号、假名、CJK 扩展、汉字、兼容汉字、
# 谚文、CJK 兼容汉字、竖排标点、全角 ASCII。
tui_dwidth() {
  local s="$1" w=0 i len b1 b2 b3 b4 cp n
  local LC_ALL=C
  len=${#s}
  i=0
  while (( i < len )); do
    printf -v b1 '%d' "'${s:$i:1}"
    if (( b1 < 0x80 )); then
      cp=$b1; n=1
    elif (( b1 >= 0xC2 && b1 <= 0xDF )); then
      printf -v b2 '%d' "'${s:$((i+1)):1}"
      cp=$(( (b1 & 0x1F) << 6 | (b2 & 0x3F) )); n=2
    elif (( b1 >= 0xE0 && b1 <= 0xEF )); then
      printf -v b2 '%d' "'${s:$((i+1)):1}"
      printf -v b3 '%d' "'${s:$((i+2)):1}"
      cp=$(( (b1 & 0x0F) << 12 | (b2 & 0x3F) << 6 | (b3 & 0x3F) )); n=3
    elif (( b1 >= 0xF0 && b1 <= 0xF4 )); then
      printf -v b2 '%d' "'${s:$((i+1)):1}"
      printf -v b3 '%d' "'${s:$((i+2)):1}"
      printf -v b4 '%d' "'${s:$((i+3)):1}"
      cp=$(( (b1 & 0x07) << 18 | (b2 & 0x3F) << 12 | (b3 & 0x3F) << 6 | (b4 & 0x3F) )); n=4
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

tui_banner() {
  local title="$1" subtitle="${2:-}" inner=$((TUI_WIDTH - 2))
  printf '\n'
  printf '  %s%s%s%s%s\n' "$C_CYAN" "$B_TL" "$(tui_repeat "$B_H" $((inner - 2)))" "$B_TR" "$C_RESET"
  printf '  %s%s%s %s%s%s%s%s\n' "$C_CYAN" "$B_V" "$C_RESET" "$C_BOLD$C_WHITE" \
    "$(tui_pad "$title" $((inner - 4)))" "$C_RESET" "$C_CYAN$B_V" "$C_RESET"
  [[ -n "$subtitle" ]] && printf '  %s%s%s %s%s%s%s%s\n' "$C_CYAN" "$B_V" "$C_RESET" "$C_GRAY" \
    "$(tui_pad "$subtitle" $((inner - 4)))" "$C_RESET" "$C_CYAN$B_V" "$C_RESET"
  printf '  %s%s%s%s%s\n' "$C_CYAN" "$B_BL" "$(tui_repeat "$B_H" $((inner - 2)))" "$B_BR" "$C_RESET"
}

tui_section() {
  local title="$1"
  printf '\n  %s%s%s %s%s%s\n' "$C_ACCENT" "$I_MARK" "$C_RESET" "$C_BOLD" "$title" "$C_RESET"
  printf '  %s%s%s\n' "$C_GRAY" "$(tui_repeat "$B_H" $((TUI_WIDTH - 4)))" "$C_RESET"
}

tui_box() {
  local title="${1:-}"
  printf '\n'
  if [[ -n "$title" ]]; then
    printf '  %s%s %s%s%s %s%s%s\n' "$C_ACCENT" "$B_TL" "$C_BOLD" "$title" "$C_RESET" \
      "$C_ACCENT" "$(tui_repeat "$B_H" $((TUI_WIDTH - 6 - $(tui_dwidth "$title"))))" "$B_TR$C_RESET"
  else
    printf '  %s%s%s%s\n' "$C_ACCENT" "$B_TL" "$(tui_repeat "$B_H" $((TUI_WIDTH - 4)))" "$B_TR$C_RESET"
  fi
}

tui_box_line() {
  local text="$1" color="${2:-$C_WHITE}"
  printf '  %s%s%s %s%s%s\n' "$C_ACCENT" "$B_V" "$C_RESET" "$color" \
    "$(tui_pad "$text" $((TUI_WIDTH - 6)))" "$C_RESET"
}

tui_box_end() {
  printf '  %s%s%s%s\n' "$C_ACCENT" "$B_BL" "$(tui_repeat "$B_H" $((TUI_WIDTH - 4)))" "$B_BR$C_RESET"
}

tui_panel() {
  local title="$1"; shift
  local inner=$((TUI_WIDTH - 4)) entry k v
  printf '\n  %s%s %s%s%s %s%s%s\n' "$C_ACCENT" "$B_TL" "$C_BOLD" "$title" "$C_RESET" \
    "$C_ACCENT" "$(tui_repeat "$B_H" $((inner - 4 - $(tui_dwidth "$title"))))" "$B_TR$C_RESET"
  for entry in "$@"; do
    k="${entry%%|*}"; v="${entry#*|}"
    printf '  %s%s%s %s%s%s %s%s%s\n' "$C_ACCENT" "$B_V" "$C_RESET" "$C_GRAY" \
      "$(tui_pad "$k" 18)" "$C_RESET" "$C_WHITE" "$v" "$C_RESET"
  done
  printf '  %s%s%s%s\n' "$C_ACCENT" "$B_BL" "$(tui_repeat "$B_H" $inner)" "$B_BR$C_RESET"
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
