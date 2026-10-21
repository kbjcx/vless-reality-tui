#!/usr/bin/env bash
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
    "$(tui_pad "$title" $cw)" "$C_RESET" "$C_CYAN$B_V" "$C_RESET"
  if [[ -n "$subtitle" ]]; then
    printf '  %s%s%s %s%s%s %s%s%s\n' "$C_CYAN" "$B_V" "$C_RESET" "$C_GRAY" \
      "$(tui_pad "$subtitle" $cw)" "$C_RESET" "$C_CYAN$B_V" "$C_RESET"
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
    "$(tui_pad "$text" $cw)" "$C_RESET" "$C_ACCENT$B_V" "$C_RESET"
}

tui_box_end() {
  local rw
  rw=$(tui_border_len $((TUI_WIDTH - 4)))
  printf '  %s%s%s%s\n' "$C_ACCENT" "$B_BL" "$(tui_repeat "$B_H" $rw)" "$B_BR$C_RESET"
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
