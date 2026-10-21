#!/usr/bin/env bash
# 单元测试入口：bash test/unit.sh
set -uo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/tui.sh
source "$ROOT/test/lib.sh"
# shellcheck source=lib/tui.sh
source "$ROOT/lib/tui.sh"

test_case "TUI 文本宽度与补白"

assert_eq "5"  "$(tui_dwidth 'abcde')"        "纯 ASCII 宽度 = 字符数"
assert_eq "4"  "$(tui_dwidth '中文')"          "两个中文字符宽度 = 4（各占 2 列）"
assert_eq "6"  "$(tui_dwidth 'ab中文')"        "ASCII 与中文混合宽度 = 6"
assert_eq "0"  "$(tui_dwidth '')"              "空串宽度 = 0"

assert_eq "-----    "  "$(tui_pad '-----' 9)" "补白到指定宽度（4 个空格）"
assert_eq "abc"        "$(tui_pad 'abc' 3)"    "已达宽度则不截断"
assert_eq "-----"      "$(tui_repeat '-' 5)"   "重复字符"

assert_eq "hello" "$(tui_strip $'\033[32mhello\033[0m')" "剥离 ANSI 序列"

test_case "TUI 框线几何"

# 框线必须合得拢：每一个非空行的显示宽度都等于 TUI_WIDTH
assert_box_widths() {
  local label="$1" text="$2" bad=0 line
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    [[ "$(tui_dwidth "$line")" == "$TUI_WIDTH" ]] || bad=1
  done <<<"$text"
  assert_eq "0" "$bad" "$label 每行显示宽度均为 TUI_WIDTH"
}

TUI_WIDTH=80
assert_box_widths "banner" "$(tui_banner '标题' '副标题')"
assert_box_widths "box"    "$(tui_box '框标题'; tui_box_line '内容行'; tui_box_end)"
assert_box_widths "panel"  "$(tui_panel '面板' '键|值' '更长的键|更长的值内容')"

# 带 ANSI 的字符串按纯文本宽度计算（否则对带色文本补白会错位）
assert_eq "4" "$(tui_dwidth $'\033[32m中文\033[0m')" "tui_dwidth 忽略 ANSI 序列"

test_case "TUI Unicode 降级"

# TUI_ASCII=1 时必须降级为 ASCII 制表符
assert_eq "ok" "$( ( export TUI_ASCII=1; tui_init; [[ "$B_H" == '-' && "$B_V" == '|' ]] && echo ok || echo bad ) )" \
  "TUI_ASCII=1 时降级为 ASCII 制表符"
# 显式 TUI_UNICODE=1 时必须保留 Unicode
assert_eq "ok" "$( ( export TUI_UNICODE=1; tui_init; [[ "$B_H" == '─' ]] && echo ok || echo bad ) )" \
  "TUI_UNICODE=1 时保留 Unicode 制表符"

test_summary
