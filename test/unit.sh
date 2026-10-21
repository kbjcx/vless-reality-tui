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
# 提示语走 stderr（stdout 只承载判定结果），这里静音以保持测试输出干净
out=$(printf '\n' | bash "$ROOT/test/helpers/confirm.sh" y 2>/dev/null)
assert_contains "$out" "yes" "tui_confirm 默认值 y → yes"

out=$(printf '\n' | bash "$ROOT/test/helpers/confirm.sh" n 2>/dev/null)
assert_contains "$out" "no" "tui_confirm 默认值 n → no"

# M4：tui_confirm 的提示语必须走 stderr，stdout 只承载判定结果
err=$(printf '\n' | bash "$ROOT/test/helpers/confirm.sh" y 2>&1 >/dev/null)
assert_contains "$err" "确认继续" "tui_confirm 提示语走 stderr"
out=$(printf '\n' | bash "$ROOT/test/helpers/confirm.sh" y 2>/dev/null)
assert_eq "yes" "$out" "tui_confirm 的 stdout 只有判定结果"

# stdout 的【字节数】必须精确：非 TTY 分支恰好是 "yes\n"（4 字节）——
# 多出的提示或收尾空行都会让字节数变大（命令替换会吃掉尾部换行，查不出空行）
n=$(printf '\n' | bash "$ROOT/test/helpers/confirm.sh" y 2>/dev/null | wc -c)
assert_eq "4" "$n" "tui_confirm 非 TTY 分支 stdout 恰好 4 字节（无提示、无多余空行）"

# TTY 分支：提示与收尾换行都必须走 stderr，stdout 必须【一个字节都没有】
n=$(printf 'y' | bash -c 'source "$1/lib/tui.sh"; tui_init; TUI_TTY=1; tui_confirm "确认继续" y' _ "$ROOT" 2>/dev/null | wc -c)
assert_eq "0" "$n" "tui_confirm 的 TTY 分支 stdout 为 0 字节（提示与换行都走 stderr）"
printf 'y' | bash -c 'source "$1/lib/tui.sh"; tui_init; TUI_TTY=1; tui_confirm "确认继续" y' _ "$ROOT" >/dev/null 2>&1; rc=$?
assert_status 0 "$rc" "tui_confirm 的 TTY 分支仍返回 0=是"

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
out=$(printf 'n\n' | bash "$ROOT/test/helpers/confirm.sh" y 2>/dev/null)
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

test_case "TUI 菜单交互路径（强制 TUI_TTY=1，管道喂按键模拟真终端）"

# 数字缓冲区被非数字污染 → 必须取消，绝不能静默选中第一项
out=$(printf '1q' | bash "$ROOT/test/helpers/menu_tty.sh" "选择" "A" "B" "C"); rc=$?
assert_status 255 "$rc" "数字后按 q 必须取消(255)，不得静默选中第一项"
assert_contains "$out" "已取消" "数字后按 q 显示取消"

# EOF / Ctrl-D → 必须取消，不得当成回车去确认高亮项
printf '' | bash "$ROOT/test/helpers/menu_tty.sh" "选择" "A" "B" "C" >/dev/null 2>&1; rc=$?
assert_status 255 "$rc" "EOF 必须取消(255)"

# 缓冲区提示行只能打印一次（printf 格式串 %s 个数必须等于实参个数）
# 输入必须是【两位数 + 回车】：单个数字会在 0.35s 窗口后立即选中，
# 根本不会渲染缓冲区提示行（计数恒为 0，无法发现「打印两遍」这个 bug）；
# 两位数才会进入缓冲区并重绘一次提示行——旧代码这里会打印 2 遍。
out=$(printf '10\n' | bash "$ROOT/test/helpers/menu_tty.sh" "选择" "A" "B" "C")
assert_eq "1" "$(printf '%s\n' "$out" | grep -c '编号')" "缓冲区提示行只打印一次"

# I3 的复发点：格式串的 %s 个数必须与实参个数【严格相等】。
# 运行时区分不了两种错法——实参少于占位符时 bash 补空串（看不出异常），
# 实参多于占位符时 bash 复用格式串（打印两遍）——所以这里做静态校验。
fmt=$(grep -o "printf '[^']*编号[^']*'" "$ROOT/lib/tui.sh" | head -1)
nspec=$(printf '%s' "$fmt" | grep -o '%s' | wc -l)
nargs=$(grep -A1 "printf '.*编号" "$ROOT/lib/tui.sh" | tail -1 | grep -o '"\$[A-Za-z_]' | wc -l)
# 封口：grep 匹配不到时 nspec/nargs 会同时变成 0，assert_eq 0 0 就是恒真通过。
# 所以必须先确认「确实匹配到了格式串」，匹配不到就算这条断言失败。
if (( nspec >= 1 )); then
  assert_eq "$nspec" "$nargs" "缓冲区提示行格式串 %s 个数（$nspec）与实参个数（$nargs）严格相等"
else
  assert_eq "至少 1 个 %s 占位符" "0（未在 lib/tui.sh 中匹配到缓冲区提示行格式串）" \
    "缓冲区提示行格式串 %s 个数（$nspec）与实参个数（$nargs）严格相等"
fi

# 方向键下移后回车 → 选中第 2 项（索引 1）
out=$( { printf '\033[B'; sleep 0.3; printf '\n'; } | bash "$ROOT/test/helpers/menu_tty.sh" "选择" "A" "B" "C" ); rc=$?
assert_status 1 "$rc" "方向键下移后回车选中第 2 项(索引 1)"

# 方向键与回车【一次性写入】：方向键只剩 2 字节，-n2 正好读完，
# 紧跟的回车不能被当成方向键序列的第 3 字节吞掉（-n3 会吞掉）
out=$(printf '\033[B\n' | bash "$ROOT/test/helpers/menu_tty.sh" "选择" "A" "B" "C"); rc=$?
assert_status 1 "$rc" "方向键后紧跟的回车不被方向键序列吞掉"

# 方向键之后的【数字键】必须被正常处理，不能被方向键序列一起吃掉。
# 这是 -n2 与 -n3 唯一可观测的差异：-n3 会把第 3 个字节（这里是 "2"）并进
# seq → 方向键不生效、且 "2" 丢失 → 选中第 1 项(索引 0)；-n2 下 "2" 被当作
# 数字直选 → 选中第 2 项(索引 1)。
out=$(printf '\033[B2\n' | bash "$ROOT/test/helpers/menu_tty.sh" "选择" "A" "B" "C"); rc=$?
assert_status 1 "$rc" "方向键之后的数字键不被方向键序列吞掉"

# 多位数：>=10 项时输入 10 并回车应选中第 10 项（索引 9）
# 必须带回车：EOF 现在按 I2 判定为「取消」(255)，不是「确认」
out=$(printf '10\n' | bash "$ROOT/test/helpers/menu_tty.sh" "选择" 1 2 3 4 5 6 7 8 9 10 11); rc=$?
assert_status 9 "$rc" "多位数 10 选中第 10 项(索引 9)"

# 直接按 q → 取消
printf 'q' | bash "$ROOT/test/helpers/menu_tty.sh" "选择" "A" "B" "C" >/dev/null 2>&1; rc=$?
assert_status 255 "$rc" "直接按 q 返回 255"

test_case "TUI tui_run 降级路径（临时文件不可用）"

# 制造「临时文件不可用」：让 mktemp 返回一个【目录】路径，重定向必然失败。
# 用 mktemp -d 建一个唯一目录来制造这个场景，不依赖 /tmp/.tui.$$ 这类
# 全局路径状态（上一轮遗留同名文件时，用例前提会静默失效）。
d=$(mktemp -d 2>/dev/null)
# 前提守卫：mktemp -d 失败时 $d 为空。此时若继续往下走，
# mkdir -p "$d/blocked" 会退化成在【根目录】建 /blocked（污染系统），
# 而且重定向报错文本不在匹配名单内 → 泄漏断言退化成真空通过。
# 所以必须让用例【明确失败】，且绝不去动根目录。
if [[ -n "$d" && -d "$d" ]]; then
  mkdir -p "$d/blocked"
  out=$(mktemp() { printf '%s' "$d/blocked"; }; tui_run "回落不可用" bash -c 'echo ran-ok; exit 7' 2>&1); rc=$?
  assert_status 7 "$rc" "回落路径不可写时命令仍被执行并透传退出码"

  # 探测失败不得把 shell 诊断泄漏到 stderr：失败的重定向先于 2>/dev/null 生效，
  # 必须用 { : >"$tmp"; } 2>/dev/null 把整条重定向包起来
  err=$(mktemp() { printf '%s' "$d/blocked"; }; tui_run "回落不可用" bash -c 'true' 2>&1 >/dev/null)
  case "$err" in
    *"is a directory"*|*"Is a directory"*|*"cannot create"*|*"Permission denied"*) leaked=1 ;;
    *) leaked=0 ;;
  esac
  assert_eq "0" "$leaked" "临时文件探测失败时不泄漏 shell 诊断到 stderr"
  rm -rf "$d"
else
  assert_eq "mktemp -d 能创建唯一临时目录" "失败（mktemp -d 返回空路径）" \
    "tui_run 降级用例前提：mktemp -d 必须能创建唯一临时目录，否则场景无法构造"
fi

# mktemp 真失败时：命令仍被执行，且输出仍能被捕获
rm -f "/tmp/.tui.$$" 2>/dev/null
out=$(mktemp() { return 1; }; tui_run "回落可用" bash -c 'echo captured-ok; exit 3' 2>&1); rc=$?
rm -f "/tmp/.tui.$$" 2>/dev/null
assert_status 3 "$rc" "mktemp 失败时命令仍被执行并透传退出码"
assert_contains "$out" "captured-ok" "mktemp 失败时仍能捕获命令输出"

test_summary
