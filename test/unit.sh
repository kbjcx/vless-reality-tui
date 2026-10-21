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
[[ -e "$t_dir/pwned" ]]; rc=$?
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

assert_eq "1.0.0" "$APP_VERSION" "core.sh 的 APP_VERSION 统一为 1.0.0"
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
[[ -n "$port_in_use_body" ]]; assert_true "$?" \
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
else
  assert_eq "mktemp -d 能创建唯一临时目录" "失败（mktemp -d 返回空路径）" \
    "write_config_atomic 用例前提：mktemp -d 必须能创建唯一临时目录"
fi
rm -rf "$atomic_dir"

test_summary
