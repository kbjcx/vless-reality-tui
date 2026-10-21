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

test_case "TUI 交互组件（非 TTY 降级路径）"

# 非 TTY 下 tui_menu 必须打印带序号的完整列表并读入序号，不得挂死
out=$(printf '2\n' | bash "$ROOT/test/helpers/menu_noninteractive.sh"); rc=$?
assert_contains "$out" "3)" "非 TTY 菜单打印完整编号列表"
assert_status 1 "$rc" "非 TTY 菜单返回选中项索引（0-based）"

# 取消（EOF）必须返回 255
printf '' | bash "$ROOT/test/helpers/menu_noninteractive.sh" >/dev/null 2>&1; rc=$?
assert_status 255 "$rc" "非 TTY 菜单遇 EOF 返回 255"

# 确认：默认应为「是」
out=$(printf '\n' | bash "$ROOT/test/helpers/confirm.sh" y)
assert_contains "$out" "yes" "tui_confirm 默认值 y → yes"

out=$(printf '\n' | bash "$ROOT/test/helpers/confirm.sh" n)
assert_contains "$out" "no" "tui_confirm 默认值 n → no"

# 输入：空输入回落到默认值
# 提示语走 stderr（stdout 只承载用户输入的值），这里静音以保持测试输出干净
out=$(printf '\n' | bash "$ROOT/test/helpers/input.sh" "默认端口" "443" 2>/dev/null)
assert_eq "443" "$out" "tui_input 空输入返回默认值"

# —— 契约补充（同样只走非 TTY 路径）——

# 输入：非空输入应原样返回，且提示语不得污染 stdout（stdout 只承载用户输入）
out=$(printf '8080\n' | bash "$ROOT/test/helpers/input.sh" "默认端口" "443" 2>/dev/null)
assert_eq "8080" "$out" "tui_input 返回用户输入且提示不混入 stdout"

# 输入：末行没有换行符时也必须保住内容（read 返回 1，但变量里已有有效值）
out=$(printf '8080' | bash "$ROOT/test/helpers/input.sh" "默认端口" "443" 2>/dev/null)
assert_eq "8080" "$out" "tui_input 末行无换行符时不丢输入"

# 确认：显式回答必须覆盖默认值
out=$(printf 'n\n' | bash "$ROOT/test/helpers/confirm.sh" y)
assert_contains "$out" "no" "tui_confirm 显式回答 n 覆盖默认值 y"

# 菜单：前导零序号必须按十进制解析，且不得触发 bash 的八进制算术报错
out=$(printf '02\n' | bash "$ROOT/test/helpers/menu_noninteractive.sh" 2>&1); rc=$?
assert_status 1 "$rc" "非 TTY 菜单接受前导零序号"
assert_contains "$out" "选项二" "非 TTY 菜单前导零序号选中正确项"
case "$out" in
  *"value too great for base"*) oct_err=1 ;;
  *) oct_err=0 ;;
esac
assert_eq "0" "$oct_err" "前导零序号不触发八进制算术错误"

# tui_run 必须原样返回被调命令的退出码（非 TTY 下不显示 spinner）
tui_run "退出码透传" bash -c 'exit 3' >/dev/null 2>&1; rc=$?
assert_status 3 "$rc" "tui_run 原样返回命令退出码"
tui_run "执行成功" true >/dev/null 2>&1; rc=$?
assert_status 0 "$rc" "tui_run 成功时返回 0"

# tui_run 失败时必须打印捕获到的输出（否则「依赖没装上」会退化成静默故障）
out=$(tui_run "故意失败" bash -c 'echo boom; exit 1' 2>&1); rc=$?
assert_status 1 "$rc" "tui_run 失败时返回非 0"
assert_contains "$out" "boom" "tui_run 失败时打印捕获到的命令输出"

# tui_select 走的是 tui_menu，索引语义必须一致
printf '2\n' | tui_select "选择" "甲" "甲" "乙" >/dev/null 2>&1; rc=$?
assert_status 1 "$rc" "tui_select 返回 0-based 索引"

# 空菜单必须返回 255，而不是挂死
tui_menu "空菜单" >/dev/null 2>&1; rc=$?
assert_status 255 "$rc" "tui_menu 无项目返回 255"

# tui_pause 在非 TTY 下必须立即返回，不得阻塞
tui_pause </dev/null >/dev/null 2>&1; rc=$?
assert_status 0 "$rc" "tui_pause 非 TTY 立即返回"

test_summary
