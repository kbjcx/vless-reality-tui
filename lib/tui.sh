#!/usr/bin/env bash
# shellcheck shell=bash
#
# lib/tui.sh — 轻量级 TUI 组件库
#
# 设计目标：
#   * 零外部依赖：只用 bash 内建 + ANSI 转义序列，不强制安装 dialog/whiptail/gum
#   * 非 TTY 环境自动降级为纯文本菜单，可用于 CI / nohup / 日志留存
#   * 中文宽字符对齐：按终端显示宽度而非字节数补白
#
# 提供的组件：
#   tui_init / tui_banner / tui_section / tui_rule / tui_box
#   tui_info / tui_ok / tui_warn / tui_err / tui_tip
#   tui_menu / tui_select / tui_confirm / tui_input / tui_input_secret
#   tui_run / tui_pause / tui_panel / tui_kv / tui_progress
#
# 约定：所有菜单类函数返回 0-based 索引；取消返回 255。

TUI_TTY=0        # 1 = 交互式终端
TUI_COLOR=0      # 1 = 启用颜色
TUI_WIDTH=80     # 可用宽度
TUI_UNICODE=1    # 1 = 使用 Unicode 制表符

# 颜色（在 tui_init 中赋值）
C_RESET=''; C_BOLD=''; C_DIM=''
C_RED=''; C_GREEN=''; C_YELLOW=''; C_BLUE=''; C_CYAN=''; C_MAGENTA=''; C_WHITE=''; C_GRAY=''
C_OK=''; C_ERR=''; C_WARN=''; C_INFO=''; C_ACCENT=''

# 制表符
B_TL='╭'; B_TR='╮'; B_BL='╰'; B_BR='╯'
B_H='─'; B_V='│'; B_L='├'; B_R='┤'
I_MARK='●'; I_ARROW='▸'; I_OK='✔'; I_ERR='✖'; I_WARN='▲'; I_INFO='ℹ'; I_TIP='▷'

# ─────────────────────────────────────────────────────────────
# 初始化
# ─────────────────────────────────────────────────────────────

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
    C_RESET=$'\033[0m';  C_BOLD=$'\033[1m';   C_DIM=$'\033[2m'
    C_RED=$'\033[38;5;203m';    C_GREEN=$'\033[38;5;114m'
    C_YELLOW=$'\033[38;5;179m'; C_BLUE=$'\033[38;5;110m'
    C_CYAN=$'\033[38;5;80m';   C_MAGENTA=$'\033[38;5;176m'
    C_WHITE=$'\033[38;5;253m'; C_GRAY=$'\033[38;5;244m'
    C_OK=$C_GREEN; C_ERR=$C_RED; C_WARN=$C_YELLOW; C_INFO=$C_BLUE; C_ACCENT=$C_CYAN
  fi

  if [[ $TUI_UNICODE -eq 0 ]]; then
    B_TL='+'; B_TR='+'; B_BL='+'; B_BR='+'; B_H='-'; B_V='|'; B_L='+'; B_R='+'
    I_MARK='*'; I_ARROW='>'; I_OK='[OK]'; I_ERR='[X]'; I_WARN='[!]'; I_INFO='[i]'; I_TIP='>'
  fi
}

# ─────────────────────────────────────────────────────────────
# 基础工具
# ─────────────────────────────────────────────────────────────

# 重复字符 n 次
tui_repeat() {
  local ch="$1" n="$2" out='' i
  for ((i = 0; i < n; i++)); do out+="$ch"; done
  printf '%s' "$out"
}

# 计算字符串在终端中的显示宽度（CJK 全角按 2 计）
tui_dwidth() {
  local s="$1" w=0 i ch
  for ((i = 0; i < ${#s}; i++)); do
    ch=${s:$i:1}
    case "$ch" in
      [$'\u1100'-$'\u115F'] | [$'\u2E80'-$'\u303E'] | [$'\u3041'-$'\u33FF'] | \
      [$'\u3400'-$'\u4DBF'] | [$'\u4E00'-$'\u9FFF'] | [$'\uA000'-$'\uA4CF'] | \
      [$'\uAC00'-$'\uD7A3'] | [$'\uF900'-$'\uFAFF'] | [$'\uFE30'-$'\uFE6F'] | \
      [$'\uFF00'-$'\uFF60'] | [$'\uFFE0'-$'\uFFE6'])
        w=$((w + 2)) ;;
      *) w=$((w + 1)) ;;
    esac
  done
  printf '%s' "$w"
}

# 右补白到指定显示宽度
tui_pad() {
  local s="$1" width="$2" d
  d=$(tui_dwidth "$s")
  (( d < width )) && s+=$(tui_repeat ' ' $((width - d)))
  printf '%s' "$s"
}

# 去除 ANSI 序列后的纯文本
tui_strip() {
  printf '%s' "$1" | sed -e 's/\033\[[0-9;]*m//g'
}

# ─────────────────────────────────────────────────────────────
# 标题 / 区块
# ─────────────────────────────────────────────────────────────

tui_banner() {
  local title="$1" subtitle="${2:-}"
  local inner=$((TUI_WIDTH - 2))
  printf '\n'
  printf '  %s%s%s%s%s\n' "$C_CYAN" "$B_TL" "$(tui_repeat "$B_H" $((inner - 2)))" "$B_TR" "$C_RESET"
  printf '  %s%s%s %s%s%s%s%s\n' \
    "$C_CYAN" "$B_V" "$C_RESET" "$C_BOLD$C_WHITE" \
    "$(tui_pad "$title" $((inner - 4)))" "$C_RESET" "$C_CYAN$B_V" "$C_RESET"
  if [[ -n "$subtitle" ]]; then
    printf '  %s%s%s %s%s%s%s%s\n' \
      "$C_CYAN" "$B_V" "$C_RESET" "$C_GRAY" \
      "$(tui_pad "$subtitle" $((inner - 4)))" "$C_RESET" "$C_CYAN$B_V" "$C_RESET"
  fi
  printf '  %s%s%s%s%s\n' "$C_CYAN" "$B_BL" "$(tui_repeat "$B_H" $((inner - 2)))" "$B_BR" "$C_RESET"
}

tui_section() {
  local title="$1"
  printf '\n  %s%s%s %s%s%s\n' "$C_ACCENT" "$I_MARK" "$C_RESET" "$C_BOLD" "$title" "$C_RESET"
  printf '  %s%s%s\n' "$C_GRAY" "$(tui_repeat "$B_H" $((TUI_WIDTH - 4)))" "$C_RESET"
}

tui_rule() {
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

tui_box_end() {
  printf '  %s%s%s%s\n' "$C_ACCENT" "$B_BL" "$(tui_repeat "$B_H" $((TUI_WIDTH - 4)))" "$B_BR$C_RESET"
}

tui_box_line() {
  local text="$1" color="${2:-$C_WHITE}"
  printf '  %s%s%s %s%s%s\n' "$C_ACCENT" "$B_V" "$C_RESET" "$color" \
    "$(tui_pad "$text" $((TUI_WIDTH - 6)))" "$C_RESET"
}

# ─────────────────────────────────────────────────────────────
# 消息
# ─────────────────────────────────────────────────────────────

tui_info() { printf '  %s%s%s %s\n' "$C_INFO" "$I_INFO" "$C_RESET" "$1"; }
tui_ok()   { printf '  %s%s%s %s\n' "$C_OK"   "$I_OK"   "$C_RESET" "$1"; }
tui_warn() { printf '  %s%s%s %s\n' "$C_WARN" "$I_WARN" "$C_RESET" "$1"; }
tui_err()  { printf '  %s%s%s %s\n' "$C_ERR"  "$I_ERR"  "$C_RESET" "$1"; }
tui_tip()  { printf '  %s%s%s %s\n' "$C_GRAY" "$I_TIP"  "$C_RESET" "$1"; }

tui_step() {
  printf '  %s%s%s %s\n' "$C_ACCENT" "$I_ARROW" "$C_RESET" "$1"
}

# 带标签的一行：tui_kv "服务器 IP" "1.2.3.4"
tui_kv() {
  local k="$1" v="$2" kw=$((TUI_WIDTH - 26))
  (( kw < 14 )) && kw=14
  printf '  %s%s%s %s\n' "$C_GRAY" "$(tui_pad "$k" $kw)" "$C_RESET" "$v"
}

# ─────────────────────────────────────────────────────────────
# 进度：带 spinner 的命令执行
# ─────────────────────────────────────────────────────────────

# tui_run "描述" cmd args...
# 成功返回 0，失败返回命令自身的退出码，并把输出打印出来。
tui_run() {
  local msg="$1"; shift
  local tmp rc=0

  if [[ $TUI_TTY -eq 0 ]]; then
    printf '  %s%s%s %s ... ' "$C_ACCENT" "$I_ARROW" "$C_RESET" "$msg"
    if "$@" >/dev/null 2>&1; then
      printf '%s%s%s\n' "$C_OK" "$I_OK" "$C_RESET"
      return 0
    fi
    printf '%s%s%s\n' "$C_ERR" "$I_ERR" "$C_RESET"
    return 1
  fi

  tmp=$(mktemp 2>/dev/null || printf '/tmp/.tui.%s' "$$")
  "$@" >"$tmp" 2>&1 &
  local pid=$!
  local frames='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏' i=0
  while kill -0 "$pid" 2>/dev/null; do
    printf '\r  %s%s%s %s%s%s' "$C_ACCENT" "${frames:$((i % 10)):1}" "$C_RESET" "$C_GRAY" "$msg" "$C_RESET"
    i=$((i + 1))
    sleep 0.08
  done
  wait "$pid" || rc=$?

  if [[ $rc -eq 0 ]]; then
    printf '\r  %s%s%s %s%s%s%s\n' "$C_OK" "$I_OK" "$C_RESET" "$C_GRAY" "$msg" "$C_RESET"
  else
    printf '\r  %s%s%s %s%s%s%s\n' "$C_ERR" "$I_ERR" "$C_RESET" "$C_GRAY" "$msg" "$C_RESET"
    [[ -s "$tmp" ]] && sed -e 's/^/      /' "$tmp"
  fi
  rm -f "$tmp" 2>/dev/null || true
  return $rc
}

# ─────────────────────────────────────────────────────────────
# 输入
# ─────────────────────────────────────────────────────────────

tui_confirm() {
  local prompt="$1" default="${2:-y}" ans hint
  if [[ $default == "y" || $default == "Y" ]]; then hint="Y/n"; else hint="y/N"; fi

  if [[ $TUI_TTY -eq 0 ]]; then
    printf '  %s%s%s %s [%s]: ' "$C_ACCENT" "$I_ARROW" "$C_RESET" "$prompt" "$hint"
    IFS= read -r ans || ans=''
    [[ -z "$ans" ]] && ans="$default"
    [[ "${ans,,}" == y* ]]
    return
  fi

  printf '  %s%s%s %s %s[%s]%s ' "$C_ACCENT" "$I_ARROW" "$C_RESET" "$prompt" "$C_GRAY" "$hint" "$C_RESET"
  IFS= read -rsn1 ans || ans=''
  printf '\n'
  [[ -z "$ans" ]] && ans="$default"
  [[ "${ans,,}" == y* ]]
}

tui_input() {
  local prompt="$1" def="${2:-}" hint="${3:-}" ans
  if [[ $TUI_TTY -eq 0 ]]; then
    if [[ -n "$hint" ]]; then
      printf '  %s%s%s %s (%s): ' "$C_ACCENT" "$I_ARROW" "$C_RESET" "$prompt" "$hint"
    else
      printf '  %s%s%s %s: ' "$C_ACCENT" "$I_ARROW" "$C_RESET" "$prompt"
    fi
    IFS= read -r ans || ans=''
    [[ -z "$ans" ]] && ans="$def"
    printf '%s' "$ans"
    return
  fi
  if [[ -n "$hint" ]]; then
    printf '  %s%s%s %s %s(%s)%s ' "$C_ACCENT" "$I_ARROW" "$C_RESET" "$prompt" "$C_GRAY" "$hint" "$C_RESET"
  else
    printf '  %s%s%s %s ' "$C_ACCENT" "$I_ARROW" "$C_RESET" "$prompt"
  fi
  IFS= read -r ans || ans=''
  [[ -z "$ans" ]] && ans="$def"
  printf '%s' "$ans"
}

tui_input_secret() {
  local prompt="$1" def="${2:-}" ans
  if [[ $TUI_TTY -eq 0 ]]; then
    printf '  %s%s%s %s: ' "$C_ACCENT" "$I_ARROW" "$C_RESET" "$prompt"
    IFS= read -r ans || ans=''
    [[ -z "$ans" ]] && ans="$def"
    printf '%s' "$ans"
    return
  fi
  printf '  %s%s%s %s ' "$C_ACCENT" "$I_ARROW" "$C_RESET" "$prompt"
  IFS= read -rs ans || ans=''
  printf '\n'
  [[ -z "$ans" ]] && ans="$def"
  printf '%s' "$ans"
}

# ─────────────────────────────────────────────────────────────
# 菜单
# ─────────────────────────────────────────────────────────────

# tui_menu "标题" "选项1" "选项2" ...
# 返回选中项的 0-based 索引；用户取消返回 255。
tui_menu() {
  local title="$1"; shift
  local -a items=("$@")
  local n=${#items[@]}
  local idx=${TUI_MENU_DEFAULT_INDEX:-0} buf=''

  (( n == 0 )) && return 255
  (( idx < 0 || idx >= n )) && idx=0

  if [[ $TUI_TTY -eq 0 ]]; then
    # 非交互环境：打印列表并要求输入序号
    local i
    tui_section "$title"
    for ((i = 0; i < n; i++)); do
      printf '     %s%2d%s) %s\n' "$C_GRAY" "$((i + 1))" "$C_RESET" "${items[$i]}"
    done
    local sel=''
    printf '  %s请输入序号 [1-%d]: %s' "$C_ACCENT" "$n" "$C_RESET"
    IFS= read -r sel || sel=''
    [[ -z "$sel" ]] && return 255
    [[ "$sel" =~ ^[0-9]+$ ]] || return 255
    (( sel >= 1 && sel <= n )) || return 255
    printf '%s\n' "${items[$((sel - 1))]}"
    return $((sel - 1))
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
      printf '     %s编号: %s_%s  %s↑↓ 移动 · Enter 确认 · q 取消%s\n' \
        "$C_GRAY" "$C_ACCENT$C_BOLD" "$buf" "$C_RESET" "$C_GRAY" "$C_RESET"
    else
      printf '     %s↑↓ 移动 · 数字直选 · Enter 确认 · q 取消%s\n' "$C_GRAY" "$C_RESET"
    fi

    key=''
    IFS= read -rsn1 key || key=$'\n'

    if [[ $key == $'\e' ]]; then
      seq=''
      IFS= read -rsn3 -t 0.2 seq || true
      case "$seq" in
        '[A') idx=$(( (idx - 1 + n) % n )); buf='' ;;
        '[B') idx=$(( (idx + 1) % n )); buf='' ;;
      esac
    elif [[ $key == $'\n' || $key == $'\r' ]]; then
      if [[ -n "$buf" ]]; then
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
      # 已经是有效编号且后面不再接数字，直接选中
      if (( 10#$buf >= 1 && 10#$buf <= n )); then
        local more=''
        IFS= read -rsn1 -t 0.35 more || more=''
        if [[ -z "$more" ]]; then
          local d=$((10#$buf - 1))
          printf '\033[%dA\033[J' "$((n + 1))"
          printf '   %s%s%s %s\n' "$C_OK" "$I_OK" "$C_RESET" "${items[$d]}"
          return $d
        fi
        buf+="$more"
      fi
    fi

    printf '\033[%dA\033[J' "$((n + 1))"
  done
}

# tui_select "标题" "默认项文本" "选项1" "选项2" ...
# 返回选中项的 0-based 索引；取消返回 255。
tui_select() {
  local title="$1" def="$2"; shift 2
  local -a items=("$@")
  local i d=0
  for ((i = 0; i < ${#items[@]}; i++)); do
    if [[ "${items[$i]}" == "$def" ]]; then d=$i; break; fi
  done
  TUI_MENU_DEFAULT_INDEX=$d
  tui_menu "$title" "${items[@]}"
  local r=$?
  TUI_MENU_DEFAULT_INDEX=0
  return $r
}

tui_pause() {
  [[ $TUI_TTY -eq 1 ]] || return 0
  printf '\n  %s按 Enter 键继续...%s' "$C_GRAY" "$C_RESET"
  IFS= read -r _ || true
  printf '\n'
}

# ─────────────────────────────────────────────────────────────
# 结果面板
# ─────────────────────────────────────────────────────────────

# tui_panel "标题" "键1|值1" "键2|值2" ...
tui_panel() {
  local title="$1"; shift
  local inner=$((TUI_WIDTH - 4))
  printf '\n  %s%s %s%s%s %s%s%s\n' "$C_ACCENT" "$B_TL" "$C_BOLD" "$title" "$C_RESET" \
    "$C_ACCENT" "$(tui_repeat "$B_H" $((inner - 4 - $(tui_dwidth "$title"))))" "$B_TR$C_RESET"
  local entry k v
  for entry in "$@"; do
    k="${entry%%|*}"
    v="${entry#*|}"
    printf '  %s%s%s %s%s%s %s%s%s\n' "$C_ACCENT" "$B_V" "$C_RESET" "$C_GRAY" \
      "$(tui_pad "$k" 18)" "$C_RESET" "$C_WHITE" "$v" "$C_RESET"
  done
  printf '  %s%s%s%s\n' "$C_ACCENT" "$B_BL" "$(tui_repeat "$B_H" $inner)" "$B_BR$C_RESET"
}
