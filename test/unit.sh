#!/usr/bin/env bash
# 单元测试入口：bash test/unit.sh
set -uo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/tui.sh
source "$ROOT/test/lib.sh"
# shellcheck source=lib/tui.sh
source "$ROOT/lib/tui.sh"
# shellcheck source=lib/core.sh
source "$ROOT/lib/core.sh"
# shellcheck source=lib/deploy.sh
source "$ROOT/lib/deploy.sh"
# shellcheck source=lib/client.sh
source "$ROOT/lib/client.sh"

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

test_case "core 纯函数"

# ── have_cmd ────────────────────────────────────────────────
assert_succeeds "have_cmd 对已存在的命令返回 0" have_cmd cat
assert_fails    "have_cmd 对不存在的命令返回非 0" have_cmd no_such_cmd_zzz_123

# ── trim ───────────────────────────────────────────────────
assert_eq "hello world" "$(trim '  hello world  ')" "trim 去除首尾空白"
assert_eq "hello" "$(trim $'\t hello \n')" "trim 去除制表符与换行"
assert_eq "" "$(trim '   ')" "trim 全空白串 → 空串"
assert_eq "a b" "$(trim '  a b  ')" "trim 只动首尾，不动内部空格"

# ── urlencode ──────────────────────────────────────────────
assert_eq "a%20b" "$(urlencode 'a b')" "urlencode 编码空格"
assert_eq "%E4%B8%AD%E6%96%87" "$(urlencode '中文')" "urlencode 编码中文（必须按字节）"
assert_eq "abc-123" "$(urlencode 'abc-123')" "urlencode 保留安全字符（连字符不编码）"
assert_eq "abc123" "$(urlencode 'abc123')" "urlencode 保留字母与数字"
assert_eq "a%27b" "$(urlencode "a'b")" "urlencode 编码单引号"
assert_eq "a%5Cb" "$(urlencode 'a\b')" "urlencode 编码反斜杠"

# python3 可用时必须优先走 python3 分支：用假 python3 探针验证【分支选择】
# （本机 python3 是 Windows Store 占位符，恒失败，因此必须靠探针才能验证这条）
out=$( python3() { printf 'FAKE-PY'; }; urlencode 'a b' )
assert_eq "FAKE-PY" "$out" "urlencode 在 python3 可用时优先走 python3 分支"

# 无 python3 时必须回退到纯 bash 实现，且结果与 python3 一致
out=$( have_cmd() { return 1; }; urlencode 'a b' )
assert_eq "a%20b" "$out" "urlencode 回退实现把空格编码为 %20"
out=$( have_cmd() { return 1; }; urlencode '中文' )
assert_eq "%E4%B8%AD%E6%96%87" "$out" "urlencode 回退实现按字节编码中文"
out=$( have_cmd() { return 1; }; urlencode "a'b" )
assert_eq "a%27b" "$out" "urlencode 回退实现把单引号编码为 %27"
out=$( have_cmd() { return 1; }; urlencode 'a\b' )
assert_eq "a%5Cb" "$out" "urlencode 回退实现把反斜杠编码为 %5C"

# ── random_hex ─────────────────────────────────────────────
assert_match_hex() {
  local v="$1"
  if [[ "$v" =~ ^[0-9a-f]+$ ]]; then assert_eq 0 0 "random_hex 输出为小写十六进制"; else assert_eq 0 1 "random_hex 输出为小写十六进制"; fi
}
assert_eq "16" "$(printf '%s' "$(random_hex 8)" | wc -c | tr -d ' ')" "random_hex 8 字节 = 16 个十六进制字符"
assert_eq "8" "$(printf '%s' "$(random_hex 4)" | wc -c | tr -d ' ')" "random_hex 4 字节 = 8 个十六进制字符"
assert_match_hex "$(random_hex 4)"
# 无 openssl 时回退到 od
out=$( have_cmd() { return 1; }; random_hex 8 )
assert_eq "16" "$(printf '%s' "$out" | wc -c | tr -d ' ')" "random_hex 回退实现长度正确"
assert_match_hex "$out"

# ── read_file ──────────────────────────────────────────────
# 前提守卫：mktemp 失败时路径为空，cat >"" 会写到【当前目录】（污染仓库），
# 所以必须让用例明确失败，绝不继续往下走。
# 注意：守卫块内的用例行【保持原样不缩进】——缩进会改动既有行，
# 导致 git diff 出现删除行（验收标准要求 test/unit.sh 的删除行数为 0）。
rf=$(mktemp)
if [[ -n "$rf" && -f "$rf" ]]; then
printf '  hello world  \n' >"$rf"
assert_eq "hello world" "$(read_file "$rf")" "read_file 读取并 trim 内容"
printf 'no-newline-at-eof' >"$rf"
assert_eq "no-newline-at-eof" "$(read_file "$rf")" "read_file 兼容无尾换行"
rm -f "$rf"
else
  assert_eq "mktemp 能创建临时文件" "失败（mktemp 返回空路径）" \
    "read_file 用例前提：mktemp 必须能创建临时文件"
fi
assert_fails "read_file 对不存在的文件返回非 0" read_file "$rf"

# ── detect_os ─────────────────────────────────────────────
# 必须能解析传入的 os-release 路径（默认 /etc/os-release 只是取值来源）
fake_os=$(mktemp)
if [[ -n "$fake_os" && -f "$fake_os" ]]; then
cat >"$fake_os" <<'EOF'
ID=debian
VERSION_ID="12"
EOF
os_out=$(detect_os "$fake_os")
assert_contains "$os_out" "debian|12|" "detect_os 解析 id|version|arch"
assert_eq "3" "$(printf '%s' "$os_out" | awk -F'|' '{print NF}')" "detect_os 输出恰好三段"
else
  assert_eq "mktemp 能创建临时文件" "失败（mktemp 返回空路径）" \
    "detect_os 用例前提：mktemp 必须能创建临时文件"
fi
fake_os2=$(mktemp)
if [[ -n "$fake_os2" && -f "$fake_os2" ]]; then
printf 'NAME="Nothing"\n' >"$fake_os2"
os_out2=$(detect_os "$fake_os2")
# cut -f1,2 只输出被选中的字段（两个空字段之间只隔【一个】分隔符），
# 所以这里按字段分别断言，失败时能直接看出是 ID 还是 VERSION_ID 没留空
assert_eq "" "$(printf '%s' "$os_out2" | cut -d'|' -f1)" "detect_os 缺少 ID 时 id 字段留空"
assert_eq "" "$(printf '%s' "$os_out2" | cut -d'|' -f2)" "detect_os 缺少 VERSION_ID 时 version 字段留空"
else
  assert_eq "mktemp 能创建临时文件" "失败（mktemp 返回空路径）" \
    "detect_os 空字段用例前提：mktemp 必须能创建临时文件"
fi
rm -f "$fake_os" "$fake_os2"

# ── assert_debian ─────────────────────────────────────────
# 用覆盖 detect_os 的方式做【确定性】断言，不依赖开发机真实系统
out=$( ( detect_os() { printf 'centos|7|amd64'; }; assert_debian ) 2>&1 ); rc=$?
assert_status 1 "$rc" "assert_debian 对非 Debian 系返回非 0"
assert_contains "$out" "Debian" "assert_debian 对非 Debian 系给出提示"
out=$( ( detect_os() { printf 'debian|12|amd64'; }; assert_debian ) 2>&1 ); rc=$?
assert_status 0 "$rc" "assert_debian 对 Debian 系返回 0"
assert_contains "$out" "debian" "assert_debian 对 Debian 系输出检测结果"

test_case "core SNI 主机名校验"

# validate_hostname：SNI 会原样进入服务端/客户端 config.json 与分享链接，
# 必须是纯 DNS 主机名，不允许引号、反斜杠、空白等会破坏 JSON 的字符。
assert_succeeds "合法主机名 www.microsoft.com"  validate_hostname "www.microsoft.com"
assert_succeeds "合法主机名 a-b.example.com"   validate_hostname "a-b.example.com"
assert_fails    "空串不是合法主机名"            validate_hostname ""
assert_fails    "无点号的单标签主机名不合法"     validate_hostname "localhost"
assert_fails    "含双引号（会破坏 JSON）"        validate_hostname 'a"b.com'
assert_fails    "含反斜杠（会破坏 JSON）"        validate_hostname 'a\b.com'
assert_fails    "含空格"                        validate_hostname "a b.com"
assert_fails    "含反斜杠命令替换"              validate_hostname 'a$(id).com'
assert_fails    "标签以连字符开头"               validate_hostname "-a.com"
assert_fails    "标签以连字符结尾"               validate_hostname "a-.com"
assert_fails    "尾点形式（SNI 不带尾点）"        validate_hostname "com."

# 追加的失败路径（每条都能单独把实现写错时的绿灯打红）
assert_fails    "空标签（连续两个点）"            validate_hostname "a..b.com"
assert_fails    "前导点"                        validate_hostname ".example.com"
assert_fails    "含下划线（主机名标签不允许）"     validate_hostname "a_b.com"
assert_succeeds "数字与全大写标签合法"            validate_hostname "Example-123.COM"

# 长度边界：标签 ≤63、总长 ≤253
l63="$(printf 'a%.0s' $(seq 1 63))"
l61="$(printf 'b%.0s' $(seq 1 61))"
assert_fails    "标签超长（64 字符）"            validate_hostname "${l63}a.com"
assert_succeeds "标签恰好 63 字符合法"           validate_hostname "${l63}.com"
assert_succeeds "总长恰好 253 字符合法"          validate_hostname "$l63.$l63.$l63.$l61"
assert_fails    "总长 259 字符超限"             validate_hostname "$l63.$l63.$l63.$l63.com"

test_case "core 状态持久化"

# state_quote：状态文件会被 load_state 用 `.`（source）引入执行，
# 写入的值必须是可被 shell 安全求值的单引号字面量。
assert_eq "'443'"     "$(state_quote 443)"      "state_quote 产出单引号字面量"
assert_eq "''"       "$(state_quote '')"        "state_quote 空值产出空字面量"
assert_eq "'a'\''b'" "$(state_quote "a'b")"     "state_quote 转义内部单引号"
assert_eq "'\$(id)'" "$(state_quote '$(id)')"   "state_quote 不让命令替换在字面量内生效"

# state_quote 的产物必须能被 shell 安全求值：求值后逐字节等于原值
sq_v=$'a b\'c$(id)`id`'
sq_q="$(state_quote "$sq_v")"
sq_back="$(eval "printf '%s' $sq_q")"
assert_eq "$sq_v" "$sq_back" "state_quote 产物 eval 后逐字节还原"

# save_state / load_state 往返：REMARK 来自用户输入（--name），
# 写入后再读回必须逐字节一致，且其中的 $(...) 不得在读取时被执行。
# 前提守卫：mktemp -d 失败时路径为空，后续 "$t_dir/deploy.env" 会退化成往
# 【当前目录】写文件（污染仓库），所以必须让用例明确失败。
t_dir=$(mktemp -d)
if [[ -n "$t_dir" && -d "$t_dir" ]]; then
t_state="$t_dir/deploy.env"
( STATE_DIR="$t_dir"; STATE_FILE="$t_state"; PORT=8443
  REMARK='$(touch '"$t_dir"'/pwned)'; SNI="a'b"
  save_state >/dev/null 2>&1 )
back=$( ( STATE_FILE="$t_state"; REMARK=''; load_state >/dev/null 2>&1; printf '%s' "$REMARK" ) )
assert_eq '$(touch '"$t_dir"'/pwned)' "$back" "load_state 读回的 REMARK 逐字节一致"
assert_contains "$(cat "$t_state")" "REMARK='" "状态文件以单引号字面量保存 REMARK"
if [[ -e "$t_dir/pwned" ]]; then rc=0; else rc=1; fi
assert_false "$rc" "load_state 不得执行状态文件中的命令替换"

# 全字段往返：每个字段都必须逐字节一致（含单引号与换行）
( STATE_DIR="$t_dir"; STATE_FILE="$t_state"
  MODE='native'; PORT=8443; UUID='u-1234'; SNI="a'b"; TARGET='www.microsoft.com'
  PRIVATE_KEY='pk-abc'; PUBLIC_KEY='pub-xyz'; SHORT_ID='0123456789abcdef'
  SERVER_IP='203.0.113.7'; REMARK=$'line1\nline2'; FLOW='xtls-rprx-vision'; FINGERPRINT='chrome'
  save_state >/dev/null 2>&1 )
back=$( ( STATE_FILE="$t_state"; load_state >/dev/null 2>&1
  for k in MODE PORT UUID SNI TARGET PRIVATE_KEY PUBLIC_KEY SHORT_ID SERVER_IP REMARK FLOW FINGERPRINT; do
    printf '%s=[%s]\n' "$k" "${!k}"
  done ) )
expected=$( printf 'MODE=[native]\nPORT=[8443]\nUUID=[u-1234]\nSNI=[%s]\nTARGET=[www.microsoft.com]\nPRIVATE_KEY=[pk-abc]\nPUBLIC_KEY=[pub-xyz]\nSHORT_ID=[0123456789abcdef]\nSERVER_IP=[203.0.113.7]\nREMARK=[%s]\nFLOW=[xtls-rprx-vision]\nFINGERPRINT=[chrome]\n' "a'b" $'line1\nline2' )
assert_eq "$expected" "$back" "save_state/load_state 全字段往返逐字节一致"
assert_contains "$(cat "$t_state")" "SNI='a'\''b'" "状态文件里的 SNI 以转义后的单引号字面量保存"
assert_contains "$(cat "$t_state")" "DEPLOYED_AT='" "状态文件记录部署时间且为单引号字面量"
if [[ -e "$t_state.tmp" ]]; then tmp_left=1; else tmp_left=0; fi
assert_eq "0" "$tmp_left" "save_state 完成后不残留 .tmp 临时文件"

( STATE_FILE="$t_state"; state_exists ); rc=$?
assert_status 0 "$rc" "state_exists 对已存在的状态文件返回 0"
( STATE_FILE="$t_dir/nope.env"; state_exists ); rc=$?
assert_status 1 "$rc" "state_exists 对不存在的状态文件返回非 0"
( STATE_FILE="$t_dir/nope.env"; load_state >/dev/null 2>&1 ); rc=$?
assert_status 1 "$rc" "load_state 对不存在的状态文件返回非 0"
rm -rf "$t_dir"
else
  assert_eq "mktemp -d 能创建唯一临时目录" "失败（mktemp -d 返回空路径）" \
    "save_state/load_state 用例前提：mktemp -d 必须能创建唯一临时目录"
fi

test_case "core 常量与文件边界"

assert_eq "1.1.0" "$APP_VERSION" "core.sh 的 APP_VERSION 统一为 1.1.0"
assert_eq "/etc/vless-reality" "$STATE_DIR" "STATE_DIR 默认值"
assert_eq "/etc/vless-reality/deploy.env" "$STATE_FILE" "STATE_FILE 默认跟随 STATE_DIR"
assert_eq "/root/vless-reality" "$OUT_DIR" "OUT_DIR 默认值（客户端导出目录）"

# bash 4.2/4.3 在 set -u 下展开空数组会报 unbound variable —— 用安全写法
if [[ "${#REALITY_TARGETS[@]}" -ge 5 ]]; then tgt_ok=1; else tgt_ok=0; fi
assert_eq "1" "$tgt_ok" "REALITY_TARGETS 至少提供 5 个候选目标"
bad_targets=''
for t in ${REALITY_TARGETS[@]+"${REALITY_TARGETS[@]}"}; do
  validate_hostname "$t" || bad_targets+="$t "
done
assert_eq "" "$bad_targets" "REALITY_TARGETS 全部是合法主机名"

# lib/core.sh 必须语法正确（静态检查，防回归）
bash -n "$ROOT/lib/core.sh"; rc=$?
assert_status 0 "$rc" "lib/core.sh 通过 bash -n 语法检查"

# 文件存在且非空 —— 下面两条 grep 类断言的前提守卫（否则会退化成真空通过）
if [[ -s "$ROOT/lib/core.sh" ]]; then core_nonempty=1; else core_nonempty=0; fi
assert_eq "1" "$core_nonempty" "lib/core.sh 存在且非空"
core_src="$(cat "$ROOT/lib/core.sh")"
assert_contains "$core_src" "chmod 600" "core.sh 对状态文件设置 600 权限"
assert_contains "$core_src" "chmod 700" "core.sh 对状态目录设置 700 权限"

test_case "core 修复轮 1 回归（评审发现项）"

# ── I-1：全局状态变量必须显式声明 ─────────────────────────
# install.sh 跑在 `set -u` 下；--menu 路径不经过 preflight → SERVER_IP 从未探测，
# 未声明时 deploy_wizard 引用 $SERVER_IP 会直接崩，且没有 tui_err 提示。
out=$(bash -c 'set -uo pipefail; source "$1"; printf "%s" "$SERVER_IP"' _ "$ROOT/lib/core.sh" 2>&1); rc=$?
assert_status 0 "$rc" "core.sh 显式声明了全局状态变量（set -u 下引用不 unbound）"
out=$(bash -c 'set -uo pipefail; PORT=1234; source "$1"; printf "%s" "$PORT"' _ "$ROOT/lib/core.sh" 2>&1)
assert_eq "1234" "$out" "core.sh 的声明块保留调用方预设的全局变量（用 ${VAR:-} 而非 VAR=''）"

# ── M-2 / F-16：random_hex 失败必须返回非零 ─────────────────
# 旧写法 `openssl ... | tr ...; return 0` 的退出码取自 tr，openssl 失败时仍返回 0
# → 输出空串 → 空 SHORT_ID 进 config.json → xray 报错与真实原因无关。
out=$( ( have_cmd() { return 1; }; od() { return 1; }; random_hex 4 ) 2>&1 ); rc=$?
assert_status 1 "$rc" "random_hex 在 openssl 与 od 都不可用时返回非零"
assert_eq "" "$out" "random_hex 失败时不输出任何内容"
# openssl 分支的静默失败必须单独覆盖：旧写法 `openssl ... | tr ...; return 0`
# 的末尾是【显式】return 0，管道退出码取的是 tr 的 → openssl 失败时返回 0
# 但输出为空。测试入口的 pipefail 也救不了它（显式 return 0 直接覆盖管道状态）。
# 只 mock「openssl 不存在」是抓不到这个缺陷的 —— 必须让 have_cmd 说 openssl 存在、
# 而 openssl 本身失败。
out=$( ( have_cmd() { return 0; }; openssl() { return 1; }; od() { return 1; }; random_hex 4 ) 2>&1 ); rc=$?
assert_status 1 "$rc" "random_hex 在 openssl 失败时返回非零（不得静默返回空串）"
assert_eq "" "$out" "random_hex 在 openssl 失败时不输出任何内容"
out=$( ( openssl() { printf 'NOTHEX'; }; random_hex 4 ) 2>&1 ); rc=$?
assert_status 0 "$rc" "openssl 输出非十六进制时退回 /dev/urandom 而不是把垃圾返回"
assert_eq "8" "$(printf '%s' "$out" | wc -c | tr -d ' ')" "回退后输出恰好 8 个十六进制字符"
if [[ "$out" =~ ^[0-9a-f]{8}$ ]]; then hex_ok=1; else hex_ok=0; fi
assert_eq "1" "$hex_ok" "回退后输出是纯小写十六进制"

# ── I-2：save_state 写失败必须返回非零，且不得谎报成功 ───────
bad_dir=$(mktemp -d 2>/dev/null)
if [[ -n "$bad_dir" ]]; then
  : > "$bad_dir/notadir"   # 用一个普通文件占住目录名，让 mkdir -p 必然失败
  out=$( ( STATE_DIR="$bad_dir/notadir"; STATE_FILE="$bad_dir/notadir/deploy.env"; save_state ) 2>&1 ); rc=$?
  assert_status 1 "$rc" "save_state 在状态目录无法创建时返回非零"
  assert_contains "$out" "无法创建状态目录" "save_state 写失败时给出明确错误"
  if [[ "$out" == *"配置已保存"* ]]; then lied=1; else lied=0; fi
  assert_eq "0" "$lied" "save_state 写失败时不得打印『配置已保存』"
else
  assert_eq "mktemp -d 能创建唯一临时目录" "失败（mktemp -d 返回空路径）" \
    "save_state 失败路径用例前提：mktemp -d 必须能创建唯一临时目录"
fi
rm -rf "$bad_dir"

# ── M-1：状态文件损坏时 load_state 必须返回非零 ───────────────
bad_dir=$(mktemp -d 2>/dev/null)
if [[ -n "$bad_dir" ]]; then
  printf 'PORT=443\nif then fi\n' > "$bad_dir/broken.env"
  out=$( ( STATE_FILE="$bad_dir/broken.env"; load_state ) 2>&1 ); rc=$?
  assert_status 1 "$rc" "load_state 对语法错误的状态文件返回非零"
  assert_contains "$out" "状态文件格式错误" "load_state 对损坏的状态文件给出明确错误"
  printf 'PORT=443\nfalse\n' > "$bad_dir/lastfalse.env"
  out=$( ( STATE_FILE="$bad_dir/lastfalse.env"; load_state ) 2>&1 ); rc=$?
  assert_status 0 "$rc" "load_state 对末条命令返回非零的合法状态文件仍视为可读"
  # 「读不到」与「格式错」必须分开报：不可读是权限问题，提示去改格式会把人带偏。
  out=$( ( STATE_FILE="$bad_dir/absent.env"; load_state ) 2>&1 ); rc=$?
  assert_status 1 "$rc" "load_state 对不存在的状态文件返回非零（读不到 ≠ 格式错）"
  assert_contains "$out" "状态文件不存在" \
    "load_state 对读不到的状态文件报『不存在』而不是笼统失败"
  # F-3：load_state 绝不能把状态文件【执行两次】。
  # 旧写法先在子 shell 里 source 一遍做「静默探测」，再正式 source 一遍
  # → 文件里的副作用发生两次（且第一次发生在子 shell 里，调用方看不见）。
  # 计数方式：状态文件里放一条会追加一行的命令，source 一次就多一行。
  printf 'PORT=443\nprintf "x\\n" >> "%s/sidefx"\n' "$bad_dir" > "$bad_dir/sidefx.env"
  out=$( ( STATE_FILE="$bad_dir/sidefx.env"; load_state ) 2>&1 ); rc=$?
  assert_status 0 "$rc" "load_state 对带副作用的合法状态文件仍视为可读"
  assert_eq "1" "$(wc -l < "$bad_dir/sidefx" 2>/dev/null | tr -d ' ')" \
    "load_state 只把状态文件执行一次（不得用子 shell 探测导致双执行）"
  # 第三态「不可读」：权限问题，报『不可读』而不是笼统失败。
  # 本平台（Windows + MSYS）chmod 000 只会把 mode 变成 444、文件仍然可读 →
  # 该分支在这台机器上不可达，断言自动跳过；
  # 在 Debian / CI（以非 root 运行）下会真正执行。
  unread_dir=$(mktemp -d 2>/dev/null)
  if [[ -n "$unread_dir" ]]; then
    printf 'PORT=443\n' > "$unread_dir/unreadable.env"
    chmod 000 "$unread_dir/unreadable.env" 2>/dev/null
    if [[ ! -r "$unread_dir/unreadable.env" ]]; then
      out=$( ( STATE_FILE="$unread_dir/unreadable.env"; load_state ) 2>&1 ); rc=$?
      assert_status 1 "$rc" "load_state 对不可读的状态文件返回非零"
      assert_contains "$out" "状态文件不可读" \
        "load_state 对不可读的状态文件报『不可读』而不是笼统失败"
    fi
  fi
  rm -rf "$unread_dir"
else
  assert_eq "mktemp -d 能创建唯一临时目录" "失败（mktemp -d 返回空路径）" \
    "load_state 失败路径用例前提：mktemp -d 必须能创建唯一临时目录"
fi
rm -rf "$bad_dir"

# ── M-7：urlencode 两个分支的 stdout 必须逐字节一致 ──────────
# 断言盲区（复评 M-7 / F-5）：原先直接对比「真实 python 分支输出」与「回退分支输出」。
# 在 python3 缺失、或 python3 存在但【功能异常】（某些系统上 python3 只是个占位存根：
# command -v 找得到、一执行就失败）的机器上，两侧其实【都是回退分支】——
# 这条断言恒真，等于什么都没测。
# 修法：把对比基准换成【确定性的 mock python3】——
# 它用与 lib/core.sh 回退实现【不同的算法】（按字节取十六进制码）算百分号编码，
# 因此这条断言在任何机器上都能真正验证回退实现的字节级正确性；
# 真实 python3 功能可用时，再额外做一次真实两分支对比。
enc_all="a b'c\\d中文"
# mock python3：等价实现 RFC 3986 的 quote(s, safe="")。
# 真实调用形如 python3 -c '<代码>' '<输入>' → 被编码的串是【最后一个】参数。
mock_python3() {
  local s="${!#}" i len out='' ch hex
  local LC_ALL=C
  len=${#s}
  for ((i = 0; i < len; i++)); do
    ch="${s:i:1}"
    if [[ "$ch" == [a-zA-Z0-9.~_-] ]]; then
      out+="$ch"
    else
      hex=$(printf '%s' "$ch" | od -An -tx1 | tr -d ' \n')
      out+="%${hex^^}"
    fi
  done
  printf '%s' "$out"
}
enc_mock="$( ( python3() { mock_python3 "$@"; }; urlencode "$enc_all" ) )"
enc_fb="$( ( have_cmd() { return 1; }; urlencode "$enc_all" ) )"
assert_eq "$enc_mock" "$enc_fb" "urlencode 的 python 分支与回退分支输出逐字节一致（mock python3 基准）"
assert_eq "a%20b%27c%5Cd%E4%B8%AD%E6%96%87" "$enc_fb" "urlencode 回退分支编码结果正确"
raw_enc="$(urlencode 'abc' | od -An -c | tr -d ' ')"
assert_eq "abc" "$raw_enc" "urlencode 输出不含多余的尾换行（od 逐字节可见）"
# 真实 python3 【功能可用】时（不只是 command -v 找得到），再对比一次真实分支。
if python3 -c 'import sys,urllib.parse' >/dev/null 2>&1; then
  enc_real="$(urlencode "$enc_all")"
  assert_eq "$enc_real" "$enc_fb" "urlencode 的真实 python3 分支与回退分支输出逐字节一致"
else
  # python3 不可用不是缺陷（回退分支正是为此存在），此处【不断言失败】，
  # 只登记一条说明以保持断言条数稳定；python 分支已由上面的 mock 用例覆盖。
  assert_eq "python3 功能不可用" "python3 功能不可用" \
    "python3 功能探测未通过：真实 python3 分支对比跳过（已由 mock python3 用例覆盖）"
fi

# ── O-1：detect_os 必须能处理 CRLF 行尾的 os-release ─────────
crlf_os=$(mktemp 2>/dev/null)
if [[ -n "$crlf_os" ]]; then
  printf 'ID=debian\r\nVERSION_ID="12"\r\n' > "$crlf_os"
  os_crlf="$(detect_os "$crlf_os")"
  assert_eq "debian" "$(printf '%s' "$os_crlf" | cut -d'|' -f1)" "detect_os 去掉 CRLF os-release 里的 CR"
  assert_eq "12" "$(printf '%s' "$os_crlf" | cut -d'|' -f2)" "detect_os 去掉 CRLF os-release 里的 CR（version）"
else
  assert_eq "mktemp 能创建临时文件" "失败（mktemp 返回空路径）" \
    "detect_os CRLF 用例前提：mktemp 必须能创建临时文件"
fi
rm -f "$crlf_os"

# ── M-5①：REALITY_TARGETS 必须钉住计划指定的全部 7 个目标 ────
missing_targets=''
for t in 'www.microsoft.com' 'dl.google.com' 'www.apple.com' 'one.one.one.one' 'www.cloudflare.com' 'time.akamai.com' 'addons.mozilla.org'; do
  found=0
  for x in ${REALITY_TARGETS[@]+"${REALITY_TARGETS[@]}"}; do
    if [[ "$x" == "$t" ]]; then found=1; break; fi
  done
  if [[ $found -eq 0 ]]; then missing_targets+="$t "; fi
done
assert_eq "" "$missing_targets" "REALITY_TARGETS 包含计划指定的全部 7 个目标"

# ── M-5②：权限位【行为断言】——只在 chmod 真的生效的文件系统上跑 ──
# Debian 真机必然生效；本开发机（MSYS）的 chmod 是模拟的，probe_mode != 600 → 跳过。
perm_dir=$(mktemp -d 2>/dev/null)
if [[ -n "$perm_dir" ]]; then
  : > "$perm_dir/probe"
  chmod 600 "$perm_dir/probe" 2>/dev/null
  probe_mode="$(stat -c '%a' "$perm_dir/probe" 2>/dev/null)"
  if [[ "$probe_mode" == "600" ]]; then
    ( STATE_DIR="$perm_dir/sd"; STATE_FILE="$perm_dir/sd/deploy.env"; save_state >/dev/null 2>&1 )
    assert_eq "600" "$(stat -c '%a' "$perm_dir/sd/deploy.env" 2>/dev/null)" "save_state 写出的状态文件权限为 600"
    assert_eq "700" "$(stat -c '%a' "$perm_dir/sd" 2>/dev/null)" "save_state 建出的状态目录权限为 700"
  fi
fi
rm -rf "$perm_dir"

test_case "core 网络探测（用可控输入验证解析逻辑）"

# 端口判定：结果在【退出码】上，不能写成 assert_false "$(port_in_use 59999)" ——
# $( ) 捕获的是 stdout（空串），退出码被丢掉，断言会恒真通过（测不出任何东西）。
# 也不能依赖「59999 恰好是空闲的」这种环境假设：用 mock 的 ss 构造确定场景。
SS_HDR='State Recv-Q Send-Q Local Address:Port Peer Address:Port\n'
mock_port_in_use() {
  local ssout="$1" port="$2"
  (
    have_cmd() { case "$1" in ss) return 0 ;; netstat) return 1 ;; *) return 1 ;; esac; }
    ss() { printf '%b' "$ssout"; }
    port_in_use "$port" >/dev/null 2>&1
  )
}
mock_port_in_use "${SS_HDR}LISTEN 0 128 0.0.0.0:59999 0.0.0.0:*\n" 59999; rc=$?
assert_true "$rc" "port_in_use 识别出被占用的端口（mock ss）"
mock_port_in_use "$SS_HDR" 59999; rc=$?
assert_false "$rc" "port_in_use 识别出空闲的端口（mock ss 只有表头）"
# 子串陷阱：":8080" 里就含 ":80" —— 对整行 grep 会把 :8080 误判成 :80 已被占用
mock_port_in_use "${SS_HDR}LISTEN 0 128 0.0.0.0:8080 0.0.0.0:*\n" 80; rc=$?
assert_false "$rc" "port_in_use 不得把 :8080 误判成 :80 已占用（按字段精确匹配）"

# ── F4-1：port_in_use 不得把 grep -q 直接接在管道上 ──────────
# 缺陷本体：管道里 `grep -q` 命中即退出 → 上游 awk 收到 SIGPIPE（141）→
# 在 set -o pipefail 下整条管道的退出码变成 141 → `&& return 0` 不成立 →
# 一个【已占用】的端口被误判成【空闲】→ 向导选了这个端口 →
# 部署到一半才报 "address in use"，且错误信息与真实原因无关。
# 这个缺陷在运行期复现需要 awk 的输出超过其管道缓冲（约 8KB，即 >1000 行），
# 且是否触发取决于时序 → 【不能】写成一条依赖时序的运行期断言。
# 因此用【源码静态断言】锁住实现形状（确定性，权威判据）。
port_in_use_body="$(awk '/^port_in_use\(\) *\{/,/^\}/' "$ROOT/lib/core.sh")"
if [[ -n "$port_in_use_body" ]]; then rc=0; else rc=1; fi
assert_true "$rc" \
  "core.sh 里必须存在 port_in_use 函数（下面那条静态断言的前提）"
# 检查前必须先去掉整行注释：函数的说明性注释里会写「不能写成 `ss | awk | grep -q`」
# 这类字样 —— 那是【说明】不是【代码】，不去掉会把自己判成违规（实测踩过）。
port_in_use_code="$(printf '%s\n' "$port_in_use_body" | grep -v '^[[:space:]]*#')"
assert_eq "" "$(printf '%s\n' "$port_in_use_code" | grep -n '|[ \t]*grep[ \t]*-q' | tr '\n' ' ')" \
  "port_in_use 不得把 grep -q 直接接在管道上（SIGPIPE 会把 141 带进退出码）"
# 辅助（行为）断言：输出量大到超过 awk 的管道缓冲时，判定仍必须是「已占用」。
# 修好后这条【必然】通过；若有人改回「管道 + grep -q」，它【可能】变红（时序相关），
# 所以它只是辅助，权威判据是上面那条静态断言。
big_ss='State Recv-Q Send-Q Local Address:Port Peer Address:Port\nLISTEN 0 128 0.0.0.0:59999 0.0.0.0:*\n'
for _ in $(seq 1 2000); do
  big_ss+="LISTEN 0 128 0.0.0.0:$((3000 + _)) 0.0.0.0:*\n"
done
mock_port_in_use "$big_ss" 59999; rc=$?
assert_true "$rc" "port_in_use 在输出量很大时仍能正确判定端口已占用（不得因 SIGPIPE 误判为空闲）"

# port_occupant 的解析同样用 mock 构造确定场景
out=$( ( have_cmd() { case "$1" in ss) return 0 ;; *) return 1 ;; esac; }
            ss() { printf '%b' "${SS_HDR}LISTEN 0 128 0.0.0.0:59999 0.0.0.0:* users:((nginx,pid=1,fd=2))\n"; }
            port_occupant 59999 ) 2>&1 )
assert_contains "$out" "pid=1" "port_occupant 解析出占用进程的描述"
out=$( ( have_cmd() { case "$1" in ss) return 0 ;; *) return 1 ;; esac; }
            ss() { printf '%b' "$SS_HDR"; }
            port_occupant 59999 ) 2>&1 )
assert_eq "" "$out" "port_occupant 在端口空闲时输出为空"

# ── is_valid_ip：挡住「响应体根本不是 IP」的情况 ──────────────
# 旧判定 `^[0-9a-fA-F:]+$` 太宽：HTTP 状态码响应体（"404" / "403" / "200"，
# 代理与网关常这么返回）和 "cafebabe" / "12345" 这类纯十六进制串都会被当成 IP
# → 写进分享链接与配置后客户端必然连不上，而用户完全看不出是「探测错了」。
assert_succeeds "is_valid_ip 接受合法 IPv4" is_valid_ip 1.2.3.4
assert_succeeds "is_valid_ip 接受 0 号段（0.0.0.0 是合法写法）" is_valid_ip 0.0.0.0
assert_succeeds "is_valid_ip 接受 255 号段" is_valid_ip 255.255.255.255
assert_succeeds "is_valid_ip 接受 IPv6 形态" is_valid_ip "2001:db8::1"
assert_succeeds "is_valid_ip 接受完整写法的 IPv6" is_valid_ip "2001:0db8:0000:0000:0000:0000:0000:0001"
assert_fails "is_valid_ip 拒绝纯数字串（404 这类 HTTP 状态码）" is_valid_ip 404
assert_fails "is_valid_ip 拒绝纯十六进制串（cafebabe）" is_valid_ip cafebabe
assert_fails "is_valid_ip 拒绝五段 IPv4" is_valid_ip 1.2.3.4.5
assert_fails "is_valid_ip 拒绝每段都大于 255 的伪 IPv4" is_valid_ip 999.999.999.999
assert_fails "is_valid_ip 拒绝空串" is_valid_ip ""
# IPv6 分支曾经只要求「含冒号 + 全是十六进制字符」→ "dead:beef" 这类只有两段、
# 且没有 "::" 压缩写法的串会被误收。收紧后必须钉住。
assert_fails "is_valid_ip 拒绝只有两段且无 :: 的伪 IPv6（dead:beef）" is_valid_ip "dead:beef"
assert_fails "is_valid_ip 拒绝只有两段且无 :: 的伪 IPv6（cafe:babe）" is_valid_ip "cafe:babe"

# ── detect_public_ip：必须 mock 掉 curl 才能得到确定性结果（真实网络不可依赖）──
# 注意：mock 的响应体【必须带尾随换行】！真实的 IP 服务（ipify / ifconfig.me /
# icanhazip / ipinfo）返回的都是 "1.2.3.4\n"。bash 的 =~ 锚点【不匹配】尾随换行，
# 而实现里靠 `tr -d '[:space:]'` 剥掉它 —— 如果那条 tr 被当成「冗余」删掉，
# 探测在【任何真实网络下】都会失败（返回空），而用无换行的 mock 去测【测不出来】。
out=$( ( curl() { printf '404\n'; }; detect_public_ip ) 2>/dev/null ); rc=$?
assert_status 1 "$rc" "detect_public_ip 面对非 IP 响应体（HTTP 状态码 404）必须返回非零"
assert_eq "" "$out" "detect_public_ip 面对非 IP 响应体时不得输出任何内容"
out=$( ( curl() { printf '1.2.3.4\n'; }; detect_public_ip ) 2>/dev/null ); rc=$?
assert_status 0 "$rc" "detect_public_ip 遇到合法 IPv4 时返回 0"
assert_eq "1.2.3.4" "$out" "detect_public_ip 输出正确的公网 IPv4"
out=$( ( curl() { printf '2001:db8::1\n'; }; detect_public_ip ) 2>/dev/null ); rc=$?
assert_status 0 "$rc" "detect_public_ip 遇到 IPv6 时返回 0"
assert_eq "2001:db8::1" "$out" "detect_public_ip 输出正确的 IPv6"
out=$( ( curl() { printf '  1.2.3.4  \n'; }; detect_public_ip ) 2>/dev/null ); rc=$?
assert_eq "1.2.3.4" "$out" "detect_public_ip 会剥掉响应里的空白与换行（真实 IP 服务都带尾随换行）"

# ── detect_local_ip：ip 命令与 hostname 两条路径都要覆盖 ──────────
out=$( ( ip() { printf '1.2.3.4 via 10.0.0.1 dev eth0 src 192.168.1.10 uid 0\n'; }
         hostname() { return 1; }
         detect_local_ip ) 2>/dev/null ); rc=$?
assert_eq "192.168.1.10" "$out" "detect_local_ip 从 ip route 的 src 字段取到本机地址"
out=$( ( ip() { return 1; }
         hostname() { printf '10.0.0.7\n'; }
         detect_local_ip ) 2>/dev/null ); rc=$?
assert_eq "10.0.0.7" "$out" "detect_local_ip 在 ip 不可用时回退到 hostname -I"
out=$( ( ip() { return 1; }; hostname() { return 1; }; detect_local_ip ) 2>/dev/null ); rc=$?
assert_status 1 "$rc" "detect_local_ip 在 ip 与 hostname 都不可用时必须返回非零（不得 rc=0 却输出空串）"
# 注意：tui_err 写的是【stdout】（本项目的 TUI 输出统一走 stdout，不是 stderr），
# 所以失败时 stdout 上会出现错误提示 —— 这里断言的是「有明确提示、且没有输出任何地址」。
assert_contains "$out" "无法探测本机地址" "detect_local_ip 失败时给出明确错误（且不输出任何地址）"

# ── random_free_port：输出必须是 20000-39999 的整数 ──────────────
out=$( ( port_in_use() { return 1; }; random_free_port ) 2>/dev/null ); rc=$?
assert_status 0 "$rc" "random_free_port 返回 0"
[[ "$out" =~ ^[0-9]+$ ]] && (( 10#$out >= 20000 && 10#$out <= 39999 )); assert_true "$?" \
  "random_free_port 输出落在 20000-39999 区间"

# ── ensure_packages：依赖缺失且 apt update 失败时必须中止，不得继续装 ──────
# 用文件记录 apt-get install 是否被调用：赋值给变量的调用在子 shell 里发生，
# 外层看不到 → 只能用文件跨子 shell 传递。
called_file="$(mktemp 2>/dev/null)"
if [[ -n "$called_file" ]]; then
  out=$( ( have_cmd() { return 1; }
           apt_update_once() { return 1; }
           # 标记文件必须【写入内容】：`: >"$called_file"` 只创建空文件（size 0），
           # 而下面的判定是 `[[ -s "$called_file" ]]`（size > 0）→ 空文件恒为假 →
           # 这条断言【永远绿、永远不可能变红】（假绿）。
           # 控制器与实施者各自独立实证：把本行改成写 1 字节后，
           # 把 ensure_packages 变异成 `apt_update_once || true` 才会红 2 条。
           tui_run() { printf called >"$called_file"; return 0; }
           ensure_packages curl ) 2>/dev/null ); rc=$?
  assert_status 1 "$rc" "ensure_packages 在 apt update 失败时必须返回非零"
  if [[ -s "$called_file" ]]; then called=1; else called=0; fi
  assert_eq "0" "$called" "ensure_packages 在 apt update 失败时不得继续调用 apt-get install"
  rm -f "$called_file"
else
  assert_eq "mktemp 能创建临时文件" "失败（mktemp 返回空路径）" \
    "ensure_packages 用例前提：mktemp 必须能创建临时文件"
fi

# ── service_run_user：systemd unit 的运行用户与回退 ──────────────
out=$( ( systemctl() { printf 'xray\n'; }; service_run_user ) 2>/dev/null )
assert_eq "xray" "$out" "service_run_user 读出 systemd unit 的运行用户"
out=$( ( systemctl() { return 1; }; service_run_user ) 2>/dev/null )
assert_eq "root" "$out" "service_run_user 在 systemctl 不可用时回退到 root"

# ── target_supports_tls13 的解析逻辑：mock 掉 openssl 得到确定性结果 ──────────
# 该函数此前【一条确定性断言都没有】—— 只在真实网络下被测，网络一抖就整条被跳过；
# 更糟的是它【测的是环境而不是实现】：把函数整个换成 `return 0` 也测不出来。
out=$( ( have_cmd() { case "$1" in openssl) return 0 ;; *) return 1 ;; esac; }
         timeout() { shift; "$@"; }
         openssl() { printf 'Protocol  : TLSv1.3\nCipher    : TLS_AES_128_GCM_SHA256\n'; }
         target_supports_tls13 'x.example' ) 2>/dev/null ); rc=$?
assert_true "$rc" "target_supports_tls13 识别出 TLS 1.3 的握手输出"
out=$( ( have_cmd() { case "$1" in openssl) return 0 ;; *) return 1 ;; esac; }
         timeout() { shift; "$@"; }
         openssl() { printf 'Protocol  : TLSv1.2\nCipher    : ECDHE-RSA-AES128-GCM-SHA256\n'; }
         target_supports_tls13 'x.example' ) 2>/dev/null ); rc=$?
assert_false "$rc" "target_supports_tls13 识别出非 TLS 1.3 的握手输出"
# 真实目标：至少一个候选站点应支持 TLS1.3。
# 网络不可用时【登记一条说明】而不是静默跳过 —— 否则断言条数会在 183/184 之间
# 振荡（实测 6 次里 2 次是 183），CI 里写死条数必然 flake。
if have_cmd openssl && curl -fsS --max-time 5 -o /dev/null https://www.microsoft.com 2>/dev/null; then
  target_supports_tls13 www.microsoft.com; rc=$?
  assert_true "$rc" "www.microsoft.com 支持 TLS 1.3"
else
  assert_eq "网络不可用" "网络不可用" \
    "真实 TLS1.3 探测已跳过（网络不可用）：解析逻辑已由上面的 mock 用例覆盖"
fi

# 【替换】下面这两行是 Task 3 加进 test/unit.sh 的断言（原样照抄，用来定位），
# 必须被下面那条收窄后的断言【替换掉】，不是并存：
#   offenders="$(grep -nE '^[[:space:]]*(function[[:space:]]+)?(require_root|is_modern_debian|detect_public_ip|detect_local_ip|port_in_use|port_occupant|random_free_port|target_supports_tls13|target_latency_ms|apt_update_once|ensure_packages|service_run_user)[[:space:]]*(\(\))?[[:space:]]*[{]' "$ROOT/lib/core.sh" | tr '\n' ' ')"
#   assert_eq "" "$offenders" "core.sh 不含属于 install.sh / Task 4 的越权函数"
# 收窄后只剩 install.sh 拥有的 require_root / is_modern_debian。
offenders="$(grep -nE '^[[:space:]]*(function[[:space:]]+)?(require_root|is_modern_debian)[[:space:]]*(\(\))?[[:space:]]*[{]' "$ROOT/lib/core.sh" | tr '\n' ' ')"
assert_eq "" "$offenders" "core.sh 不含属于 install.sh 的越权函数（require_root / is_modern_debian）"

# apt update 失败必须中止：否则依赖装不上，调用方却以为装好了。
# 用 mock 覆盖 tui_run 让它失败（子 shell 内覆盖，不污染测试进程）。
# 若本机已存在标记文件则跳过（此时函数会提前返回 0，用例前提不成立）。
# 注意：真实 Debian 上跑过一次 apt update 后标记文件就在了 → 这条断言会消失。
# 所以 else 侧必须登记一条说明，把条数补回来（见全局约束）。
if [[ ! -f /var/lib/vless-reality/apt-updated ]]; then
  ( tui_run() { return 1; }; apt_update_once >/dev/null 2>&1 ); rc=$?
  assert_false "$rc" "apt update 失败时 apt_update_once 必须返回非零"
else
  assert_eq "标记文件已存在" "标记文件已存在" \
    "apt update 失败用例已跳过（本机已存在 /var/lib/vless-reality/apt-updated，用例前提不成立）"
fi

test_case "x25519 密钥解析（跨版本兼容）"

# 旧版输出格式
out=$(xray_parse_keys "Private key: aaaBBB111ccc
Public key: dddEEE222fff")
assert_eq "aaaBBB111ccc|dddEEE222fff" "$out" "解析旧版 Private/Public key 格式"

# 新版 v25.x 输出格式（公钥字段名为 Password）
out=$(xray_parse_keys "PrivateKey: xxxYYY222zzz
Password: wwwVVV333uuu")
assert_eq "xxxYYY222zzz|wwwVVV333uuu" "$out" "解析新版 PrivateKey/Password 格式"

# key=value 写法：有的版本输出的是 "PrivateKey=xxx" 而非 "PrivateKey: xxx"。
# 这条分支此前【一条断言都没有】—— 控制器变异实测：把该分支删掉，0 条红。
out=$(xray_parse_keys "PrivateKey=aaaBBB111ccc
Password=dddEEE222fff")
assert_eq "aaaBBB111ccc|dddEEE222fff" "$out" "解析 key=value 写法（PrivateKey/Password）"

# 单行、带多余空白的脏输出
out=$(xray_parse_keys "  Private key :   qqq444   ")
assert_eq "qqq444|" "$out" "私钥可解析时公钥为空"

# 无关输出不应误判。必须【同时】断言「输出为空」与「退出码非零」——
# 原来只有一条 assert_eq，描述里写的「退出码非零」从来没被断言过。
out=$(xray_parse_keys "hello world" 2>/dev/null || printf '')
assert_eq "" "$out" "无法识别时返回空串"
rc=0
xray_parse_keys "hello world" >/dev/null 2>&1 || rc=$?
assert_status 1 "$rc" "无法识别时退出码非零"

test_case "服务端配置渲染"

# mktemp 失败时 $cfg 为空 → 渲染函数会写出 ".new" 污染仓库当前目录 → 必须守卫。
cfg=$(mktemp)
if [[ -z "$cfg" ]]; then
  assert_eq "mktemp 能创建临时文件" "失败（mktemp 返回空路径）" "渲染用例前提：mktemp 必须可用"
else
  # 私钥必须用【真实的 x25519 私钥形态】（base64url，40-64 字符）：
  # render_server_config 会对入参做白名单校验（见 Step 3），
  # "PRIVKEY" 这种占位串会被直接拒绝。
  PRIVKEY='PRIVKEY0123456789abcdefghijklmnopqrstuvwxyzABCDE'
  render_server_config "$cfg" "11111111-2222-3333-4444-555555555555" "$PRIVKEY" "www.microsoft.com" "443" "a1b2c3d4" >/dev/null
  # JSON 合法性检查必须在 python3 判活守卫【之内】：
  # 守卫外的那条会在「没有 python3」的机器上必然判红（捕获到 "1" → assert_true 失败）。
  # 判活必须用【功能可用】而不是 have_cmd：本机可能存在名为 python3 的占位/存根
  # （例如 Microsoft Store 的 app execution alias），`command -v` 找得到但一跑就失败。
  # 用 have_cmd 判活会让「JSON 合法性」断言在这些机器上必然判红。
  if python3 -c 'import json' >/dev/null 2>&1; then
    assert_status 0 "$(python3 -c "import json,sys;json.load(open(sys.argv[1]));print(0)" "$cfg" 2>/dev/null || echo 1)" "生成的配置是合法 JSON"
    assert_contains "$(cat "$cfg")" '"security": "reality"' "配置启用 reality"
    assert_contains "$(cat "$cfg")" '"target": "www.microsoft.com:443"' "reality target 正确"
    assert_contains "$(cat "$cfg")" '"serverNames": [' "配置含 serverNames"
    assert_contains "$(cat "$cfg")" '"flow": "xtls-rprx-vision"' "配置含 xtls-rprx-vision 流控"
    assert_contains "$(cat "$cfg")" '"privateKey": "'"$PRIVKEY"'"' "配置含私钥"
    assert_contains "$(cat "$cfg")" '"shortIds": [' "配置含 shortIds"
    assert_eq 0 "$(grep -c 'geoip' "$cfg")" "配置不引用 geoip（避免 geoip.dat 依赖）"
  else
    # python3 不可用不是缺陷（它只是校验 JSON 合法性的手段），此处【不断言失败】，
    # 只登记一条说明以保持断言条数恒定（见全局约束）。
    assert_eq "python3 功能不可用" "python3 功能不可用" \
      "python3 功能探测未通过：JSON 合法性校验已跳过（条数保持恒定）"
  fi

  # ── 注入面：未加引号的 heredoc 会【执行】入参里的 $(...) ──────────────
  # render_server_config 用 `cat >"$tmp" <<EOF`（未加引号）渲染 →
  # 入参里的 $(...) / 反引号会被真实执行。
  # 控制器实证：把 '$(echo PWNED)' 传进 ShortID 或 SNI，
  # 该命令被执行并把结果写进了 config.json。
  # 当前所有调用方恰好都校验过输入（Task 8 校验 --sni/--port，向导校验端口），
  # 但「安全性靠调用方自觉」不是函数契约 —— 函数自身必须守住。
  rc=0
  render_server_config "$cfg.inj" "11111111-2222-3333-4444-555555555555" "$PRIVKEY" "www.microsoft.com" "443" '$(echo PWNED)' >/dev/null 2>&1 || rc=$?
  assert_status 1 "$rc" "render_server_config 拒绝含命令替换的 ShortID"
  rc=0
  render_server_config "$cfg.inj2" "11111111-2222-3333-4444-555555555555" "$PRIVKEY" 'x$(echo PWNED).com' "443" "a1b2c3d4" >/dev/null 2>&1 || rc=$?
  assert_status 1 "$rc" "render_server_config 拒绝含命令替换的 SNI"
  rc=0
  render_server_config "$cfg.inj3" "11111111-2222-3333-4444-555555555555" "$PRIVKEY" "www.microsoft.com" '443$(id)' "a1b2c3d4" >/dev/null 2>&1 || rc=$?
  assert_status 1 "$rc" "render_server_config 拒绝含命令替换的端口"
  rc=0
  render_server_config "$cfg.inj4" '11111111-2222-3333-4444-555555555$(id)' "$PRIVKEY" "www.microsoft.com" "443" "a1b2c3d4" >/dev/null 2>&1 || rc=$?
  assert_status 1 "$rc" "render_server_config 拒绝含命令替换的 UUID"
  rc=0
  render_server_config "$cfg.inj5" "11111111-2222-3333-4444-555555555555" '$(echo PWNED)' "www.microsoft.com" "443" "a1b2c3d4" >/dev/null 2>&1 || rc=$?
  assert_status 1 "$rc" "render_server_config 拒绝含命令替换的私钥"
  # ── D2：目标路径是【已存在的目录】时必须报错，不得把配置移进目录里 ──────────────
  mkdir -p "$cfg.dir"
  out=$(render_server_config "$cfg.dir" "11111111-2222-3333-4444-555555555555" "$PRIVKEY" "www.microsoft.com" "443" "a1b2c3d4" 2>&1); rc=$?
  assert_status 1 "$rc" "render_server_config 在目标路径是目录时返回非零"
  assert_contains "$out" "目录" "render_server_config 在目标路径是目录时给出明确提示"
  rm -rf "$cfg.dir"
  rm -f "$cfg" "$cfg.inj" "$cfg.inj2" "$cfg.inj3" "$cfg.inj4" "$cfg.inj5"

  # 目标目录不存在时，cat 的重定向会失败 —— 必须返回非零并给出【我们自己的】提示
  # （不能把裸的 bash 报错漏给用户）。
  # 光断言退出码【没有判别力】：去掉 cat 的退出码检查后，函数仍会因为后面的
  # `chmod 600 "$tmp"` 失败而返回 1 → 退出码一样是 1 → 那条断言仍然绿。
  # 所以必须断言【错误提示的文本】—— 这才是真正被 cat 检查守住的东西。
  # 路径用 "$cfg.d/no-such-dir/..."，保证父目录一定不存在，
  # 且在 Linux / macOS / MSYS 上行为一致。
  out=$(render_server_config "$cfg.d/no-such-dir/config.json" "11111111-2222-3333-4444-555555555555" "$PRIVKEY" "www.microsoft.com" "443" "a1b2c3d4" 2>&1); rc=$?
  assert_status 1 "$rc" "render_server_config 在目标目录不存在时返回非零"
  assert_contains "$out" "无法写入配置暂存文件" "render_server_config 在目标目录不存在时给出自己的错误提示（而不是裸的 bash 报错）"
fi

test_case "gen_keys 与 xray_test_config"

# gen_keys 与 xray_test_config 此前【一条断言都没有】——
# 把 gen_keys 整个换成 `return 0`、把 xray_test_config 整个换成 `return 0`，
# 全部断言仍然全绿、0 条红（控制器 P3/P4 实证）。
# 这两个函数恰好是「把 xray 的输出变成配置」的关键环节，必须钉住。
#
# 假 xray 用 shell 函数实现，而不是「造可执行脚本 + chmod +x」：
# MSYS 的 chmod 位不可靠（本机上 chmod 000 都不生效），
# 而 bash 会在变量展开之后继续做函数查找 —— 所以 XRAY_BIN=xray 就能命中这个函数。
FAKE_XRAY_MODE=''
xray() {
  case "$1" in
    x25519)
      case "$FAKE_XRAY_MODE" in
        bad)    printf 'hello world\n' ;;
        nopriv) printf 'Public key: IIIIJJJJKKKKLLLL\n' ;;
        nopub)  printf 'Private key: AAAABBBBCCCCDDDDEEEEFFFFGGGGHHHH\n' ;;
        *)      printf 'Private key: AAAABBBBCCCCDDDDEEEEFFFFGGGGHHHH\nPublic key: IIIIJJJJKKKKLLLL\n' ;;
      esac ;;
    uuid)
      case "$FAKE_XRAY_MODE" in
        baduuid) printf 'not-a-uuid\n' ;;
        *)       printf '11111111-2222-3333-4444-555555555555\n' ;;
      esac ;;
    run|-test)
      case "$FAKE_XRAY_MODE" in
        cfg)   [[ "$3" == "-config" ]] && return 0; return 1 ;;
        short) [[ "$3" == "-c" ]] && return 0; return 1 ;;
        bare)  [[ "$1" == "-test" && "$2" == "-config" ]] && return 0; return 1 ;;
        none)  return 1 ;;
        *)     return 0 ;;
      esac ;;
    *) return 1 ;;
  esac
}

# ── gen_keys：成功路径必须一次设置 4 个全局变量 ──────────────
# 注意：gen_keys 设置的是【全局变量】，在 $( ) 子 shell 里设置父 shell 看不到 →
# 必须在子 shell 内部把值打印出来再断言。
out=$( ( XRAY_BIN=xray; FAKE_XRAY_MODE=ok; gen_keys >/dev/null 2>&1
         printf 'PRIV=%s|PUB=%s|UUID=%s|SIDLEN=%s' "$PRIVATE_KEY" "$PUBLIC_KEY" "$UUID" "${#SHORT_ID}" ) 2>&1 )
assert_contains "$out" "PRIV=AAAABBBBCCCCDDDDEEEEFFFFGGGGHHHH" "gen_keys 设置 PRIVATE_KEY"
assert_contains "$out" "PUB=IIIIJJJJKKKKLLLL" "gen_keys 设置 PUBLIC_KEY"
assert_contains "$out" "UUID=11111111-2222-3333-4444-555555555555" "gen_keys 设置 UUID"
assert_contains "$out" "SIDLEN=8" "gen_keys 设置 8 位十六进制 SHORT_ID"

# ── gen_keys：五条失败路径都必须返回非零 ──────────────
out=$( ( XRAY_BIN=./no-such-xray-binary; gen_keys ) 2>&1 ); rc=$?
assert_status 1 "$rc" "gen_keys 在 xray x25519 失败时返回非零"
out=$( ( XRAY_BIN=xray; FAKE_XRAY_MODE=bad; gen_keys ) 2>&1 ); rc=$?
assert_status 1 "$rc" "gen_keys 在无法解析 xray 输出时返回非零"
out=$( ( XRAY_BIN=xray; FAKE_XRAY_MODE=nopriv; gen_keys ) 2>&1 ); rc=$?
assert_status 1 "$rc" "gen_keys 在 xray 只给出公钥（私钥为空）时返回非零"
out=$( ( XRAY_BIN=xray; FAKE_XRAY_MODE=nopub; gen_keys ) 2>&1 ); rc=$?
assert_status 1 "$rc" "gen_keys 在 xray 只给出私钥（公钥为空）时返回非零"
out=$( ( XRAY_BIN=xray; FAKE_XRAY_MODE=baduuid; gen_keys ) 2>&1 ); rc=$?
assert_status 1 "$rc" "gen_keys 在 xray uuid 输出的不是合法 UUID 时返回非零"
out=$( ( XRAY_BIN=xray; FAKE_XRAY_MODE=ok; random_hex() { return 1; }; gen_keys ) 2>&1 ); rc=$?
assert_status 1 "$rc" "gen_keys 在 random_hex 失败时返回非零"
out=$( ( XRAY_BIN=xray; FAKE_XRAY_MODE=ok; random_hex() { printf ''; return 0; }; gen_keys ) 2>&1 ); rc=$?
assert_status 1 "$rc" "gen_keys 在 random_hex 输出空串时返回非零"

# 上面两条断言【区分不了】random_hex 的两种失败：去掉 `SHORT_ID=$(random_hex 4) || {...}`
# 这道检查后，random_hex 返回非零但【有输出】时 SHORT_ID 非空 → 第二道检查也放行
# → 函数返回 0 → 那两条断言仍然全绿（控制器变异实测：0 条红）。
# 判据必须是【错误提示的文本】：返回非零的那条报「生成 ShortID 失败」，
# 返回零但输出为空的那条报「生成的 ShortID 为空」—— 两者的提示必须能分开。
out=$( ( XRAY_BIN=xray; FAKE_XRAY_MODE=ok; random_hex() { printf 'deadbeef'; return 1; }; gen_keys ) 2>&1 ); rc=$?
assert_status 1 "$rc" "gen_keys 在 random_hex 返回非零（即使它有输出）时返回非零"
assert_contains "$out" "生成 ShortID 失败" "gen_keys 在 random_hex 返回非零时提示『生成 ShortID 失败』"
out=$( ( XRAY_BIN=xray; FAKE_XRAY_MODE=ok; random_hex() { printf ''; return 0; }; gen_keys ) 2>&1 ); rc=$?
assert_contains "$out" "ShortID 为空" "gen_keys 在 random_hex 输出空串时提示『ShortID 为空』"

# ── xray_test_config：四种子命令写法都要认 ──────────────
out=$( ( XRAY_BIN=xray; FAKE_XRAY_MODE=cfg; xray_test_config "/tmp/whatever.json" ) 2>&1 ); rc=$?
assert_status 0 "$rc" "xray_test_config 识别 run -test -config 写法"
out=$( ( XRAY_BIN=xray; FAKE_XRAY_MODE=short; xray_test_config "/tmp/whatever.json" ) 2>&1 ); rc=$?
assert_status 0 "$rc" "xray_test_config 识别 run -test -c 写法"
out=$( ( XRAY_BIN=xray; FAKE_XRAY_MODE=bare; xray_test_config "/tmp/whatever.json" ) 2>&1 ); rc=$?
assert_status 0 "$rc" "xray_test_config 识别 -test -config 写法"
out=$( ( XRAY_BIN=xray; FAKE_XRAY_MODE=none; xray_test_config "/tmp/whatever.json" ) 2>&1 ); rc=$?
assert_status 1 "$rc" "xray_test_config 在所有写法都不被支持时返回非零"
# 假 xray 只在本用例里用 —— 用完立刻撤掉，别影响后续用例（Task 6 起会用到真 xray）。
unset -f xray

test_case "服务端配置原子写入"

# write_config_atomic 是写服务端配置的唯一入口，两条路径都必须被覆盖。
# 校验失败：必须返回非零、【保留原有配置】、并清理临时文件。
atomic_dir=$(mktemp -d 2>/dev/null)
if [[ -n "$atomic_dir" ]]; then
  atarget="$atomic_dir/config.json"
  printf 'OLD-CONTENT\n' >"$atarget"
  # 源文件必须是【真实存在的路径】！
  # 原来这里直接传字面量 '{"broken":' —— 而 write_config_atomic 的第一步就是
  # `[[ -f "$src" ]]` → 直接把它挡在门外，根本走不到 xray 校验那条路径 →
  # 下面三条断言全是恒真（控制器 P1 实证：把校验失败分支改成【破坏目标文件】，
  # 全部断言仍然全绿、0 条红）。
  printf '{"broken":\n' >"$atomic_dir/broken.json"
  # 本机没有 xray → xray_test_config 必然失败 → 正好走「校验失败」这条路径
  out=$( ( XRAY_BIN="$atomic_dir/no-such-xray"; write_config_atomic "$atarget" "$atomic_dir/broken.json" ) 2>&1 ); rc=$?
  assert_status 1 "$rc" "write_config_atomic 在配置校验失败时返回非零"
  assert_eq "OLD-CONTENT" "$(cat "$atarget")" "write_config_atomic 校验失败时保留原有配置不变"
  if [[ -e "$atarget.new" ]]; then leftover=1; else leftover=0; fi
  assert_eq "0" "$leftover" "write_config_atomic 校验失败时清理临时文件"
  # 校验通过：必须原子替换成新内容（注意 write_config_atomic 收的是【源文件】）
  printf '{"ok":1}\n' >"$atomic_dir/src.json"
  out=$( ( xray_test_config() { return 0; }; write_config_atomic "$atarget" "$atomic_dir/src.json" ) 2>&1 ); rc=$?
  assert_status 0 "$rc" "write_config_atomic 在配置校验通过时返回 0"
  assert_contains "$(cat "$atarget")" '"ok":1' "write_config_atomic 校验通过时替换成新配置"
  # 源文件不存在时必须失败，而不是写出空配置
  # 先把目标文件恢复成 OLD-CONTENT —— 上一条断言已经把它换成新内容了。
  printf 'OLD-CONTENT\n' >"$atarget"
  out=$( ( xray_test_config() { return 0; }; write_config_atomic "$atarget" "$atomic_dir/no-such-file" ) 2>&1 ); rc=$?
  assert_status 1 "$rc" "write_config_atomic 在源文件不存在时返回非零"
  # 源文件不存在时【不得碰目标文件】—— 上面那条只查退出码，
  # 若实现写成「先覆盖目标再校验」，退出码仍可能对，但正式配置已经被毁了。
  assert_eq "OLD-CONTENT" "$(cat "$atarget")" "write_config_atomic 在源文件不存在时不得覆盖目标文件"

  # ── TG3：chmod 必须【早于】mv ──────────────────────────────
  # 计划 T5-6 的修复（chmod 600 写在 mv 之前）此前【零覆盖】——
  # 控制器变异实测：把 chmod 挪回 mv 之后，0 条红。
  # 判据：chmod 失败时【目标文件必须没被动过】。
  printf 'OLD-CONTENT-2\n' >"$atarget"
  out=$( ( chmod() { return 1; }; xray_test_config() { return 0; }
           write_config_atomic "$atarget" "$atomic_dir/src.json" ) 2>&1 ); rc=$?
  assert_status 1 "$rc" "write_config_atomic 在 chmod 失败时返回非零"
  assert_eq "OLD-CONTENT-2" "$(cat "$atarget")" "write_config_atomic 在 chmod 失败时不得落位（chmod 必须早于 mv）"

  # ── TG5：服务端配置必须 chmod 600 ──────────────────────────────
  # 本机（MSYS）的 chmod 是【模拟的】→ 断言文件权限位在本机不可达
  # → 改断言【传给 chmod 的参数】：chmod 600 <最终配置路径> 必须出现过。
  # 必须整行精确匹配：临时文件那次的参数是 "600 $atarget.new"，
  # 它【包含】"600 $atarget" → 用子串匹配会误判成通过。
  chmod_log="$atomic_dir/chmod.log"
  : > "$chmod_log"
  out=$( ( chmod() { printf '%s\n' "$*" >> "$chmod_log"; command chmod "$@"; }
           xray_test_config() { return 0; }
           write_config_atomic "$atarget" "$atomic_dir/src.json" ) 2>&1 ); rc=$?
  assert_status 0 "$rc" "write_config_atomic 在 chmod 可用时正常写入"
  assert_eq "1" "$(grep -Fxc "600 $atarget" "$chmod_log" 2>/dev/null || printf 0)" \
    "write_config_atomic 必须对最终配置文件执行 chmod 600（含 REALITY 私钥）"

  # ── TG4：render 与 write 必须用【不同】的暂存名 ──────────────────────────────
  # 碰撞的后果：render 写的 $outfile.new 会被 write_config_atomic 的 cp 直接覆盖
  # → 被 xray 校验的从来不是渲染出来的那份配置 → 渲染层的校验形同虚设。
  # 做法：mock mv 记录它的【源参数】，分别看两个函数各自用的是哪个后缀。
  mv_log="$atomic_dir/mv.log"
  : > "$mv_log"
  out=$( ( mv() { printf '%s\n' "$*" >> "$mv_log"; command mv "$@"; }
           render_server_config "$atomic_dir/rendered.json" \
             "11111111-2222-3333-4444-555555555555" \
             "PRIVKEY0123456789abcdefghijklmnopqrstuvwxyzABCDE" \
             "www.microsoft.com" "443" "a1b2c3d4" ) 2>&1 ); rc=$?
  assert_status 0 "$rc" "render_server_config 渲染到指定路径成功"
  # 用【子串】匹配而不是整行匹配：mv 的调用形状是 `mv -f <src> <dst>`，
  # mock 记录的是整行参数（"-f <src> <dst>"）→ 整行匹配必然对不上。
  # 两个断言之间日志是清空过的 → 子串匹配不会互相污染。
  assert_eq "1" "$(grep -Fc "$atomic_dir/rendered.json.render" "$mv_log" 2>/dev/null || printf 0)" \
    "render_server_config 的暂存名必须是 .render（不得与 write 的 .new 撞名）"
  : > "$mv_log"
  out=$( ( mv() { printf '%s\n' "$*" >> "$mv_log"; command mv "$@"; }
           xray_test_config() { return 0; }
           write_config_atomic "$atomic_dir/rendered.json" "$atomic_dir/src.json" ) 2>&1 ); rc=$?
  assert_eq "1" "$(grep -Fc "$atomic_dir/rendered.json.new" "$mv_log" 2>/dev/null || printf 0)" \
    "write_config_atomic 的暂存名必须是 .new"

  # ── TG6 + D1：校验失败时必须【原样输出】xray 的真实报错 ──────────────────────────────
  # 旧实现只保留【最后一次】尝试的报错 → 现代 xray 上最后一次用的是旧语法
  # → 必然报 "unknown flag: -test" / "unknown command" → 用户看到的是
  # 完全无关的误导性报错。判据：必须是「配置本身有问题」那条。
  # 假 xray 必须在【本用例的子 shell 内】定义：前一个用例末尾为了不影响后续用例
  # 已经 `unset -f xray` 了 —— 在外面定义等于把假 xray 泄漏给后面的用例。
  # 它模拟「只认 run -test -c 的版本」：第 1 种写法报「写法不被支持」，
  # 第 2 种写法报【真实原因】，第 3 种（旧语法）报「写法不被支持」。
  out=$( ( xray() { case "$3" in
                      -config) printf 'unknown flag: -test\n' >&2; return 1 ;;
                      -c)      printf 'failed to parse config: invalid json\n' >&2; return 1 ;;
                      *)       printf 'unknown command\n' >&2; return 1 ;;
                    esac; }
           XRAY_BIN=xray
           write_config_atomic "$atarget" "$atomic_dir/broken.json" ) 2>&1 ); rc=$?
  assert_status 1 "$rc" "write_config_atomic 在配置校验失败时返回非零"
  assert_contains "$out" "failed to parse config" \
    "write_config_atomic 必须输出 xray 的真实报错（而不是『写法不被支持』那类）"
  # 「原样输出」的判据：xray 的报错必须【整行原样】出现。
  # 只断言「包含某子串」是不够的 —— 早先的实现给每行加了 6 个空格的前缀，
  # 子串照样包含 → 那条断言恒绿、钉不住 D4。
  # 整行精确匹配才能区分「原样」与「加了缩进」。
  assert_eq "1" "$(printf '%s\n' "$out" | grep -Fxc "failed to parse config: invalid json" 2>/dev/null || printf 0)" \
    "write_config_atomic 必须【原样】输出 xray 的报错（不得加缩进或改写）"
  case "$out" in
    *"unknown flag"*|*"unknown command"*) misled=1 ;;
    *) misled=0 ;;
  esac
  assert_eq "0" "$misled" "write_config_atomic 不得输出『写法不被支持』这类误导性报错"

  # ── D2：目标路径是【已存在的目录】时必须报错 ──────────────────────────────
  # `mv -f "$tmp" "$outfile"` 在 outfile 是目录时会把文件【移进目录里】
  # → mv 返回 0（看起来成功）但配置根本没落到 outfile。
  mkdir -p "$atomic_dir/asdir"
  out=$( ( xray_test_config() { return 0; }
           write_config_atomic "$atomic_dir/asdir" "$atomic_dir/src.json" ) 2>&1 ); rc=$?
  assert_status 1 "$rc" "write_config_atomic 在目标路径是目录时返回非零"
  assert_contains "$out" "目录" "write_config_atomic 在目标路径是目录时给出明确提示"

  # ── D3：cp 失败必须清理半截的临时文件 ──────────────────────────────
  out=$( ( cp() { printf 'PARTIAL\n' >"$atarget.new"; return 1; }
           write_config_atomic "$atarget" "$atomic_dir/src.json" ) 2>&1 ); rc=$?
  assert_status 1 "$rc" "write_config_atomic 在 cp 失败时返回非零"
  if [[ -e "$atarget.new" ]]; then leftover=1; else leftover=0; fi
  assert_eq "0" "$leftover" "write_config_atomic 在 cp 失败时清理半截的临时文件"
else
  assert_eq "mktemp -d 能创建唯一临时目录" "失败（mktemp -d 返回空路径）" \
    "write_config_atomic 用例前提：mktemp -d 必须能创建唯一临时目录"
fi
rm -rf "$atomic_dir"

test_case "deploy 系统操作的可测分支"

# ── xray_installed：未安装返回非零，已安装返回 0 ──────────────
# 必须【1 换 1 配对】：真实 Debian 上装好 xray 后 `[[ ! -x "$XRAY_BIN" ]]` 为假
# → 原来的写法会让这条断言【整条消失】→ 断言条数随机器状态漂移（见全局约束）。
if [[ ! -x "$XRAY_BIN" ]]; then
  assert_fails "未安装时 xray_installed 返回非零" xray_installed
else
  assert_succeeds "已安装时 xray_installed 返回 0" xray_installed
fi

# ── xray_version：必须输出 xray 的版本串 ──────────────
# 用 shell 函数当假 xray（MSYS 的 chmod 位不可靠，造可执行脚本 + chmod +x 不稳）。
out=$( ( XRAY_BIN=xrayv; xrayv() { printf 'Xray 1.8.0 (Xray, Penetrates Everything.) Custom\n'; }; xray_version 2>&1 ) )
assert_contains "$out" "Xray 1.8.0" "xray_version 输出 xray 的版本串"

# ── install_xray：已安装时不得重复安装 ──────────────
out=$( ( XRAY_BIN=/nonexistent/xray; xray_installed() { return 0; }
         xray_version() { printf 'Xray 1.8.0\n'; }; install_xray 2>&1 ) ); rc=$?
assert_status 0 "$rc" "install_xray 在已安装时返回 0"
assert_contains "$out" "已安装" "install_xray 在已安装时给出提示"

# ── install_xray：下载安装包失败必须返回非零（不得谎报已安装）──
# ensure_packages 与 curl 都必须 mock：前者会真的调 apt-get，后者会真的联网。
# 注意：新版 install_xray 不再下载「上游安装脚本」，而是直接取 release 压缩包；
#      彻底失败时必须给出【可操作】的三条解法，而不是让人去「检查网络」。
out=$( ( XRAY_BIN=/nonexistent/xray; xray_installed() { return 1; }
         ensure_packages() { return 0; }; curl() { return 22; }
         install_xray 2>&1 ) ); rc=$?
assert_status 1 "$rc" "install_xray 在下载安装包失败时返回非零"
assert_contains "$out" "无法下载 Xray 安装包" "install_xray 下载失败时给出明确提示"
assert_contains "$out" "--proxy" "install_xray 下载失败时提示代理走法"
assert_contains "$out" "--mirror" "install_xray 下载失败时提示镜像走法"
assert_contains "$out" "--local" "install_xray 下载失败时提示离线包走法"
# 注意：assert_false 的语义是「退出码非 0」，【没有】「子串不存在」这个语义。
# 三参用法会把第 2 个参数当成描述 → 这条断言恒真（控制器核对 test/lib.sh 后发现）。
# 「子串必须不存在」必须自己判断再断言。
if [[ "$out" == *"Xray 安装完成"* ]]; then lied=1; else lied=0; fi
assert_eq "0" "$lied" "install_xray 下载失败时不得谎报『Xray 安装完成』"

# ── setup_systemd：服务未运行时必须返回非零并输出 xray 的原始日志 ──────────────
# systemctl / journalctl / tui_run 全部 mock：绝不能真的动宿主机的 systemd。
out=$( ( have_cmd() { return 0; }; tui_run() { return 0; }
         systemctl() { return 3; }
         journalctl() { printf 'xray: Failed to start.\n'; }
         service_run_user() { printf 'root'; }
         setup_systemd 2>&1 ) ); rc=$?
assert_status 1 "$rc" "setup_systemd 在服务未运行时返回非零"
assert_contains "$out" "xray 服务未能启动" "setup_systemd 失败时给出明确提示"
assert_contains "$out" "xray: Failed to start." "setup_systemd 失败时输出 xray 的原始日志"

# ── setup_systemd：服务正常运行时返回 0 ──────────────
out=$( ( have_cmd() { return 0; }; tui_run() { return 0; }
         systemctl() { return 0; }
         service_run_user() { printf 'root'; }
         setup_systemd 2>&1 ) ); rc=$?
assert_status 0 "$rc" "setup_systemd 在服务正常运行时返回 0"

# ── restart_service：服务未运行时必须返回非零 ──────────────
out=$( ( tui_run() { return 0; }; systemctl() { return 3; }
         journalctl() { printf 'xray: Failed to start.\n'; }
         restart_service 2>&1 ) ); rc=$?
assert_status 1 "$rc" "restart_service 在服务未运行时返回非零"
assert_contains "$out" "未处于运行状态" "restart_service 失败时给出明确提示"

# ── restart_service：服务正常运行时返回 0 ──────────────
out=$( ( tui_run() { return 0; }; systemctl() { return 0; }
         restart_service 2>&1 ) ); rc=$?
assert_status 0 "$rc" "restart_service 在服务正常运行时返回 0"

# ── service_status：必须打印服务状态与端口监听情况 ──────────────
out=$( ( have_cmd() { return 0; }
         systemctl() { case "$1" in
                         is-active)  printf 'active\n'; return 0 ;;
                         is-enabled) printf 'enabled\n'; return 0 ;;
                       esac; return 0; }
         xray_version() { printf 'Xray 1.8.0\n'; }
         port_in_use() { return 1; }
         PORT=8443
         service_status 2>&1 ) )
assert_contains "$out" "服务状态" "service_status 打印服务状态"
assert_contains "$out" "active" "service_status 显示服务是否在运行"
assert_contains "$out" "8443" "service_status 显示端口监听情况"
assert_contains "$out" "开机自启" "service_status 显示开机自启状态"

# ── enable_bbr 在不支持 bbr 的内核上必须安全失败而非崩溃 ──────────────
# 必须 mock 掉 sysctl 走「不支持 bbr」分支：真实调用会写
# /etc/sysctl.d/99-vless-reality-bbr.conf 并 `sysctl -p` 立即应用，
# 那是单元测试不该有的主机副作用（CI 上会真的改掉运行内核的拥塞控制）。
# 断言必须点【具体文案】而不是「提及 bbr」—— 成功路径的输出里也有 bbr，
# 断言「提及 bbr」在两条路径上都成立 → 恒绿、没有判别力。
out=$( ( sysctl() { printf 'cubic\n'; }; enable_bbr 2>&1 ) ) || true
assert_contains "$out" "未提供 bbr" "enable_bbr 在内核不支持 bbr 时明确说明"
assert_contains "$out" "可用算法" "enable_bbr 在内核不支持 bbr 时提示可用算法"

# ── open_firewall 在无任何防火墙工具时必须明确告知而不是静默成功 ──────────────
# 必须【1 换 1 配对】：真实 Debian 上一定有 iptables 或 nft → 原来的写法会让
# 这条断言【整条消失】→ 断言条数随机器状态漂移（见全局约束）。
if ! have_cmd ufw && ! have_cmd nft && ! have_cmd iptables; then
  out=$(open_firewall 443 2>&1) || true
  assert_contains "$out" "防火墙" "无防火墙工具时给出明确提示"
else
  assert_eq "本机存在防火墙工具" "本机存在防火墙工具" \
    "无防火墙工具的用例已跳过（本机存在 ufw / nft / iptables，用例前提不成立）"
fi

# open_firewall：ufw 分支必须真的调用 ufw allow 且把失败码传出去。
# 用 mock 捕获 tui_run 的命令，【不碰真实防火墙】。
out=$( ( have_cmd() { case "$1" in ufw) return 0 ;; iptables|nft) return 1 ;; *) return 1 ;; esac; }
            ufw() { printf 'Status: active\n'; }
            tui_run() { printf '%s\n' "$*"; return 0; }
            open_firewall 8443 2>&1 ) )
assert_contains "$out" "放行端口 8443/tcp (ufw)" "open_firewall 的 ufw 分支被走到（必须真的调用 ufw allow）"
if [[ "$out" == *"未检测到 ufw"* ]]; then bailed=1; else bailed=0; fi
assert_eq "0" "$bailed" "open_firewall 不得退化成『未检测到防火墙』（ufw 分支）"
out=$( ( have_cmd() { case "$1" in ufw) return 0 ;; iptables|nft) return 1 ;; *) return 1 ;; esac; }
            ufw() { printf 'Status: active\n'; }
            tui_run() { return 7; }
            open_firewall 8443 >/dev/null 2>&1 ) ); rc=$?
assert_status 7 "$rc" "open_firewall 必须把防火墙命令的失败码传出去（不得静默成功）"

# enable_bbr 的成功路径：配置路径由环境变量覆盖 → 不碰宿主机内核参数。
# （原来的成功路径根本没法测：一写就是真的改宿主机拥塞控制。）
bbr_dir=$(mktemp -d 2>/dev/null)
if [[ -n "$bbr_dir" ]]; then
  out=$( ( sysctl() { case "$1" in -n) printf 'bbr cubic\n' ;; *) return 0 ;; esac; }
            VLESS_REALITY_SYSCTL_CONF="$bbr_dir/99-bbr.conf"; enable_bbr 2>&1 ) ); rc=$?
  assert_status 0 "$rc" "enable_bbr 在支持 bbr 时返回 0"
  assert_contains "$(cat "$bbr_dir/99-bbr.conf" 2>/dev/null)" 'tcp_congestion_control = bbr' "enable_bbr 写入 bbr 配置"
  # 写不进去时必须返回非零并明确报错（不得谎报「已启用」）
  out=$( ( sysctl() { case "$1" in -n) printf 'bbr cubic\n' ;; *) return 0 ;; esac; }
            VLESS_REALITY_SYSCTL_CONF="$bbr_dir/no-such-dir/99-bbr.conf"; enable_bbr 2>&1 ) ); rc=$?
  assert_status 1 "$rc" "enable_bbr 在无法写入 sysctl 配置时返回非零"
  if [[ "$out" == *"已启用 bbr"* ]]; then lied=1; else lied=0; fi
  assert_eq "0" "$lied" "enable_bbr 写失败时不得谎报『已启用 bbr』"

  # ── 内核参数【应用】失败（sysctl -p / --system 都失败）必须返回非零 ──────────────
  # 原来只测了「配置写不进去」，没测「配置写进去了但内核参数应用失败」
  # → 那条分支根本没被执行到（控制器第二轮变异实证：删掉它，0 条红）。
  out=$( ( sysctl() { case "$1" in
                        -n) printf 'bbr cubic\n' ;;
                        *) return 1 ;;
                      esac; }
              VLESS_REALITY_SYSCTL_CONF="$bbr_dir/99-bbr.conf"; enable_bbr 2>&1 ) ); rc=$?
  assert_status 1 "$rc" "enable_bbr 在内核参数应用失败时返回非零"
  assert_contains "$out" "内核参数应用失败" "enable_bbr 在 sysctl 应用失败时给出明确报错"
else
  assert_eq "mktemp -d 能创建唯一临时目录" "失败（mktemp -d 返回空路径）" \
    "enable_bbr 用例前提：mktemp -d 必须能创建唯一临时目录"
fi
rm -rf "$bbr_dir"
# ── T6-9（F4-1 同款）：open_firewall 的 ufw 状态检测不得把 grep -q 直接接在管道上 ──────────────
# 为什么必须是【源码静态断言】而不是运行期断言：
# 「管道 + grep -q」在【小输出】下不会触发 SIGPIPE —— mock 的 ufw 只输出一行
# → 写不进管道缓冲 → 上游不会收到 SIGPIPE(141) → 运行期根本复现不出差异。
# 控制器第二轮变异实证：把 ufw 检测改回 `| grep -q` 形态 → 0 条红。
# 真实 `ufw status` 的输出要超过管道缓冲（约 8KB）且是否触发取决于时序
# → 不能写成依赖时序的运行期断言。权威判据是这条静态断言（与 Task 4 的 F4-1 同款）。
open_firewall_body="$(awk '/^open_firewall\(\) *\{/,/^\}/' "$ROOT/lib/deploy.sh")"
if [[ -n "$open_firewall_body" ]]; then rc=0; else rc=1; fi
assert_true "$rc" \
  "deploy.sh 里必须存在 open_firewall 函数（下面那条静态断言的前提）"
# 检查前必须先去掉整行注释：函数的说明性注释里会写「不能写成 ufw status | grep -q」
# 这类字样 —— 那是【说明】不是【代码】，不去掉会把自己判成违规（Task 4 实测踩过）。
open_firewall_code="$(printf '%s\n' "$open_firewall_body" | grep -v '^[[:space:]]*#')"
assert_eq "" "$(printf '%s\n' "$open_firewall_code" | grep -n 'ufw status.*grep[ \t]*-q' | tr '\n' ' ')" \
  "open_firewall 的 ufw 状态检测不得把 grep -q 直接接在管道上（SIGPIPE 会把 141 带进退出码）"
# 正向钉住修法本身：必须先把输出收进变量，再对变量做匹配。
# open_firewall 里【另有】一处合法的 `nft list chain ... | grep -q`（那是「内容里
# 有没有这条规则」的查询，命中与否两条路都走到 then/else，退出码 1 与 141 后果相同
# → 不属于 F4-1 同款缺陷）→ 所以上面那条只针对含 "ufw status" 的行，不误伤。
assert_contains "$open_firewall_code" 'ufw_status=$(ufw status' \
  "open_firewall 的 ufw 状态检测必须先把输出收进变量再匹配"

# ── T6-10：setup_systemd 的「运行用户不是 root」分支之前根本没被执行到 ──────────────
# 原来的 mock 里 service_run_user 恒返回 root → `run_user != "root"` 分支永远进不去
# → mkdir 的退出码检查就永远测不到（控制器第二轮变异实证：删掉它，0 条红）。
out=$( ( have_cmd() { return 0; }; tui_run() { return 0; }
         systemctl() { return 0; }
         service_run_user() { printf 'xray'; }
         mkdir() { return 1; }
         setup_systemd 2>&1 ) ); rc=$?
assert_status 0 "$rc" "setup_systemd 在日志目录创建失败时仍正常返回（只是警告）"
assert_contains "$out" "无法创建日志目录" "setup_systemd 在 mkdir 失败时给出明确警告"
if [[ "$out" == *"日志目录已授权"* ]]; then lied=1; else lied=0; fi
assert_eq "0" "$lied" "setup_systemd 在 mkdir 失败时不得谎报『日志目录已授权』"

# ── setup_systemd：非 root 运行用户 + 目录创建成功 → 必须给出授权提示 ──────────────
out=$( ( have_cmd() { return 0; }; tui_run() { return 0; }
         systemctl() { return 0; }
         service_run_user() { printf 'xray'; }
         mkdir() { return 0; }
         id() { return 0; }
         chown() { return 0; }
         setup_systemd 2>&1 ) ); rc=$?
assert_status 0 "$rc" "setup_systemd 在非 root 运行用户下正常返回"
assert_contains "$out" "日志目录已授权给运行用户 xray" "setup_systemd 在目录创建成功时给出授权提示"

# ── setup_systemd：没有 systemctl 时必须明确报错 ──────────────
out=$( ( have_cmd() { case "$1" in systemctl) return 1 ;; *) return 0 ;; esac; }
         setup_systemd 2>&1 ) ); rc=$?
assert_status 1 "$rc" "setup_systemd 在没有 systemctl 时返回非零"
assert_contains "$out" "systemd 不可用" "setup_systemd 在没有 systemctl 时给出明确提示"

# ── install_xray：下载与安装都成功时必须返回 0 并提示完成 ──────────────
# 新版 install_xray 的链路是「取包 → 装包」，两步都得 mock：
#   xray_fetch_release_zip  取包（会真的联网）
#   xray_install_from_zip   装包（会真的往 /usr/local/bin 写二进制）
out=$( ( XRAY_BIN=/nonexistent/xray
         xray_installed() { return 1; }
         ensure_packages() { return 0; }
         xray_fetch_release_zip() { XRAY_FETCHED_ZIP=/tmp/fake-xray.zip; XRAY_FETCHED_TMPDIR=/tmp/fake-xray-dir; return 0; }
         xray_install_from_zip() { return 0; }
         xray_version() { printf 'Xray 1.8.0\n'; }
         install_xray 2>&1 ) ); rc=$?
assert_status 0 "$rc" "install_xray 在下载与安装都成功时返回 0"
assert_contains "$out" "Xray 安装完成" "install_xray 成功时提示安装完成"

# ── install_xray：mktemp 失败时必须给出明确提示，不得把错误指向「网络」 ──────────────
out=$( ( XRAY_BIN=/nonexistent/xray
         xray_installed() { return 1; }
         ensure_packages() { return 0; }
         mktemp() { return 1; }
         curl() { return 0; }
         install_xray 2>&1 ) ); rc=$?
assert_status 1 "$rc" "install_xray 在 mktemp 失败时返回非零"
assert_contains "$out" "无法创建临时目录" "install_xray 在 mktemp 失败时给出明确提示"

# ── open_firewall：iptables 分支 ──────────────
# 判据必须点【该分支独有的东西】：「iptables」这三个字在兜底提示
# （「未检测到 ufw / iptables / nftables」）里也出现、「8443」在
# 「请自行放行端口：8443/tcp」里也出现 → 用它们当判据是**恒真的**
# （控制器探针实测：把整个 iptables 分支删掉，只有「识别出规则已存在」那条变红，
#   「被走到」「带上了端口」两条仍然绿）。
out=$( ( have_cmd() { case "$1" in iptables) return 0 ;; ufw|nft) return 1 ;; *) return 1 ;; esac; }
            iptables() { return 1; }
            tui_run() { printf '%s\n' "$*"; return 0; }
            open_firewall 8443 2>&1 ) )
assert_contains "$out" "放行端口 8443/tcp (iptables)" "open_firewall 的 iptables 分支被走到（必须真的调用 iptables -I）"
if [[ "$out" == *"未检测到 ufw"* ]]; then bailed=1; else bailed=0; fi
assert_eq "0" "$bailed" "open_firewall 不得退化成『未检测到防火墙』（iptables 分支）"
out=$( ( have_cmd() { case "$1" in iptables) return 0 ;; ufw|nft) return 1 ;; *) return 1 ;; esac; }
            iptables() { return 0; }
            tui_run() { printf '%s\n' "$*"; return 0; }
            open_firewall 8443 2>&1 ) )
assert_contains "$out" "iptables 规则已存在" "open_firewall 的 iptables 分支识别出规则已存在"

# ── open_firewall：nftables 分支 ──────────────
# nft 的 list 子命令返回非零 → 规则不存在 → 走 tui_run 插入规则的分支。
# ⚠️ 这三条断言原先全是**恒真的**：把整个 nftables 分支删掉，0 条红
# （控制器探针实测）—— 因为「nftables」「8443」在兜底提示里也出现。
out=$( ( have_cmd() { case "$1" in nft) return 0 ;; ufw|iptables) return 1 ;; *) return 1 ;; esac; }
            nft() { case "$1" in
                      list) return 1 ;;
                      *) return 0 ;;
                    esac; }
            tui_run() { printf '%s\n' "$*"; return 0; }
            open_firewall 8443 2>&1 ) )
assert_contains "$out" "放行端口 8443/tcp (nftables)" "open_firewall 的 nftables 分支被走到（必须真的插入 nft 规则）"
if [[ "$out" == *"未检测到 ufw"* ]]; then bailed=1; else bailed=0; fi
assert_eq "0" "$bailed" "open_firewall 不得退化成『未检测到防火墙』（nftables 分支）"

test_case "分享链接与客户端配置"

# 有效的入参（必须能通过 render_client_config 的白名单校验）：
#   UUID 规范形态 / 端口 1-65535 / 公钥 base64url 40-64 / ShortID 十六进制 2-16 /
#   SNI 合法主机名 / IP 合法。
# 原来的用例用的是 "UUID123" / "PUBKEY" 这类占位串 —— 加了白名单之后它们会被拒绝，
# 所以这里统一换成【真值】。
T7_UUID='11111111-2222-3333-4444-555555555555'
T7_IP='1.2.3.4'
T7_PORT='443'
T7_SNI='www.microsoft.com'
T7_PUB='PRIVKEY0123456789abcdefghijklmnopqrstuvwxyzABCDE'
T7_SID='a1b2c3d4'
T7_REMARK='我的节点'

link=$(build_share_link "$T7_UUID" "$T7_IP" "$T7_PORT" "$T7_SNI" "$T7_PUB" "$T7_SID" "$T7_REMARK")
assert_contains "$link" "vless://$T7_UUID@$T7_IP:$T7_PORT" "链接含协议与地址"
assert_contains "$link" "encryption=none" "链接含 encryption"
assert_contains "$link" "flow=xtls-rprx-vision" "链接含 flow"
assert_contains "$link" "security=reality" "链接含 security=reality"
assert_contains "$link" "sni=$T7_SNI" "链接含 sni"
assert_contains "$link" "fp=chrome" "链接含指纹"
assert_contains "$link" "pbk=$T7_PUB" "链接含公钥 pbk"
assert_contains "$link" "sid=$T7_SID" "链接含 shortId"
assert_contains "$link" "type=tcp" "链接含传输协议"
assert_contains "$link" "%E6%88%91%E7%9A%84%E8%8A%82%E7%82%B9" "备注被 URL 编码"

# IPv6 地址在分享链接里必须加方括号，否则客户端导入即废。
link6=$(build_share_link "$T7_UUID" "2001:db8::1" "$T7_PORT" "$T7_SNI" "$T7_PUB" "$T7_SID" "v6")
assert_contains "$link6" "@[2001:db8::1]:$T7_PORT" "IPv6 地址在分享链接里加了方括号"

# ── FLOW / FINGERPRINT 是【全局状态】，不能被写死 ──────────────
# 变异实测：把 ${FLOW:-…} / ${FINGERPRINT:-…} 换成字面量 → 0 条红。
_saved_flow="${FLOW:-}"; _saved_fp="${FINGERPRINT:-}"
FLOW='xtls-rprx-vision-alt'; FINGERPRINT='firefox'
linkg=$(build_share_link "$T7_UUID" "$T7_IP" "$T7_PORT" "$T7_SNI" "$T7_PUB" "$T7_SID" "$T7_REMARK")
assert_contains "$linkg" "flow=xtls-rprx-vision-alt" "build_share_link 使用全局 FLOW 而不是写死"
assert_contains "$linkg" "fp=firefox" "build_share_link 使用全局 FINGERPRINT 而不是写死"
FLOW="$_saved_flow"; FINGERPRINT="$_saved_fp"

# 同上：mktemp 失败时路径为空会写出 ".render" 污染仓库 → 必须守卫。
ccfg=$(mktemp)
if [[ -z "$ccfg" ]]; then
  assert_eq "mktemp 能创建临时文件" "失败（mktemp 返回空路径）" "客户端渲染用例前提：mktemp 必须可用"
else
render_client_config "$ccfg" "$T7_UUID" "$T7_IP" "$T7_PORT" "$T7_SNI" "$T7_PUB" "$T7_SID" >/dev/null
# 判活用【功能可用】而不是 have_cmd（见 Task 5 处的同一条说明）。
if python3 -c 'import json' >/dev/null 2>&1; then
  assert_status 0 "$(python3 -c "import json,sys;json.load(open(sys.argv[1]));print(0)" "$ccfg" 2>/dev/null || echo 1)" "客户端配置是合法 JSON"
else
  # 同 Task 5：python3 不可用不是缺陷，只登记一条说明以保持条数恒定。
  assert_eq "python3 功能不可用" "python3 功能不可用" \
    "python3 功能探测未通过：客户端 JSON 合法性校验已跳过（条数保持恒定）"
fi
assert_contains "$(cat "$ccfg")" '"port": 1080' "客户端含 socks 入站 1080"
assert_contains "$(cat "$ccfg")" '"port": 1081' "客户端含 http 入站 1081"
assert_contains "$(cat "$ccfg")" '"publicKey": "'"$T7_PUB"'"' "客户端含公钥"
assert_contains "$(cat "$ccfg")" '"serverName": "'"$T7_SNI"'"' "客户端含 serverName"
assert_contains "$(cat "$ccfg")" '"fingerprint": "chrome"' "客户端含 fingerprint"
assert_contains "$(cat "$ccfg")" '"id": "'"$T7_UUID"'"' "客户端含 UUID"

# ── 注入面：未加引号的 heredoc 会【执行】入参里的 $(...) / 反引号 ──────────────
# 控制器实证：把 '$(echo PWNED_UUID)' 传进 UUID、'`echo PWNED_SNI`' 传进 SNI、
# '$(echo PWNED_PUB)' 传进公钥 —— 三个都被【真实执行】，执行结果被写进了 client.json。
# 非法端口（"443; id"）还会把 JSON 【直接写坏】→ 客户端拿到的是废文件。
# 处置：函数自身加白名单校验（Step 3），入参不合法时返回 1 且【不落盘】。
rc=0
render_client_config "$ccfg.inj.uuid" '$(echo PWNED_UUID)' "$T7_IP" "$T7_PORT" "$T7_SNI" "$T7_PUB" "$T7_SID" >/dev/null 2>&1 || rc=$?
assert_status 1 "$rc" "render_client_config 拒绝含命令替换的 UUID"
rc=0
render_client_config "$ccfg.inj.sni" "$T7_UUID" "$T7_IP" "$T7_PORT" 'x$(echo PWNED_SNI).com' "$T7_PUB" "$T7_SID" >/dev/null 2>&1 || rc=$?
assert_status 1 "$rc" "render_client_config 拒绝含命令替换的 SNI"
rc=0
render_client_config "$ccfg.inj.pub" "$T7_UUID" "$T7_IP" "$T7_PORT" "$T7_SNI" '$(echo PWNED_PUB)' "$T7_SID" >/dev/null 2>&1 || rc=$?
assert_status 1 "$rc" "render_client_config 拒绝含命令替换的公钥"
rc=0
render_client_config "$ccfg.inj.port" "$T7_UUID" "$T7_IP" '443; id' "$T7_SNI" "$T7_PUB" "$T7_SID" >/dev/null 2>&1 || rc=$?
assert_status 1 "$rc" "render_client_config 拒绝非法端口"
rc=0
render_client_config "$ccfg.inj.sid" "$T7_UUID" "$T7_IP" "$T7_PORT" "$T7_SNI" "$T7_PUB" 'zz; id' >/dev/null 2>&1 || rc=$?
assert_status 1 "$rc" "render_client_config 拒绝含命令替换的 ShortID"
# IP 也是【未加引号的 heredoc】的一部分 → 同样能被执行 → 必须也走白名单。
rc=0
render_client_config "$ccfg.inj.ip" "$T7_UUID" '$(echo PWNED_IP)' "$T7_PORT" "$T7_SNI" "$T7_PUB" "$T7_SID" >/dev/null 2>&1 || rc=$?
assert_status 1 "$rc" "render_client_config 拒绝含命令替换的 IP"
# 拒绝时【不得落盘】：否则半截/被污染的配置会留在磁盘上。
if [[ -e "$ccfg.inj.uuid" || -e "$ccfg.inj.port" || -e "$ccfg.inj.ip" ]]; then leaked=1; else leaked=0; fi
assert_eq "0" "$leaked" "render_client_config 拒绝非法入参时不得落盘"

# ── 目标路径是【已存在的目录】时必须报错（mv 会把文件移进目录里）──────────────
mkdir -p "$ccfg.dir"
out=$(render_client_config "$ccfg.dir" "$T7_UUID" "$T7_IP" "$T7_PORT" "$T7_SNI" "$T7_PUB" "$T7_SID" 2>&1); rc=$?
assert_status 1 "$rc" "render_client_config 在目标路径是目录时返回非零"
assert_contains "$out" "目录" "render_client_config 在目标路径是目录时给出明确提示"

# ── 目标目录不存在时必须给出【我们自己的】提示（而不是裸的 bash 报错）────────────
out=$(render_client_config "$ccfg.d/no-such-dir/client.json" "$T7_UUID" "$T7_IP" "$T7_PORT" "$T7_SNI" "$T7_PUB" "$T7_SID" 2>&1); rc=$?
assert_status 1 "$rc" "render_client_config 在目标目录不存在时返回非零"
assert_contains "$out" "无法写入配置暂存文件" "render_client_config 在目标目录不存在时给出自己的错误提示（而不是裸的 bash 报错）"

# ── chmod 必须【早于】mv ──────────────
# 权限设置失败时文件已经落位 → 函数返回非零但磁盘上多了一份权限不对的配置。
out=$( ( chmod() { return 1; }; render_client_config "$ccfg.perm" "$T7_UUID" "$T7_IP" "$T7_PORT" "$T7_SNI" "$T7_PUB" "$T7_SID" 2>&1 ) ); rc=$?
assert_status 1 "$rc" "render_client_config 在 chmod 失败时返回非零"
if [[ -e "$ccfg.perm" ]]; then landed=1; else landed=0; fi
assert_eq "0" "$landed" "render_client_config 在 chmod 失败时不得落位（chmod 必须早于 mv）"

# ── mv 失败必须报错（不得静默成功）──────────────
out=$( ( mv() { return 1; }; render_client_config "$ccfg.mvf" "$T7_UUID" "$T7_IP" "$T7_PORT" "$T7_SNI" "$T7_PUB" "$T7_SID" 2>&1 ) ); rc=$?
assert_status 1 "$rc" "render_client_config 在 mv 失败时返回非零"
assert_contains "$out" "无法写入客户端配置" "render_client_config 在 mv 失败时给出明确提示"

# ── 内部暂存名必须是 .render（不得与 write_config_atomic 的 .new 撞名）────────────
mv_log="$ccfg.mvlog"
: > "$mv_log"
out=$( ( mv() { printf '%s\n' "$*" >> "$mv_log"; command mv "$@"; }
         render_client_config "$ccfg.mv" "$T7_UUID" "$T7_IP" "$T7_PORT" "$T7_SNI" "$T7_PUB" "$T7_SID" 2>&1 ) ); rc=$?
assert_status 0 "$rc" "render_client_config 渲染到指定路径成功"
assert_eq "1" "$(grep -Fc "$ccfg.mv.render" "$mv_log" 2>/dev/null || printf 0)" \
  "render_client_config 的暂存名必须是 .render（不得与 write_config_atomic 的 .new 撞名）"

rm -f "$ccfg" "$ccfg.inj.uuid" "$ccfg.inj.sni" "$ccfg.inj.pub" "$ccfg.inj.port" "$ccfg.inj.sid" \
      "$ccfg.inj.ip" "$ccfg.perm" "$ccfg.mv" "$ccfg.mvlog" "$ccfg.mvf"
rm -rf "$ccfg.dir"
fi

test_case "客户端物料导出"

# export_client_artifacts 此前【几乎没有测试】—— 而它正是产出分享链接的函数。
exp_dir=$(mktemp -d 2>/dev/null)
if [[ -n "$exp_dir" ]]; then
  out=$( export_client_artifacts "$exp_dir" "$T7_UUID" "$T7_IP" "$T7_PORT" "$T7_SNI" "$T7_PUB" "$T7_SID" "$T7_REMARK" 2>&1 ); rc=$?
  assert_status 0 "$rc" "export_client_artifacts 成功返回 0"
  assert_contains "$(cat "$exp_dir/link.txt" 2>/dev/null)" "vless://$T7_UUID@$T7_IP:$T7_PORT" "link.txt 含分享链接"
  assert_contains "$(cat "$exp_dir/client.txt" 2>/dev/null)" "UUID: $T7_UUID" "client.txt 含 UUID"
  # 备注不出现在 client.txt 的明文字段里（只作为分享链接的 fragment，URL 编码后出现）
  assert_contains "$(cat "$exp_dir/client.txt" 2>/dev/null)" "%E6%88%91%E7%9A%84%E8%8A%82%E7%82%B9" "client.txt 的分享链接里备注被 URL 编码"
  if [[ -s "$exp_dir/client.json" ]]; then jf=1; else jf=0; fi
  assert_eq "1" "$jf" "client.json 已生成且非空"

  # ── client.txt 里显示的 flow / fp 必须与实际配置一致 ──────────────
  # 原来这里写死了 "xtls-rprx-vision" / "chrome" → 与 build_share_link 用的全局状态
  # 可能不一致 → 用户照着显示的值排查会查错方向。
  _saved_flow="${FLOW:-}"; _saved_fp="${FINGERPRINT:-}"
  FLOW='xtls-rprx-vision-alt'; FINGERPRINT='firefox'
  out=$( export_client_artifacts "$exp_dir/g" "$T7_UUID" "$T7_IP" "$T7_PORT" "$T7_SNI" "$T7_PUB" "$T7_SID" "$T7_REMARK" 2>&1 ); rc=$?
  assert_status 0 "$rc" "export_client_artifacts 在自定义 flow/fp 时成功"
  assert_contains "$(cat "$exp_dir/g/client.txt" 2>/dev/null)" "流控 (flow): xtls-rprx-vision-alt" "client.txt 显示的流控与全局状态一致"
  assert_contains "$(cat "$exp_dir/g/client.txt" 2>/dev/null)" "指纹 (fp): firefox" "client.txt 显示的指纹与全局状态一致"
  assert_contains "$(cat "$exp_dir/g/client.json" 2>/dev/null)" '"flow": "xtls-rprx-vision-alt"' "client.json 的流控与全局状态一致"
  assert_contains "$(cat "$exp_dir/g/client.json" 2>/dev/null)" '"fingerprint": "firefox"' "client.json 的指纹与全局状态一致"
  FLOW="$_saved_flow"; FINGERPRINT="$_saved_fp"

  # ── 二维码：缺 qrencode 时明确告知；有 qrencode 时真的生成文件 ──────────────
  out=$( ( have_cmd() { case "$1" in qrencode) return 1 ;; *) return 0 ;; esac; }
           export_client_artifacts "$exp_dir/noqr" "$T7_UUID" "$T7_IP" "$T7_PORT" "$T7_SNI" "$T7_PUB" "$T7_SID" "$T7_REMARK" 2>&1 ) ); rc=$?
  assert_status 0 "$rc" "export_client_artifacts 在没有 qrencode 时仍然成功"
  assert_contains "$out" "未安装 qrencode" "export_client_artifacts 在没有 qrencode 时明确告知"
  out=$( ( have_cmd() { case "$1" in qrencode) return 0 ;; *) return 0 ;; esac; }
           qrencode() { local prev='' a; for a in "$@"; do
                          if [[ "$prev" == "-o" ]]; then printf 'QR' > "$a"; fi
                          prev="$a"; done; return 0; }
           export_client_artifacts "$exp_dir/qr" "$T7_UUID" "$T7_IP" "$T7_PORT" "$T7_SNI" "$T7_PUB" "$T7_SID" "$T7_REMARK" 2>&1 ) ); rc=$?
  assert_status 0 "$rc" "export_client_artifacts 在有 qrencode 时成功"
  if [[ -s "$exp_dir/qr/qrcode.png" ]]; then q1=1; else q1=0; fi
  assert_eq "1" "$q1" "export_client_artifacts 在有 qrencode 时生成 PNG 二维码"
  if [[ -s "$exp_dir/qr/qrcode.txt" ]]; then q2=1; else q2=0; fi
  assert_eq "1" "$q2" "export_client_artifacts 在有 qrencode 时生成终端二维码"

  # ── 四条失败路径：每一条都必须返回非零并给出自己的提示 ──────────────
  # 全局约束：所有失败路径必须以非零退出码结束，且经 tui_err 输出。
  #
  # ⚠️ mock 的写法很关键（控制器实测踩过坑）：
  #   · mkdir 的 mock 必须【真的把目录建出来】再返回失败 —— 否则目录不存在 →
  #     后面 chmod 也会失败 → 函数照样返回非零 → 「返回非零」那条断言恒绿，
  #     真正变红的只有「给出明确提示」那条（判别力落空）。
  #   · chmod 的 mock 必须【只对 700 失败】—— 否则 render_client_config 内部的
  #     chmod 600 也会失败 → 提前从别的分支返回非零 → 同样把「返回非零」那条
  #     断言变成恒绿。
  out=$( ( mkdir() { command mkdir "$@"; return 1; }
           export_client_artifacts "$exp_dir/mk" "$T7_UUID" "$T7_IP" "$T7_PORT" "$T7_SNI" "$T7_PUB" "$T7_SID" "$T7_REMARK" 2>&1 ) ); rc=$?
  assert_status 1 "$rc" "export_client_artifacts 在目录创建失败时返回非零"
  assert_contains "$out" "无法创建客户端导出目录" "export_client_artifacts 在目录创建失败时给出明确提示"
  out=$( ( chmod() { if [[ "$1" == "700" ]]; then return 1; fi; command chmod "$@"; }
           export_client_artifacts "$exp_dir/cm" "$T7_UUID" "$T7_IP" "$T7_PORT" "$T7_SNI" "$T7_PUB" "$T7_SID" "$T7_REMARK" 2>&1 ) ); rc=$?
  assert_status 1 "$rc" "export_client_artifacts 在目录权限设置失败时返回非零"
  assert_contains "$out" "无法设置客户端导出目录权限" "export_client_artifacts 在目录权限设置失败时给出明确提示"
  out=$( ( build_share_link() { printf ''; }
           export_client_artifacts "$exp_dir/lk" "$T7_UUID" "$T7_IP" "$T7_PORT" "$T7_SNI" "$T7_PUB" "$T7_SID" "$T7_REMARK" 2>&1 ) ); rc=$?
  assert_status 1 "$rc" "export_client_artifacts 在分享链接为空时返回非零"
  assert_contains "$out" "分享链接生成为空" "export_client_artifacts 在分享链接为空时给出明确提示"
  out=$( ( render_client_config() { return 1; }
           export_client_artifacts "$exp_dir/rc" "$T7_UUID" "$T7_IP" "$T7_PORT" "$T7_SNI" "$T7_PUB" "$T7_SID" "$T7_REMARK" 2>&1 ) ); rc=$?
  assert_status 1 "$rc" "export_client_artifacts 在客户端配置渲染失败时返回非零"

  # ── 物料文件的写入/权限失败路径同样必须报错（不得静默成功）──────────────
  # 让 client.txt 先是一个【目录】→ 重定向必然失败。
  mkdir -p "$exp_dir/fw/client.txt"
  out=$( export_client_artifacts "$exp_dir/fw" "$T7_UUID" "$T7_IP" "$T7_PORT" "$T7_SNI" "$T7_PUB" "$T7_SID" "$T7_REMARK" 2>&1 ); rc=$?
  assert_status 1 "$rc" "export_client_artifacts 在客户端信息文件写入失败时返回非零"
  assert_contains "$out" "无法写入客户端信息文件" "export_client_artifacts 在客户端信息文件写入失败时给出明确提示"
  # chmod 只对 client.txt 失败 → 其余 chmod 正常 → 退出码只由这一条路径决定。
  out=$( ( chmod() { case "$2" in "$exp_dir/cmt/client.txt") return 1 ;; esac; command chmod "$@"; }
           export_client_artifacts "$exp_dir/cmt" "$T7_UUID" "$T7_IP" "$T7_PORT" "$T7_SNI" "$T7_PUB" "$T7_SID" "$T7_REMARK" 2>&1 ) ); rc=$?
  assert_status 1 "$rc" "export_client_artifacts 在客户端信息文件权限设置失败时返回非零"
  assert_contains "$out" "无法设置客户端信息文件权限" "export_client_artifacts 在客户端信息文件权限设置失败时给出明确提示"
  # 让 link.txt 先是一个【目录】→ 重定向必然失败。
  mkdir -p "$exp_dir/fw2/link.txt"
  out=$( export_client_artifacts "$exp_dir/fw2" "$T7_UUID" "$T7_IP" "$T7_PORT" "$T7_SNI" "$T7_PUB" "$T7_SID" "$T7_REMARK" 2>&1 ); rc=$?
  assert_status 1 "$rc" "export_client_artifacts 在分享链接文件写入失败时返回非零"
  assert_contains "$out" "无法写入分享链接文件" "export_client_artifacts 在分享链接文件写入失败时给出明确提示"
  out=$( ( chmod() { case "$2" in "$exp_dir/cml/link.txt") return 1 ;; esac; command chmod "$@"; }
           export_client_artifacts "$exp_dir/cml" "$T7_UUID" "$T7_IP" "$T7_PORT" "$T7_SNI" "$T7_PUB" "$T7_SID" "$T7_REMARK" 2>&1 ) ); rc=$?
  assert_status 1 "$rc" "export_client_artifacts 在分享链接文件权限设置失败时返回非零"
  assert_contains "$out" "无法设置分享链接文件权限" "export_client_artifacts 在分享链接文件权限设置失败时给出明确提示"

  # 权限位：只在 chmod 真的生效的文件系统上断言（MSYS 模拟 chmod，会自动跳过）
  exp_probe="$exp_dir/.probe"
  : >"$exp_probe"
  chmod 600 "$exp_probe" 2>/dev/null
  if [[ "$(stat -c '%a' "$exp_probe" 2>/dev/null)" == "600" ]]; then
    assert_eq "600" "$(stat -c '%a' "$exp_dir/link.txt" 2>/dev/null)" "link.txt 权限为 600"
    assert_eq "600" "$(stat -c '%a' "$exp_dir/client.txt" 2>/dev/null)" "client.txt 权限为 600"
    assert_eq "700" "$(stat -c '%a' "$exp_dir" 2>/dev/null)" "客户端导出目录权限为 700"
  fi
else
  assert_eq "mktemp -d 能创建唯一临时目录" "失败（mktemp -d 返回空路径）" \
    "export_client_artifacts 用例前提：mktemp -d 必须能创建唯一临时目录"
fi
rm -rf "$exp_dir"

# ── 本段用到的辅助断言 ─────────────────────────────────────────
# assert_contains 只能表达「包含」，而本任务有多条断言要表达「【不】含」
# （例如「参数校验失败时不得走到 root 检查」）。
# 用 grep -c 数命中行数（0 = 不存在）；grep 无匹配时退出码是 1，
# 必须用 `|| true` 吞掉，否则会把非零码带出命令替换。
assert_not_contains() {
  local haystack="$1" needle="$2" msg="${3:-不含子串}"
  local n
  n=$(printf '%s' "$haystack" | grep -c -F -- "$needle" || true)
  assert_eq "0" "$n" "$msg"
}

# 本段有 4 条断言依赖「当前不是 root」。
# ⚠️ EUID 是 bash 的【只读特殊变量】→ 没法注入 → 只能靠实际运行身份判断。
#    以 root 运行时必须走 else 分支（条数不变 + 说明已跳过），
#    否则在 Debian 上以 root 跑测试会有 3 条断言假红。
T8_IS_ROOT=0
if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
  T8_IS_ROOT=1
fi

test_case "install.sh 参数解析"

# ⚠️ 每一次调用 install.sh 都要用 `timeout 10` 包一层。
#    原因：参数解析的守卫（`[[ -n "$OPT_X" ]] || { ...; exit 1; }`）一旦被删，
#    `shift 2` 在「参数缺失」时会失败 → while 循环消费不掉当前参数 → 进程死循环。
#    控制器实测（C5 变异）：`bash install.sh --uuid` 永不退出 → 整个测试套件挂死。
#    包上 timeout 之后，这类失败变成 rc=124（断言照样变红），套件不会挂死。
run_help=$(timeout 10 bash "$ROOT/install.sh" --help 2>&1)
assert_contains "$run_help" "--port" "帮助信息含 --port"
assert_contains "$run_help" "--sni" "帮助信息含 --sni"
assert_contains "$run_help" "--menu" "帮助信息含 --menu"
assert_contains "$run_help" "--addr" "帮助信息含 --addr"

# --addr 的字符集校验：会原样进分享链接与客户端 JSON → 必须拒绝引号/空格/$
out=$(timeout 10 bash "$ROOT/install.sh" --addr 'bad"addr' 2>&1); rc=$?
assert_status 1 "$rc" "--addr 含引号时以非零码退出"
assert_contains "$out" "--addr" "--addr 非法时给出明确提示"
assert_not_contains "$out" "需要 root 权限" "--addr 非法时不得走到 root 检查（校验必须在参数解析口）"
out=$(timeout 10 bash "$ROOT/install.sh" --addr 'a b' 2>&1); rc=$?
assert_status 1 "$rc" "--addr 含空格时以非零码退出"
out=$(timeout 10 bash "$ROOT/install.sh" --addr 2>&1); rc=$?
assert_status 1 "$rc" "--addr 缺少参数时以非零码退出"
assert_contains "$out" "缺少参数" "--addr 缺少参数时给出明确提示"

# 未知参数必须报错退出
out=$(timeout 10 bash "$ROOT/install.sh" --definitely-not-a-real-flag 2>&1); rc=$?
assert_status 1 "$rc" "未知参数以非零码退出"
assert_contains "$out" "未知" "未知参数给出提示"

# --status 在未部署时应优雅退出而非崩溃（只读操作，不要求 root）
out=$(timeout 10 bash "$ROOT/install.sh" --status 2>&1); rc=$?
assert_status 0 "$rc" "未部署时 --status 退出码为 0"

# ── 其余参数的【缺参数】与【取值非法】必须各自报错 ──────────────
# 这一组是「参数解析口」的守卫：漏掉任何一个，用户就会得到
# 「参数被静默吞掉」或「非法值一路写进 config.json」的结果。
out=$(timeout 10 bash "$ROOT/install.sh" --port 2>&1); rc=$?
assert_status 1 "$rc" "--port 缺少参数时以非零码退出"
assert_contains "$out" "缺少参数" "--port 缺少参数时给出明确提示"
out=$(timeout 10 bash "$ROOT/install.sh" --port 99999 2>&1); rc=$?
assert_status 1 "$rc" "--port 超出范围时以非零码退出"
assert_contains "$out" "--port" "--port 超出范围时给出明确提示"
assert_not_contains "$out" "需要 root 权限" "--port 越界时不得走到 root 检查（范围校验必须在参数解析口）"
out=$(timeout 10 bash "$ROOT/install.sh" --port 0 2>&1); rc=$?
assert_status 1 "$rc" "--port 为 0 时以非零码退出"
out=$(timeout 10 bash "$ROOT/install.sh" --sni 2>&1); rc=$?
assert_status 1 "$rc" "--sni 缺少参数时以非零码退出"
assert_contains "$out" "缺少参数" "--sni 缺少参数时给出明确提示"
out=$(timeout 10 bash "$ROOT/install.sh" --name 2>&1); rc=$?
assert_status 1 "$rc" "--name 缺少参数时以非零码退出"
assert_contains "$out" "缺少参数" "--name 缺少参数时给出明确提示"
out=$(timeout 10 bash "$ROOT/install.sh" --uuid 2>&1); rc=$?
assert_status 1 "$rc" "--uuid 缺少参数时以非零码退出"
assert_contains "$out" "缺少参数" "--uuid 缺少参数时给出明确提示"

# --sni 的值会原样进 config.json 与分享链接 → 非法主机名必须被拒
out=$(timeout 10 bash "$ROOT/install.sh" --sni 'bad host' 2>&1); rc=$?
assert_status 1 "$rc" "--sni 非法主机名以非零码退出"
assert_contains "$out" "--sni" "--sni 非法主机名时给出明确提示"
assert_not_contains "$out" "需要 root 权限" "--sni 非法时不得走到 root 检查（主机名校验必须在参数解析口）"

# ── require_root：非 root 时必须报错并以非零码退出 ──────────────
if [[ "$T8_IS_ROOT" -eq 0 ]]; then
  out=$( ( INSTALL_SH_NO_MAIN=1; source "$ROOT/install.sh"; require_root ) 2>&1 ); rc=$?
  assert_status 1 "$rc" "非 root 时 require_root 返回非零"
  assert_contains "$out" "root" "非 root 时 require_root 给出明确提示"
else
  assert_eq "以 root 运行" "以 root 运行" "非 root 时 require_root 返回非零（以 root 运行，前提不成立，已跳过）"
  assert_eq "以 root 运行" "以 root 运行" "非 root 时 require_root 给出明确提示（以 root 运行，前提不成立，已跳过）"
fi

# ── require_root 的【root 分支】只能用源码静态断言 ──────────────
# ⚠️ EUID 是 bash 的【只读特殊变量】→ `EUID=0` 改不了它 →
# 本机（Windows + MSYS，EUID=197615）永远进不了 root 分支。
# 而 root 分支恰恰是「误报『需要 root』」的唯一来源 → 必须钉住。
# 办法：把函数体取出来做【源码静态断言】（与 Task 4 的 F4-1、Task 6 的 T6-9 同款）。
rr_body=$( ( INSTALL_SH_NO_MAIN=1; source "$ROOT/install.sh"; declare -f require_root ) )
assert_contains "$rr_body" "return 1" "require_root 在非 root 时返回非零（不得直接 exit 掉调用方）"
assert_contains "$rr_body" "return 0" "require_root 在 root 时返回 0"

test_case "install.sh 的函数级分支（source 但不执行 main）"

# install.sh 末尾的 main 调用有守卫：被 source 时不执行 main
# （否则本机非 root → 立刻 exit 1 → 什么都测不到）。
# 所以这里统一用 `INSTALL_SH_NO_MAIN=1; source "$ROOT/install.sh"` 拿到函数。
#
# ⚠️ 每次 source 都要重新加载 —— install.sh 顶层会把 OPT_* 全部重置成空串，
#    所以【必须在 source 之后】再设置这些变量，否则会被覆盖。

# ── preflight：全部依赖都满足时必须返回 0 ──────────────
# ⚠️ 绝对不能让它真的 apt-get / 真的联网 → 全部 mock。
out=$( ( INSTALL_SH_NO_MAIN=1; source "$ROOT/install.sh"
         assert_debian() { return 0; }
         have_cmd() { return 0; }
         ensure_packages() { return 0; }
         detect_public_ip() { printf '203.0.113.9'; }
         preflight ) 2>&1 ); rc=$?
assert_status 0 "$rc" "preflight 在依赖齐备时返回 0"
assert_contains "$out" "环境预检" "preflight 打印环境预检标题"
assert_contains "$out" "systemd 可用" "preflight 确认 systemd 可用"
assert_contains "$out" "curl 可用" "preflight 确认 curl 可用"
assert_contains "$out" "203.0.113.9" "preflight 显示探测到的公网 IP"

# ── preflight：缺 systemd 时必须失败并指出原因 ──────────────
out=$( ( INSTALL_SH_NO_MAIN=1; source "$ROOT/install.sh"
         assert_debian() { return 0; }
         have_cmd() { case "$1" in systemctl) return 1 ;; *) return 0 ;; esac; }
         ensure_packages() { return 0; }
         detect_public_ip() { printf '203.0.113.9'; }
         preflight ) 2>&1 ); rc=$?
assert_status 1 "$rc" "preflight 缺 systemd 时返回非零"
assert_contains "$out" "systemd 不可用" "preflight 缺 systemd 时给出明确提示"

# ── preflight：缺 curl 时必须失败并指出原因 ──────────────
out=$( ( INSTALL_SH_NO_MAIN=1; source "$ROOT/install.sh"
         assert_debian() { return 0; }
         have_cmd() { case "$1" in curl) return 1 ;; *) return 0 ;; esac; }
         ensure_packages() { return 0; }
         detect_public_ip() { printf '203.0.113.9'; }
         preflight ) 2>&1 ); rc=$?
assert_status 1 "$rc" "preflight 缺 curl 时返回非零"
assert_contains "$out" "无法下载安装脚本" "preflight 缺 curl 时给出明确提示"

# ── preflight：不是 Debian 时必须失败 ──────────────
out=$( ( INSTALL_SH_NO_MAIN=1; source "$ROOT/install.sh"
         assert_debian() { return 1; }
         have_cmd() { return 0; }
         ensure_packages() { return 0; }
         detect_public_ip() { printf '203.0.113.9'; }
         preflight ) 2>&1 ); rc=$?
assert_status 1 "$rc" "preflight 在非 Debian 系统上返回非零"

# ── preflight：依赖安装失败必须计入失败 ──────────────
out=$( ( INSTALL_SH_NO_MAIN=1; source "$ROOT/install.sh"
         assert_debian() { return 0; }
         have_cmd() { return 0; }
         ensure_packages() { return 1; }
         detect_public_ip() { printf '203.0.113.9'; }
         preflight ) 2>&1 ); rc=$?
assert_status 1 "$rc" "preflight 在依赖安装失败时返回非零"

# ── preflight：缺 qrencode 不得阻断部署 ──────────────
# qrencode 只是「锦上添花」（二维码可以之后手动生成）→ 装不上只能提示，不能中止。
# ⚠️ mock 必须精确：ensure_packages 只对 qrencode 失败，openssl 仍然成功 ——
#    否则这条用例测的其实是「依赖安装失败」那条路径。
out=$( ( INSTALL_SH_NO_MAIN=1; source "$ROOT/install.sh"
         assert_debian() { return 0; }
         have_cmd() { case "$1" in qrencode) return 1 ;; *) return 0 ;; esac; }
         ensure_packages() { [[ "$1" == "qrencode" ]] && return 1; return 0; }
         detect_public_ip() { printf '203.0.113.9'; }
         preflight ) 2>&1 ); rc=$?
assert_status 0 "$rc" "preflight 缺 qrencode 时不阻断部署"
assert_contains "$out" "qrencode" "preflight 缺 qrencode 时给出提示"

# ── preflight：探测不到公网 IP 时必须回退并提示 ──────────────
out=$( ( INSTALL_SH_NO_MAIN=1; source "$ROOT/install.sh"
         assert_debian() { return 0; }
         have_cmd() { return 0; }
         ensure_packages() { return 0; }
         detect_public_ip() { return 1; }
         detect_local_ip() { printf '10.0.0.5'; }
         preflight ) 2>&1 ); rc=$?
assert_contains "$out" "未能探测到公网 IP" "preflight 探测不到公网 IP 时给出提示"
assert_contains "$out" "10.0.0.5" "preflight 探测不到公网 IP 时回退到本机地址"

# ── preflight：--addr 指定时必须用它而不是去探测 ──────────────
# ⚠️ OPT_ADDR 必须在 source 【之后】设置 —— install.sh 顶层会把它重置为空串。
out=$( ( INSTALL_SH_NO_MAIN=1; source "$ROOT/install.sh"
         OPT_ADDR='203.0.113.7'
         assert_debian() { return 0; }
         have_cmd() { return 0; }
         ensure_packages() { return 0; }
         detect_public_ip() { printf '198.51.100.1'; }
         preflight
         printf 'SERVER_IP=[%s]\n' "$SERVER_IP" ) 2>&1 ); rc=$?
assert_contains "$out" "203.0.113.7" "preflight 优先使用 --addr 指定的地址"
assert_contains "$out" "SERVER_IP=[203.0.113.7]" "preflight 把 --addr 写进 SERVER_IP"

# ── parse_args：合法参数必须被正确解析 ──────────────
out=$( ( INSTALL_SH_NO_MAIN=1; source "$ROOT/install.sh"
         parse_args --port 8443 --sni www.microsoft.com --name 我的节点 --uuid 11111111-2222-3333-4444-555555555555 --addr 203.0.113.7 -y
         printf 'PORT=%s\nSNI=%s\nNAME=%s\nUUID=%s\nADDR=%s\nYES=%s\n' \
                "$OPT_PORT" "$OPT_SNI" "$OPT_NAME" "$OPT_UUID" "$OPT_ADDR" "$OPT_YES" ) 2>&1 ); rc=$?
assert_status 0 "$rc" "parse_args 解析合法参数时返回 0"
assert_contains "$out" "PORT=8443" "parse_args 解析 --port"
assert_contains "$out" "SNI=www.microsoft.com" "parse_args 解析 --sni"
assert_contains "$out" "NAME=我的节点" "parse_args 解析 --name"
assert_contains "$out" "UUID=11111111-2222-3333-4444-555555555555" "parse_args 解析 --uuid"
assert_contains "$out" "ADDR=203.0.113.7" "parse_args 解析 --addr"
assert_contains "$out" "YES=1" "parse_args 解析 -y"

# ── parse_args：--menu / --status / --uninstall 的开关必须置位 ──────────────
out=$( ( INSTALL_SH_NO_MAIN=1; source "$ROOT/install.sh"
         parse_args --menu
         printf 'MENU=%s\n' "$OPT_MENU" ) 2>&1)
assert_contains "$out" "MENU=1" "parse_args 解析 --menu"
out=$( ( INSTALL_SH_NO_MAIN=1; source "$ROOT/install.sh"
         parse_args --status
         printf 'STATUS=%s\n' "$OPT_STATUS" ) 2>&1)
assert_contains "$out" "STATUS=1" "parse_args 解析 --status"
out=$( ( INSTALL_SH_NO_MAIN=1; source "$ROOT/install.sh"
         parse_args --uninstall
         printf 'UNINSTALL=%s\n' "$OPT_UNINSTALL" ) 2>&1)
assert_contains "$out" "UNINSTALL=1" "parse_args 解析 --uninstall"

# ── main：--uninstall 时找不到卸载脚本必须报错退出 ──────────────
out=$( ( INSTALL_SH_NO_MAIN=1; source "$ROOT/install.sh"
         ROOT_DIR=/nonexistent-dir-for-test
         main --uninstall ) 2>&1); rc=$?
assert_status 1 "$rc" "--uninstall 找不到卸载脚本时以非零码退出"
assert_contains "$out" "uninstall.sh" "--uninstall 找不到卸载脚本时给出明确提示"

# ── main 的 root 相关分支：源码静态断言 ──────────────
# ⚠️ EUID 只读 → 本机无法把 EUID 设成 0 → 「root 下 --menu / --status /
#    部署主路径」这三条在本机【不可达】。但它们是「部署到底能不能跑」的
#    关键路径 → 不能就这么放过。用源码静态断言钉住结构。
main_body=$( ( INSTALL_SH_NO_MAIN=1; source "$ROOT/install.sh"; declare -f main ) )
# ⚠️ 不能只断言 main_body 里出现过 "require_root || exit 1"：
#    --menu 分支里也有一句 → 删掉【部署路径】那句，断言照样绿（恒真）。
#    判据必须唯一：「部署路径」= 打印部署 banner 的那段 → 它前面必须有 require_root。
deploy_guard=$(printf '%s\n' "$main_body" | grep -A1 'require_root || exit 1' | grep -c 'tui_banner')
assert_eq "1" "$deploy_guard" "main 在进入部署路径前必须要求 root"
assert_contains "$main_body" 'OPT_STATUS -eq 1' "main 必须处理 --status 分支"
assert_contains "$main_body" 'OPT_MENU -eq 1' "main 必须处理 --menu 分支"
assert_contains "$main_body" 'OPT_UNINSTALL -eq 1' "main 必须处理 --uninstall 分支"
# ⚠️ 不能只断言 main_body 里出现过 "deploy_wizard"：
#    `if ! declare -F deploy_wizard >/dev/null 2>&1; then` 那行也含这个词
#    → 删掉【调用】那一行，断言照样绿（恒真）。
#    判据必须唯一：只数【这一行就是 deploy_wizard 调用】的行。
#    （declare -f 会重排版：补分号、改缩进 → 用词边界而不是整行相等。）
wizard_call=$(printf '%s\n' "$main_body" | grep -c '^[[:space:]]*deploy_wizard\b')
assert_eq "1" "$wizard_call" "main 必须调用 deploy_wizard"
# --status 必须在 require_root 之前（只读操作不应要求 root）→
# 顺序本身就是一条可断言的性质：--status 的判定行号必须小于 require_root 的行号。
status_line=$(printf '%s\n' "$main_body" | grep -n 'OPT_STATUS -eq 1' | head -1 | cut -d: -f1)
root_line=$(printf '%s\n' "$main_body" | grep -n 'require_root || exit 1' | tail -1 | cut -d: -f1)
order_ok=0
if [[ -n "$status_line" && -n "$root_line" && "$status_line" -lt "$root_line" ]]; then
  order_ok=1
fi
assert_eq "1" "$order_ok" "--status 的判定在 require_root 之前（只读操作不要求 root）"

# ── 非 root 下 --menu 必须以非零码退出（这条【可达】）──────────────
if [[ "$T8_IS_ROOT" -eq 0 ]]; then
  out=$( ( INSTALL_SH_NO_MAIN=1; source "$ROOT/install.sh"; main --menu ) 2>&1); rc=$?
  assert_status 1 "$rc" "非 root 下 --menu 以非零码退出"
  assert_contains "$out" "root" "非 root 下 --menu 提示需要 root 权限"
else
  assert_eq "以 root 运行" "以 root 运行" "非 root 下 --menu 以非零码退出（以 root 运行，前提不成立，已跳过）"
  assert_eq "以 root 运行" "以 root 运行" "非 root 下 --menu 提示需要 root 权限（以 root 运行，前提不成立，已跳过）"
fi

# ── Task 9：部署向导（全部 mock：不联网、不装内核、不开防火墙、不碰系统目录）──
# ⚠️ 本段【不写任何会整块跳过的条件块】：原 Step 1 就是栽在这里 ——
#    「有 openssl + 有外网」才跑断言 → 本机一条都没跑 → 条数在机器之间漂移。
#    所有外部依赖一律用 shell 函数 mock；mock 一律打印可辨认的标记，
#    断言据此判断「哪一步真的执行了」以及「执行时拿到了什么值」。
#
# ⚠️ assert_not_contains 是 Task 8 段已经定义好的辅助断言，直接用。

# 统一的向导 mock 集合：把 do_deploy / deploy_wizard 依赖的【所有】外部动作
# 换成会打印标记的假实现。定义一次，各用例用 `eval "$(t9_mocks)"` 引入；
# 需要改行为的用例，在 eval 之后【重新定义】同名函数覆盖它。
t9_mocks() {
  cat <<'MOCKS'
install_xray() { printf 'MOCK_INSTALL_XRAY\n'; return 0; }
gen_keys() { UUID='11111111-2222-3333-4444-555555555555'; PRIVATE_KEY='PRIVKEY0123456789abcdefghijklmnopqrstuvwxyzABCDE'; PUBLIC_KEY='PUBKEY0123456789abcdefghijklmnopqrstuvwxyzABCDE'; SHORT_ID='a1b2c3d4'; printf 'MOCK_GEN_KEYS\n'; return 0; }
render_server_config() { printf 'MOCK_RENDER\n'; return 0; }
write_config_atomic() { printf 'MOCK_ATOMIC\n'; return 0; }
setup_systemd() { printf 'MOCK_SYSTEMD\n'; return 0; }
open_firewall() { printf 'MOCK_FIREWALL\n'; return 0; }
enable_bbr() { printf 'MOCK_BBR\n'; return 0; }
save_state() { printf 'MOCK_SAVE_STATE UUID=%s PORT=%s\n' "$UUID" "$PORT"; return 0; }
export_client_artifacts() { printf 'MOCK_EXPORT DIR=%s PORT=%s\n' "$1" "$4"; return 0; }
build_share_link() { printf 'vless://11111111-2222-3333-4444-555555555555@203.0.113.9:443?security=reality#node'; return 0; }
choose_target() { printf 'www.microsoft.com'; return 0; }
port_in_use() { return 1; }
port_occupant() { printf ''; return 0; }
random_free_port() { printf '8443'; return 0; }
detect_public_ip() { printf '203.0.113.9'; return 0; }
detect_local_ip() { printf '10.0.0.5'; return 0; }
have_cmd() { return 0; }
tui_confirm() { return 0; }
tui_input() { printf '8443'; return 0; }
tui_menu() { return 0; }
tui_pause() { return 0; }
management_menu() { printf 'MOCK_MENU\n'; return 0; }
MOCKS
}

# ⚠️ do_deploy 的 mock 必须【单独】一份：
#    它和 do_deploy 本身同名 → 放进共享集合会把【被测对象】替换掉，
#    于是「测 do_deploy」的用例其实在测这个假实现（控制器第一版就栽在这里：
#    22 条 do_deploy 断言全部变红）。
t9_mocks_wizard() {
  cat <<'MOCKS'
do_deploy() { UUID='11111111-2222-3333-4444-555555555555'; PUBLIC_KEY='PUBKEY0123456789abcdefghijklmnopqrstuvwxyzABCDE'; SHORT_ID='a1b2c3d4'; printf 'MOCK_DO_DEPLOY PORT=%s SNI=%s IP=%s\n' "$PORT" "$SNI" "$SERVER_IP"; FIREWALL_OK=1; return 0; }
MOCKS
}

T9_TMP=$(mktemp -d 2>/dev/null)
if [[ -n "$T9_TMP" ]]; then

test_case "向导：目标探测与排序"

# probe_targets：输出 "host|tls|latency"，按延迟升序，未知延迟 '?' 排最后。
out=$( ( REALITY_TARGETS=(slow.test ok.test unknown.test)
         target_supports_tls13() { [[ "$1" == "ok.test" ]]; }
         target_latency_ms() { case "$1" in slow.test) printf '30' ;; ok.test) printf '10' ;; unknown.test) printf '?' ;; esac; }
         probe_targets ) 2>&1 ); rc=$?
assert_status 0 "$rc" "probe_targets 正常路径返回 0"
assert_contains "$out" "ok.test|ok|10" "probe_targets 输出格式为 host|tls|latency"
assert_contains "$out" "slow.test|fail|30" "probe_targets 把不支持 TLS1.3 的目标标为 fail"
assert_contains "$out" "unknown.test|fail|?" "probe_targets 把未知延迟标为 ?"
assert_eq "ok.test|ok|10" "$(printf '%s\n' "$out" | head -1)" "probe_targets 把延迟最小的目标排在第一"
assert_eq "unknown.test|fail|?" "$(printf '%s\n' "$out" | tail -1)" "probe_targets 把未知延迟的目标排在最后"
assert_eq "3" "$(printf '%s\n' "$out" | grep -c '|')" "probe_targets 的输出行数等于候选数"

# probe_targets：mktemp 失败必须报错退出，且【诊断信息不能走 stdout】——
# 调用方是 `probe=$(probe_targets)`：报错被当成探测数据吞进 probe，
# choose_target 就会拿一段错误文本当主机名去解析。
out=$( ( mktemp() { return 1; }
         target_supports_tls13() { return 0; }
         target_latency_ms() { printf '10'; }
         probe_targets ) 2>/dev/null ); rc=$?
assert_status 1 "$rc" "probe_targets 在 mktemp 失败时返回非零"
assert_eq "" "$out" "probe_targets 的诊断信息不写 stdout（否则会被当成探测数据吞掉）"
err=$( ( mktemp() { return 1; }
         target_supports_tls13() { return 0; }
         target_latency_ms() { printf '10'; }
         probe_targets ) 2>&1 >/dev/null )
assert_contains "$err" "无法创建临时文件" "probe_targets 在 mktemp 失败时给出明确提示"

test_case "向导：伪装目标选择"

# choose_target：探测不可用（返回空）时回退默认目标，
# 且【提示语不能进 stdout】——调用方是 `SNI=$(choose_target)`。
sel=$( ( probe_targets() { return 0; }
         choose_target ) 2>/dev/null )
assert_eq "www.microsoft.com" "$sel" "choose_target 在探测不可用时回退到默认目标"
err=$( ( probe_targets() { return 0; }
         choose_target ) 2>&1 >/dev/null )
assert_contains "$err" "目标探测不可用" "choose_target 在探测不可用时把提示写到 stderr"

# choose_target：探测【失败】（rc≠0、stdout 为空）时同样走回退路径
sel=$( ( probe_targets() { return 1; }
         choose_target ) 2>/dev/null )
assert_eq "www.microsoft.com" "$sel" "choose_target 在探测失败时回退到默认目标"

# choose_target：--yes 自动挑选「第一个支持 TLS1.3 且延迟已知」的目标
# ⚠️ 第一个候选必须是「ok 但延迟未知（?）」：否则去掉 `&& "$lat" != '?'`
#    那个条件，选中的目标【不变】→ 这条断言就恒真了。
sel=$( ( OPT_YES=1
         probe_targets() { printf 'a.test|ok|?\nb.test|ok|20\nc.test|ok|30\n'; }
         choose_target ) 2>/dev/null )
assert_eq "b.test" "$sel" "choose_target 在 --yes 下自动挑选第一个 ok 且延迟已知的目标"

# choose_target：--yes 且没有 ok 目标时回退到第一个候选
sel=$( ( OPT_YES=1
         probe_targets() { printf 'a.test|fail|10\nb.test|fail|20\n'; }
         choose_target ) 2>/dev/null )
assert_eq "a.test" "$sel" "choose_target 在 --yes 且无 ok 目标时回退到第一个候选"

# choose_target：交互模式下用菜单返回码取选中项；
# 菜单文本必须走 stderr —— 它会把整张菜单打到 stdout，
# 而调用方是 `SNI=$(choose_target)` → SNI 会变成「菜单 + 主机名」的多行串。
sel=$( ( probe_targets() { printf 'a.test|ok|10\nb.test|ok|20\n'; }
         tui_menu() { printf '菜单标题\n选项一\n选项二\n'; return 1; }
         choose_target ) 2>/dev/null )
assert_eq "b.test" "$sel" "choose_target 用菜单返回码取选中项"
err=$( ( probe_targets() { printf 'a.test|ok|10\nb.test|ok|20\n'; }
         tui_menu() { printf '菜单标题\n选项一\n选项二\n'; return 1; }
         choose_target ) 2>&1 >/dev/null )
assert_contains "$err" "菜单标题" "choose_target 把菜单渲染到 stderr"

# choose_target：用户取消（返回码 255）时回退到第一项
sel=$( ( probe_targets() { printf 'a.test|ok|10\nb.test|ok|20\n'; }
         tui_menu() { printf '菜单标题\n'; return 255; }
         choose_target ) 2>/dev/null )
assert_eq "a.test" "$sel" "choose_target 在用户取消时回退到第一项"

test_case "向导：六步部署"

# do_deploy 的六步全部 mock 成功 → 走完全程
out=$( ( XRAY_CONFIG="$T9_TMP/cfg.json"
         eval "$(t9_mocks)"
         do_deploy ) 2>&1 ); rc=$?
assert_status 0 "$rc" "do_deploy 全部步骤成功时返回 0"
assert_contains "$out" "MOCK_INSTALL_XRAY" "do_deploy 执行了安装内核这一步"
assert_contains "$out" "MOCK_GEN_KEYS" "do_deploy 执行了生成密钥这一步"
assert_contains "$out" "MOCK_RENDER" "do_deploy 执行了渲染配置这一步"
assert_contains "$out" "MOCK_ATOMIC" "do_deploy 执行了原子写配置这一步"
assert_contains "$out" "MOCK_SYSTEMD" "do_deploy 执行了配置 systemd 这一步"
assert_contains "$out" "MOCK_FIREWALL" "do_deploy 执行了放行防火墙这一步"
assert_contains "$out" "MOCK_BBR" "do_deploy 执行了网络调优这一步"
assert_contains "$out" "服务端配置已写入" "do_deploy 成功后提示配置已写入"
assert_contains "$out" "部署完成" "do_deploy 成功后提示部署完成"

# do_deploy：安装内核失败必须中止，且后续步骤一步都不许执行
out=$( ( XRAY_CONFIG="$T9_TMP/cfg.json"
         eval "$(t9_mocks)"
         install_xray() { printf 'MOCK_INSTALL_XRAY\n'; return 1; }
         do_deploy ) 2>&1 ); rc=$?
assert_status 1 "$rc" "do_deploy 在安装内核失败时返回非零"
assert_contains "$out" "Xray 安装失败" "do_deploy 在安装内核失败时给出明确提示"
assert_not_contains "$out" "MOCK_GEN_KEYS" "do_deploy 在安装内核失败后不继续生成密钥"

# do_deploy：生成密钥失败必须中止
out=$( ( XRAY_CONFIG="$T9_TMP/cfg.json"
         eval "$(t9_mocks)"
         gen_keys() { printf 'MOCK_GEN_KEYS\n'; return 1; }
         do_deploy ) 2>&1 ); rc=$?
assert_status 1 "$rc" "do_deploy 在生成密钥失败时返回非零"
assert_contains "$out" "密钥生成失败" "do_deploy 在生成密钥失败时给出明确提示"
assert_not_contains "$out" "MOCK_RENDER" "do_deploy 在生成密钥失败后不继续渲染配置"

# do_deploy：渲染配置失败必须中止，且不得再写配置
out=$( ( XRAY_CONFIG="$T9_TMP/cfg.json"
         eval "$(t9_mocks)"
         render_server_config() { printf 'MOCK_RENDER\n'; return 1; }
         do_deploy ) 2>&1 ); rc=$?
assert_status 1 "$rc" "do_deploy 在渲染配置失败时返回非零"
assert_not_contains "$out" "MOCK_ATOMIC" "do_deploy 在渲染配置失败后不写配置"

# do_deploy：写配置失败必须中止，且不得打印「已写入」
out=$( ( XRAY_CONFIG="$T9_TMP/cfg.json"
         eval "$(t9_mocks)"
         write_config_atomic() { printf 'MOCK_ATOMIC\n'; return 1; }
         do_deploy ) 2>&1 ); rc=$?
assert_status 1 "$rc" "do_deploy 在写配置失败时返回非零"
assert_not_contains "$out" "服务端配置已写入" "do_deploy 在写配置失败时不提示配置已写入"

# do_deploy：systemd 配置失败必须中止
out=$( ( XRAY_CONFIG="$T9_TMP/cfg.json"
         eval "$(t9_mocks)"
         setup_systemd() { printf 'MOCK_SYSTEMD\n'; return 1; }
         do_deploy ) 2>&1 ); rc=$?
assert_status 1 "$rc" "do_deploy 在 systemd 配置失败时返回非零"
assert_contains "$out" "systemd 配置失败" "do_deploy 在 systemd 配置失败时给出明确提示"

# do_deploy：防火墙放行失败【不中止】部署，但必须如实标记
out=$( ( XRAY_CONFIG="$T9_TMP/cfg.json"
         eval "$(t9_mocks)"
         open_firewall() { printf 'MOCK_FIREWALL\n'; return 1; }
         do_deploy
         printf 'FIREWALL_OK=%s\n' "${FIREWALL_OK:-unset}" ) 2>&1 ); rc=$?
assert_status 0 "$rc" "do_deploy 在防火墙放行失败时不中止部署"
assert_contains "$out" "防火墙放行未成功" "do_deploy 在防火墙放行失败时给出警告"
assert_contains "$out" "FIREWALL_OK=0" "do_deploy 在防火墙放行失败时把状态标记为 0"

# do_deploy：网络调优失败是非致命的
out=$( ( XRAY_CONFIG="$T9_TMP/cfg.json"
         eval "$(t9_mocks)"
         enable_bbr() { printf 'MOCK_BBR\n'; return 1; }
         do_deploy ) 2>&1 ); rc=$?
assert_status 0 "$rc" "do_deploy 在网络调优失败时不中止部署"
assert_contains "$out" "部署完成" "do_deploy 在网络调优失败后仍然提示部署完成"

# do_deploy：mktemp 失败必须中止（否则会把配置写到 ".new" 污染当前目录）
out=$( ( XRAY_CONFIG="$T9_TMP/cfg.json"
         eval "$(t9_mocks)"
         mktemp() { return 1; }
         do_deploy ) 2>&1 ); rc=$?
assert_status 1 "$rc" "do_deploy 在 mktemp 失败时返回非零"
assert_contains "$out" "无法创建临时文件" "do_deploy 在 mktemp 失败时给出明确提示"

test_case "向导：部署参数确认与收尾"

# deploy_wizard 的正常路径：端口 / 地址 / 伪装目标都要正确传给后续步骤
out=$( ( eval "$(t9_mocks; t9_mocks_wizard)"
         OPT_YES=1
         XRAY_CONFIG="$T9_TMP/cfg.json"
         OUT_DIR="$T9_TMP/out"
         deploy_wizard ) 2>&1 ); rc=$?
assert_status 0 "$rc" "deploy_wizard 正常路径返回 0"
assert_contains "$out" "PORT=443" "deploy_wizard 把默认端口 443 传给 do_deploy"
assert_contains "$out" "SNI=www.microsoft.com" "deploy_wizard 把伪装目标传给 do_deploy"
assert_contains "$out" "IP=203.0.113.9" "deploy_wizard 把探测到的公网地址传给 do_deploy"
assert_contains "$out" "MOCK_SAVE_STATE UUID=11111111-2222-3333-4444-555555555555" "deploy_wizard 保存的状态里带着生成的 UUID"
assert_contains "$out" "MOCK_EXPORT" "deploy_wizard 导出客户端物料"
assert_contains "$out" "部署完成" "deploy_wizard 成功后打印部署完成面板"
assert_contains "$out" "vless://11111111-2222-3333-4444-555555555555@203.0.113.9:443" "deploy_wizard 打印分享链接"
assert_not_contains "$out" "MOCK_MENU" "deploy_wizard 在 --yes 下不进入管理菜单"

# deploy_wizard：--addr 指定的地址优先于探测
out=$( ( eval "$(t9_mocks; t9_mocks_wizard)"
         OPT_YES=1
         OPT_ADDR='198.51.100.7'
         XRAY_CONFIG="$T9_TMP/cfg.json"
         OUT_DIR="$T9_TMP/out"
         deploy_wizard ) 2>&1 ); rc=$?
assert_status 0 "$rc" "deploy_wizard 在指定 --addr 时返回 0"
assert_contains "$out" "IP=198.51.100.7" "deploy_wizard 优先使用 --addr 指定的地址"

# deploy_wizard：探测不到公网 IP 时回退到本机地址并提示
out=$( ( eval "$(t9_mocks; t9_mocks_wizard)"
         OPT_YES=1
         detect_public_ip() { return 1; }
         XRAY_CONFIG="$T9_TMP/cfg.json"
         OUT_DIR="$T9_TMP/out"
         deploy_wizard ) 2>&1 ); rc=$?
assert_status 0 "$rc" "deploy_wizard 在探测不到公网 IP 时回退到本机地址"
assert_contains "$out" "IP=10.0.0.5" "deploy_wizard 回退使用本机地址"
assert_contains "$out" "未能自动探测到公网地址" "deploy_wizard 回退时给出提示"

# deploy_wizard：公网 IP 与本机地址都探测不到必须中止
out=$( ( eval "$(t9_mocks; t9_mocks_wizard)"
         OPT_YES=1
         detect_public_ip() { return 1; }
         detect_local_ip() { return 1; }
         XRAY_CONFIG="$T9_TMP/cfg.json"
         OUT_DIR="$T9_TMP/out"
         deploy_wizard ) 2>&1 ); rc=$?
assert_status 1 "$rc" "deploy_wizard 在探测不到任何地址时返回非零"
assert_contains "$out" "无法探测到本机地址" "deploy_wizard 在探测不到任何地址时给出明确提示"

# deploy_wizard：伪装目标为空必须中止
out=$( ( eval "$(t9_mocks; t9_mocks_wizard)"
         OPT_YES=1
         choose_target() { return 0; }
         XRAY_CONFIG="$T9_TMP/cfg.json"
         OUT_DIR="$T9_TMP/out"
         deploy_wizard ) 2>&1 ); rc=$?
assert_status 1 "$rc" "deploy_wizard 在伪装目标为空时返回非零"
assert_contains "$out" "未确定伪装目标" "deploy_wizard 在伪装目标为空时给出明确提示"

# deploy_wizard：用户不确认必须中止
out=$( ( eval "$(t9_mocks; t9_mocks_wizard)"
         OPT_YES=0
         tui_confirm() { return 1; }
         XRAY_CONFIG="$T9_TMP/cfg.json"
         OUT_DIR="$T9_TMP/out"
         deploy_wizard ) 2>&1 ); rc=$?
assert_status 1 "$rc" "deploy_wizard 在用户不确认时返回非零"
assert_contains "$out" "已取消" "deploy_wizard 在用户不确认时给出取消提示"
assert_not_contains "$out" "MOCK_DO_DEPLOY" "deploy_wizard 在用户不确认时不执行部署"

# deploy_wizard：部署失败必须中止，且不得保存状态
out=$( ( eval "$(t9_mocks; t9_mocks_wizard)"
         OPT_YES=1
         do_deploy() { printf 'MOCK_DO_DEPLOY\n'; return 1; }
         XRAY_CONFIG="$T9_TMP/cfg.json"
         OUT_DIR="$T9_TMP/out"
         deploy_wizard ) 2>&1 ); rc=$?
assert_status 1 "$rc" "deploy_wizard 在部署失败时返回非零"
assert_not_contains "$out" "MOCK_SAVE_STATE" "deploy_wizard 在部署失败时不保存状态"

# deploy_wizard：状态没落盘必须停在这里（否则 --status 会显示未部署）
out=$( ( eval "$(t9_mocks; t9_mocks_wizard)"
         OPT_YES=1
         save_state() { printf 'MOCK_SAVE_STATE\n'; return 1; }
         XRAY_CONFIG="$T9_TMP/cfg.json"
         OUT_DIR="$T9_TMP/out"
         deploy_wizard ) 2>&1 ); rc=$?
assert_status 1 "$rc" "deploy_wizard 在状态保存失败时返回非零"
assert_contains "$out" "状态保存失败" "deploy_wizard 在状态保存失败时给出明确提示"
assert_not_contains "$out" "MOCK_EXPORT" "deploy_wizard 在状态保存失败后不导出客户端物料"

# deploy_wizard：物料导出失败必须中止
out=$( ( eval "$(t9_mocks; t9_mocks_wizard)"
         OPT_YES=1
         export_client_artifacts() { printf 'MOCK_EXPORT\n'; return 1; }
         XRAY_CONFIG="$T9_TMP/cfg.json"
         OUT_DIR="$T9_TMP/out"
         deploy_wizard ) 2>&1 ); rc=$?
assert_status 1 "$rc" "deploy_wizard 在客户端物料导出失败时返回非零"
assert_contains "$out" "客户端物料导出失败" "deploy_wizard 在物料导出失败时给出明确提示"

# deploy_wizard：分享链接为空必须中止（空链接粘到客户端就是一条废链接）
out=$( ( eval "$(t9_mocks; t9_mocks_wizard)"
         OPT_YES=1
         build_share_link() { return 0; }
         XRAY_CONFIG="$T9_TMP/cfg.json"
         OUT_DIR="$T9_TMP/out"
         deploy_wizard ) 2>&1 ); rc=$?
assert_status 1 "$rc" "deploy_wizard 在分享链接为空时返回非零"
assert_contains "$out" "分享链接生成为空" "deploy_wizard 在分享链接为空时给出明确提示"

# deploy_wizard：防火墙放行失败必须在最终面板里如实反映
out=$( ( eval "$(t9_mocks; t9_mocks_wizard)"
         OPT_YES=1
         do_deploy() { printf 'MOCK_DO_DEPLOY\n'; FIREWALL_OK=0; return 0; }
         XRAY_CONFIG="$T9_TMP/cfg.json"
         OUT_DIR="$T9_TMP/out"
         deploy_wizard ) 2>&1 ); rc=$?
assert_status 0 "$rc" "deploy_wizard 在防火墙放行失败时仍完成部署"
assert_contains "$out" "放行失败" "deploy_wizard 在部署完成面板里如实反映防火墙放行失败"

# deploy_wizard：有终端二维码文件才打印
out=$( ( eval "$(t9_mocks; t9_mocks_wizard)"
         OPT_YES=1
         mkdir -p "$T9_TMP/out"
         printf 'QR-PLACEHOLDER\n' > "$T9_TMP/out/qrcode.txt"
         XRAY_CONFIG="$T9_TMP/cfg.json"
         OUT_DIR="$T9_TMP/out"
         deploy_wizard ) 2>&1 ); rc=$?
assert_contains "$out" "QR-PLACEHOLDER" "deploy_wizard 在存在 qrcode.txt 时打印终端二维码"
out=$( ( eval "$(t9_mocks; t9_mocks_wizard)"
         OPT_YES=1
         XRAY_CONFIG="$T9_TMP/cfg.json"
         OUT_DIR="$T9_TMP/out-noqr"
         deploy_wizard ) 2>&1 ); rc=$?
assert_not_contains "$out" "QR-PLACEHOLDER" "deploy_wizard 在没有 qrcode.txt 时不打印二维码"
assert_not_contains "$out" "终端二维码" "deploy_wizard 在没有 qrcode.txt 时不打印二维码小节标题"

# deploy_wizard：交互模式（--yes=0）确认后进入管理菜单
out=$( ( eval "$(t9_mocks; t9_mocks_wizard)"
         OPT_YES=0
         XRAY_CONFIG="$T9_TMP/cfg.json"
         OUT_DIR="$T9_TMP/out"
         deploy_wizard ) 2>&1 ); rc=$?
assert_status 0 "$rc" "deploy_wizard 在交互模式完成部署后返回 0"
assert_contains "$out" "MOCK_MENU" "deploy_wizard 在交互模式下进入管理菜单"

test_case "向导：端口冲突处理"

# 端口被占用 + --yes → 自动改用随机空闲端口
out=$( ( eval "$(t9_mocks; t9_mocks_wizard)"
         OPT_YES=1
         port_in_use() { [[ "$1" == "443" ]] && return 0 || return 1; }
         port_occupant() { printf 'nginx'; return 0; }
         XRAY_CONFIG="$T9_TMP/cfg.json"
         OUT_DIR="$T9_TMP/out"
         deploy_wizard ) 2>&1 ); rc=$?
assert_status 0 "$rc" "deploy_wizard 在端口冲突且 --yes 时自动改端口并继续"
assert_contains "$out" "已被占用" "deploy_wizard 在端口被占用时给出提示"
assert_contains "$out" "PORT=8443" "deploy_wizard 在端口冲突时改用随机空闲端口"

# 端口被占用 + 交互 + 选「改用随机空闲端口」
out=$( ( eval "$(t9_mocks; t9_mocks_wizard)"
         OPT_YES=0
         port_in_use() { [[ "$1" == "443" ]] && return 0 || return 1; }
         tui_menu() { return 0; }
         XRAY_CONFIG="$T9_TMP/cfg.json"
         OUT_DIR="$T9_TMP/out"
         deploy_wizard ) 2>&1 ); rc=$?
assert_status 0 "$rc" "deploy_wizard 在菜单选「改用随机端口」时继续部署"
assert_contains "$out" "PORT=8443" "deploy_wizard 按菜单选择改用随机端口"

# 端口被占用 + 交互 + 选「我手动指定其它端口」
out=$( ( eval "$(t9_mocks; t9_mocks_wizard)"
         OPT_YES=0
         port_in_use() { [[ "$1" == "443" ]] && return 0 || return 1; }
         tui_menu() { return 1; }
         tui_input() { printf '9443'; return 0; }
         XRAY_CONFIG="$T9_TMP/cfg.json"
         OUT_DIR="$T9_TMP/out"
         deploy_wizard ) 2>&1); rc=$?
assert_status 0 "$rc" "deploy_wizard 在用户手动指定端口时继续部署"
assert_contains "$out" "PORT=9443" "deploy_wizard 使用用户手动输入的端口"

# 端口被占用 + 交互 + 输入非法端口必须中止
out=$( ( eval "$(t9_mocks; t9_mocks_wizard)"
         OPT_YES=0
         port_in_use() { [[ "$1" == "443" ]] && return 0 || return 1; }
         tui_menu() { return 1; }
         tui_input() { printf 'abc'; return 0; }
         XRAY_CONFIG="$T9_TMP/cfg.json"
         OUT_DIR="$T9_TMP/out"
         deploy_wizard ) 2>&1); rc=$?
assert_status 1 "$rc" "deploy_wizard 在用户输入非法端口时返回非零"
assert_contains "$out" "端口非法" "deploy_wizard 在用户输入非法端口时给出明确提示"

# 端口被占用 + 用户取消必须中止
out=$( ( eval "$(t9_mocks; t9_mocks_wizard)"
         OPT_YES=0
         port_in_use() { [[ "$1" == "443" ]] && return 0 || return 1; }
         tui_menu() { return 255; }
         XRAY_CONFIG="$T9_TMP/cfg.json"
         OUT_DIR="$T9_TMP/out"
         deploy_wizard ) 2>&1); rc=$?
assert_status 1 "$rc" "deploy_wizard 在用户取消端口冲突处理时返回非零"
assert_contains "$out" "已取消部署" "deploy_wizard 在用户取消时给出取消提示"

# 随机端口仍然被占用必须中止（random_free_port 的兜底端口从未校验过）
out=$( ( eval "$(t9_mocks; t9_mocks_wizard)"
         OPT_YES=1
         port_in_use() { return 0; }
         random_free_port() { printf '8443'; return 0; }
         XRAY_CONFIG="$T9_TMP/cfg.json"
         OUT_DIR="$T9_TMP/out"
         deploy_wizard ) 2>&1); rc=$?
assert_status 1 "$rc" "deploy_wizard 在改用的端口仍被占用时返回非零"
assert_contains "$out" "仍被占用" "deploy_wizard 在改用的端口仍被占用时给出明确提示"

# 同上，但走的是「菜单选 0 改用随机端口」那条路径（与上面是【两处】代码）
out=$( ( eval "$(t9_mocks; t9_mocks_wizard)"
         OPT_YES=0
         port_in_use() { return 0; }
         tui_menu() { return 0; }
         XRAY_CONFIG="$T9_TMP/cfg.json"
         OUT_DIR="$T9_TMP/out"
         deploy_wizard ) 2>&1); rc=$?
assert_status 1 "$rc" "deploy_wizard 在菜单改端口后遇到占用端口时中止"
assert_contains "$out" "仍被占用" "deploy_wizard 在菜单改端口后遇到占用端口时给出明确提示"

# 端口探测不可用（既没有 ss 也没有 netstat）时必须提示
out=$( ( eval "$(t9_mocks; t9_mocks_wizard)"
         OPT_YES=1
         have_cmd() { case "$1" in ss|netstat) return 1 ;; *) return 0 ;; esac; }
         XRAY_CONFIG="$T9_TMP/cfg.json"
         OUT_DIR="$T9_TMP/out"
         deploy_wizard ) 2>&1); rc=$?
assert_contains "$out" "无法确认端口是否空闲" "deploy_wizard 在端口探测不可用时给出提示"

else
  assert_eq "mktemp -d 能创建唯一临时目录" "失败（mktemp -d 返回空路径）" \
    "Task 9 用例前提：mktemp -d 必须能创建唯一临时目录"
fi
rm -rf "$T9_TMP"

# ── Task 10：管理菜单（全部 mock：不装内核、不动防火墙、不联网、不起服务）──
# ⚠️ 本段【不写任何会整块跳过的条件块】：外部依赖一律用 shell 函数 mock。
#    mock 一律打印可辨认的标记，断言据此判断「哪一步真的执行了」。
#
# ⚠️ 共享 mock 集合里【不许】出现与被测对象同名的函数（Task 9 的教训：
#    把 do_deploy 放进共享 mock → 把被测对象本身替换掉 → 22 条断言全红）。
#    本任务被测对象是 management_menu 与 menu_* 系列 → 共享集合里一个都不许有。
#
# ⚠️ assert_not_contains 是 Task 8 段已定义好的辅助断言，直接用。

# 共享 mock 集合：管理菜单依赖的【所有】外部动作换成会打印标记的假实现。
t10_mocks() {
  cat <<'MOCKS'
state_exists() { return 1; }
load_state() { return 1; }
save_state() { printf 'MOCK_SAVE_STATE\n'; return 0; }
restart_service() { printf 'MOCK_RESTART\n'; return 0; }
service_status() { printf 'MOCK_STATUS\n'; return 0; }
open_firewall() { printf 'MOCK_FIREWALL PORT=%s\n' "$1"; return 0; }
enable_bbr() { printf 'MOCK_BBR\n'; return 0; }
ensure_packages() { printf 'MOCK_ENSURE_PKGS %s\n' "$*"; return 0; }
# curl 必须【真的写出目标文件】：下载链判成功的条件是「curl 退出码为 0 且目标文件非空」，
# 只打印标记不落文件的话，下载链会一直判失败 → 后面的安装步骤永远走不到。
curl() { printf 'MOCK_CURL %s\n' "$*"; local o=''; while [[ $# -gt 0 ]]; do if [[ "$1" == '-o' ]]; then o="${2:-}"; shift 2; else shift; fi; done; if [[ -n "$o" ]]; then printf 'MOCK_DOWNLOADED\n' > "$o"; fi; return 0; }
# 内核安装这一步会真的往 /usr/local/bin 与 /etc/systemd 写东西 → 必须 mock。
xray_install_from_zip() { printf 'MOCK_INSTALL_ZIP\n'; return 0; }
journalctl() { printf 'MOCK_JOURNALCTL %s\n' "$*"; return 0; }
tui_run() { printf 'MOCK_TUI_RUN %s\n' "$*"; return 0; }
tui_banner() { printf 'MOCK_BANNER\n'; return 0; }
tui_pause() { printf 'MOCK_PAUSE\n'; return 0; }
tui_confirm() { return 0; }
tui_input() { printf '8443'; return 0; }
gen_keys() { UUID='22222222-3333-4444-5555-666666666666'; PRIVATE_KEY='PRIVKEY2'; PUBLIC_KEY='PUBKEY2'; SHORT_ID='b2c3d4e5'; printf 'MOCK_GEN_KEYS\n'; return 0; }
render_server_config() { printf 'MOCK_RENDER\n'; return 0; }
write_config_atomic() { printf 'MOCK_ATOMIC\n'; return 0; }
export_client_artifacts() { printf 'MOCK_EXPORT\n'; return 0; }
build_share_link() { printf 'vless://22222222-3333-4444-5555-666666666666@198.51.100.9:443?security=reality#n'; return 0; }
detect_public_ip() { printf '198.51.100.9'; return 0; }
detect_local_ip() { printf '10.0.0.5'; return 0; }
MOCKS
}

# ⚠️ deploy_wizard 用例的 mock 必须【单独】一份：
#    它要替换掉 do_deploy 与 management_menu —— 后者是本任务的被测对象，
#    放进共享集合会把它替换掉（Task 9 的同款错误）。
t10_mocks_wizard() {
  cat <<'MOCKS'
do_deploy() { UUID='22222222-3333-4444-5555-666666666666'; PUBLIC_KEY='PUBKEY2'; SHORT_ID='b2c3d4e5'; printf 'MOCK_DO_DEPLOY PORT=%s SNI=%s\n' "$PORT" "$SNI"; FIREWALL_OK=1; return 0; }
management_menu() { printf 'MOCK_MENU\n'; return 0; }
choose_target() { printf 'www.microsoft.com'; return 0; }
random_free_port() { printf '8443'; return 0; }
port_occupant() { printf ''; return 0; }
MOCKS
}

# ⚠️ 管理菜单用例也要单独一份：第 0 项会调 deploy_wizard，
#    这里要把它换成假实现，否则会真的跑一遍部署向导。
#    （不能放进 t10_mocks —— deploy_wizard 在「向导」那组用例里是被测对象。）
t10_mocks_menu() {
  cat <<'MOCKS'
deploy_wizard() { printf 'MOCK_DEPLOY_WIZARD\n'; return 0; }
MOCKS
}

# tui_menu 的返回码序列：第一次返回 MENU_PICK，之后一律 255（用户取消）
# → management_menu 的 while 循环必须能退出，测试才不会挂死。
t10_menu_pick() {
  MENU_N=0
  tui_menu() {
    MENU_N=$((MENU_N + 1))
    if (( MENU_N == 1 )); then return "$MENU_PICK"; fi
    return 255
  }
}

T10_TMP=$(mktemp -d 2>/dev/null)
if [[ -n "$T10_TMP" ]]; then

test_case "管理菜单：未部署状态下的健壮性"

# 未部署时进入管理菜单：必须给出明确提示，并且能正常退出
out=$( ( eval "$(t10_mocks; t10_mocks_menu)"
         MENU_PICK=255
         t10_menu_pick
         management_menu ) 2>&1 ); rc=$?
assert_status 0 "$rc" "未部署时管理菜单可正常退出"
assert_contains "$out" "尚未部署" "未部署时给出明确提示"
assert_contains "$out" "已退出" "用户取消菜单时提示已退出"

# 菜单必须渲染到 stderr —— tui_menu 把整张菜单打到 stdout，
# 而 deploy_wizard 末尾会调 management_menu，一旦有人用 $(...) 捕获就会吞掉菜单。
out=$( ( eval "$(t10_mocks; t10_mocks_menu)"
         tui_menu() { printf 'MOCK_MENU_MARKER\n'; return 255; }
         management_menu ) 2>/dev/null )
err=$( ( eval "$(t10_mocks; t10_mocks_menu)"
         tui_menu() { printf 'MOCK_MENU_MARKER\n'; return 255; }
         management_menu ) 2>&1 >/dev/null )
assert_not_contains "$out" "MOCK_MENU_MARKER" "management_menu 把菜单渲染到 stderr（不污染 stdout）"
assert_contains "$err" "MOCK_MENU_MARKER" "management_menu 的菜单确实写到了 stderr"

test_case "管理菜单：各菜单项的分发"

# 第 0 项：重新部署 → 调 deploy_wizard
out=$( ( eval "$(t10_mocks; t10_mocks_menu)"
         MENU_PICK=0
         t10_menu_pick
         management_menu ) 2>&1 ); rc=$?
assert_status 0 "$rc" "管理菜单选择「重新部署」时正常返回"
assert_contains "$out" "MOCK_DEPLOY_WIZARD" "management_menu 第 0 项调用 deploy_wizard"

# 第 1 项：查看配置 → 调 menu_show_client
out=$( ( eval "$(t10_mocks; t10_mocks_menu)"
         state_exists() { return 0; }
         load_state() { UUID='22222222-3333-4444-5555-666666666666'; SERVER_IP='198.51.100.9'; PORT=443; SNI='www.microsoft.com'; PUBLIC_KEY='PUBKEY2'; SHORT_ID='b2c3d4e5'; REMARK='node'; return 0; }
         MENU_PICK=1
         t10_menu_pick
         management_menu ) 2>&1 ); rc=$?
assert_status 0 "$rc" "管理菜单选择「查看配置」时正常返回"
assert_contains "$out" "vless://22222222-3333-4444-5555-666666666666@198.51.100.9:443" "management_menu 第 1 项展示分享链接"
assert_contains "$out" "198.51.100.9:443" "management_menu 第 1 项展示节点地址"

# 第 2 项：重启服务 → 调 restart_service
out=$( ( eval "$(t10_mocks; t10_mocks_menu)"
         MENU_PICK=2
         t10_menu_pick
         management_menu ) 2>&1 ); rc=$?
assert_status 0 "$rc" "管理菜单选择「重启服务」时正常返回"
assert_contains "$out" "MOCK_RESTART" "management_menu 第 2 项调用 restart_service"

# 第 3 项：实时日志 → 调 journalctl
out=$( ( eval "$(t10_mocks; t10_mocks_menu)"
         MENU_PICK=3
         t10_menu_pick
         management_menu ) 2>&1 ); rc=$?
assert_status 0 "$rc" "管理菜单选择「实时日志」时正常返回"
assert_contains "$out" "MOCK_JOURNALCTL" "management_menu 第 3 项调用 journalctl"

# 第 4 项：更新内核 → 调 ensure_packages + 下载 + 安装 + 重启
out=$( ( eval "$(t10_mocks; t10_mocks_menu)"
         MENU_PICK=4
         t10_menu_pick
         management_menu ) 2>&1 ); rc=$?
assert_status 0 "$rc" "管理菜单选择「更新内核」时正常返回"
assert_contains "$out" "MOCK_ENSURE_PKGS" "management_menu 第 4 项先补齐依赖"
assert_contains "$out" "MOCK_CURL" "management_menu 第 4 项下载安装包"
assert_contains "$out" "MOCK_INSTALL_ZIP" "management_menu 第 4 项执行安装"
assert_contains "$out" "MOCK_RESTART" "management_menu 第 4 项更新成功后重启服务"

# 第 5 项：网络调优 → 已部署时放行防火墙 + 开 BBR
out=$( ( eval "$(t10_mocks; t10_mocks_menu)"
         state_exists() { return 0; }
         load_state() { PORT=443; return 0; }
         MENU_PICK=5
         t10_menu_pick
         management_menu ) 2>&1 ); rc=$?
assert_status 0 "$rc" "管理菜单选择「网络调优」时正常返回"
assert_contains "$out" "MOCK_FIREWALL PORT=443" "management_menu 第 5 项放行已部署的端口"
assert_contains "$out" "MOCK_BBR" "management_menu 第 5 项开启 BBR"
assert_contains "$out" "MOCK_STATUS" "management_menu 第 5 项最后展示服务状态"

# 第 6 项：轮换密钥 → 走完整的换密钥链路
out=$( ( eval "$(t10_mocks; t10_mocks_menu)"
         state_exists() { return 0; }
         load_state() { UUID='22222222-3333-4444-5555-666666666666'; SERVER_IP='198.51.100.9'; PORT=443; SNI='www.microsoft.com'; PUBLIC_KEY='PUBKEY2'; SHORT_ID='b2c3d4e5'; REMARK='node'; return 0; }
         XRAY_CONFIG="$T10_TMP/cfg.json"
         OUT_DIR="$T10_TMP/out"
         MENU_PICK=6
         t10_menu_pick
         management_menu ) 2>&1 ); rc=$?
assert_status 0 "$rc" "管理菜单选择「轮换密钥」时正常返回"
assert_contains "$out" "MOCK_GEN_KEYS" "management_menu 第 6 项生成新密钥"
assert_contains "$out" "MOCK_RENDER" "management_menu 第 6 项重新渲染服务端配置"
assert_contains "$out" "MOCK_ATOMIC" "management_menu 第 6 项原子替换服务端配置"
assert_contains "$out" "MOCK_SAVE_STATE" "management_menu 第 6 项保存新状态"
assert_contains "$out" "MOCK_EXPORT" "management_menu 第 6 项重新导出客户端物料"
assert_contains "$out" "密钥已轮换" "management_menu 第 6 项提示密钥已轮换"

# 第 7 项：卸载 → 单文件分发版没有 uninstall.sh，必须给出手工指引
out=$( ( eval "$(t10_mocks; t10_mocks_menu)"
         ROOT_DIR="$T10_TMP"
         MENU_PICK=7
         t10_menu_pick
         management_menu ) 2>&1 ); rc=$?
assert_status 0 "$rc" "管理菜单选择「卸载」时正常返回"
assert_contains "$out" "没有 uninstall.sh" "management_menu 第 7 项在没有卸载脚本时给出明确提示"
assert_contains "$out" "systemctl disable --now xray" "management_menu 第 7 项给出手工卸载命令"

# 第 8 项：退出
out=$( ( eval "$(t10_mocks; t10_mocks_menu)"
         MENU_PICK=8
         t10_menu_pick
         management_menu ) 2>&1 ); rc=$?
assert_status 0 "$rc" "管理菜单选择「退出」时正常返回"
assert_contains "$out" "已退出" "management_menu 第 8 项提示已退出"

test_case "管理菜单项：未部署时的守卫"

# menu_show_client：未部署 → 提示 + 返回非零，且绝不能去拼分享链接
out=$( ( eval "$(t10_mocks; t10_mocks_menu)"
         menu_show_client ) 2>&1 ); rc=$?
assert_status 1 "$rc" "menu_show_client 在未部署时返回非零"
assert_contains "$out" "尚未部署" "menu_show_client 在未部署时给出明确提示"
assert_not_contains "$out" "vless://" "menu_show_client 在未部署时不展示分享链接"

# menu_rotate_keys：未部署 → 提示 + 返回非零，且绝不能生成新密钥
out=$( ( eval "$(t10_mocks; t10_mocks_menu)"
         menu_rotate_keys ) 2>&1 ); rc=$?
assert_status 1 "$rc" "menu_rotate_keys 在未部署时返回非零"
assert_contains "$out" "尚未部署" "menu_rotate_keys 在未部署时给出明确提示"
assert_not_contains "$out" "MOCK_GEN_KEYS" "menu_rotate_keys 在未部署时不生成新密钥"

# ⚠️ menu_tune：未部署时 $PORT 是空串 → open_firewall "" 会去执行
#    `ufw allow "/tcp"` / `iptables --dport ""` —— 报错与真实原因完全无关。
#    必须有「尚未部署」的守卫，且绝不能碰防火墙。
out=$( ( eval "$(t10_mocks; t10_mocks_menu)"
         menu_tune ) 2>&1 ); rc=$?
assert_status 1 "$rc" "menu_tune 在未部署时返回非零"
assert_contains "$out" "尚未部署" "menu_tune 在未部署时给出明确提示"
assert_not_contains "$out" "MOCK_FIREWALL" "menu_tune 在未部署时不碰防火墙"

test_case "管理菜单项：失败路径必须报错"

# menu_tune：防火墙放行失败 → 必须报错并返回非零
out=$( ( eval "$(t10_mocks; t10_mocks_menu)"
         state_exists() { return 0; }
         load_state() { PORT=443; return 0; }
         open_firewall() { printf 'MOCK_FIREWALL PORT=%s\n' "$1"; return 1; }
         menu_tune ) 2>&1 ); rc=$?
assert_status 1 "$rc" "menu_tune 在防火墙放行失败时返回非零"
assert_contains "$out" "防火墙放行失败" "menu_tune 在防火墙放行失败时给出明确提示"

# menu_tune：BBR 没开是非致命的 → 仍然返回 0
out=$( ( eval "$(t10_mocks; t10_mocks_menu)"
         state_exists() { return 0; }
         load_state() { PORT=443; return 0; }
         enable_bbr() { printf 'MOCK_BBR\n'; return 1; }
         menu_tune ) 2>&1 ); rc=$?
assert_status 0 "$rc" "menu_tune 在 BBR 未启用时仍返回 0"
assert_contains "$out" "BBR 未启用" "menu_tune 在 BBR 未启用时给出警告"

# menu_rotate_keys：状态保存失败 → 必须报错，并如实说明「配置已换、状态没落盘」
out=$( ( eval "$(t10_mocks; t10_mocks_menu)"
         state_exists() { return 0; }
         load_state() { UUID='u'; SERVER_IP='1.2.3.4'; PORT=443; SNI='s'; PUBLIC_KEY='p'; SHORT_ID='x'; REMARK='r'; return 0; }
         save_state() { printf 'MOCK_SAVE_STATE\n'; return 1; }
         XRAY_CONFIG="$T10_TMP/cfg.json"
         OUT_DIR="$T10_TMP/out"
         menu_rotate_keys ) 2>&1 ); rc=$?
assert_status 1 "$rc" "menu_rotate_keys 在状态保存失败时返回非零"
assert_contains "$out" "状态保存失败" "menu_rotate_keys 在状态保存失败时给出明确提示"
assert_contains "$out" "已更新为新密钥" "menu_rotate_keys 如实说明服务端配置已换但状态未落盘"

# menu_rotate_keys：物料导出失败 → 必须报错
out=$( ( eval "$(t10_mocks; t10_mocks_menu)"
         state_exists() { return 0; }
         load_state() { UUID='u'; SERVER_IP='1.2.3.4'; PORT=443; SNI='s'; PUBLIC_KEY='p'; SHORT_ID='x'; REMARK='r'; return 0; }
         export_client_artifacts() { printf 'MOCK_EXPORT\n'; return 1; }
         XRAY_CONFIG="$T10_TMP/cfg.json"
         OUT_DIR="$T10_TMP/out"
         menu_rotate_keys ) 2>&1 ); rc=$?
assert_status 1 "$rc" "menu_rotate_keys 在客户端物料导出失败时返回非零"
assert_contains "$out" "客户端物料导出失败" "menu_rotate_keys 在物料导出失败时给出明确提示"

# menu_rotate_keys：用户取消 → 返回 0（不是失败）
out=$( ( eval "$(t10_mocks; t10_mocks_menu)"
         state_exists() { return 0; }
         load_state() { UUID='u'; SERVER_IP='1.2.3.4'; PORT=443; SNI='s'; PUBLIC_KEY='p'; SHORT_ID='x'; REMARK='r'; return 0; }
         tui_confirm() { return 1; }
         menu_rotate_keys ) 2>&1 ); rc=$?
assert_status 0 "$rc" "menu_rotate_keys 在用户取消时返回 0"
assert_contains "$out" "已取消" "menu_rotate_keys 在用户取消时给出明确提示"
assert_not_contains "$out" "MOCK_GEN_KEYS" "menu_rotate_keys 在用户取消时不生成新密钥"

# menu_update_xray：依赖装不上 → 必须停在这里（不能去下载安装包）
out=$( ( eval "$(t10_mocks; t10_mocks_menu)"
         ensure_packages() { printf 'MOCK_ENSURE_PKGS %s\n' "$*"; return 1; }
         menu_update_xray ) 2>&1 ); rc=$?
assert_status 1 "$rc" "menu_update_xray 在依赖安装失败时返回非零"
assert_contains "$out" "依赖安装失败" "menu_update_xray 在依赖安装失败时给出明确提示"
assert_not_contains "$out" "MOCK_CURL" "menu_update_xray 在依赖安装失败后不下载安装包"

# menu_update_xray：下载失败 → 必须报错，并给出三条可操作的解法
out=$( ( eval "$(t10_mocks; t10_mocks_menu)"
         curl() { printf 'MOCK_CURL %s\n' "$*"; return 1; }
         menu_update_xray ) 2>&1 ); rc=$?
assert_status 1 "$rc" "menu_update_xray 在下载安装包失败时返回非零"
assert_contains "$out" "无法下载 Xray 安装包" "menu_update_xray 在下载失败时给出明确提示"
assert_contains "$out" "--local" "menu_update_xray 在下载失败时提示离线包走法"
assert_not_contains "$out" "MOCK_INSTALL_ZIP" "menu_update_xray 在下载失败后不执行安装"

# menu_update_xray：mktemp 失败 → 必须中止（否则 curl -o "" 会失败、rm -f "" 会报错）
out=$( ( eval "$(t10_mocks; t10_mocks_menu)"
         mktemp() { return 1; }
         menu_update_xray ) 2>&1 ); rc=$?
assert_status 1 "$rc" "menu_update_xray 在 mktemp 失败时返回非零"
assert_contains "$out" "无法创建临时目录" "menu_update_xray 在 mktemp 失败时给出明确提示"

# menu_update_xray：安装失败 → 必须返回非零且不重启
out=$( ( eval "$(t10_mocks; t10_mocks_menu)"
         xray_install_from_zip() { printf 'MOCK_INSTALL_ZIP\n'; return 1; }
         menu_update_xray ) 2>&1 ); rc=$?
assert_status 1 "$rc" "menu_update_xray 在安装失败时返回非零"
assert_not_contains "$out" "MOCK_RESTART" "menu_update_xray 在安装失败后不重启服务"

test_case "向导：手动指定端口的占用复查"

# 手动输入的端口【同样】必须复查占用：
# 只校验范围不校验占用 → 用户会一路走到 systemd 才炸，
# 首句报错是「systemd 配置失败」，与真实原因（端口被占）完全无关。
out=$( ( eval "$(t10_mocks; t10_mocks_wizard)"
         OPT_YES=0
         OPT_PORT=443
         port_in_use() { [[ "$1" == "443" || "$1" == "8443" ]] && return 0 || return 1; }
         tui_menu() { return 1; }
         tui_input() { printf '8443'; return 0; }
         XRAY_CONFIG="$T10_TMP/cfg.json"
         OUT_DIR="$T10_TMP/out"
         deploy_wizard ) 2>&1 ); rc=$?
assert_status 1 "$rc" "deploy_wizard 在手动指定的端口被占用时返回非零"
assert_contains "$out" "已被占用" "deploy_wizard 在手动指定的端口被占用时给出明确提示"
assert_not_contains "$out" "MOCK_DO_DEPLOY" "deploy_wizard 在手动端口被占用时不继续部署"

# 反向对照：手动指定的端口【没有】被占用 → 必须照常部署
out=$( ( eval "$(t10_mocks; t10_mocks_wizard)"
         OPT_YES=0
         OPT_PORT=443
         port_in_use() { [[ "$1" == "443" ]] && return 0 || return 1; }
         tui_menu() { return 1; }
         tui_input() { printf '8443'; return 0; }
         XRAY_CONFIG="$T10_TMP/cfg.json"
         OUT_DIR="$T10_TMP/out"
         deploy_wizard ) 2>&1 ); rc=$?
assert_status 0 "$rc" "deploy_wizard 在手动指定的端口空闲时正常部署"
assert_contains "$out" "MOCK_DO_DEPLOY PORT=8443" "deploy_wizard 采用手动指定的新端口继续部署"

# ⚠️ 防递归：管理菜单的「重新部署」会调 deploy_wizard，
#    而 deploy_wizard 末尾又会调 management_menu → 用户选一次「重新部署」
#    就被套进第二层菜单。用 IN_MENU 标志位把这条回路掐断。
#    正向：已经在菜单里（IN_MENU=1）→ deploy_wizard 【不得】再调管理菜单。
out=$( ( eval "$(t10_mocks; t10_mocks_wizard)"
         OPT_YES=0
         IN_MENU=1
         port_in_use() { return 1; }
         XRAY_CONFIG="$T10_TMP/cfg.json"
         OUT_DIR="$T10_TMP/out"
         deploy_wizard ) 2>&1 ); rc=$?
assert_status 0 "$rc" "deploy_wizard 在已经处于管理菜单中时正常返回"
assert_not_contains "$out" "MOCK_MENU" "deploy_wizard 在已经处于管理菜单中时不再嵌套调用管理菜单"

# 反向对照：不在菜单里（IN_MENU=0）→ deploy_wizard 仍然要落回管理菜单
out=$( ( eval "$(t10_mocks; t10_mocks_wizard)"
         OPT_YES=0
         IN_MENU=0
         port_in_use() { return 1; }
         XRAY_CONFIG="$T10_TMP/cfg.json"
         OUT_DIR="$T10_TMP/out"
         deploy_wizard ) 2>&1 ); rc=$?
assert_status 0 "$rc" "deploy_wizard 在不在管理菜单中时正常返回"
assert_contains "$out" "MOCK_MENU" "deploy_wizard 在【不】处于管理菜单中时仍然落回管理菜单"

test_case "管理菜单：真实 shell 里的非 TTY 渲染"

# 这一组【不 mock 任何东西】：起一个真实的 bash，source 真实的 lib/*，
# 用管道喂「9」选中「退出」→ 验证真实菜单在非 TTY 下能正常渲染并退出。
# ⚠️ 状态文件必须指向一个【必然不存在】的路径：
#    core.sh 的 STATE_FILE="${STATE_FILE:-...}" 会保留调用方预设的值 →
#    开发机上真的部署过时，这一组断言也不会翻脸。
out=$(printf '9\n' | T10_STATE_FILE="$T10_TMP/no-such-state.env" bash "$ROOT/test/helpers/menu_management.sh" 2>&1); rc=$?
assert_status 0 "$rc" "真实 shell 里进入管理菜单并选择退出时返回 0"
assert_contains "$out" "尚未部署" "真实 shell 里未部署时给出明确提示"
assert_contains "$out" "已退出" "真实 shell 里选择退出时提示已退出"

else
  assert_eq "mktemp -d 能创建唯一临时目录" "失败（mktemp -d 返回空路径）" \
    "Task 10 用例前提：mktemp -d 必须能创建唯一临时目录"
fi
rm -rf "$T10_TMP"

# ── Task 11：卸载脚本（全部 mock：不碰系统目录、不动防火墙，不停真服务）──
# ⚠️ 本段【不写任何会整块跳过的条件块】：外部依赖一律用 shell 函数 mock。
# ⚠️ 共享 mock 集合里【不许】出现与被测对象同名的函数
#    （被测对象是 uninstall.sh 里的那些函数，一个都不许出现在共享集合里）。
#
# ⚠️ uninstall.sh 必须【可被 source 而不执行 main】——
#    否则单元测试只能测参数解析，主流程（停服务 / 备份 / 删配置 / 撤防火墙）
#    一条都测不到；而 main 里的 root 检查在非 root 机器上会直接 exit。
#    所以测试用 `UNINSTALL_SH_NO_MAIN=1` + `source` 的方式引入，
#    再逐个函数用 mock 驱动。
#
# ⚠️ mock 的「调用记录」必须走【日志文件】，不能走 stdout：
#    实现里有几处刻意丢弃外部命令的输出（systemctl >/dev/null 2>&1、
#    ufw delete >/dev/null 2>&1）—— 那正是这些命令「成功了但没话说」的正常表现。
#    用 stdout 当记录通道会有两个问题：
#      ① 「命令被调用过」和「命令自己的输出」混在一起，分不清；
#      ② 凡是实现里带了 >/dev/null 的，记录被吞掉 → 断言根本无从观察。
#    记录走日志文件后，「命令被调用过」（calls）与「给用户看的提示」（out）
#    是两条互相独立的通道。

T11_TMP=$(mktemp -d 2>/dev/null)
T11_LOG=''
T11_STATE_DIR="${T11_TMP}/state"
T11_STATE_FILE="${T11_STATE_DIR}/deploy.env"
T11_CONFIG="${T11_TMP}/config.json"
T11_OUT_DIR="${T11_TMP}/out"
T11_SYSCTL_CONF="${T11_TMP}/bbr.conf"

# 共享 mock 集合：卸载流程依赖的【所有】外部动作换成会记日志的假实现。
# ⚠️ cp / rm / mkdir 【不 mock】—— 它们的操作目标全在 $T11_TMP 临时目录里，
#    用真命令跑更真实（还能验证「文件真的被删了」而不只是「调用了 rm」）。
#    只有需要模拟「备份失败 / 删除失败 / 目录建不出来」的那三个用例里
#    才临时覆盖对应的命令。
t11_mocks() {
  cat <<'MOCKS'
have_cmd() { case "$1" in ufw|iptables|nft) return 1 ;; *) return 0 ;; esac; }
systemctl() { printf 'MOCK_SYSTEMCTL %s\n' "$*" >> "$T11_LOG"; return 0; }
ufw() { case "$1" in status) printf 'Status: inactive\n' ;; *) printf 'MOCK_UFW %s\n' "$*" >> "$T11_LOG" ;; esac; return 0; }
iptables() { case "$1" in -C) return 1 ;; *) printf 'MOCK_IPTABLES %s\n' "$*" >> "$T11_LOG" ;; esac; return 0; }
nft() { case "$1" in -a) printf 'table inet filter {\n chain input {\n }\n}\n' ;; *) printf 'MOCK_NFT %s\n' "$*" >> "$T11_LOG" ;; esac; return 0; }
sysctl() { printf 'MOCK_SYSCTL %s\n' "$*" >> "$T11_LOG"; return 0; }
tui_confirm() { printf 'MOCK_CONFIRM %s\n' "$*" >> "$T11_LOG"; return 0; }
tui_panel() { printf 'MOCK_PANEL %s\n' "$*" >> "$T11_LOG"; return 0; }
tui_banner() { printf 'MOCK_BANNER\n' >> "$T11_LOG"; return 0; }
tui_init() { printf 'MOCK_TUI_INIT\n' >> "$T11_LOG"; return 0; }
MOCKS
}

# 把 uninstall.sh 引进来但不跑 main，并装好全套 mock。
# ⚠️ 必须【直接调用】t11_load，绝不能写成 `eval "$(t11_load)"`：
#    `$(...)` 会在【子 shell】里执行 t11_load → 里面 source 进来的被测函数与
#    eval 出来的 mock 全部随子 shell 一起消失 → 被测函数根本不存在，
#    每次调用都是 "command not found"（rc=127）；而断言大多只看输出文本，
#    就会得到一堆【看似失败、实则根本没测到】的红。
t11_load() {
  export UNINSTALL_SH_NO_MAIN=1
  export STATE_DIR="$T11_STATE_DIR"
  export STATE_FILE="$T11_STATE_FILE"
  export XRAY_CONFIG="$T11_CONFIG"
  export OUT_DIR="$T11_OUT_DIR"
  # sysctl 调优文件必须指到临时目录：remove_tuning 会真的 rm 掉它，
  # 用默认路径会【真的删掉这台机器上的 /etc/sysctl.d/99-vless-reality-bbr.conf】。
  export VLESS_REALITY_SYSCTL_CONF="$T11_SYSCTL_CONF"
  # 这几个文件必须【真的存在】：
  #   ① $XRAY_CONFIG —— 被测代码用 [[ -f ]] 判断「配置在不在」，
  #      文件不存在就直接跳过整段备份逻辑 → 备份分支一条都走不到；
  #   ② $STATE_FILE —— 同理，revoke_firewall 用它判断「有没有部署过」；
  #   ③ $VLESS_REALITY_SYSCTL_CONF —— 用来验证 remove_tuning 真的删掉了它。
  # 状态文件里写一个端口：让 revoke_firewall 走得到防火墙分支。
  mkdir -p "$STATE_DIR" "$OUT_DIR"
  printf "PORT='443'\n" > "$STATE_FILE"
  : > "$XRAY_CONFIG"
  : > "$VLESS_REALITY_SYSCTL_CONF"
  # shellcheck source=/dev/null
  source "$ROOT/uninstall.sh"
  eval "$(t11_mocks)"
}

if [[ -n "$T11_TMP" ]]; then
  T11_LOG="${T11_TMP}/calls.log"
  : > "$T11_LOG"

  test_case "uninstall：参数解析"

  # 未知参数 → 非零退出 + 明确提示
  out=$(bash "$ROOT/uninstall.sh" --not-a-flag 2>&1); rc=$?
  assert_status 1 "$rc" "uninstall 未知参数以非零码退出"
  assert_contains "$out" "未知" "uninstall 未知参数给出提示"

  # --help → 0 退出，且帮助里说清 --purge 与「用 bash 调用」
  out=$(bash "$ROOT/uninstall.sh" --help 2>&1); rc=$?
  assert_status 0 "$rc" "uninstall --help 退出码为 0"
  assert_contains "$out" "purge" "uninstall 帮助含 --purge"
  assert_contains "$out" "bash uninstall.sh" "uninstall 帮助用 bash 调用（不依赖执行位）"

  test_case "uninstall：root 检查与可 source 性"

  # ⚠️ EUID 是 bash 的【只读】变量 → 本机无法注入 root 身份 →
  #    「非 root 时返回非零」这条断言在本机与 Debian 上的结果【相反】，
  #    写进单元测试就会让条数随平台漂移 → 只做源码级断言。
  src=$(cat "$ROOT/uninstall.sh")
  assert_contains "$src" "EUID" "uninstall.sh 用 EUID 判定 root 身份"
  assert_contains "$src" "需要 root 权限" "uninstall.sh 在非 root 时给出明确提示"
  assert_contains "$src" "UNINSTALL_SH_NO_MAIN" "uninstall.sh 有「被 source 时不跑 main」的开关"
  assert_contains "$src" "BASH_SOURCE[0]" "uninstall.sh 用 BASH_SOURCE 守卫主流程"

  test_case "uninstall：备份与删除配置"

  # 备份失败 → 必须中止，且【绝不】删除原配置（这是本脚本最关键的安全性质）
  : > "$T11_LOG"
  out=$( ( t11_load
           cp() { return 1; }
           backup_and_remove_config ) 2>&1 ); rc=$?
  assert_status 1 "$rc" "backup_and_remove_config 在备份失败时返回非零"
  assert_contains "$out" "备份配置失败" "备份失败时给出明确提示"
  assert_contains "$out" "未删除原配置" "备份失败时明确说明原配置未被删除"
  if [[ -f "$T11_CONFIG" ]]; then rc=0; else rc=1; fi
  assert_true "$rc" "备份失败时原配置文件仍在（绝没有被删）"

  # 备份目录建不出来 → 同样必须中止，且不删原配置
  : > "$T11_LOG"
  out=$( ( t11_load
           mkdir() { return 1; }
           backup_and_remove_config ) 2>&1 ); rc=$?
  assert_status 1 "$rc" "backup_and_remove_config 在备份目录建不出来时返回非零"
  assert_contains "$out" "无法创建备份目录" "备份目录建不出来时给出明确提示"
  if [[ -f "$T11_CONFIG" ]]; then rc=0; else rc=1; fi
  assert_true "$rc" "备份目录建不出来时原配置文件仍在"

  # 备份成功 → 删配置 + 报告备份路径
  : > "$T11_LOG"
  out=$( ( t11_load
           backup_and_remove_config ) 2>&1 ); rc=$?
  assert_status 0 "$rc" "backup_and_remove_config 在备份成功时返回 0"
  assert_contains "$out" "配置已备份并移除" "备份成功时给出明确提示"
  backup_missing=1
  for f in "$T11_OUT_DIR"/backup/config.json.*; do
    [[ -e "$f" ]] && backup_missing=0
  done
  assert_true "$backup_missing" "备份成功时备份文件真的生成了"
  if [[ ! -f "$T11_CONFIG" ]]; then rc=0; else rc=1; fi
  assert_true "$rc" "备份成功时原配置真的被删除了"

  # 删配置失败 → 必须报错（备份已在，但不能悄悄说成功）
  : > "$T11_LOG"
  out=$( ( t11_load
           rm() { return 1; }
           backup_and_remove_config ) 2>&1 ); rc=$?
  assert_status 1 "$rc" "backup_and_remove_config 在删除原配置失败时返回非零"
  assert_contains "$out" "原配置删除失败" "删除原配置失败时给出明确提示"
  backup_missing=1
  for f in "$T11_OUT_DIR"/backup/config.json.*; do
    [[ -e "$f" ]] && backup_missing=0
  done
  assert_true "$backup_missing" "删除原配置失败时备份文件已经存在（没有回滚丢失）"

  test_case "uninstall：撤销防火墙规则"

  # ufw 处于 active → 必须删规则
  : > "$T11_LOG"
  out=$( ( t11_load
           have_cmd() { case "$1" in ufw) return 0 ;; iptables|nft) return 1 ;; *) return 0 ;; esac; }
           ufw() { case "$1" in status) printf 'Status: active\n' ;; *) printf 'MOCK_UFW %s\n' "$*" >> "$T11_LOG" ;; esac; return 0; }
           load_state() { PORT=443; return 0; }
           revoke_firewall ) 2>&1 ); rc=$?
  calls=$(cat "$T11_LOG")
  assert_status 0 "$rc" "revoke_firewall 在 ufw 分支正常返回 0"
  assert_contains "$out" "已撤销 ufw 规则 443/tcp" "revoke_firewall 如实报告撤销了 ufw 规则"
  assert_contains "$calls" "MOCK_UFW delete allow 443/tcp" "revoke_firewall 真的调用了 ufw delete allow"

  # ufw 存在但没激活 → 不删 ufw 规则
  : > "$T11_LOG"
  out=$( ( t11_load
           have_cmd() { case "$1" in ufw) return 0 ;; iptables|nft) return 1 ;; *) return 0 ;; esac; }
           ufw() { case "$1" in status) printf 'Status: inactive\n' ;; *) printf 'MOCK_UFW %s\n' "$*" >> "$T11_LOG" ;; esac; return 0; }
           load_state() { PORT=443; return 0; }
           revoke_firewall ) 2>&1 ); rc=$?
  calls=$(cat "$T11_LOG")
  assert_status 0 "$rc" "revoke_firewall 在 ufw 未激活时正常返回 0"
  assert_not_contains "$calls" "MOCK_UFW delete" "ufw 未激活时不删 ufw 规则"

  # iptables 分支：必须【数一数】真删了几条，不能只说「已撤销」
  : > "$T11_LOG"
  out=$( ( t11_load
           have_cmd() { case "$1" in iptables) return 0 ;; ufw|nft) return 1 ;; *) return 0 ;; esac; }
           IPT_C=0
           iptables() { case "$1" in
               -C) IPT_C=$((IPT_C+1)); [[ $IPT_C -le 2 ]] && return 0; return 1 ;;
               -D) printf 'MOCK_IPTABLES %s\n' "$*" >> "$T11_LOG"; return 0 ;;
               *) return 0 ;; esac; }
           load_state() { PORT=443; return 0; }
           revoke_firewall ) 2>&1 ); rc=$?
  calls=$(cat "$T11_LOG")
  assert_status 0 "$rc" "revoke_firewall 在 iptables 分支正常返回 0"
  assert_contains "$out" "已撤销 iptables 规则 443/tcp" "revoke_firewall 如实报告撤销了 iptables 规则"
  assert_contains "$out" "2 条" "revoke_firewall 如实报告撤销的条数"
  assert_contains "$calls" "MOCK_IPTABLES -D INPUT" "revoke_firewall 真的调用了 iptables -D"

  # iptables 分支一条都没有 → 不能谎报「已撤销」
  : > "$T11_LOG"
  out=$( ( t11_load
           have_cmd() { case "$1" in iptables) return 0 ;; ufw|nft) return 1 ;; *) return 0 ;; esac; }
           iptables() { case "$1" in -C) return 1 ;; *) return 0 ;; esac; }
           load_state() { PORT=443; return 0; }
           revoke_firewall ) 2>&1 ); rc=$?
  assert_status 0 "$rc" "revoke_firewall 在没有 iptables 规则时正常返回 0"
  assert_contains "$out" "未找到 iptables 规则" "没有 iptables 规则时如实说明未找到"

  # nft 分支：必须用【handle】而不是行号
  : > "$T11_LOG"
  out=$( ( t11_load
           have_cmd() { case "$1" in nft) return 0 ;; ufw|iptables) return 1 ;; *) return 0 ;; esac; }
           nft() { case "$1" in
               -a) printf 'table inet filter {\n chain input {\n  tcp dport 443 accept # handle 7\n }\n}\n' ;;
               *) printf 'MOCK_NFT %s\n' "$*" >> "$T11_LOG" ;; esac; return 0; }
           load_state() { PORT=443; return 0; }
           revoke_firewall ) 2>&1 ); rc=$?
  calls=$(cat "$T11_LOG")
  assert_status 0 "$rc" "revoke_firewall 在 nft 分支正常返回 0"
  assert_contains "$out" "handle 7" "revoke_firewall 用 nft 的 handle（不是行号）删除规则"
  assert_contains "$calls" "MOCK_NFT delete rule inet filter input handle 7" "revoke_firewall 按 handle 删除 nft 规则"

  # 状态文件读不到 → 必须提示，且【不碰】防火墙
  : > "$T11_LOG"
  out=$( ( t11_load
           load_state() { return 1; }
           revoke_firewall ) 2>&1 ); rc=$?
  calls=$(cat "$T11_LOG")
  assert_status 0 "$rc" "revoke_firewall 在状态文件读不到时正常返回 0"
  assert_contains "$out" "状态文件读取失败" "状态文件读不到时给出明确提示"
  assert_not_contains "$calls" "MOCK_UFW" "状态文件读不到时不碰防火墙"

  # 端口未知（状态文件里没有端口）→ 跳过防火墙，且说明原因
  : > "$T11_LOG"
  out=$( ( t11_load
           load_state() { PORT=''; return 0; }
           revoke_firewall ) 2>&1 ); rc=$?
  calls=$(cat "$T11_LOG")
  assert_status 0 "$rc" "revoke_firewall 在端口未知时正常返回 0"
  assert_contains "$out" "未能确定监听端口" "端口未知时如实说明跳过了防火墙撤销"
  assert_not_contains "$calls" "MOCK_UFW" "端口未知时不碰 ufw"

  test_case "uninstall：网络调优与状态清理"

  # sysctl 文件路径必须与 enable_bbr 用的是同一个变量
  : > "$T11_LOG"
  out=$( ( t11_load
           remove_tuning ) 2>&1 ); rc=$?
  calls=$(cat "$T11_LOG")
  assert_status 0 "$rc" "remove_tuning 正常返回 0"
  if [[ ! -f "$T11_SYSCTL_CONF" ]]; then rc=0; else rc=1; fi
  assert_true "$rc" "remove_tuning 真的删掉了 sysctl 调优文件"
  assert_contains "$calls" "MOCK_SYSCTL --system" "remove_tuning 重载了 sysctl"

  # --purge → 删状态文件
  : > "$T11_LOG"
  out=$( ( t11_load
           PURGE=1
           clean_state ) 2>&1 ); rc=$?
  assert_status 0 "$rc" "clean_state 在 --purge 下正常返回 0"
  assert_contains "$out" "已删除状态文件" "clean_state 在 --purge 下给出明确提示"
  if [[ ! -f "$T11_STATE_FILE" ]]; then rc=0; else rc=1; fi
  assert_true "$rc" "clean_state 在 --purge 下真的删掉了状态文件"

  # 不加 --purge → 保留状态文件
  : > "$T11_LOG"
  out=$( ( t11_load
           PURGE=0
           clean_state ) 2>&1 ); rc=$?
  assert_status 0 "$rc" "clean_state 在默认模式下正常返回 0"
  assert_contains "$out" "保留状态文件" "clean_state 在默认模式下说明状态文件被保留"
  if [[ -f "$T11_STATE_FILE" ]]; then rc=0; else rc=1; fi
  assert_true "$rc" "不加 --purge 时状态文件仍在"

  test_case "uninstall：主流程与卸载前确认"

  # 用户不确认 → 必须取消，且【一步都不许做】
  : > "$T11_LOG"
  out=$( ( t11_load
           require_root() { return 0; }
           tui_confirm() { printf 'MOCK_CONFIRM %s\n' "$*" >> "$T11_LOG"; return 1; }
           ASSUME_YES=0
           main ) 2>&1 ); rc=$?
  calls=$(cat "$T11_LOG")
  assert_status 0 "$rc" "用户在卸载前取消时退出码为 0"
  assert_contains "$out" "已取消" "用户取消时给出明确提示"
  assert_not_contains "$calls" "MOCK_SYSTEMCTL" "用户取消时不停止服务"
  if [[ -f "$T11_CONFIG" ]]; then rc=0; else rc=1; fi
  assert_true "$rc" "用户取消时不删除服务端配置"
  if [[ -f "$T11_STATE_FILE" ]]; then rc=0; else rc=1; fi
  assert_true "$rc" "用户取消时不删除状态文件"

  # --yes → 走完整流程
  : > "$T11_LOG"
  out=$( ( t11_load
           require_root() { return 0; }
           ASSUME_YES=1
           main ) 2>&1 ); rc=$?
  calls=$(cat "$T11_LOG")
  assert_status 0 "$rc" "main 在 --yes 下返回 0"
  assert_contains "$calls" "MOCK_SYSTEMCTL disable --now xray" "main 停用了 xray 服务"
  assert_contains "$out" "卸载完成" "main 结束时打印卸载完成"

  # --yes + --purge → 状态文件也被删
  : > "$T11_LOG"
  out=$( ( t11_load
           require_root() { return 0; }
           ASSUME_YES=1
           PURGE=1
           main ) 2>&1 ); rc=$?
  assert_status 0 "$rc" "main 在 --yes --purge 下返回 0"
  assert_contains "$out" "已删除状态文件" "main 在 --purge 下删除了状态文件"
  if [[ ! -f "$T11_STATE_FILE" ]]; then rc=0; else rc=1; fi
  assert_true "$rc" "main 在 --purge 下真的删掉了状态文件"

  test_case "uninstall：可执行位（定点修订）"

  # ⚠️ `-x` 判定依赖执行位，而执行位【不可靠】——
  #    单文件分发版里根本没有 uninstall.sh，curl 下载来的文件也没有执行位
  #    → 用 -x 判定会永远判成「没有」，卸载入口就是死的。
  #    必须用 -f 判定 + `bash` 显式执行。
  inst=$(cat "$ROOT/install.sh")
  assert_not_contains "$inst" 'if [[ -x "$ROOT_DIR/uninstall.sh" ]]' "install.sh 不再用 -x 判定 uninstall.sh"
  assert_contains "$inst" 'exec bash "$ROOT_DIR/uninstall.sh"' "install.sh 用 bash 显式执行 uninstall.sh（不依赖执行位）"
  dep=$(cat "$ROOT/lib/deploy.sh")
  assert_not_contains "$dep" 'if [[ ! -x "$ROOT_DIR/uninstall.sh" ]]' "menu_uninstall 不再用 -x 判定 uninstall.sh"
  assert_contains "$dep" 'exec bash "$ROOT_DIR/uninstall.sh"' "menu_uninstall 用 bash 显式执行 uninstall.sh（不依赖执行位）"

else
  assert_eq "mktemp -d 能创建唯一临时目录" "失败（mktemp -d 返回空路径）" \
    "Task 11 用例前提：mktemp -d 必须能创建唯一临时目录"
fi
rm -rf "$T11_TMP"


# ── Task 12：构建产物、CI 与脚本可执行位 ─────────────────────────
# ⚠️ 本段【不写任何会整块跳过的条件块】：
#    build.sh 在本段开头【必定先跑一遍】→ dist/install.sh 必定存在 →
#    断言条数与机器 / 网络 / 依赖状态【无关】。
#    即使 build.sh 失败，后续断言也照样执行（只是变红）→ 条数恒定。
#    （原计划把 4 条断言放在 `if [[ -f dist/install.sh ]]` 里，
#      条件不成立时那 4 条不执行 → 条数会随 build.sh 成败漂移。）

test_case "Task 12：构建产物"

# ⚠️ 用 out=$(...) 包起来再取 $?：rc 与输出同时拿到，
#    build.sh 失败时能把它的报错直接打进断言消息。
out=$(bash "$ROOT/build.sh" 2>&1); rc=$?
assert_status 0 "$rc" "build.sh 执行成功"
assert_contains "$out" "已生成" "build.sh 报告已生成产物"
assert_true "$([[ -f "$ROOT/dist/install.sh" ]] && echo 0 || echo 1)" "生成 dist/install.sh"

# build.sh 本身的两条硬要求：
#   ① 不用 `sed … | head -1`：head 命中即退出会让上游 sed 收到 SIGPIPE(141)，
#      而 build.sh 有 `set -euo pipefail` → 管道 rc=141 → 构建中止
#      （本仓库的既定约定见 lib/core.sh 的 port_occupant）；
#   ② 必须 chmod +x 产物：分发物 clone 下来要能直接 ./install.sh。
bsh=$(cat "$ROOT/build.sh")
# ⚠️ 判据必须看【代码行】，不能做字面量查找：
#    build.sh 自己的注释里就写着 "head -1"（为了说明为什么不能这么写），
#    字面量查找会把【注释】当成【代码】→ 这条断言【恒红】，什么也证明不了
#    （控制器实测：字面量判据 = 1，代码判据 = 0，而旧版 build.sh 才是真的用了它）。
#    判据：行首不是注释（`^[^#]*`）的行里出现 "| head"。
assert_eq "0" "$(grep -cE '^[^#]*\|[[:space:]]*head' "$ROOT/build.sh" 2>/dev/null || true)" \
  "build.sh 不用提前退出的管道（head -1）"
assert_contains "$bsh" 'chmod +x' "build.sh 把产物设为可执行"

test_case "Task 12：单文件产物自包含"

dist="$ROOT/dist/install.sh"
# 单文件产物必须【不引用】外部 lib/ 路径 —— 否则「下载一个文件就能用」是假的
assert_eq "0" "$(grep -c 'source.*lib/' "$dist" 2>/dev/null || true)" \
  "单文件产物不引用外部 lib/ 路径"
# set 行必须【恰好一条】：零条 → 产物没有 set -u → 未定义变量不报错；
# 两条 → 后一条可能把 -u 关掉
assert_eq "1" "$(grep -c '^set -uo pipefail$' "$dist" 2>/dev/null || true)" \
  "单文件产物里恰好一条 set -uo pipefail"
# 这条 shellcheck 注释也要剥掉（否则产物里留着「这个文件来自 lib/」的误导性注释）
assert_eq "0" "$(grep -c 'shellcheck source=lib/' "$dist" 2>/dev/null || true)" \
  "单文件产物里没有 shellcheck source 注释"
# ROOT_DIR 必须由头部定义（install.sh 自己那行被剥掉了）
assert_contains "$(cat "$dist" 2>/dev/null)" 'ROOT_DIR="$(cd --' \
  "单文件产物自己定义 ROOT_DIR"
# 四个模块都在
# ⚠️ 用 tui_pad 而不是 tui_banner 做判据：tui_banner 在 install.sh 里也有【调用点】，
#    只看 tui_banner 无法区分「lib/tui.sh 内联进来了」与「只是调用点被带进来了」；
#    tui_pad 是 lib/tui.sh 【独有】的符号 → 判据唯一。
assert_contains "$(cat "$dist" 2>/dev/null)" "tui_pad" "单文件产物包含 TUI 实现"
assert_contains "$(cat "$dist" 2>/dev/null)" "render_server_config" "单文件产物包含配置渲染"
# ⚠️ 判据用 client.sh【独有】的 render_client_config，不用 build_share_link：
#    后者在 lib/deploy.sh 里也有【调用点】→ 只看这个名字分不清
#    「client.sh 被内联进来了」与「只是调用点被带进来了」
#    （与上面 tui_pad 不用 tui_banner 是同一条理由）。
assert_contains "$(cat "$dist" 2>/dev/null)" "render_client_config" "单文件产物包含分享链接生成"

test_case "Task 12：单文件产物可独立执行"

out=$(bash "$dist" --help 2>&1); rc=$?
assert_status 0 "$rc" "单文件产物 --help 退出码为 0"
assert_contains "$out" "用法" "单文件产物 --help 给出用法"
out=$(bash -n "$dist" 2>&1); rc=$?
assert_status 0 "$rc" "单文件产物语法正确"

test_case "Task 12：可执行位与用法文案（定点修订）"

# ⚠️ 用法文案必须写 `sudo bash install.sh`（**不是** `./install.sh`）：
#    `curl -o` 下载下来的文件**没有执行位** → `./install.sh` 会 Permission denied。
#    （仓库里的 install.sh 提交模式是 100755，clone 下来就带执行位；
#      但 `bash install.sh` 两种情况都成立。）
inst=$(cat "$ROOT/install.sh")
assert_not_contains "$inst" "sudo ./install.sh" "install.sh 的用法文案不写 sudo ./install.sh"
assert_contains "$inst" "sudo bash install.sh" "install.sh 的用法文案写 sudo bash install.sh"
# 产物里也必须改掉（产物是从 install.sh 派生的）
assert_not_contains "$(cat "$dist" 2>/dev/null)" "sudo ./install.sh" \
  "单文件产物的用法文案不写 sudo ./install.sh"

test_case "Task 12：CI 与按键超时（定点修订）"

assert_true "$([[ -f "$ROOT/.github/workflows/ci.yml" ]] && echo 0 || echo 1)" "CI 配置文件存在"
cic=$(cat "$ROOT/.github/workflows/ci.yml" 2>/dev/null)
assert_contains "$cic" "bash build.sh" "CI 校验 dist 与源码同步"
# ⚠️ 下面四条判据必须看【结构】，不能只查「字符串是否出现」—— 否则【恒真】：
#    * "git diff --exit-code"：把校验的路径改掉之后它【还在】→
#      「字符串还在」的判据抓不住「校验目标被改错」；
#    * "shellcheck"：CI 里出现【两次】（安装 + 执行）→ 删掉安装那一步后，
#      执行那行还在 → 照样抓不住；
#    * .shellcheckrc 的【注释行】里就写着 "SC1090/SC1091" →
#      删掉 disable 行之后整文件里依然有 "SC1090" → 照样抓不住。
#    → 改成数【结构性出现次数】，必须恰好 1 个。
assert_eq "1" "$(grep -c 'git diff --exit-code' "$ROOT/.github/workflows/ci.yml" 2>/dev/null || true)" \
  "CI 用 git diff 判定产物是否脱节"
assert_eq "1" "$(grep -cE '^[[:space:]]*- name: ShellCheck$' "$ROOT/.github/workflows/ci.yml" 2>/dev/null || true)" \
  "CI 跑 ShellCheck"
# 这条 shellcheck 的豁免要看【disable= 行】，不能看整文件（行首不能是「# shellcheck」，
# 否则会被当成 shellcheck 指令解析并报 error）：
# .shellcheckrc 的注释里就写着 SC1090/SC1091 → 整文件查找恒真。
assert_eq "1" "$(grep -cE '^disable=.*SC1090' "$ROOT/.shellcheckrc" 2>/dev/null || true)" \
  "shellcheck 豁免运行时 source（SC1090）"
assert_eq "1" "$(grep -cE '^disable=.*SC1091' "$ROOT/.shellcheckrc" 2>/dev/null || true)" \
  "shellcheck 豁免找不到被 source 的文件（SC1091）"

# lib/tui.sh 的两个按键超时必须【可被环境变量覆盖】：
# 默认的 0.2 / 0.35 秒是【墙钟截止点】，机器繁忙时会把方向键读丢、
# 把两位数输入截断 → CI 上随机红（GitHub runner 是共享机器，负载不可控）。
# 改成 ${TUI_KEY_TIMEOUT:-0.2} 之后，测试 helper 可以把它放大到确定值。
tuic=$(cat "$ROOT/lib/tui.sh")
assert_contains "$tuic" '${TUI_KEY_TIMEOUT:-' "lib/tui.sh 的方向键超时可被环境变量覆盖"
assert_contains "$tuic" '${TUI_DIGIT_TIMEOUT:-' "lib/tui.sh 的数字键超时可被环境变量覆盖"
# ⚠️ 判据必须是「值确实被放大了」，不能只看「出现了这个名字」——
#    `export TUI_KEY_TIMEOUT=0.2` 里也有 TUI_KEY_TIMEOUT → 名字判据【恒真】。
#    → 解析出导出的值，要求它【严格大于默认值】（0.2 / 0.35）；
#      解析不到（文件缺失 / 写法变了）→ 按 0 处理 → 判红。
mh=$(cat "$ROOT/test/helpers/menu_tty.sh")
kto=$(sed -n 's/^export TUI_KEY_TIMEOUT=//p' "$ROOT/test/helpers/menu_tty.sh" | tr -d '[:space:]')
dto=$(sed -n 's/^export TUI_DIGIT_TIMEOUT=//p' "$ROOT/test/helpers/menu_tty.sh" | tr -d '[:space:]')
assert_true "$(awk -v v="${kto:-0}" 'BEGIN{print (v+0>0.2)?0:1}')" "菜单测试 helper 放大了方向键超时"
assert_true "$(awk -v v="${dto:-0}" 'BEGIN{print (v+0>0.35)?0:1}')" "菜单测试 helper 放大了数字键超时"

# ── Task 13：demo.sh、README 与集成测试 ─────────────────────────────
# ⚠️ 本段【不写任何会整块跳过的条件块】：
#    所有断言要么恒定执行、要么在前提不成立时【判红】→
#    断言条数与机器 / 网络 / 依赖状态【无关】。

test_case "Task 13：demo.sh 不触碰系统"

# ⚠️ 必须给 demo.sh 接上 </dev/null：demo.sh 会调用 tui_menu / tui_input /
#    tui_confirm，这三个在【非 TTY 分支里仍然 read stdin】。
#    不接 /dev/null 时，本地交互式跑测试（stdin 是终端）会直接挂死。
# ⚠️ 还必须加 timeout：demo.sh 若在某个分支里等输入不返回，
#    整个测试套件会【挂住】—— CI 上表现为「超时失败」，
#    且看不出是哪一条断言出的问题（这比红更糟）。
out=$(timeout 30 bash "$ROOT/demo.sh" </dev/null 2>&1); rc=$?
assert_status 0 "$rc" "demo.sh 正常退出"
assert_contains "$out" "分享链接" "demo 展示分享链接样例"
assert_eq 0 "$(grep -c 'systemctl ' <<<"$out")" "demo 不调用 systemctl"
assert_eq 0 "$(grep -c 'apt-get' <<<"$out")" "demo 不调用 apt-get"
# 只看输出不够：demo.sh 若把命令输出重定向到 /dev/null，上面的断言就漏掉了。
# 再直接查一次 demo.sh 的源码。
assert_eq 0 "$(grep -cE '^[^#]*(systemctl|apt-get|ufw|iptables|nft|rm -f|systemctl disable)' "$ROOT/demo.sh" || true)" \
  "demo.sh 源码里不含任何改系统的命令"
# ⚠️ demo.sh 依赖「没有 set -e」：tui_menu 在非 TTY 下返回 255（取消）、
#    tui_input 在 EOF 下返回非零 —— 有了 set -e 就会在菜单那一步直接退出，
#    demo 变成半截输出。谁加了一行 set -e，这条断言立刻变红。
assert_eq 0 "$(grep -cE '^[[:space:]]*set -[a-z]*e' "$ROOT/demo.sh" || true)" \
  "demo.sh 不含 set -e（否则 tui_menu 的 255 会让它半路退出）"

test_case "Task 13：超宽内容不撑破边框"

# ⚠️ 分享链接有 150+ 字符，而框内净宽只有 TUI_WIDTH-6（默认 74）→
#    硬塞进框里会把右边框顶出去，框线合不拢（框线必须恰好等于 TUI_WIDTH 才合得拢）。
#    也不能把链接折成多行：用户要从终端复制这一行，折行后粘到客户端是废链接。
#    → 放不下时不开框，改用小节标题 + 整行输出；
#      终端的【软换行】只是显示效果，不会在内容里插入字符 → 复制出来仍是完整的一行。
tuilib=$(cat "$ROOT/lib/tui.sh")
assert_contains "$tuilib" "tui_box_text" "lib/tui.sh 提供超宽内容的处理组件"

# 窄内容：照常画框
narrow=$(tui_box_text "标题" "短内容" 2>&1)
assert_contains "$narrow" "╭" "窄内容照常画框"
assert_contains "$narrow" "短内容" "窄内容的框里有内容"
assert_contains "$narrow" "╰" "窄内容画出了下边框"
# 「框线合得拢」的判据：框的【顶边】与【内容行】的显示宽度必须【相等】
# （两者都应恰好等于 TUI_WIDTH）—— 不等就说明有内容把框撑破了。
box_top=$(tui_box "标题" 2>&1)
box_line=$(tui_box_line "短内容" 2>&1)
top_w=$(tui_dwidth "$(tui_strip "$box_top" | tr -d '\n')")
line_w=$(tui_dwidth "$(tui_strip "$box_line" | tr -d '\n')")
assert_eq "$top_w" "$line_w" "框的顶边与内容行宽度一致（框线合得拢）"

# 超宽内容：不能画框（画了框线就合不拢），但内容一个都不能少
wide_text=$(printf 'x%.0s' {1..200})
wide=$(tui_box_text "标题" "$wide_text" 2>&1)
assert_not_contains "$wide" "╭" "超宽内容不画上边框（框线会合不拢）"
assert_not_contains "$wide" "╰" "超宽内容不画下边框"
assert_contains "$wide" "$wide_text" "超宽内容整行输出，内容一个不少"
assert_contains "$wide" "标题" "超宽内容仍带小节标题"

test_case "Task 13：两处分享链接展示都用 tui_box_text"

dep=$(cat "$ROOT/lib/deploy.sh")
assert_contains "$dep" 'tui_box_text "分享链接（可直接粘贴到客户端导入）" "$link"' \
  "部署完成时用 tui_box_text 显示分享链接"
assert_contains "$dep" 'tui_box_text "分享链接" "$link"' \
  "管理菜单查看分享链接时用 tui_box_text"

test_case "Task 13：README 的验证状态声明"

rmd=$(cat "$ROOT/README.md" 2>/dev/null)
# ⚠️ 判据必须是【标题级】：README **开头的引导语**里也写着
#    「请先读 [验证状态声明](#验证状态声明)」→ 只查「出现过这个词」的话，
#    把小节**标题**改名了这条断言照样绿（控制器实测：rc=0、0 条红）。
#    → 剔掉 ``` 围栏后只认 markdown 的标题行（与下面 9 个小节同款判据）。
rmd_heads=$(awk 'BEGIN{inb=0} /^```/{inb=!inb; next} !inb && /^#+ /{print}' "$ROOT/README.md" 2>/dev/null || true)
assert_true "$(grep -qE '^#+ .*验证状态声明' <<<"$rmd_heads" && echo 0 || echo 1)" "README 有「验证状态声明」小节"
# 下面逐条点名：未验证项必须【逐条】列出，不能含糊成一句「仅供参考」。
assert_contains "$rmd" "权限位" "声明里点名：权限位 600/700 未在 Debian 真机验证"
assert_contains "$rmd" "Debian 真机" "声明里点名：Debian 真机端到端未验证"
assert_contains "$rmd" "shellcheck" "声明里点名：shellcheck 未在本机运行"
assert_contains "$rmd" "nft" "声明里点名：nft 的 handle 语义未实测"
assert_contains "$rmd" "systemd" "声明里点名：真实 systemd 的启停未验证"
assert_contains "$rmd" "REALITY" "声明里点名：REALITY 握手未验证"
assert_contains "$rmd" "TLS 1.3" "声明里点名：单元套件含网络依赖断言（TLS 1.3 探测）"
assert_contains "$rmd" "apt-get" "声明里点名：apt-get 安装 Xray-core 未验证"
# 已验证的项也要列出来，读者才能自己判断哪些结论可信
assert_contains "$rmd" "已验证" "README 同时列出已验证的项"
# 快速开始：必须是「先下载再执行」，不用管道
assert_contains "$rmd" "sudo bash install.sh" "README 给出 sudo bash install.sh 的用法"
assert_contains "$rmd" "curl" "README 给出 curl 单文件方式的命令"

# ⚠️ T13-14：README 里曾陈述「仓库里的 .sh 提交模式是 100644，install.sh 不可执行」
#    —— 但 Task 11 的 T11-6(b) 与 Task 12 的 T12-4 / T12-5 已把 install.sh /
#    uninstall.sh / build.sh / dist/install.sh / demo.sh / test/integration-debian.sh
#    全部提交成 100755。陈述与仓库的真实状态【矛盾】→ 用户会以为 clone 下来的
#    脚本一个都跑不了。真正该说的理由是【另一个】：curl 下载下来的文件没有执行位。
assert_not_contains "$rmd" "100644" "README 不再陈述过时的提交模式（100644）"
assert_contains "$rmd" "没有执行位" "README 点名：curl 下载下来的文件没有执行位"
assert_contains "$rmd" "100755" "README 点名：仓库里的脚本提交模式是 100755"

# 三个入口脚本里的同一处陈述也要改掉 —— 它们不是散文，是用户可能直接读到的源码。
inst13=$(cat "$ROOT/install.sh")
uninst13=$(cat "$ROOT/uninstall.sh")
dep13=$(cat "$ROOT/lib/deploy.sh")
assert_not_contains "$inst13 $dep13 $uninst13" "100644" \
  "install.sh / uninstall.sh / lib/deploy.sh 不再陈述过时的提交模式（100644）"

test_case "Task 13：README 的必需小节一个都不能少"

# ⚠️ Step 5 要求 README 有 12 个小节，但上面那组断言只覆盖了「验证状态声明」那一格 →
#    实现者少写一半小节，测试照样全绿。→ 这里逐个小节点名。
# ⚠️ 判据是【标题级】的：只认 markdown 的标题行，不认「正文里出现过这个词」——
#    否则正文里随口提一句「目录结构」也算数，等于没断言。
#    先把 ``` 围栏里的内容剔掉：代码块里以 # 开头的注释行不算标题。
rmd_heads=$(awk 'BEGIN{inb=0} /^```/{inb=!inb; next} !inb && /^#+ /{print}' "$ROOT/README.md" 2>/dev/null || true)
assert_true "$(grep -qE '^#+ .*(特性|特点)' <<<"$rmd_heads" && echo 0 || echo 1)" "README 有「特性」小节"
assert_true "$(grep -qE '^#+ .*(目录结构|文件结构)' <<<"$rmd_heads" && echo 0 || echo 1)" "README 有「目录结构」小节"
assert_true "$(grep -qE '^#+ .*(CLI|命令行)' <<<"$rmd_heads" && echo 0 || echo 1)" "README 有「CLI 参数」小节"
assert_true "$(grep -qE '^#+ .*(部署向导|部署流程)' <<<"$rmd_heads" && echo 0 || echo 1)" "README 有「部署向导」小节"
assert_true "$(grep -qE '^#+ .*管理菜单' <<<"$rmd_heads" && echo 0 || echo 1)" "README 有「管理菜单」小节"
assert_true "$(grep -qE '^#+ .*(客户端|导入)' <<<"$rmd_heads" && echo 0 || echo 1)" "README 有「客户端导入」小节"
assert_true "$(grep -qE '^#+ .*(常见问题|FAQ)' <<<"$rmd_heads" && echo 0 || echo 1)" "README 有「常见问题」小节"
assert_true "$(grep -qE '^#+ .*卸载' <<<"$rmd_heads" && echo 0 || echo 1)" "README 有「卸载」小节"
assert_true "$(grep -qE '^#+ .*(致谢|上游|Xray-install)' <<<"$rmd_heads" && echo 0 || echo 1)" "README 有「致谢与上游项目链接」小节"

# 光有小节标题还不够，里面得真的说到这些点
assert_contains "$rmd" "v2rayNG" "客户端导入说明里点名 v2rayN / v2rayNG"
assert_contains "$rmd" "Clash" "客户端导入说明里点名 Clash Verge"
assert_contains "$rmd" "BBR" "常见问题里点名 BBR"
assert_contains "$rmd" "二维码" "常见问题里点名二维码缺失"
# ⚠️ T6-7 的登记项在 v1.1 起【已被消除】：工具不再下载、也不再以 root 执行任何第三方脚本。
#    但「本项目声明过哪些风险」这件事必须留在 README 里（读者要能看到风险是怎么变化的），
#    所以仍要求 README 点名「校验和」，并说明现在改用 SHA-256 校验安装包。
assert_contains "$rmd" "校验和" "声明里点名：安装包校验和的处理方式（旧版第三方脚本风险已消除）"
assert_contains "$rmd" "SHA-256" "声明里点名：安装包改用 SHA-256 校验"
assert_contains "$rmd" "不再下载并以 root 执行" "声明里点名：不再以 root 执行第三方脚本"

test_case "Task 13：设计稿的依赖图补上 core.sh → tui.sh（F-18）"

# F-18 是 Task 1 修订轮登记的「留到 Task 13 收尾补设计稿」：
#   设计稿 4.1 的依赖图漏了 core.sh → tui.sh 这条边
#   （core.sh 会调用 tui.sh 的 tui_err / tui_tip / tui_ok）。
design_doc="$ROOT/docs/superpowers/specs/2026-10-21-vless-reality-deploy-design.md"
assert_true "$(grep -qF 'core.sh ──> tui.sh' "$design_doc" 2>/dev/null && echo 0 || echo 1)" \
  "设计稿 4.1 的依赖图补上了 core.sh → tui.sh 边（F-18）"

test_case "Task 13：集成测试脚本"

assert_true "$([[ -f "$ROOT/test/integration-debian.sh" ]] && echo 0 || echo 1)" "集成测试脚本存在"
assert_status 0 "$(bash -n "$ROOT/test/integration-debian.sh" 2>&1; echo $?)" "集成测试脚本语法正确"
itg=$(cat "$ROOT/test/integration-debian.sh" 2>/dev/null)
assert_contains "$itg" "docker" "集成测试用 docker 起容器"
assert_contains "$itg" "test/unit.sh" "集成测试在容器里跑单元测试"
assert_contains "$itg" "build.sh" "集成测试在容器里构建单文件"
assert_contains "$itg" "dist/install.sh" "集成测试在容器里验证单文件产物"

# ══════════════════════════════════════════════════════════════
# Task 14：受限网络环境的下载链与离线安装
# ══════════════════════════════════════════════════════════════
# 背景（本项目真机实测）：目标服务器只有 IPv6、没有公网 IPv4，
# 而 api.github.com / github.com / objects.githubusercontent.com 全都只有 IPv4
# → 上游 install-release.sh 的在线安装必然失败在
#   "Failed to get release list, please check your network."。
# 新版链路自己取 release 压缩包（多源回退 + 代理 + SHA-256 校验），
# 并且支持完全离线的 --local 安装包。下面逐个函数点名断言。

T14_TMP=$(mktemp -d 2>/dev/null)
if [[ -n "$T14_TMP" && -d "$T14_TMP" ]]; then

# ── xray_asset_machine：架构 → release 资产名 ──────────────────────
# 映射错一个 = 在那台机器上下载到 404 的 zip，所以逐个架构点名断言。
out=$( ( uname() { printf 'x86_64\n'; }; xray_asset_machine ) ); rc=$?
assert_eq "64" "$out" "xray_asset_machine 把 x86_64 映射成 64"
out=$( ( uname() { printf 'amd64\n'; }; xray_asset_machine ) )
assert_eq "64" "$out" "xray_asset_machine 把 amd64 映射成 64"
out=$( ( uname() { printf 'aarch64\n'; }; xray_asset_machine ) )
assert_eq "arm64-v8a" "$out" "xray_asset_machine 把 aarch64 映射成 arm64-v8a"
out=$( ( uname() { printf 'armv8l\n'; }; xray_asset_machine ) )
assert_eq "arm64-v8a" "$out" "xray_asset_machine 把 armv8l 映射成 arm64-v8a"
out=$( ( uname() { printf 'armv7l\n'; }; xray_cpu_has_vfp() { return 0; }; xray_asset_machine ) )
assert_eq "arm32-v7a" "$out" "xray_asset_machine 把 armv7l 映射成 arm32-v7a"
out=$( ( uname() { printf 'armv7l\n'; }; xray_cpu_has_vfp() { return 1; }; xray_asset_machine ) )
assert_eq "arm32-v5" "$out" "xray_asset_machine 在没有 vfp 时把 armv7l 降级成 arm32-v5"
out=$( ( uname() { printf 'armv6l\n'; }; xray_cpu_has_vfp() { return 0; }; xray_asset_machine ) )
assert_eq "arm32-v6" "$out" "xray_asset_machine 把 armv6l 映射成 arm32-v6"
out=$( ( uname() { printf 'i686\n'; }; xray_asset_machine ) )
assert_eq "32" "$out" "xray_asset_machine 把 i686 映射成 32"
out=$( ( uname() { printf 's390x\n'; }; xray_asset_machine ) )
assert_eq "s390x" "$out" "xray_asset_machine 把 s390x 映射成 s390x"
out=$( ( uname() { printf 'riscv64\n'; }; xray_asset_machine ) )
assert_eq "riscv64" "$out" "xray_asset_machine 把 riscv64 映射成 riscv64"
out=$( ( uname() { printf 'ppc64le\n'; }; xray_asset_machine ) )
assert_eq "ppc64le" "$out" "xray_asset_machine 把 ppc64le 映射成 ppc64le"
out=$( ( uname() { printf 'mips64le\n'; }; xray_asset_machine ) )
assert_eq "mips64le" "$out" "xray_asset_machine 把 mips64le 映射成 mips64le"
out=$( ( uname() { printf 'mips\n'; }; xray_asset_machine ) )
assert_eq "mips32" "$out" "xray_asset_machine 把 mips 映射成 mips32"
out=$( ( uname() { printf 'sparc64\n'; }; xray_asset_machine ) 2>&1 ); rc=$?
assert_status 1 "$rc" "xray_asset_machine 对未知架构返回非零"
assert_eq "" "$out" "xray_asset_machine 对未知架构不输出资产名"

# ── xray_download_candidates：候选源的顺序与拼接 ──────────────────
out=$( ( GITHUB_MIRROR=''; xray_download_candidates 'https://example.com/a.zip' 'mirror' ) | head -1 )
assert_eq "https://example.com/a.zip" "$out" "未设镜像时第一个候选源是直连地址"
out=$( ( GITHUB_MIRROR='https://m.example/'; xray_download_candidates 'https://example.com/a.zip' 'mirror' ) | head -1 )
assert_eq "https://m.example/https://example.com/a.zip" "$out" "设了镜像时第一个候选源是镜像地址"
out=$( ( GITHUB_MIRROR='https://m.example/'; xray_download_candidates 'https://example.com/a.zip' 'direct' ) | head -1 )
assert_eq "https://example.com/a.zip" "$out" "direct 顺序下直连地址排在镜像之前"
out=$( ( GITHUB_MIRROR='https://m.example'; xray_download_candidates 'https://example.com/a.zip' 'mirror' ) | head -1 )
assert_eq "https://m.example/https://example.com/a.zip" "$out" "镜像前缀末尾没有斜杠时不会拼出双斜杠"
out=$( ( GITHUB_MIRROR=''; xray_download_candidates 'https://example.com/a.zip' 'mirror' ) | wc -l | tr -d ' ' )
assert_eq "3" "$out" "未设镜像时候选源为「直连 + 两个内置镜像」"

# ── xray_download_to：第一个源失败必须自动回退到下一个源 ──────────
out=$( ( GITHUB_MIRROR=''
         _n=0
         curl() { _n=$((_n + 1)); if [[ $_n -eq 1 ]]; then return 22; fi
                  local o=''; while [[ $# -gt 0 ]]; do if [[ "$1" == '-o' ]]; then o="${2:-}"; shift 2; else shift; fi; done
                  printf 'PAYLOAD' > "$o"; return 0; }
         xray_download_to 'https://example.com/a.zip' "$T14_TMP/a.zip" 'mirror'
         printf 'USED=%s\n' "$DOWNLOAD_SOURCE_USED" ) 2>&1 ); rc=$?
assert_status 0 "$rc" "xray_download_to 在首个源失败后自动回退到下一个源"
if [[ "$out" == *"USED=https://example.com/a.zip"* ]]; then same=1; else same=0; fi
assert_eq "0" "$same" "xray_download_to 不会把失败的源记成已用源"
assert_true "$([[ -s "$T14_TMP/a.zip" ]] && echo 0 || echo 1)" "xray_download_to 回退成功后落下了文件"

# ── xray_download_to：所有源都失败时返回非零且不留半截文件 ──────────
out=$( ( GITHUB_MIRROR=''; curl() { return 22; }
         xray_download_to 'https://example.com/a.zip' "$T14_TMP/b.zip" 'mirror' ) 2>&1 ); rc=$?
assert_status 1 "$rc" "xray_download_to 在所有源都失败时返回非零"
assert_true "$([[ ! -s "$T14_TMP/b.zip" ]] && echo 0 || echo 1)" "xray_download_to 失败后不留半截文件"

# ── xray_download_to：代理必须透传给 curl ──────────────────────────
out=$( ( GITHUB_MIRROR=''; XRAY_PROXY='http://127.0.0.1:7890'
         curl() { printf 'CURL %s\n' "$*"
                  local o=''; while [[ $# -gt 0 ]]; do if [[ "$1" == '-o' ]]; then o="${2:-}"; shift 2; else shift; fi; done
                  printf 'PAYLOAD' > "$o"; return 0; }
         xray_download_to 'https://example.com/a.zip' "$T14_TMP/c.zip" 'mirror' ) 2>&1 )
assert_contains "$out" "-x http://127.0.0.1:7890" "xray_download_to 把代理透传给 curl"

# ── xray_verify_sha256：用官方 .dgst 校验安装包 ────────────────────
printf 'FAKE-PACKAGE-CONTENT' > "$T14_TMP/pkg.zip"
if have_cmd openssl; then
  real_sum=$(openssl dgst -sha256 "$T14_TMP/pkg.zip" 2>/dev/null | awk '{print $NF}')
  out=$( ( GITHUB_MIRROR=''
           curl() { local o='' u=''; while [[ $# -gt 0 ]]; do
                      if [[ "$1" == '-o' ]]; then o="${2:-}"; shift 2
                      elif [[ "$1" == -* ]]; then shift
                      else u="$1"; shift; fi; done
                    case "$u" in *.dgst) printf 'SHA2-256= %s\n' "$real_sum" > "$o" ;; *) printf 'PAYLOAD' > "$o" ;; esac
                    return 0; }
           xray_verify_sha256 "$T14_TMP/pkg.zip" 'https://example.com/pkg.zip' ) 2>&1 ); rc=$?
  assert_status 0 "$rc" "xray_verify_sha256 在哈希一致时返回 0"
  assert_contains "$out" "校验通过" "xray_verify_sha256 校验通过时给出提示"

  out=$( ( GITHUB_MIRROR=''
           curl() { local o='' u=''; while [[ $# -gt 0 ]]; do
                      if [[ "$1" == '-o' ]]; then o="${2:-}"; shift 2
                      elif [[ "$1" == -* ]]; then shift
                      else u="$1"; shift; fi; done
                    case "$u" in *.dgst) printf 'SHA2-256= %s\n' "0000000000000000000000000000000000000000000000000000000000000000" > "$o" ;; *) printf 'PAYLOAD' > "$o" ;; esac
                    return 0; }
           xray_verify_sha256 "$T14_TMP/pkg.zip" 'https://example.com/pkg.zip' ) 2>&1 ); rc=$?
  assert_status 1 "$rc" "xray_verify_sha256 在哈希不一致时返回 1"
  assert_contains "$out" "校验不通过" "xray_verify_sha256 哈希不符时给出明确提示"

  out=$( ( GITHUB_MIRROR=''; curl() { return 22; }
           xray_verify_sha256 "$T14_TMP/pkg.zip" 'https://example.com/pkg.zip' ) 2>&1 ); rc=$?
  assert_status 2 "$rc" "xray_verify_sha256 在取不到校验文件时返回 2（不阻断）"
  if [[ "$out" == *"校验通过"* ]]; then lied=1; else lied=0; fi
  assert_eq "0" "$lied" "xray_verify_sha256 取不到校验文件时不得谎报『校验通过』"

  out=$( ( have_cmd() { return 1; }
           xray_verify_sha256 "$T14_TMP/pkg.zip" 'https://example.com/pkg.zip' ) 2>&1 ); rc=$?
  assert_status 2 "$rc" "xray_verify_sha256 在 openssl 不可用时返回 2（不阻断）"
else
  assert_eq "openssl 可用" "openssl 不可用" \
    "SHA-256 校验用例前提：openssl 必须可用（random_hex 用例已覆盖其回退路径）"
fi

# ── xray_install_from_zip：离线安装包 → 二进制 + systemd unit ─────
mkdir -p "$T14_TMP/bin"
printf '#!/bin/sh\nprintf "Xray 1.8.0 (fake)\n"\n' > "$T14_TMP/fake-xray"
chmod 755 "$T14_TMP/fake-xray"
out=$( ( XRAY_BIN="$T14_TMP/bin/xray"; XRAY_SERVICE_UNIT="$T14_TMP/xray.service"
         id() { return 0; }
         unzip() { local d=''; while [[ $# -gt 0 ]]; do if [[ "$1" == '-d' ]]; then d="${2:-}"; shift 2; else shift; fi; done
                   cp -f "$T14_TMP/fake-xray" "$d/xray"; return 0; }
         xray_install_from_zip "$T14_TMP/pkg.zip" ) 2>&1 ); rc=$?
assert_status 0 "$rc" "xray_install_from_zip 从离线包安装成功时返回 0"
assert_true "$([[ -x "$T14_TMP/bin/xray" ]] && echo 0 || echo 1)" "xray_install_from_zip 把二进制装到了目标位置"
assert_true "$([[ -f "$T14_TMP/xray.service" ]] && echo 0 || echo 1)" "xray_install_from_zip 写出了 systemd unit"
unit_txt=$(cat "$T14_TMP/xray.service" 2>/dev/null)
assert_contains "$unit_txt" "ExecStart=$T14_TMP/bin/xray run -config" "systemd unit 的 ExecStart 指向实际二进制与配置"
assert_contains "$unit_txt" "User=xray" "systemd unit 以 xray 用户运行"
assert_contains "$unit_txt" "CAP_NET_BIND_SERVICE" "systemd unit 给了绑定特权端口的能力"

# ── xray_install_from_zip：包不存在 / 不是有效安装包时必须明确报错 ──
out=$( ( XRAY_BIN="$T14_TMP/bin/xray"; XRAY_SERVICE_UNIT="$T14_TMP/xray.service"
         xray_install_from_zip "$T14_TMP/no-such-file.zip" ) 2>&1 ); rc=$?
assert_status 1 "$rc" "xray_install_from_zip 在安装包不存在时返回非零"
assert_contains "$out" "不存在或为空" "xray_install_from_zip 在安装包不存在时给出明确提示"
out=$( ( XRAY_BIN="$T14_TMP/bin/xray"; XRAY_SERVICE_UNIT="$T14_TMP/xray.service"
         unzip() { return 9; }
         xray_install_from_zip "$T14_TMP/pkg.zip" ) 2>&1 ); rc=$?
assert_status 1 "$rc" "xray_install_from_zip 在解压失败时返回非零"
assert_contains "$out" "解压安装包失败" "xray_install_from_zip 在解压失败时给出明确提示"

# ── install.sh 的三个新选项：解析与校验 ────────────────────────────
out=$( ( INSTALL_SH_NO_MAIN=1; source "$ROOT/install.sh"
         parse_args --mirror 'https://m.example/' --proxy 'http://127.0.0.1:7890'
         printf 'MIRROR=%s\nPROXY=%s\n' "$GITHUB_MIRROR" "$XRAY_PROXY" ) 2>&1 ); rc=$?
assert_status 0 "$rc" "parse_args 解析 --mirror 与 --proxy 时返回 0"
assert_contains "$out" "MIRROR=https://m.example/" "parse_args 把 --mirror 写进 GITHUB_MIRROR"
assert_contains "$out" "PROXY=http://127.0.0.1:7890" "parse_args 把 --proxy 写进 XRAY_PROXY"

printf 'FAKE-PACKAGE-CONTENT' > "$T14_TMP/local.zip"
out=$( ( INSTALL_SH_NO_MAIN=1; source "$ROOT/install.sh"
         parse_args --local "$T14_TMP/local.zip"
         printf 'LOCAL=%s\n' "$XRAY_LOCAL_FILE" ) 2>&1 ); rc=$?
assert_status 0 "$rc" "parse_args 解析 --local 时返回 0"
assert_contains "$out" "LOCAL=$T14_TMP/local.zip" "parse_args 把 --local 写进 XRAY_LOCAL_FILE"

# 非法值必须在【参数解析口】就拒掉：不能等下载失败之后才发现写错了。
out=$( ( INSTALL_SH_NO_MAIN=1; source "$ROOT/install.sh"; parse_args --mirror 'not-a-url' ) 2>&1 ); rc=$?
assert_status 1 "$rc" "parse_args 拒绝非 http(s) 的 --mirror"
assert_contains "$out" "--mirror 必须是 http(s) 镜像地址" "parse_args 对非法 --mirror 给出明确提示"
out=$( ( INSTALL_SH_NO_MAIN=1; source "$ROOT/install.sh"; parse_args --proxy 'not-a-url' ) 2>&1 ); rc=$?
assert_status 1 "$rc" "parse_args 拒绝非法的 --proxy"
assert_contains "$out" "--proxy 必须是 http/https/socks5 代理地址" "parse_args 对非法 --proxy 给出明确提示"
out=$( ( INSTALL_SH_NO_MAIN=1; source "$ROOT/install.sh"; parse_args --local "$T14_TMP/no-such-file.zip" ) 2>&1 ); rc=$?
assert_status 1 "$rc" "parse_args 拒绝不存在的 --local 文件"
assert_contains "$out" "不存在或不可读" "parse_args 对不存在的 --local 给出明确提示"

rm -rf "$T14_TMP"
else
  assert_eq "mktemp -d 能创建唯一临时目录" "失败（mktemp -d 返回空路径）" \
    "Task 14 用例前提：mktemp -d 必须能创建唯一临时目录"
fi

test_summary
