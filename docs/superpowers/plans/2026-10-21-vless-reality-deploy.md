# VLESS + REALITY 一键部署工具 · 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 交付一个零依赖纯 bash TUI 工具，在 Debian 服务器上一键部署 VLESS + REALITY（Xray-core + systemd），并产出可直接导入客户端的分享链接与二维码。

**Architecture:** 分层模块化。`lib/tui.sh` 是零业务逻辑的展示层组件库；`lib/core.sh` 负责环境探测与状态；`lib/deploy.sh` 负责 Xray 安装/配置/systemd/防火墙/BBR；`lib/client.sh` 负责客户端物料导出。依赖严格单向 `install.sh → deploy.sh/client.sh → core.sh → tui.sh`。`build.sh` 把 `lib/` 内联成 `dist/install.sh` 单文件分发物，CI 校验两者同步。

**Tech Stack:** Bash 4.2+ / ANSI 转义序列 / Xray-core / systemd / ufw|nft|iptables

**设计文档:** `docs/superpowers/specs/2026-10-21-vless-reality-deploy-design.md`

---

## Global Constraints

以下约束适用于**每一个**任务，任务描述不再重复：

- 纯 bash 4.2+，**零第三方 TUI 依赖**（不装 dialog / whiptail / gum / ncurses）
- 允许使用的外部命令仅限：`curl` `openssl` `systemctl` `ss` `ip` `awk` `sed` `grep` `od` `tr` `cat` `mktemp` `cp` `mv` `rm` `mkdir` `chmod` `chown` `apt-get` `qrencode`(可选) `python3`(可选，仅 urlencode 回退)
- `lib/tui.sh` **不得**包含任何业务判断、文件写入或系统调用（唯一例外：`mktemp` 用于 `tui_run` 捕获输出）
- 状态文件 `/etc/vless-reality/deploy.env` 权限 `600`，状态目录 `700`；客户端导出目录 `/root/vless-reality/` 权限 `700`
- 服务端配置写入流程恒为：**写临时文件 → `xray run -test` 校验 → 通过才 `mv` 原子替换**；不通过则保留旧配置并原样输出 xray 报错
- 不得使用 `jq`；不得用 `grep` 反解 JSON
- 所有 `.sh` 文件必须 LF 行尾（`.gitattributes` 已锁定）
- 非 TTY 环境（`nohup` / `curl | bash` / CI）必须降级为编号列表，**不得挂死**
- 所有失败路径必须以非零退出码结束，且经 `tui_err` 输出
- 变量命名：全局状态用大写（`PORT` `UUID` `SNI` `PRIVATE_KEY` `PUBLIC_KEY` `SHORT_ID` `SERVER_IP` `REMARK`），函数局部用小写下划线
- 函数返回约定：成功 `0`，失败非 `0`；菜单类函数返回 **0-based 索引**，取消返回 `255`

---

## File Structure

| 文件 | 职责 |
|---|---|
| `lib/tui.sh` | 展示层：颜色/边框/菜单/输入/确认/spinner/面板。零业务逻辑 |
| `lib/core.sh` | 环境探测、IP/端口/TLS 探测、随机数、URL 编码、状态读写 |
| `lib/deploy.sh` | Xray 安装、密钥生成、配置渲染、systemd、防火墙、BBR |
| `lib/client.sh` | 分享链接、客户端 JSON、二维码、客户端物料落盘 |
| `install.sh` | 入口：参数解析 → 预检 → 向导 / 管理菜单 / --status |
| `uninstall.sh` | 卸载与回滚 |
| `build.sh` | `lib/` → `dist/install.sh` |
| `demo.sh` | 纯预览 TUI 外观，不触碰系统 |
| `test/lib.sh` | 断言库（纯 bash，不依赖 bats） |
| `test/unit.sh` | 单元测试入口 |
| `test/integration-debian.sh` | Debian 容器内端到端（需 Docker） |
| `dist/install.sh` | 构建产物，提交进仓库 |
| `.github/workflows/ci.yml` | bash -n + shellcheck + dist 同步校验 |

---

## Task 1: 断言库 + TUI 基础层（宽度/补白/颜色/边框）

**Files:**
- Create: `test/lib.sh`
- Create: `test/unit.sh`
- Create: `lib/tui.sh`

**Interfaces:**
- Consumes: 无（首个任务）
- Produces:
  - `test/lib.sh` 提供 `assert_eq <期望> <实际> [描述]`、`assert_contains <大串> <子串> [描述]`、`assert_status <期望码> <实际码> [描述]`、`assert_true` / `assert_false`、`test_summary`
  - `lib/tui.sh` 提供：`tui_init`、`tui_repeat <char> <n>`、`tui_dwidth <str>`、`tui_pad <str> <width>`、`tui_strip <str>`、`tui_banner`、`tui_section`、`tui_box`、`tui_box_line`、`tui_box_end`、`tui_panel`、`tui_info/ok/warn/err/tip/step`、`tui_kv`

**Step 1: 写断言库**

创建 `test/lib.sh`：

```bash
#!/usr/bin/env bash
# 极简断言库：纯 bash 实现，不依赖 bats / shunit2
# 用法：source test/lib.sh; assert_eq "期望" "实际" "描述"

TEST_PASS=0
TEST_FAIL=0
TEST_CASE="${TEST_CASE:-未命名}"

test_case() {
  TEST_CASE="$1"
  printf '\n  \033[1m%s\033[0m\n' "$1"
}

assert_eq() {
  local expected="$1" actual="$2" msg="${3:-值相等}"
  if [[ "$expected" == "$actual" ]]; then
    TEST_PASS=$((TEST_PASS + 1))
    printf '    \033[32m✔\033[0m %s\n' "$msg"
  else
    TEST_FAIL=$((TEST_FAIL + 1))
    printf '    \033[31m✘\033[0m %s\n' "$msg"
    printf '        期望: %s\n' "$expected"
    printf '        实际: %s\n' "$actual"
  fi
}

assert_contains() {
  local haystack="$1" needle="$2" msg="${3:-包含子串}"
  if [[ "$haystack" == *"$needle"* ]]; then
    TEST_PASS=$((TEST_PASS + 1))
    printf '    \033[32m✔\033[0m %s\n' "$msg"
  else
    TEST_FAIL=$((TEST_FAIL + 1))
    printf '    \033[31m✘\033[0m %s\n' "$msg"
    printf '        期望包含: %s\n' "$needle"
    printf '        实际: %s\n' "$haystack"
  fi
}

assert_status() {
  local expected="$1" actual="$2" msg="${3:-退出码}"
  assert_eq "$expected" "$actual" "$msg (期望码 $expected / 实际码 $actual)"
}

assert_true()  { if [[ "$1" == "0" ]]; then assert_eq 0 0 "${2:-为真}"; else assert_eq 0 1 "${2:-为真}"; fi; }
assert_false() { if [[ "$1" == "0" ]]; then assert_eq 0 1 "${2:-为假}"; else assert_eq 0 0 "${2:-为假}"; fi; }

test_summary() {
  printf '\n  ────────────────────────────────\n'
  if [[ $TEST_FAIL -eq 0 ]]; then
    printf '  \033[32m全部通过\033[0m：%d 项断言\n' "$TEST_PASS"
    return 0
  fi
  printf '  \033[31m失败 %d 项\033[0m（通过 %d 项）\n' "$TEST_FAIL" "$TEST_PASS"
  return 1
}
```

**Step 2: 写失败的测试**

创建 `test/unit.sh`（后续任务持续向其中追加用例）：

```bash
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
assert_eq "6"  "$(tui_dwidth '中文')"          "两个中文字符宽度 = 4"
assert_eq "6"  "$(tui_dwidth 'ab中文')"        "ASCII 与中文混合宽度"
assert_eq "1"  "$(tui_dwidth '')"              "空串宽度 = 0"

assert_eq "-----  "  "$(tui_pad '-----' 9)"   "补白到指定宽度"
assert_eq "abc"      "$(tui_pad 'abc' 3)"      "已达宽度则不截断"
assert_eq "-----"    "$(tui_repeat '-' 5)"     "重复字符"

assert_eq "hello" "$(tui_strip $'\033[32mhello\033[0m')" "剥离 ANSI 序列"

test_summary
```

> 注：`tui_dwidth '中文'` 的期望值 6 —— 「中」「文」各占 2 列。

**Step 3: 运行测试确认失败**

```bash
bash test/unit.sh
```

预期：FAIL，报 `lib/tui.sh: No such file or directory` 或函数未定义。

**Step 4: 实现 `lib/tui.sh` 基础层**

创建 `lib/tui.sh`（完整实现，含后续任务要用的交互组件；交互组件在 Task 2 补齐，先把基础层与接口占位写全）：

```bash
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

tui_pad() {
  local s="$1" width="$2" d
  d=$(tui_dwidth "$s")
  (( d < width )) && s+=$(tui_repeat ' ' $((width - d)))
  printf '%s' "$s"
}

tui_strip() {
  printf '%s' "$1" | sed -e 's/\033\[[0-9;]*m//g'
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
```

**Step 5: 运行测试确认通过**

```bash
bash test/unit.sh
```

预期：`全部通过：N 项断言`，退出码 0。

**Step 6: 提交**

```bash
git add test/lib.sh test/unit.sh lib/tui.sh
git commit -m "feat(tui): 基础层——颜色、宽度计算、边框与消息组件"
```

---

## Task 2: TUI 交互层（菜单/输入/确认/spinner）

**Files:**
- Modify: `lib/tui.sh`（追加交互组件）
- Modify: `test/unit.sh`（追加用例）

**Interfaces:**
- Consumes: Task 1 的 `tui_pad` `tui_repeat` `tui_section` `C_*` 变量
- Produces:
  - `tui_run <msg> <cmd> [args...]` → 返回命令退出码；非 TTY 下不显示 spinner
  - `tui_confirm <prompt> [y|n]` → `0`=是 `1`=否
  - `tui_input <prompt> [default] [hint]` → stdout 输出用户输入
  - `tui_input_secret <prompt> [default]` → stdout 输出用户输入（不回显）
  - `tui_menu <title> <item>...` → stdout 打印选中项；返回 0-based 索引，取消返回 `255`
  - `tui_select <title> <default_item> <item>...` → 同上，默认高亮 `default_item`
  - `tui_pause`

**Step 1: 写失败的测试**

追加到 `test/unit.sh`：

```bash
test_case "TUI 交互组件（非 TTY 降级路径）"

# 非 TTY 下 tui_menu 必须打印带序号的完整列表并读入序号，不得挂死
out=$(printf '2\n' | bash "$ROOT/test/helpers/menu_noninteractive.sh")
assert_contains "$out" "3)" "非 TTY 菜单打印完整编号列表"
assert_status 1 "$?" "非 TTY 菜单返回选中项索引（0-based）"

# 取消（EOF）必须返回 255
out=$(printf '' | bash "$ROOT/test/helpers/menu_noninteractive.sh")
assert_status 255 "$?" "非 TTY 菜单遇 EOF 返回 255"

# 确认：默认应为「是」
out=$(printf '\n' | bash "$ROOT/test/helpers/confirm.sh" y)
assert_contains "$out" "yes" "tui_confirm 默认值 y → yes"

out=$(printf '\n' | bash "$ROOT/test/helpers/confirm.sh" n)
assert_contains "$out" "no" "tui_confirm 默认值 n → no"

# 输入：空输入回落到默认值
out=$(printf '\n' | bash "$ROOT/test/helpers/input.sh" "默认端口" "443")
assert_eq "443" "$out" "tui_input 空输入返回默认值"
```

同时创建三个 helper（`test/helpers/`）：

`test/helpers/menu_noninteractive.sh`：

```bash
#!/usr/bin/env bash
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/lib/tui.sh"
tui_init
tui_menu "选择" "选项一" "选项二" "选项三"
exit $?
```

`test/helpers/confirm.sh`：

```bash
#!/usr/bin/env bash
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/lib/tui.sh"
tui_init
if tui_confirm "确认继续" "$1"; then echo yes; else echo no; fi
```

`test/helpers/input.sh`：

```bash
#!/usr/bin/env bash
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/lib/tui.sh"
tui_init
tui_input "$1" "$2"
printf '\n'
```

**Step 2: 运行测试确认失败**

```bash
bash test/unit.sh
```

预期：FAIL，`tui_menu: command not found`。

**Step 3: 实现交互组件**

追加到 `lib/tui.sh`：

```bash
tui_run() {
  local msg="$1"; shift
  local tmp rc=0

  if [[ $TUI_TTY -eq 0 ]]; then
    printf '  %s%s%s %s ... ' "$C_ACCENT" "$I_ARROW" "$C_RESET" "$msg"
    if "$@" >/dev/null 2>&1; then
      printf '%s%s%s\n' "$C_OK" "$I_OK" "$C_RESET"; return 0
    fi
    printf '%s%s%s\n' "$C_ERR" "$I_ERR" "$C_RESET"; return 1
  fi

  tmp=$(mktemp 2>/dev/null || printf '/tmp/.tui.%s' "$$")
  "$@" >"$tmp" 2>&1 &
  local pid=$! frames='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏' i=0
  while kill -0 "$pid" 2>/dev/null; do
    printf '\r  %s%s%s %s%s%s' "$C_ACCENT" "${frames:$((i % 10)):1}" "$C_RESET" "$C_GRAY" "$msg" "$C_RESET"
    i=$((i + 1)); sleep 0.08
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

tui_confirm() {
  local prompt="$1" default="${2:-y}" ans hint
  if [[ "$default" == "y" || "$default" == "Y" ]]; then hint="Y/n"; else hint="y/N"; fi
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
    printf '%s' "$ans"; return
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
    printf '%s' "$ans"; return
  fi
  printf '  %s%s%s %s ' "$C_ACCENT" "$I_ARROW" "$C_RESET" "$prompt"
  IFS= read -rs ans || ans=''
  printf '\n'
  [[ -z "$ans" ]] && ans="$def"
  printf '%s' "$ans"
}

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
```

**Step 4: 运行测试确认通过**

```bash
bash test/unit.sh
```

预期：全部通过。

**Step 5: 提交**

```bash
git add lib/tui.sh test/unit.sh test/helpers/
git commit -m "feat(tui): 交互层——菜单、输入、确认与 spinner"
```

---

## Task 3: core.sh 纯函数与状态管理

**Files:**
- Create: `lib/core.sh`
- Modify: `test/unit.sh`

**Interfaces:**
- Consumes: 无
- Produces:
  - `have_cmd <cmd>` → `0`/`1`
  - `trim <str>` → stdout
  - `urlencode <str>` → stdout
  - `random_hex <bytes>` → stdout 小写十六进制
  - `read_file <path>` → stdout（已 trim）
  - `detect_os [os_release_path]` → stdout `"id|version|arch"`
  - `assert_debian` → `0`/`1`
  - `save_state` / `load_state` / `state_exists`
  - 常量：`STATE_DIR` `STATE_FILE` `OUT_DIR` `XRAY_BIN` `XRAY_CONFIG` `LOG_DIR` `REALITY_TARGETS[]`

**Step 1: 写失败的测试**

追加到 `test/unit.sh`（需在文件顶部 `source "$ROOT/lib/core.sh"`）：

```bash
source "$ROOT/lib/core.sh"

test_case "core 纯函数"

assert_eq "hello world" "$(trim '  hello world  ')" "trim 去除首尾空白"
assert_eq "a%20b" "$(urlencode 'a b')" "urlencode 编码空格"
assert_eq "%E4%B8%AD%E6%96%87" "$(urlencode '中文')" "urlencode 编码中文"
assert_eq "abc123" "$(urlencode 'abc-123')" "urlencode 保留安全字符"

assert_eq "16"  "${#-}" 2>/dev/null || true
assert_eq "16"  "$(printf '%s' "$(random_hex 8)" | wc -c | tr -d ' ')" "random_hex 8 字节 = 16 个十六进制字符"
assert_match_hex() {
  local v="$1"
  if [[ "$v" =~ ^[0-9a-f]+$ ]]; then assert_eq 0 0 "random_hex 输出为小写十六进制"; else assert_eq 0 1 "random_hex 输出为小写十六进制"; fi
}
assert_match_hex "$(random_hex 4)"

# detect_os 必须能解析传入的 os-release 路径
fake_os=$(mktemp)
cat >"$fake_os" <<'EOF'
ID=debian
VERSION_ID="12"
EOF
assert_eq "debian|12|$(uname -m)" "$(detect_os "$fake_os")" "detect_os 解析 id|version|arch"
rm -f "$fake_os"
```

> 注：`detect_os` 接受可选参数 `os_release_path`，默认 `/etc/os-release`——这使它可测。

**Step 2: 运行测试确认失败**

```bash
bash test/unit.sh
```

预期：FAIL，`lib/core.sh: No such file or directory`。

**Step 3: 实现 `lib/core.sh`**

创建 `lib/core.sh`（本任务只写纯函数与状态部分，网络探测在 Task 4 追加）：

```bash
#!/usr/bin/env bash
# lib/core.sh — 环境探测与通用能力

APP_NAME='VLESS + REALITY 部署工具'
APP_VERSION='1.0.0'

LIB_DIR="${LIB_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)}"
STATE_DIR="${STATE_DIR:-/etc/vless-reality}"
STATE_FILE="$STATE_DIR/deploy.env"
OUT_DIR="${OUT_DIR:-/root/vless-reality}"
XRAY_BIN="${XRAY_BIN:-/usr/local/bin/xray}"
XRAY_CONFIG="${XRAY_CONFIG:-/usr/local/etc/xray/config.json}"
LOG_DIR="${LOG_DIR:-/var/log/xray}"

REALITY_TARGETS=(
  'www.microsoft.com'
  'dl.google.com'
  'www.apple.com'
  'one.one.one.one'
  'www.cloudflare.com'
  'time.akamai.com'
  'addons.mozilla.org'
)

have_cmd() { command -v "$1" >/dev/null 2>&1; }

trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

urlencode() {
  local s="$1"
  if have_cmd python3; then
    python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1],safe=""))' "$s" 2>/dev/null && return 0
  fi
  local out='' i c
  for ((i = 0; i < ${#s}; i++)); do
    c=${s:$i:1}
    case "$c" in
      [a-zA-Z0-9.~_-]) out+="$c" ;;
      *) out+=$(LC_ALL=C printf '%%%02X' "'$c") ;;
    esac
  done
  printf '%s' "$out"
}

random_hex() {
  local n="${1:-8}"
  if have_cmd openssl; then
    openssl rand -hex "$n" 2>/dev/null | tr -d '\n'; return 0
  fi
  od -An -tx1 -N "$n" /dev/urandom 2>/dev/null | tr -d ' \n'
}

read_file() {
  local f="$1"
  [[ -f "$f" ]] || return 1
  trim "$(cat "$f" 2>/dev/null)"
}

detect_os() {
  local os_release="${1:-/etc/os-release}" id='' ver='' arch=''
  if [[ -r "$os_release" ]]; then
    id=$(. "$os_release"; printf '%s' "${ID:-}")
    ver=$(. "$os_release"; printf '%s' "${VERSION_ID:-}")
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

save_state() {
  mkdir -p "$STATE_DIR"
  chmod 700 "$STATE_DIR"
  local tmp="$STATE_FILE.tmp"
  {
    printf '# %s v%s 部署状态（勿手工编辑）\n' "$APP_NAME" "$APP_VERSION"
    printf 'DEPLOYED_AT=%s\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')"
    printf 'MODE=%s\n' "${MODE:-native}"
    printf 'PORT=%s\n' "${PORT:-}"
    printf 'UUID=%s\n' "${UUID:-}"
    printf 'SNI=%s\n' "${SNI:-}"
    printf 'TARGET=%s\n' "${TARGET:-}"
    printf 'PRIVATE_KEY=%s\n' "${PRIVATE_KEY:-}"
    printf 'PUBLIC_KEY=%s\n' "${PUBLIC_KEY:-}"
    printf 'SHORT_ID=%s\n' "${SHORT_ID:-}"
    printf 'SERVER_IP=%s\n' "${SERVER_IP:-}"
    printf 'REMARK=%s\n' "${REMARK:-}"
    printf 'FLOW=%s\n' "${FLOW:-xtls-rprx-vision}"
    printf 'FINGERPRINT=%s\n' "${FINGERPRINT:-chrome}"
  } >"$tmp"
  chmod 600 "$tmp"
  mv -f "$tmp" "$STATE_FILE"
  tui_ok "配置已保存：$STATE_FILE"
}

load_state() {
  [[ -f "$STATE_FILE" ]] || return 1
  # shellcheck disable=SC1090
  . "$STATE_FILE"
  return 0
}

state_exists() { [[ -f "$STATE_FILE" ]]; }
```

**Step 4: 运行测试确认通过**

```bash
bash test/unit.sh
```

预期：全部通过。

**Step 5: 提交**

```bash
git add lib/core.sh test/unit.sh
git commit -m "feat(core): 纯函数工具集与部署状态持久化"
```

---

## Task 4: core.sh 网络探测

**Files:**
- Modify: `lib/core.sh`（追加网络探测函数）
- Modify: `test/unit.sh`

**Interfaces:**
- Consumes: Task 3 的 `have_cmd` `trim`
- Produces:
  - `detect_public_ip` → stdout IP；失败返回 `1`
  - `detect_local_ip` → stdout IP
  - `port_in_use <port>` → `0`=占用 `1`=空闲
  - `port_occupant <port>` → stdout 占用进程描述
  - `random_free_port` → stdout 端口号
  - `target_supports_tls13 <host>` → `0`/`1`
  - `target_latency_ms <host>` → stdout 毫秒整数
  - `apt_update_once`、`ensure_packages <pkg>...`
  - `service_run_user` → stdout 运行用户名

**Step 1: 写失败的测试**

追加到 `test/unit.sh`：

```bash
test_case "core 网络探测（用可控输入验证解析逻辑）"

# 端口判定：用一个必然空闲的高位端口
assert_false "$(port_in_use 59999)" "高位端口 59999 判定为空闲"
assert_false "$(port_occupant 59999)" "空闲端口无占用进程"

# 延迟解析：传入一个必然超时的域名，应返回 '?'
assert_eq "?" "$(target_latency_ms 'invalid.invalid.nonexistent' 2>/dev/null || printf '?')" "不可达目标返回 ?"

# 真实目标：至少一个候选站点应支持 TLS1.3（网络不可用时跳过断言，不算失败）
if have_cmd openssl && curl -fsS --max-time 5 -o /dev/null https://www.microsoft.com 2>/dev/null; then
  assert_true "$(target_supports_tls13 www.microsoft.com)" "www.microsoft.com 支持 TLS 1.3"
fi
```

> 网络相关断言必须**可跳过**——CI 与本地都可能有网/无网两种情况，不得因无网络而红。

**Step 2: 运行测试确认失败**

```bash
bash test/unit.sh
```

预期：FAIL，`port_in_use: command not found`。

**Step 3: 实现网络探测**

追加到 `lib/core.sh`：

```bash
detect_public_ip() {
  local ip u
  local urls=(
    'https://api.ipify.org'
    'https://ifconfig.me/ip'
    'https://icanhazip.com'
    'https://ipinfo.io/ip'
    'https://myip.ipip.net'
  )
  for u in "${urls[@]}"; do
    ip=$(curl -fsS --max-time 8 "$u" 2>/dev/null | tr -d '[:space:]')
    if [[ "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ || "$ip" =~ ^[0-9a-fA-F:]+$ ]]; then
      printf '%s' "$ip"; return 0
    fi
  done
  return 1
}

detect_local_ip() {
  local ip
  ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')
  [[ -z "$ip" ]] && ip=$(hostname -I 2>/dev/null | awk '{print $1}')
  printf '%s' "$ip"
}

port_in_use() {
  local port="$1"
  if have_cmd ss; then
    ss -ltn "sport = :$port" 2>/dev/null | grep -q ":$port" && return 0
    return 1
  fi
  if have_cmd netstat; then
    netstat -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]$port\$" && return 0
    return 1
  fi
  return 1
}

port_occupant() {
  local port="$1"
  if have_cmd ss; then
    ss -ltnp "sport = :$port" 2>/dev/null | awk 'NR>1{print $NF}' | head -1
    return 0
  fi
  printf ''
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
  if [[ $? -eq 0 ]]; then
    mkdir -p /var/lib/vless-reality
    touch /var/lib/vless-reality/apt-updated
  fi
}

ensure_packages() {
  local missing=() p
  for p in "$@"; do
    have_cmd "$p" || missing+=("$p")
  done
  ((${#missing[@]} == 0)) && return 0
  apt_update_once
  tui_run "安装依赖：${missing[*]}" env DEBIAN_FRONTEND=noninteractive \
    apt-get install -y --no-install-recommends "${missing[@]}"
}

service_run_user() {
  local u
  u=$(systemctl show xray -p User --value 2>/dev/null || printf '')
  [[ -z "$u" || "$u" == '0' ]] && u='root'
  printf '%s' "$u"
}
```

**Step 4: 运行测试确认通过**

```bash
bash test/unit.sh
```

预期：全部通过。

**Step 5: 提交**

```bash
git add lib/core.sh test/unit.sh
git commit -m "feat(core): 网络探测——公网 IP、端口占用、TLS1.3 与延迟"
```

---

## Task 5: deploy.sh 密钥解析与配置渲染（核心纯逻辑）

**Files:**
- Create: `lib/deploy.sh`
- Modify: `test/unit.sh`

**Interfaces:**
- Consumes: Task 3 的 `tui_*` `random_hex` `trim`
- Produces:
  - `xray_parse_keys <raw_output>` → stdout `"priv|pub"`；解析失败返回 `1`
  - `gen_keys` → 设置全局 `PRIVATE_KEY` `PUBLIC_KEY` `SHORT_ID` `UUID`
  - `render_server_config <outfile> <uuid> <priv> <sni> <port> <shortid>` → 写文件，返回 `0`
  - `xray_test_config <cfgfile>` → `0`/`1`
  - `write_config_atomic <outfile> <content>` → 临时文件 + 校验 + 原子替换

**Step 1: 写失败的测试**

追加到 `test/unit.sh`：

```bash
source "$ROOT/lib/deploy.sh"

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

# 无关输出不应误判
out=$(xray_parse_keys "hello world" 2>/dev/null || printf '')
assert_eq "" "$out" "无法识别时返回空串且退出码非零"

test_case "服务端配置渲染"

cfg=$(mktemp)
render_server_config "$cfg" "11111111-2222-3333-4444-555555555555" "PRIVKEY" "www.microsoft.com" "443" "a1b2c3d4" >/dev/null
assert_true "$(python3 -c "import json,sys;json.load(open(sys.argv[1]));print(0)" "$cfg" 2>/dev/null || echo 1)" "生成的配置是合法 JSON" 2>/dev/null || true
if have_cmd python3; then
  assert_status 0 "$(python3 -c "import json,sys;json.load(open(sys.argv[1]));print(0)" "$cfg" 2>/dev/null || echo 1)" "生成的配置是合法 JSON"
  assert_contains "$(cat "$cfg")" '"security": "reality"' "配置启用 reality"
  assert_contains "$(cat "$cfg")" '"target": "www.microsoft.com:443"' "reality target 正确"
  assert_contains "$(cat "$cfg")" '"serverNames": [' "配置含 serverNames"
  assert_contains "$(cat "$cfg")" '"flow": "xtls-rprx-vision"' "配置含 xtls-rprx-vision 流控"
  assert_contains "$(cat "$cfg")" '"privateKey": "PRIVKEY"' "配置含私钥"
  assert_contains "$(cat "$cfg")" '"shortIds": [' "配置含 shortIds"
  assert_eq 0 "$(grep -c 'geoip' "$cfg")" "配置不引用 geoip（避免 geoip.dat 依赖）"
fi
rm -f "$cfg"
```

**Step 2: 运行测试确认失败**

```bash
bash test/unit.sh
```

预期：FAIL，`lib/deploy.sh: No such file or directory`。

**Step 3: 实现 `lib/deploy.sh` 纯逻辑部分**

创建 `lib/deploy.sh`（本任务只写纯逻辑，系统操作在 Task 6 追加）：

```bash
#!/usr/bin/env bash
# lib/deploy.sh — Xray 安装、配置生成、systemd、防火墙、BBR

# 解析 xray x25519 的输出，兼容多种版本格式。
# 旧版: "Private key: <priv>" / "Public key: <pub>"
# 新版: "PrivateKey: <priv>"  / "Password: <pub>"
# 输出: "<priv>|<pub>"，任一缺失则对应位置为空
xray_parse_keys() {
  local raw="$1" priv='' pub='' line key val
  while IFS= read -r line; do
    [[ "$line" == *=* ]] && continue
    key="${line%%:*}"
    val="${line#*:}"
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

  SHORT_ID=$(random_hex 4)
  tui_ok "密钥对已生成"
  tui_kv "公钥 (pbk)" "$PUBLIC_KEY"
  tui_kv "ShortID (sid)" "$SHORT_ID"
  tui_kv "UUID" "$UUID"
  return 0
}

# 渲染服务端 config.json
render_server_config() {
  local outfile="$1" uuid="$2" priv="$3" sni="$4" port="$5" sid="$6"
  local tmp="$outfile.new"
  cat >"$tmp" <<EOF
{
  "log": {
    "loglevel": "warning",
    "access": "/var/log/xray/access.log",
    "error": "/var/log/xray/error.log"
  },
  "inbounds": [
    {
      "tag": "vless-reality-in",
      "listen": "0.0.0.0",
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
      "settings": {
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
  mv -f "$tmp" "$outfile"
  chmod 644 "$outfile"
}

# 校验配置可用。兼容不同 xray 版本的子命令写法。
xray_test_config() {
  local cfg="$1"
  "$XRAY_BIN" run -test -config "$cfg" >/dev/null 2>&1 && return 0
  "$XRAY_BIN" run -test -c "$cfg" >/dev/null 2>&1 && return 0
  "$XRAY_BIN" -test -config "$cfg" >/dev/null 2>&1 && return 0
  return 1
}

# 写临时文件 → 校验 → 原子替换。校验失败保留旧文件并输出 xray 报错。
write_config_atomic() {
  local outfile="$1" content="$2"
  local tmp="$outfile.new"
  printf '%s\n' "$content" >"$tmp"
  if ! xray_test_config "$tmp"; then
    tui_err "配置校验未通过，已保留原有配置不变。"
    "$XRAY_BIN" run -test -config "$tmp" 2>&1 | sed -e 's/^/      /' || true
    rm -f "$tmp"
    return 1
  fi
  mv -f "$tmp" "$outfile"
  chmod 644 "$outfile"
  return 0
}
```

**Step 4: 运行测试确认通过**

```bash
bash test/unit.sh
```

预期：全部通过。

**Step 5: 提交**

```bash
git add lib/deploy.sh test/unit.sh
git commit -m "feat(deploy): 密钥解析跨版本兼容与服务端配置渲染"
```

---

## Task 6: deploy.sh 系统操作（安装/systemd/防火墙/BBR）

**Files:**
- Modify: `lib/deploy.sh`（追加系统操作函数）

**Interfaces:**
- Consumes: Task 3 `have_cmd` `tui_*` `ensure_packages`；Task 5 `render_server_config` `xray_test_config`
- Produces:
  - `install_xray` → `0`/`1`
  - `xray_installed` → `0`/`1`
  - `xray_version` → stdout 版本串
  - `setup_systemd` → `0`/`1`
  - `restart_service` → `0`/`1`
  - `open_firewall <port>` → `0`/`1`
  - `enable_bbr` → `0`/`1`
  - `service_status` → 打印状态

**Step 1: 写失败的测试**

追加到 `test/unit.sh`：

```bash
test_case "deploy 系统操作的可测分支"

# 未安装 xray 时 xray_installed 必须返回非零
if [[ ! -x "$XRAY_BIN" ]]; then
  assert_false "$(xray_installed)" "未安装时 xray_installed 返回假"
fi

# enable_bbr 在不支持 bbr 的内核上必须安全失败而非崩溃
out=$(enable_bbr 2>&1) || true
assert_contains "$out" "bbr" "enable_bbr 输出提及 bbr 状态"

# open_firewall 在无任何防火墙工具时必须明确告知而不是静默成功
if ! have_cmd ufw && ! have_cmd nft && ! have_cmd iptables; then
  out=$(open_firewall 443 2>&1) || true
  assert_contains "$out" "防火墙" "无防火墙工具时给出明确提示"
fi
```

**Step 2: 运行测试确认失败**

```bash
bash test/unit.sh
```

预期：FAIL，`xray_installed: command not found`。

**Step 3: 实现系统操作**

追加到 `lib/deploy.sh`：

```bash
xray_installed() { [[ -x "$XRAY_BIN" ]]; }

xray_version() {
  "$XRAY_BIN" version 2>/dev/null | head -1 | tr -d '\r'
}

install_xray() {
  if xray_installed; then
    tui_ok "Xray 已安装：$(xray_version)"
    tui_tip "如需更新请使用管理菜单的「更新 Xray 内核」"
    return 0
  fi
  ensure_packages curl ca-certificates
  local installer
  installer=$(mktemp)
  if ! curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh -o "$installer"; then
    tui_err "下载 Xray 安装脚本失败，请检查网络连通性"
    rm -f "$installer"
    return 1
  fi
  chmod +x "$installer"
  tui_run "安装 Xray 内核" bash "$installer" install
  local rc=$?
  rm -f "$installer"
  if [[ $rc -ne 0 ]] || ! xray_installed; then
    tui_err "Xray 安装失败"
    return 1
  fi
  tui_ok "Xray 安装完成：$(xray_version)"
  return 0
}

setup_systemd() {
  if ! have_cmd systemctl; then
    tui_err "未找到 systemctl，systemd 不可用"
    return 1
  fi
  tui_run "启用并启动 xray 服务" systemctl enable --now xray
  if ! systemctl is-active --quiet xray; then
    tui_err "xray 服务未能启动，最近日志如下："
    journalctl -u xray -n 30 --no-pager 2>/dev/null | sed -e 's/^/      /' || true
    return 1
  fi
  # 依据实际运行用户授权日志目录
  local run_user svc_user
  run_user=$(service_run_user)
  if [[ "$run_user" != "root" ]]; then
    svc_user="$run_user"
    mkdir -p "$LOG_DIR"
    if id "$svc_user" >/dev/null 2>&1; then
      chown -R "$svc_user" "$LOG_DIR" 2>/dev/null || true
    fi
    tui_tip "日志目录已授权给运行用户 $svc_user"
  fi
  tui_ok "xray 服务已运行"
  return 0
}

restart_service() {
  tui_run "重启 xray 服务" systemctl restart xray
  if systemctl is-active --quiet xray; then
    tui_ok "xray 服务重启成功"
    return 0
  fi
  tui_err "xray 服务重启后未处于运行状态"
  journalctl -u xray -n 30 --no-pager 2>/dev/null | sed -e 's/^/      /' || true
  return 1
}

open_firewall() {
  local port="$1"
  if have_cmd ufw && ufw status 2>/dev/null | grep -q 'Status: active'; then
    tui_run "放行端口 $port/tcp (ufw)" ufw allow "$port/tcp"
    return $?
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
      tui_run "放行端口 $port/tcp (nftables)" nft insert rule inet filter input tcp dport "$port" ct state new counter accept
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
  local conf=/etc/sysctl.d/99-vless-reality-bbr.conf
  cat >"$conf" <<'EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_fastopen = 3
net.core.somaxconn = 4096
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_slow_start_after_idle = 0
EOF
  sysctl -p "$conf" >/dev/null 2>&1 || sysctl --system >/dev/null 2>&1 || true
  tui_ok "已启用 bbr 拥塞控制与 fq 队列（$conf）"
  return 0
}

service_status() {
  if have_cmd systemctl; then
    local active enabled
    active=$(systemctl is-active xray 2>/dev/null || printf 'unknown')
    enabled=$(systemctl is-enabled xray 2>/dev/null || printf 'unknown')
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
```

**Step 4: 运行测试确认通过**

```bash
bash test/unit.sh
```

预期：全部通过。

**Step 5: 提交**

```bash
git add lib/deploy.sh test/unit.sh
git commit -m "feat(deploy): 内核安装、systemd、防火墙放行与 BBR 调优"
```

---

## Task 7: client.sh 分享链接与客户端物料

**Files:**
- Create: `lib/client.sh`
- Modify: `test/unit.sh`

**Interfaces:**
- Consumes: Task 3 `urlencode` `trim`；Task 6 `tui_*`
- Produces:
  - `build_share_link <uuid> <ip> <port> <sni> <pub> <sid> <remark>` → stdout
  - `render_client_config <outfile> <uuid> <ip> <port> <sni> <pub> <sid>` → 写文件
  - `export_client_artifacts <outdir> <uuid> <ip> <port> <sni> <pub> <sid> <remark>` → 写全部物料，返回 `0`

**Step 1: 写失败的测试**

追加到 `test/unit.sh`：

```bash
source "$ROOT/lib/client.sh"

test_case "分享链接与客户端配置"

link=$(build_share_link "UUID123" "1.2.3.4" "443" "www.microsoft.com" "PUBKEY" "a1b2c3d4" "我的节点")
assert_contains "$link" "vless://UUID123@1.2.3.4:443" "链接含协议与地址"
assert_contains "$link" "encryption=none" "链接含 encryption"
assert_contains "$link" "flow=xtls-rprx-vision" "链接含 flow"
assert_contains "$link" "security=reality" "链接含 security=reality"
assert_contains "$link" "sni=www.microsoft.com" "链接含 sni"
assert_contains "$link" "fp=chrome" "链接含指纹"
assert_contains "$link" "pbk=PUBKEY" "链接含公钥 pbk"
assert_contains "$link" "sid=a1b2c3d4" "链接含 shortId"
assert_contains "$link" "type=tcp" "链接含传输协议"
assert_contains "$link" "%E6%88%91%E7%9A%84%E8%8A%82%E7%82%B9" "备注被 URL 编码"

ccfg=$(mktemp)
render_client_config "$ccfg" "UUID123" "1.2.3.4" "443" "www.microsoft.com" "PUBKEY" "a1b2c3d4" >/dev/null
if have_cmd python3; then
  assert_status 0 "$(python3 -c "import json,sys;json.load(open(sys.argv[1]));print(0)" "$ccfg" 2>/dev/null || echo 1)" "客户端配置是合法 JSON"
fi
assert_contains "$(cat "$ccfg")" '"port": 1080' "客户端含 socks 入站 1080"
assert_contains "$(cat "$ccfg")" '"port": 1081' "客户端含 http 入站 1081"
assert_contains "$(cat "$ccfg")" '"publicKey": "PUBKEY"' "客户端含公钥"
assert_contains "$(cat "$ccfg")" '"serverName": "www.microsoft.com"' "客户端含 serverName"
assert_contains "$(cat "$ccfg")" '"fingerprint": "chrome"' "客户端含 fingerprint"
rm -f "$ccfg"
```

**Step 2: 运行测试确认失败**

```bash
bash test/unit.sh
```

预期：FAIL，`lib/client.sh: No such file or directory`。

**Step 3: 实现 `lib/client.sh`**

创建 `lib/client.sh`：

```bash
#!/usr/bin/env bash
# lib/client.sh — 客户端物料导出

build_share_link() {
  local uuid="$1" ip="$2" port="$3" sni="$4" pub="$5" sid="$6" remark="$7"
  local enc
  enc=$(urlencode "$remark")
  printf 'vless://%s@%s:%s?encryption=none&flow=xtls-rprx-vision&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=tcp&headerType=none#%s' \
    "$uuid" "$ip" "$port" "$sni" "$pub" "$sid" "$enc"
}

render_client_config() {
  local outfile="$1" uuid="$2" ip="$3" port="$4" sni="$5" pub="$6" sid="$7"
  local tmp="$outfile.new"
  cat >"$tmp" <<EOF
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
                "flow": "xtls-rprx-vision",
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
          "fingerprint": "chrome",
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
  mv -f "$tmp" "$outfile"
  chmod 600 "$outfile"
}

export_client_artifacts() {
  local outdir="$1" uuid="$2" ip="$3" port="$4" sni="$5" pub="$6" sid="$7" remark="$8"
  mkdir -p "$outdir"
  chmod 700 "$outdir"

  local link
  link=$(build_share_link "$uuid" "$ip" "$port" "$sni" "$pub" "$sid" "$remark")

  render_client_config "$outdir/client.json" "$uuid" "$ip" "$port" "$sni" "$pub" "$sid"

  {
    printf '# VLESS + REALITY 客户端信息\n\n'
    printf '生成时间: %s\n\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')"
    printf '地址: %s\n' "$ip"
    printf '端口: %s\n' "$port"
    printf 'UUID: %s\n' "$uuid"
    printf 'SNI: %s\n' "$sni"
    printf '公钥 (pbk): %s\n' "$pub"
    printf 'ShortID (sid): %s\n' "$sid"
    printf '流控 (flow): xtls-rprx-vision\n'
    printf '指纹 (fp): chrome\n\n'
    printf '分享链接:\n%s\n\n' "$link"
    printf '导入方式: v2rayN / v2rayNG / Clash Verge / Shadowrocket / Hiddify 均可直接粘贴该链接。\n'
  } >"$outdir/client.txt"
  chmod 600 "$outdir/client.txt"

  printf '%s' "$link" >"$outdir/link.txt"
  chmod 600 "$outdir/link.txt"

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
```

**Step 4: 运行测试确认通过**

```bash
bash test/unit.sh
```

预期：全部通过。

**Step 5: 提交**

```bash
git add lib/client.sh test/unit.sh
git commit -m "feat(client): 分享链接、客户端配置与二维码导出"
```

---

## Task 8: install.sh 骨架、参数解析与预检

**Files:**
- Create: `install.sh`
- Modify: `test/unit.sh`

**Interfaces:**
- Consumes: Task 3–7 全部
- Produces:
  - `install.sh` 支持 `-y/--yes` `-p/--port` `-s/--sni` `-n/--name` `--uuid` `-m/--menu` `--status` `--uninstall` `-h/--help`
  - `parse_args "$@"` → 设置 `OPT_YES` `OPT_PORT` `OPT_SNI` `OPT_NAME` `OPT_UUID` `OPT_MODE`
  - `preflight` → `0`/`1`
  - `require_root`

**Step 1: 写失败的测试**

追加到 `test/unit.sh`：

```bash
test_case "install.sh 参数解析"

run_help=$(bash "$ROOT/install.sh" --help 2>&1)
assert_contains "$run_help" "--port" "帮助信息含 --port"
assert_contains "$run_help" "--sni" "帮助信息含 --sni"
assert_contains "$run_help" "--menu" "帮助信息含 --menu"

# 未知参数必须报错退出
out=$(bash "$ROOT/install.sh" --definitely-not-a-real-flag 2>&1)
assert_status 1 "$?" "未知参数以非零码退出"
assert_contains "$out" "未知" "未知参数给出提示"

# --status 在未部署时应优雅退出而非崩溃
out=$(bash "$ROOT/install.sh" --status 2>&1)
assert_status 0 "$?" "未部署时 --status 退出码为 0"
```

**Step 2: 运行测试确认失败**

```bash
bash test/unit.sh
```

预期：FAIL，`install.sh: No such file or directory`。

**Step 3: 实现 `install.sh` 骨架**

创建 `install.sh`：

```bash
#!/usr/bin/env bash
# install.sh — VLESS + REALITY 一键部署工具（入口）
#
# 用法:
#   sudo ./install.sh              交互式向导
#   sudo ./install.sh -y           全自动（用默认值）
#   sudo ./install.sh --menu       进入管理菜单
#   sudo ./install.sh --status     查看运行状态
#   sudo ./install.sh --uninstall  卸载

set -uo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/tui.sh
source "$ROOT_DIR/lib/tui.sh"
# shellcheck source=lib/core.sh
source "$ROOT_DIR/lib/core.sh"
# shellcheck source=lib/deploy.sh
source "$ROOT_DIR/lib/deploy.sh"
# shellcheck source=lib/client.sh
source "$ROOT_DIR/lib/client.sh"

OPT_YES=0
OPT_MENU=0
OPT_STATUS=0
OPT_UNINSTALL=0
OPT_PORT=''
OPT_SNI=''
OPT_NAME=''
OPT_UUID=''

usage() {
  cat <<EOF
${APP_NAME} v${APP_VERSION}

用法:
  sudo ./install.sh [选项]

选项:
  -y, --yes          全自动无交互，使用内置默认值
  -p, --port <端口>   指定监听端口（默认 443）
  -s, --sni <域名>    指定 REALITY 伪装目标
  -n, --name <备注>   指定分享链接备注
      --uuid <UUID>   指定 UUID（默认自动生成）
  -m, --menu          直接进入管理菜单
      --status        查看运行状态并退出
      --uninstall     卸载并清理
  -h, --help          显示本帮助

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
      -p|--port)     OPT_PORT="${2:-}"; [[ -n "$OPT_PORT" ]] || { tui_err "--port 缺少参数"; exit 1; }; shift 2 ;;
      -s|--sni)      OPT_SNI="${2:-}"; [[ -n "$OPT_SNI" ]] || { tui_err "--sni 缺少参数"; exit 1; }; shift 2 ;;
      -n|--name)     OPT_NAME="${2:-}"; [[ -n "$OPT_NAME" ]] || { tui_err "--name 缺少参数"; exit 1; }; shift 2 ;;
      --uuid)        OPT_UUID="${2:-}"; [[ -n "$OPT_UUID" ]] || { tui_err "--uuid 缺少参数"; exit 1; }; shift 2 ;;
      *) tui_err "未知参数：$1"; usage; exit 1 ;;
    esac
  done
}

require_root() {
  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    tui_err "需要 root 权限，请使用 sudo 重新执行。"
    exit 1
  fi
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

  # 公网 IP
  SERVER_IP=$(detect_public_ip || true)
  if [[ -z "$SERVER_IP" ]]; then
    SERVER_IP=$(detect_local_ip || true)
    tui_warn "未能探测到公网 IP，回退使用本机地址：${SERVER_IP:-未知}"
    tui_tip "若服务器位于 NAT 后，请用 --sni/--name 之外的方式确认对外地址后再配置客户端"
  else
    tui_ok "公网 IP：$SERVER_IP"
  fi

  return $rc
}

main() {
  parse_args "$@"
  tui_init

  if [[ $OPT_UNINSTALL -eq 1 ]]; then
    if [[ -x "$ROOT_DIR/uninstall.sh" ]]; then
      exec "$ROOT_DIR/uninstall.sh"
    fi
    tui_warn "当前目录没有 uninstall.sh（单文件分发版不含卸载脚本）。"
    tui_tip "请手动执行：systemctl disable --now xray && rm -f $XRAY_CONFIG"
    exit 1
  fi

  if [[ $OPT_STATUS -eq 1 ]]; then
    require_root
    load_state || true
    tui_banner "$APP_NAME" "状态自检"
    tui_section "服务状态"
    service_status
    exit 0
  fi

  if [[ $OPT_MENU -eq 1 ]]; then
    require_root
    load_state || true
    if ! declare -F management_menu >/dev/null 2>&1; then
      tui_err "内部错误：management_menu 未定义，源码不完整。"
      exit 1
    fi
    management_menu
    exit 0
  fi

  require_root
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

main "$@"
```

> **函数归属约定**（避免重复定义冲突）：
> `install.sh` 只包含 `usage` `parse_args` `require_root` `preflight` `main`。
> `deploy_wizard` `management_menu` 及全部 `menu_*` 函数一律放在 `lib/deploy.sh`。
> `lib/deploy.sh` 在 `install.sh` 中**先于**任何函数定义被 source，因此不存在覆盖问题。
> `declare -F` 守卫同时保护了被截断的单文件构建产物。
> 本任务不定义 `deploy_wizard` 占位实现——`--help` / 未知参数 / `--status` 三条测试路径
> 都不会触及它，`main` 中的 `declare -F` 守卫负责在缺失时给出明确错误。

**Step 4: 运行测试确认通过**

```bash
bash test/unit.sh
```

预期：全部通过。

**Step 5: 提交**

```bash
git add install.sh test/unit.sh
git commit -m "feat(cli): 入口骨架、参数解析与环境预检"
```

---

## Task 9: install.sh 部署向导

**Files:**
- Modify: `lib/deploy.sh`（追加 `probe_targets` `choose_target` `do_deploy` `deploy_wizard`）
- Modify: `test/unit.sh`

**Interfaces:**
- Consumes: Task 5 `gen_keys` `render_server_config` `xray_test_config`；Task 6 `install_xray` `setup_systemd` `open_firewall` `enable_bbr`；Task 7 `export_client_artifacts`；Task 3 `save_state` `target_supports_tls13` `target_latency_ms` `port_in_use` `random_free_port`
- Produces:
  - `deploy_wizard` → `0`/`1`
  - `probe_targets` → stdout 每行 `"<host>|<tls13 ok|fail>|<latency ms|?>"`，已按延迟升序
  - `choose_target` → stdout 选中的 host
  - `do_deploy` → `0`/`1`

**Step 1: 写失败的测试**

追加到 `test/unit.sh`：

```bash
test_case "目标探测与排序"

# 探测结果必须形如 host|ok|latency，且只包含 REALITY_TARGETS 中的条目
if have_cmd openssl; then
  probe=$(probe_targets 2>/dev/null || true)
  if [[ -n "$probe" ]]; then
    assert_contains "$probe" "|" "探测结果含分隔符"
    while IFS='|' read -r h tls lat; do
      found=0
      for t in "${REALITY_TARGETS[@]}"; do [[ "$t" == "$h" ]] && found=1; done
      assert_eq 1 "$found" "探测目标 $h 在候选列表内"
    done <<<"$probe"
  fi
fi
```

**Step 2: 运行测试确认失败**

```bash
bash test/unit.sh
```

预期：FAIL，`probe_targets: command not found`。

**Step 3: 实现向导**

把以下实现**追加到 `lib/deploy.sh`**（不是 `install.sh`——见 Task 8 的函数归属约定）：

```bash
# 并发探测候选伪装目标：TLS1.3 支持 + 连通延迟，按延迟升序输出
probe_targets() {
  local host tls lat tmp
  tmp=$(mktemp)
  local -a pids=() hosts=()
  for host in "${REALITY_TARGETS[@]}"; do
    (
      tls='fail'
      target_supports_tls13 "$host" && tls='ok'
      lat=$(target_latency_ms "$host")
      printf '%s|%s|%s\n' "$host" "$tls" "$lat" >"$tmp.$host"
    ) &
    pids+=($!)
    hosts+=("$host")
  done
  for p in "${pids[@]}"; do wait "$p" 2>/dev/null || true; done
  for host in "${hosts[@]}"; do
    [[ -f "$tmp.$host" ]] && cat "$tmp.$host"
    rm -f "$tmp.$host"
  done
  rm -f "$tmp"
  # 按延迟升序排序（? 视为最大）
  sort -t'|' -k3,3n -k1,1
}

choose_target() {
  local probe line host tls lat
  probe=$(probe_targets)
  if [[ -z "$probe" ]]; then
    tui_warn "目标探测不可用，回退默认：www.microsoft.com"
    printf 'www.microsoft.com'; return 0
  fi
  local -a labels=() hosts=()
  while IFS='|' read -r host tls lat; do
    [[ -z "$host" ]] && continue
    hosts+=("$host")
    if [[ "$tls" == 'ok' ]]; then
      labels+=("${host}    TLS1.3 ✔   ${lat}ms")
    else
      labels+=("${host}    TLS1.3 ✘   ${lat}ms")
    fi
  done <<<"$probe"

  if [[ $OPT_YES -eq 1 ]]; then
    # 自动挑选第一个支持 TLS1.3 且延迟最低的目标
    local pick=''
    while IFS='|' read -r host tls lat; do
      if [[ "$tls" == 'ok' && "$lat" != '?' ]]; then pick="$host"; break; fi
    done <<<"$probe"
    [[ -z "$pick" ]] && pick="${hosts[0]}"
    printf '%s' "$pick"; return 0
  fi

  tui_section "伪装目标候选（按延迟升序）"
  local i
  for i in "${!labels[@]}"; do
    printf '     %s%2d%s) %s\n' "$C_GRAY" "$((i + 1))" "$C_RESET" "${labels[$i]}"
  done
  local sel
  sel=$(tui_menu "选择 REALITY 伪装目标（SNI）" "${labels[@]}") || sel=0
  printf '%s' "${hosts[$sel]}"
}

do_deploy() {
  tui_section "执行部署"

  tui_step "① 安装 Xray 内核"
  install_xray || { tui_err "Xray 安装失败，部署中止"; return 1; }

  tui_step "② 生成 REALITY 密钥与 UUID"
  gen_keys || { tui_err "密钥生成失败，部署中止"; return 1; }
  [[ -n "$OPT_UUID" ]] && UUID="$OPT_UUID"

  tui_step "③ 生成服务端配置"
  mkdir -p "$(dirname "$XRAY_CONFIG")"
  local cfg
  cfg=$(mktemp)
  render_server_config "$cfg" "$UUID" "$PRIVATE_KEY" "$SNI" "$PORT" "$SHORT_ID"
  if ! xray_test_config "$cfg"; then
    tui_err "配置校验未通过，已保留原有配置不变。"
    "$XRAY_BIN" run -test -config "$cfg" 2>&1 | sed -e 's/^/      /' || true
    rm -f "$cfg"
    return 1
  fi
  mv -f "$cfg" "$XRAY_CONFIG"
  chmod 644 "$XRAY_CONFIG"
  tui_ok "服务端配置已写入：$XRAY_CONFIG"

  tui_step "④ 配置 systemd 服务"
  setup_systemd || { tui_err "systemd 配置失败，部署中止"; return 1; }

  tui_step "⑤ 放行防火墙端口 $PORT/tcp"
  open_firewall "$PORT" || tui_warn "防火墙放行未成功，请手工确认"

  tui_step "⑥ 网络调优"
  enable_bbr || tui_tip "已跳过网络调优（非致命）"

  tui_ok "部署完成"
  return 0
}

deploy_wizard() {
  tui_section "部署参数"

  # 端口
  PORT="${OPT_PORT:-443}"
  if port_in_use "$PORT"; then
    local occ
    occ=$(port_occupant "$PORT")
    tui_warn "端口 $PORT 已被占用${occ:+（$occ）}"
    if [[ $OPT_YES -eq 1 ]]; then
      PORT=$(random_free_port)
      tui_tip "已自动改用空闲端口：$PORT"
    else
      local choice
      choice=$(tui_menu "如何处理端口冲突？" \
        "改用随机空闲端口" \
        "我手动指定其它端口" \
        "取消部署")
      case $choice in
        0) PORT=$(random_free_port); tui_tip "已改用端口 $PORT" ;;
        1) PORT=$(tui_input "请输入新端口" "$PORT" "1-65535")
            [[ "$PORT" =~ ^[0-9]+$ ]] && (( PORT > 0 && PORT < 65536 )) || { tui_err "端口非法"; return 1; } ;;
        *) tui_info "已取消部署"; return 1 ;;
      esac
    fi
  fi

  # 伪装目标
  SNI="${OPT_SNI:-}"
  if [[ -z "$SNI" ]]; then
    SNI=$(choose_target)
  fi
  TARGET="$SNI"
  [[ -z "$SNI" ]] && { tui_err "未确定伪装目标"; return 1; }
  tui_kv "伪装目标 (SNI)" "$SNI"

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

  if [[ $OPT_YES -eq 0 ]]; then
    tui_confirm "确认开始部署？" "y" || { tui_info "已取消"; return 1; }
  fi

  do_deploy || return 1

  # 保存状态
  MODE='native'
  FLOW='xtls-rprx-vision'
  FINGERPRINT='chrome'
  save_state

  # 客户端物料
  tui_section "客户端物料"
  export_client_artifacts "$OUT_DIR" "$UUID" "$SERVER_IP" "$PORT" "$SNI" "$PUBLIC_KEY" "$SHORT_ID" "$REMARK"

  local link
  link=$(build_share_link "$UUID" "$SERVER_IP" "$PORT" "$SNI" "$PUBLIC_KEY" "$SHORT_ID" "$REMARK")
  tui_panel "部署完成" \
    "地址|$SERVER_IP:$PORT" \
    "UUID|$UUID" \
    "SNI|$SNI" \
    "公钥 pbk|$PUBLIC_KEY" \
    "ShortID sid|$SHORT_ID" \
    "客户端配置|$OUT_DIR/client.json" \
    "二维码|$OUT_DIR/qrcode.png"

  tui_box "分享链接（可直接粘贴到客户端导入）"
  tui_box_line "$link"
  tui_box_end

  if [[ -f "$OUT_DIR/qrcode.txt" ]]; then
    tui_section "终端二维码"
    cat "$OUT_DIR/qrcode.txt"
  fi

  if [[ $OPT_YES -eq 0 ]]; then
    tui_pause
    management_menu
  fi
  return 0
}
```

**Step 4: 运行测试确认通过**

```bash
bash test/unit.sh
```

预期：全部通过。

**Step 5: 提交**

```bash
git add lib/deploy.sh test/unit.sh
git commit -m "feat(wizard): 部署向导——参数确认、目标探测与六步部署"
```

---

## Task 10: install.sh 管理菜单

**Files:**
- Modify: `lib/deploy.sh`（追加 `menu_*` 与 `management_menu`）
- Modify: `test/unit.sh`
- Create: `test/helpers/menu_management.sh`

**Interfaces:**
- Consumes: Task 3 `load_state` `save_state`；Task 5 `gen_keys`；Task 6 `install_xray` `restart_service` `open_firewall` `enable_bbr` `service_status`；Task 7 `build_share_link` `export_client_artifacts`
- Produces:
  - `management_menu` → 循环直到用户退出
  - `menu_show_client` / `menu_restart` / `menu_logs` / `menu_update_xray` / `menu_tune` / `menu_rotate_keys` / `menu_uninstall`

**Step 1: 写失败的测试**

追加到 `test/unit.sh`：

```bash
test_case "管理菜单（未部署状态下的健壮性）"

# 未部署时进入管理菜单，菜单必须正常渲染而不是崩溃
out=$(printf '9\n' | bash "$ROOT/test/helpers/menu_management.sh" 2>&1)
assert_status 0 "$?" "未部署时管理菜单可正常退出"
assert_contains "$out" "未部署" "未部署时给出明确提示"
```

创建 `test/helpers/menu_management.sh`（管理菜单实现在 `lib/deploy.sh`，直接 source 调用，
**不使用 `sed`+`eval` 抽取函数——那种做法在函数体含 `}` 时会截断**）：

```bash
#!/usr/bin/env bash
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/lib/tui.sh"
source "$ROOT/lib/core.sh"
source "$ROOT/lib/deploy.sh"
source "$ROOT/lib/client.sh"
tui_init
load_state || true
management_menu
```

**Step 2: 运行测试确认失败**

```bash
bash test/unit.sh
```

预期：FAIL。

**Step 3: 实现管理菜单**

把以下实现追加到 `lib/deploy.sh`。`install.sh` 无需任何改动——它已在 Task 8 通过
`declare -F management_menu` 守卫 + 直接调用来使用该实现。

```bash
menu_show_client() {
  if ! state_exists; then
    tui_warn "尚未部署，无客户端信息可显示。"
    return 1
  fi
  load_state || return 1
  local link
  link=$(build_share_link "$UUID" "$SERVER_IP" "$PORT" "$SNI" "$PUBLIC_KEY" "$SHORT_ID" "$REMARK")
  tui_panel "当前节点" \
    "地址|$SERVER_IP:$PORT" \
    "UUID|$UUID" \
    "SNI|$SNI" \
    "公钥 pbk|$PUBLIC_KEY" \
    "ShortID sid|$SHORT_ID" \
    "备注|$REMARK"
  tui_box "分享链接"
  tui_box_line "$link"
  tui_box_end
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
  journalctl -u xray -f --no-pager
}

menu_update_xray() {
  ensure_packages curl ca-certificates
  local installer
  installer=$(mktemp)
  curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh -o "$installer" || {
    tui_err "下载安装脚本失败"; rm -f "$installer"; return 1; }
  chmod +x "$installer"
  tui_run "更新 Xray 内核" bash "$installer" install
  local rc=$?
  rm -f "$installer"
  [[ $rc -eq 0 ]] && restart_service
  return $rc
}

menu_tune() {
  open_firewall "$PORT" || true
  enable_bbr || true
  service_status
}

menu_rotate_keys() {
  state_exists || { tui_warn "尚未部署，无密钥可轮换"; return 1; }
  load_state
  tui_confirm "轮换密钥与 UUID 会使所有旧客户端失效，继续？" "n" || { tui_info "已取消"; return 0; }
  gen_keys || return 1
  local cfg; cfg=$(mktemp)
  render_server_config "$cfg" "$UUID" "$PRIVATE_KEY" "$SNI" "$PORT" "$SHORT_ID"
  if ! xray_test_config "$cfg"; then
    tui_err "新配置校验未通过，已保留原有配置。"
    rm -f "$cfg"; return 1
  fi
  mv -f "$cfg" "$XRAY_CONFIG"; chmod 644 "$XRAY_CONFIG"
  save_state
  restart_service || return 1
  export_client_artifacts "$OUT_DIR" "$UUID" "$SERVER_IP" "$PORT" "$SNI" "$PUBLIC_KEY" "$SHORT_ID" "$REMARK"
  tui_ok "密钥已轮换，请使用新的分享链接更新客户端"
}

menu_uninstall() {
  exec "$ROOT_DIR/uninstall.sh"
}

management_menu() {
  while true; do
    tui_banner "$APP_NAME" "管理菜单"
    if ! state_exists; then
      tui_warn "尚未部署。选「重新部署」开始，或直接退出。"
    fi
    local choice
    choice=$(tui_menu "请选择操作" \
      "重新部署（重跑向导）" \
      "查看配置 / 分享链接 / 二维码" \
      "重启服务" \
      "实时日志（tail -f）" \
      "更新 Xray 内核" \
      "网络调优（BBR / 防火墙）" \
      "轮换密钥与 UUID" \
      "卸载" \
      "退出")
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
```

并把 `install.sh` 的 `management_menu` 占位改为直接调用 `lib/deploy.sh` 中的实现（删除占位函数），
`deploy_wizard` 若也移入 `lib/deploy.sh` 需一并移动（`install.sh` 中删除其占位定义）。

**Step 4: 运行测试确认通过**

```bash
bash test/unit.sh
```

预期：全部通过。

**Step 5: 提交**

```bash
git add lib/deploy.sh test/unit.sh test/helpers/
git commit -m "feat(menu): 管理菜单——查看、重启、日志、更新、轮换密钥与卸载"
```

---

## Task 11: uninstall.sh

**Files:**
- Create: `uninstall.sh`
- Modify: `test/unit.sh`

**Interfaces:**
- Consumes: Task 3 `STATE_FILE` `OUT_DIR` `XRAY_CONFIG`；Task 6 `have_cmd`
- Produces:
  - `uninstall.sh [--purge]` → `0`/`1`

**Step 1: 写失败的测试**

追加到 `test/unit.sh`：

```bash
test_case "uninstall 参数校验"

out=$(bash "$ROOT/uninstall.sh" --not-a-flag 2>&1)
assert_status 1 "$?" "uninstall 未知参数以非零码退出"
assert_contains "$out" "未知" "uninstall 未知参数给出提示"

out=$(bash "$ROOT/uninstall.sh" --help 2>&1)
assert_status 0 "$?" "uninstall --help 退出码为 0"
assert_contains "$out" "purge" "uninstall 帮助含 --purge"
```

**Step 2: 运行测试确认失败**

```bash
bash test/unit.sh
```

预期：FAIL，`uninstall.sh: No such file or directory`。

**Step 3: 实现 `uninstall.sh`**

创建 `uninstall.sh`：

```bash
#!/usr/bin/env bash
# uninstall.sh — 卸载 VLESS + REALITY 部署
set -uo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/tui.sh
source "$ROOT_DIR/lib/tui.sh"
# shellcheck source=lib/core.sh
source "$ROOT_DIR/lib/core.sh"

PURGE=0
usage() {
  cat <<EOF
卸载 VLESS + REALITY 部署

用法:
  sudo ./uninstall.sh [--purge]

选项:
      --purge   同时删除状态文件 $STATE_FILE（默认保留）
  -h, --help   显示本帮助
EOF
}

for a in "$@"; do
  case "$a" in
    --purge) PURGE=1 ;;
    -h|--help) usage; exit 0 ;;
    *) tui_err "未知参数：$a"; usage; exit 1 ;;
  esac
done

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  tui_err "需要 root 权限，请使用 sudo 重新执行。"
  exit 1
fi

tui_init
tui_banner "卸载工具" "VLESS + REALITY"

tui_section "停止服务"
if have_cmd systemctl; then
  systemctl disable --now xray >/dev/null 2>&1 && tui_ok "xray 服务已停止并取消开机自启" || tui_warn "xray 服务停止失败（可能未安装）"
fi

tui_section "备份并移除配置"
if [[ -f "$XRAY_CONFIG" ]]; then
  mkdir -p "$OUT_DIR/backup"
  cp -f "$XRAY_CONFIG" "$OUT_DIR/backup/config.json.$(date +%Y%m%d%H%M%S)"
  rm -f "$XRAY_CONFIG"
  tui_ok "配置已备份并移除：$OUT_DIR/backup/"
fi

tui_section "撤销防火墙规则"
PORT=''
[[ -f "$STATE_FILE" ]] && PORT=$(. "$STATE_FILE"; printf '%s' "${PORT:-}")
if [[ -n "$PORT" ]]; then
  if have_cmd ufw && ufw status 2>/dev/null | grep -q 'Status: active'; then
    ufw delete allow "$PORT/tcp" >/dev/null 2>&1 && tui_ok "已撤销 ufw 规则 $PORT/tcp" || true
  elif have_cmd iptables; then
    while iptables -C INPUT -p tcp --dport "$PORT" -j ACCEPT 2>/dev/null; do
      iptables -D INPUT -p tcp --dport "$PORT" -j ACCEPT 2>/dev/null || break
    done
    tui_ok "已撤销 iptables 规则 $PORT/tcp"
  elif have_cmd nft; then
    nft list table inet filter >/dev/null 2>&1 && {
      local_rule=$(nft list chain inet filter input 2>/dev/null | grep -n "tcp dport $PORT" | head -1 | cut -d: -f1)
      [[ -n "$local_rule" ]] && nft delete rule inet filter input handle "$local_rule" 2>/dev/null || true
    }
    tui_ok "已尝试撤销 nftables 规则 $PORT/tcp"
  fi
fi

tui_section "移除网络调优"
rm -f /etc/sysctl.d/99-vless-reality-bbr.conf
sysctl --system >/dev/null 2>&1 || true
tui_ok "已移除 sysctl 调优文件"

tui_section "清理状态"
if [[ $PURGE -eq 1 ]]; then
  rm -f "$STATE_FILE"
  tui_ok "已删除状态文件：$STATE_FILE"
else
  tui_ok "保留状态文件：$STATE_FILE（如需删除请加 --purge）"
fi

tui_warn "Xray 内核二进制未删除，仍位于 $XRAY_BIN。"
tui_tip "如需彻底清理可手动执行：rm -f $XRAY_BIN"

tui_section "结果"
tui_ok "卸载完成。客户端导出目录保留于 $OUT_DIR"
exit 0
```

**Step 4: 运行测试确认通过**

```bash
bash test/unit.sh
```

预期：全部通过。

**Step 5: 提交**

```bash
git add uninstall.sh test/unit.sh
git commit -m "feat(uninstall): 停止服务、备份配置、撤销防火墙规则与状态清理"
```

---

## Task 12: build.sh、dist/install.sh 与 CI

**Files:**
- Create: `build.sh`
- Create: `dist/install.sh`（由 build.sh 生成）
- Create: `.github/workflows/ci.yml`
- Modify: `test/unit.sh`

**Interfaces:**
- Consumes: `lib/tui.sh` `lib/core.sh` `lib/client.sh` `lib/deploy.sh`
- Produces:
  - `build.sh` → 生成 `dist/install.sh`，退出码 `0`
  - `dist/install.sh` → 可独立执行的单文件安装脚本
  - `.github/workflows/ci.yml` → CI job

**Step 1: 写失败的测试**

追加到 `test/unit.sh`：

```bash
test_case "构建产物"

bash "$ROOT/build.sh" >/dev/null 2>&1
assert_status 0 "$?" "build.sh 执行成功"
assert_true "$([[ -f "$ROOT/dist/install.sh" ]] && echo 0 || echo 1)" "生成 dist/install.sh"

# 单文件产物必须自包含：不含 source lib/ 的相对引用
if [[ -f "$ROOT/dist/install.sh" ]]; then
  assert_eq 0 "$(grep -c 'source.*lib/' "$ROOT/dist/install.sh" || true)" "单文件产物不引用外部 lib/ 路径"
  assert_eq 0 "$(bash -n "$ROOT/dist/install.sh" 2>&1; echo $?)" "单文件产物语法正确"
  assert_contains "$(cat "$ROOT/dist/install.sh")" "tui_banner" "单文件产物包含 TUI 实现"
  assert_contains "$(cat "$ROOT/dist/install.sh")" "render_server_config" "单文件产物包含配置渲染"
fi
```

**Step 2: 运行测试确认失败**

```bash
bash test/unit.sh
```

预期：FAIL，`build.sh: No such file or directory`。

**Step 3: 实现 `build.sh`**

创建 `build.sh`：

```bash
#!/usr/bin/env bash
# build.sh — 把 lib/ 与 install.sh 内联成 dist/install.sh 单文件分发物
#
# 关键设计：入口代码**不在这里重写**，而是从 install.sh 抽取并剥离 source 行。
# 否则单文件版与开发版会立刻漂移，两条路径的行为将不再一致。
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
OUT="$ROOT/dist/install.sh"
VERSION="$(sed -n "s/^APP_VERSION='\(.*\)'.*/\1/p" "$ROOT/lib/core.sh" | head -1)"
[[ -n "$VERSION" ]] || VERSION='0.0.0'

mkdir -p "$ROOT/dist"
tmp="$OUT.tmp"

{
  cat <<HEADER
#!/usr/bin/env bash
# VLESS + REALITY 一键部署工具 —— 单文件分发版
#
# 本文件由 build.sh 自动生成，请勿手工编辑。
# 修改请编辑 lib/ 下的源文件与 install.sh 后重新运行 build.sh。
#
# 构建版本: ${VERSION}
# 构建时间: $(date -u '+%Y-%m-%dT%H:%M:%SZ')
#
# 用法: sudo bash install.sh [-y|--menu|--status|--uninstall|-h]
set -uo pipefail

ROOT_DIR="\$(cd -- "\$(dirname -- "\${BASH_SOURCE[0]}")" && pwd)"
HEADER

  # 固定顺序，保证产物可复现、diff 稳定
  for f in tui.sh core.sh client.sh deploy.sh; do
    printf '\n# ==================== lib/%s ====================\n' "$f"
    sed -e '1{/^#!/d;}' "$ROOT/lib/$f"
  done

  # install.sh 的入口部分：剥离 shebang、source 行、重复的 set/ROOT_DIR
  printf '\n# ==================== 入口 (install.sh) ====================\n'
  sed -e '1{/^#!/d;}' \
      -e '/^# shellcheck source=lib\//d' \
      -e '/^source "\$ROOT_DIR\/lib\//d' \
      -e '/^ROOT_DIR=.*BASH_SOURCE/d' \
      -e '/^set -uo pipefail$/d' \
      "$ROOT/install.sh"
} >"$tmp"

chmod +x "$tmp"
mv -f "$tmp" "$OUT"
printf '已生成 %s (v%s)\n' "$OUT" "$VERSION"
```

> **为什么不用 `cat lib/*.sh` 直接拼**：那会把每个文件重复的 shebang 拼进产物，
> 且入口代码要另写一份。上面这版只拼一次 source 依赖，且入口来自 `install.sh` 本身，
> CI 的 `git diff --exit-code dist/install.sh` 校验因此才有意义。

**Step 4: 实现 CI**

创建 `.github/workflows/ci.yml`：

```yaml
name: CI

on:
  push:
    branches: [main, master]
  pull_request:

jobs:
  check:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: 语法检查 (bash -n)
        run: |
          set -e
          find . -name '*.sh' -not -path './.git/*' -print0 | xargs -0 -n1 bash -n

      - name: ShellCheck
        run: |
          sudo apt-get update -qq
          sudo apt-get install -y -qq shellcheck
          shellcheck --severity=warning --exclude=SC1090,SC1091,SC2034 install.sh uninstall.sh build.sh demo.sh lib/*.sh test/*.sh

      - name: 单元测试
        run: bash test/unit.sh

      - name: dist 与源码同步校验
        run: |
          set -e
          bash build.sh
          if ! git diff --exit-code --stat dist/install.sh; then
            echo "::error::dist/install.sh 与 lib/ 已脱节，请运行 ./build.sh 后提交。"
            exit 1
          fi
```

**Step 5: 运行测试确认通过**

```bash
bash test/unit.sh
```

预期：全部通过。

**Step 6: 提交**

```bash
git add build.sh dist/install.sh .github/workflows/ci.yml test/unit.sh
git commit -m "feat(build): 单文件构建脚本、dist 产物与 CI 流水线"
```

---

## Task 13: demo.sh、README 与集成测试脚本

**Files:**
- Create: `demo.sh`
- Create: `README.md`
- Create: `test/integration-debian.sh`
- Modify: `test/unit.sh`

**Interfaces:**
- Consumes: `lib/tui.sh` `lib/core.sh`
- Produces:
  - `demo.sh` → 渲染 TUI 全部组件，不触碰系统
  - `README.md` → 使用说明
  - `test/integration-debian.sh` → 容器内端到端

**Step 1: 写失败的测试**

追加到 `test/unit.sh`：

```bash
test_case "demo.sh 不触碰系统"

out=$(bash "$ROOT/demo.sh" 2>&1)
assert_status 0 "$?" "demo.sh 正常退出"
assert_contains "$out" "分享链接" "demo 展示分享链接样例"
assert_eq 0 "$(grep -c 'systemctl ' <<<"$out")" "demo 不调用 systemctl"
assert_eq 0 "$(grep -c 'apt-get' <<<"$out")" "demo 不调用 apt-get"
```

**Step 2: 运行测试确认失败**

```bash
bash test/unit.sh
```

预期：FAIL，`demo.sh: No such file or directory`。

**Step 3: 实现 `demo.sh`**

创建 `demo.sh`：

```bash
#!/usr/bin/env bash
# demo.sh — 预览 TUI 界面外观，不做任何系统改动
set -uo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/tui.sh
source "$ROOT/lib/tui.sh"
# shellcheck source=lib/core.sh
source "$ROOT/lib/core.sh"

tui_init
tui_banner "VLESS + REALITY 部署工具" "TUI 界面预览 · 本脚本不会修改系统任何配置"

tui_section "区块标题与状态行"
tui_info "这是一条信息提示"
tui_ok   "这是一条成功提示"
tui_warn "这是一条警告提示"
tui_err  "这是一条错误提示"
tui_tip  "这是一条补充说明"
tui_step "这是一步进行中的操作"

tui_section "键值对与结果面板"
tui_kv "服务器地址" "203.0.113.10"
tui_kv "监听端口" "443"
tui_panel "示例配置" \
  "地址|203.0.113.10:443" \
  "UUID|8f3a1c22-4b6d-4e51-9b2c-7a0e5d3f1c88" \
  "SNI|www.microsoft.com" \
  "公钥 pbk|xQ0G2k7F0l3mN8pQ2rS5tU7vW9xY1zA3bC5dE7fG"

tui_section "圆角内容框"
tui_box "分享链接（示例）"
tui_box_line "vless://8f3a1c22-...@203.0.113.10:443?encryption=none&flow=xtls-rprx-vision&security=reality"
tui_box_end

tui_section "菜单（方向键移动 / 数字直选 / Enter 确认 / q 取消）"
tui_menu "示例菜单" \
  "部署 VLESS + REALITY 服务" \
  "查看客户端分享链接" \
  "重启服务" \
  "实时日志" \
  "退出"

tui_section "输入与确认"
tui_input "示例输入" "443" "监听端口"
printf '\n'
tui_confirm "示例确认（回车=是）" "y" || true

tui_pause
```

**Step 4: 实现 `test/integration-debian.sh`**

创建 `test/integration-debian.sh`：

```bash
#!/usr/bin/env bash
# 在 Debian 容器内跑完整的部署 → 校验 → 卸载流程
# 用法: bash test/integration-debian.sh
# 依赖: docker
set -uo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE="${IMAGE:-debian:bookworm-slim}"
CNAME="vless-reality-it-$$"

if ! command -v docker >/dev/null 2>&1; then
  echo "跳过：未找到 docker"
  exit 0
fi

cleanup() {
  docker rm -f "$CNAME" >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "==> 启动容器 $IMAGE"
docker run -d --name "$CNAME" -v "$ROOT:/work" -w /work "$IMAGE" sleep 3600 >/dev/null

echo "==> 安装依赖"
docker exec "$CNAME" bash -c 'apt-get update -qq && apt-get install -y -qq curl ca-certificates openssl qrencode procps iproute2 systemd >/dev/null 2>&1' || true

echo "==> 语法检查"
docker exec "$CNAME" bash -c 'find . -name "*.sh" -not -path "./.git/*" -print0 | xargs -0 -n1 bash -n' || {
  echo "语法检查失败"; exit 1; }

echo "==> 单元测试"
docker exec "$CNAME" bash -c 'bash test/unit.sh' || { echo "单元测试失败"; exit 1; }

echo "==> 构建单文件"
docker exec "$CNAME" bash -c 'bash build.sh' || { echo "构建失败"; exit 1; }

echo "==> 非交互部署（--yes）"
docker exec "$CNAME" bash -c 'bash dist/install.sh --yes --port 443 --sni www.microsoft.com --name it-test' || {
  echo "部署失败（容器内 systemd 不可用时属预期，需在真机或 privileged 容器验证）"
}

echo "==> 集成测试结束"
```

**Step 5: 编写 README.md**

创建 `README.md`，必须包含以下小节（内容按此骨架展开，命令与路径必须与实现一致）：

- 项目简介与特性列表
- 快速开始（两种方式：clone 运行 / `curl` 单文件）
- `curl` 单文件方式的完整命令（**先下载再执行**，不用管道）
- 目录结构说明
- CLI 参数表
- 部署向导的交互流程说明
- 管理菜单说明
- 客户端导入说明（v2rayN / v2rayNG / Clash Verge / Shadowrocket / Hiddify）
- 常见问题（端口占用、防火墙、BBR、二维码缺失、xray 服务未启动）
- **验证状态声明**（必须明确写出：单元测试与语法检查已在本环境通过；Debian 真机端到端部署尚未在本环境验证）
- 卸载说明
- 致谢与上游项目链接（XTLS/Xray-core、XTLS/Xray-install）

**Step 6: 运行测试确认通过**

```bash
bash test/unit.sh
```

预期：全部通过。

**Step 7: 提交**

```bash
git add demo.sh README.md test/integration-debian.sh test/unit.sh
git commit -m "docs: TUI 预览脚本、集成测试与 README"
```

---

## Self-Review

### 1. 规格覆盖

| 规格章节 | 对应任务 |
|---|---|
| 4.1 依赖方向单向无环 | Task 1–7 的文件划分 + Task 12 内联顺序 |
| 4.3 状态单一真相 | Task 3 `save_state`/`load_state`、Task 5 `render_server_config` |
| 4.4 安装落点 | Task 3 常量、Task 5 写配置、Task 7 导出目录 |
| 6.1 组件清单 | Task 1 基础层 + Task 2 交互层 |
| 6.2 视觉规范 | Task 1 `tui_init` / `tui_dwidth` / `tui_pad` |
| 6.3 降级策略 | Task 2 `tui_menu` 非 TTY 分支、`tui_run` 非 TTY 分支 |
| 7.1 预检 | Task 8 `preflight` |
| 7.2 目标选择 | Task 9 `probe_targets` / `choose_target` |
| 7.3 执行序列 ①–⑥ | Task 9 `do_deploy` |
| 8 管理菜单九项 | Task 10 |
| 9.1 密钥版本兼容 | Task 5 `xray_parse_keys` |
| 9.2 服务端配置模板 | Task 5 `render_server_config` |
| 9.3 三个关键决策 | Task 5（字面 CIDR / IPIfNonMatch / target） |
| 9.4 客户端配置 | Task 7 `render_client_config` |
| 9.5 分享链接格式 | Task 7 `build_share_link` |
| 10 CLI 契约 | Task 8 `parse_args` + Task 12 单文件版 |
| 11 错误处理矩阵 | Task 5/6/8/9 各自的错误分支 |
| 12 幂等性与安全 | Task 5 `write_config_atomic`、Task 6 `open_firewall` 去重 |
| 13 分发与 CI | Task 12 |
| 14 测试策略三层 | Task 1–11 单元层、Task 13 集成层、CI 语法层 |
| 15 卸载 | Task 11 |
| 16 未验证项 | Task 13 README 必须声明 |

**无遗漏。**

### 2. 占位符扫描

计划中无 TBD / TODO / "类似 Task N" / 无代码的步骤。所有代码块均含实际内容。
`deploy_wizard` / `management_menu` 在 Task 8 以**显式占位实现**出现（返回错误码），
并在 Task 9 / Task 10 被真实实现替换——这是有意的 TDD 顺序，不是占位符遗留。

### 3. 命名一致性

- `tui_*` 组件命名在 Task 1/2 定义，Task 8/9/10 调用 → 一致
- `core.sh` 函数名在 Task 3/4 定义，Task 5/6/8 引用 → 一致
- `render_server_config` 签名 `(outfile uuid priv sni port sid)` 在 Task 5 定义，
  Task 9 `do_deploy`、Task 10 `menu_rotate_keys` 调用 → 参数顺序一致
- `build_share_link` 签名 `(uuid ip port sni pub sid remark)` 在 Task 7 定义，
  Task 9、Task 10 调用 → 一致
- `export_client_artifacts` 签名 `(outdir uuid ip port sni pub sid remark)` → 一致
- 全局变量 `PORT UUID SNI PRIVATE_KEY PUBLIC_KEY SHORT_ID SERVER_IP REMARK` 在 Task 3 声明、
  Task 5/7/9 赋值 → 一致
- `XRAY_CONFIG` 在 Task 3 定义、Task 5/9/11 使用 → 一致
- **函数归属唯一**：`install.sh` 只含 `usage` `parse_args` `require_root` `preflight` `main`；
  `deploy_wizard` `management_menu` `menu_*` `probe_targets` `choose_target` `do_deploy`
  一律在 `lib/deploy.sh`。`install.sh` 通过 `declare -F` 守卫调用，不重复定义 → 无覆盖冲突
- **单文件产物与开发版不漂移**：`build.sh` 从 `install.sh` 抽取入口代码并剥离 `source` 行，
  不重写第二份入口 → 两者行为一致，CI 的 `git diff --exit-code` 校验才有意义

**未发现命名冲突。**

---

## Execution Handoff

计划已保存到 `docs/superpowers/plans/2026-10-21-vless-reality-deploy.md`。
