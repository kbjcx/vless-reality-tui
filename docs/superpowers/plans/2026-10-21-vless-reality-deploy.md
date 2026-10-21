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
- 允许使用的外部命令仅限（**运行时 / 分发物内**，即 `dist/install.sh` 与 `lib/`）：
  - 基础系统工具（Debian 基础系统自带，coreutils 等）：`awk` `sed` `grep` `tr` `cat` `od` `cut` `head` `sort` `seq` `sleep` `date` `uname` `hostname` `env` `timeout`
  - 文件与权限：`mktemp` `cp` `mv` `rm` `mkdir` `chmod` `chown`
  - 网络与系统：`curl` `openssl` `systemctl` `journalctl` `ss` `ip`
  - 防火墙（三选一，缺失时只提示不改规则）：`ufw` `iptables` `nft`
  - 包管理：`apt-get`
  - 可选：`qrencode`（二维码）`python3`（仅 urlencode 回退）`netstat`（仅 `ss` 不可用时的端口探测回退）
  - 被部署的负载程序：`xray`（由官方 `install-release.sh` 安装，非系统自带，但显然是允许调用的）
  - **CI / 开发期脚本**（不随分发物发布，可用范围更宽）：`git` `find` `xargs` `diff` `docker`
- `lib/tui.sh` **不得**包含任何业务判断、文件写入或系统调用（例外仅两处：`mktemp`/`sed`/`rm` 用于 `tui_run` 捕获输出，`sleep` 用于 spinner 帧间隔）
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

# 以【退出码】断言：用法为 assert_succeeds "描述" <命令> [参数...]
# 描述必须是【第一个】参数——若放在末尾，"$@" 会把描述一起当作命令参数执行，
# 被测命令会收到多余的参数，导致测试「因错误的原因通过或失败」。
assert_succeeds() { local m="$1"; shift; if "$@" >/dev/null 2>&1; then assert_eq 0 0 "$m"; else assert_eq 0 1 "$m"; fi; }
assert_fails()    { local m="$1"; shift; if "$@" >/dev/null 2>&1; then assert_eq 0 1 "$m"; else assert_eq 0 0 "$m"; fi; }

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
# 硬约束：本文件不得包含任何业务逻辑、文件写入或系统调用。
# （Task 2 的 tui_run 需要 mktemp 捕获命令输出，是这条约束的唯一例外。）

TUI_TTY=0; TUI_COLOR=0; TUI_WIDTH=80
# TUI_UNICODE 留空表示「自动探测」（由 tui_init 按 locale 判定）；
# 显式设为 1/0 可强制 Unicode / ASCII。
# 必须留空而不能写死 1：否则下面 tui_init 里的「显式覆盖」分支恒真，
# locale 探测分支将永远不可达，LANG=C → ASCII 的降级规则形同虚设。
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
    # 格式串占位符必须与实参个数严格相等（11 个 %s ↔ 11 个实参）：
    # 多一个 %s 会让 bash printf 把空串补上去，从而把一个分隔空格挤到
    # 右边框【之后】——行宽仍是 80，但右边框会停在第 79 列、与角标错开 1 列。
    printf '  %s%s%s %s%s%s%s %s%s%s %s%s%s\n' "$C_ACCENT" "$B_V" "$C_RESET" "$C_GRAY" \
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

> **给实施者的两条交接提醒（来自 Task 1 复评，务必遵守）：**
> 1. **只追加，不重写**：`lib/tui.sh` 的基础层已通过评审并修好了若干坑——
>    locale 无关的 `tui_dwidth`（按字节解码 UTF-8、校验续字节、跳过 ANSI 序列）、
>    用真实 ESC 字节的 `tui_strip`、统一的框线几何（内容行 = `2空格+│+空格+(W-6)+空格+│`）、
>    Unicode→ASCII 降级。**这些都不要再动**，你只负责追加交互组件。
> 2. **不要依赖 `tui_strip` 处理非 SGR 序列**：它只剥 `ESC[...m` 形式，
>    不处理光标移动（`ESC[nA`、`ESC[J`）与 OSC。菜单重绘若要测宽，
>    请用 `tui_dwidth`（它会自行跳过 ANSI 序列），不要用 `tui_strip`。
> 3. `tui_run` 的签名必须为 `tui_run <消息> <命令> [参数...]`——
>    `lib/core.sh` 的 `apt_update_once` 与 `ensure_packages` 已按此形状调用它，
>    签名不符会导致依赖静默不装而部署继续。

**Files:**
- Modify: `lib/tui.sh`（追加交互组件）
- Modify: `test/unit.sh`（追加用例）
- Create: `test/helpers/menu_noninteractive.sh`
- Create: `test/helpers/menu_tty.sh`（强制 TUI_TTY=1，管道喂按键驱动交互分支）
- Create: `test/helpers/confirm.sh`
- Create: `test/helpers/input.sh`

**Interfaces:**
- Consumes: Task 1 的 `tui_pad` `tui_repeat` `tui_section` `C_*` 变量
- Produces:
  - `tui_run <msg> <cmd> [args...]` → 返回命令退出码；非 TTY 下不显示 spinner，但仍捕获输出并在失败时打印
  - `tui_confirm <prompt> [y|n]` → `0`=是 `1`=否；**提示走 stderr**
  - `tui_input <prompt> [default] [hint]` → stdout 输出用户输入；**提示走 stderr**
  - `tui_input_secret <prompt> [default]` → stdout 输出用户输入（不回显）；提示走 stderr
  - `tui_menu <title> <item>...` → **整个菜单打到 stdout**；返回 0-based 索引，取消返回 `255`
  - `tui_select <title> <default_item> <item>...` → 同上，默认高亮 `default_item`
  - `tui_pause`

**Step 1: 写失败的测试**

追加到 `test/unit.sh`：

```bash
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
out=$(printf '\n' | bash "$ROOT/test/helpers/input.sh" "默认端口" "443")
assert_eq "443" "$out" "tui_input 空输入返回默认值"

test_case "TUI 菜单交互路径（强制 TUI_TTY=1，管道喂按键模拟真终端）"

# 数字缓冲区被非数字污染 → 必须取消，绝不能静默选中第一项
out=$(printf '1q' | bash "$ROOT/test/helpers/menu_tty.sh" "选择" "A" "B" "C"); rc=$?
assert_status 255 "$rc" "数字后按 q 必须取消(255)，不得静默选中第一项"
assert_contains "$out" "已取消" "数字后按 q 显示取消"

# EOF / Ctrl-D → 必须取消，不得当成回车去确认高亮项
printf '' | bash "$ROOT/test/helpers/menu_tty.sh" "选择" "A" "B" "C" >/dev/null 2>&1; rc=$?
assert_status 255 "$rc" "EOF 必须取消(255)"

# 缓冲区提示行只能打印一次（printf 格式串 %s 个数必须等于实参个数）
# 必须用两位数 + 回车：单数字在 0.35s 窗口后立即选中，菜单只重绘一次且缓冲区
# 始终为空 → 根本不会渲染提示行，计数恒 0，发现不了「打印两遍」这个 bug。
# 两位数才会进入缓冲区并重绘一次提示行（旧代码这里会打印 2 遍）。
out=$(printf '10\n' | bash "$ROOT/test/helpers/menu_tty.sh" "选择" "A" "B" "C")
assert_eq "1" "$(printf '%s\n' "$out" | grep -c '编号')" "缓冲区提示行只打印一次"

# 方向键下移后回车 → 选中第 2 项（索引 1）
out=$( { printf '\033[B'; sleep 0.3; printf '\n'; } | bash "$ROOT/test/helpers/menu_tty.sh" "选择" "A" "B" "C" ); rc=$?
assert_status 1 "$rc" "方向键下移后回车选中第 2 项(索引 1)"

# 方向键与回车【一次性写入】：方向键只剩 2 字节，-n2 正好读完，
# 紧跟的回车不能被当成方向键序列的第 3 字节吞掉（-n3 会吞掉）
out=$(printf '\033[B\n' | bash "$ROOT/test/helpers/menu_tty.sh" "选择" "A" "B" "C"); rc=$?
assert_status 1 "$rc" "方向键后紧跟的回车不被方向键序列吞掉"

# 方向键之后的数字键：-n3 会把 "2" 吞进方向键序列（方向键不生效且 "2" 丢失
# → 选中第 1 项）；-n2 下 "2" 被当作数字直选 → 选中第 2 项(索引 1)
out=$(printf '\033[B2\n' | bash "$ROOT/test/helpers/menu_tty.sh" "选择" "A" "B" "C"); rc=$?
assert_status 1 "$rc" "方向键之后的数字键不被方向键序列吞掉"

# 多位数：>=10 项时输入 10 并回车应选中第 10 项（索引 9）
# 必须带回车：EOF 现在按 I2 判定为「取消」(255)，不是「确认」
out=$(printf '10\n' | bash "$ROOT/test/helpers/menu_tty.sh" "选择" 1 2 3 4 5 6 7 8 9 10 11); rc=$?
assert_status 9 "$rc" "多位数 10 选中第 10 项(索引 9)"

# 直接按 q → 取消
printf 'q' | bash "$ROOT/test/helpers/menu_tty.sh" "选择" "A" "B" "C" >/dev/null 2>&1; rc=$?
assert_status 255 "$rc" "直接按 q 返回 255"
```

> **实施说明（Task 2 已完成，以 `test/unit.sh` 为准）**：上面的 Step 1 是本任务的**原始规格**。
> 经 3 轮修复（每轮都有独立评审），`test/unit.sh` 最终为 **52 条断言全部通过**，
> 相对上面的原始规格**额外**增加了：缓冲区提示行格式串 `%s` 占位符个数的**静态校验**
> （含「匹配不到格式串就算失败」的封口，避免 `assert_eq 0 0` 恒真通过）、
> `tui_confirm` 两个分支的 stdout 字节数断言、`tui_run` 临时文件不可用时的降级路径断言。
> 逐条改动与实测证据见
> `.superpowers/sdd/2026-10-21-vless-reality-deploy/task-2-report.md`。
> **本任务后续不再修改**；若要改 `lib/tui.sh`，先读该报告。

同时创建四个 helper（`test/helpers/`）：

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

`test/helpers/menu_tty.sh`（强制走交互分支，用管道喂按键模拟真终端）：

```bash
#!/usr/bin/env bash
# 用法: printf '按键序列' | bash menu_tty.sh "标题" "选项1" "选项2" ...
# 退出码 = tui_menu 的返回码（0-based 索引，取消为 255）
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/lib/tui.sh"
tui_init
# 必须在 tui_init 之后覆盖：tui_init 会按真实 TTY 把 TUI_TTY 置 0
TUI_TTY=1
tui_menu "$@"
exit $?
```

**Step 2: 运行测试确认失败**

```bash
bash test/unit.sh
```

预期：FAIL，`tui_menu: command not found`。

**Step 3: 实现交互组件**

追加到 `lib/tui.sh`：

```bash
# ===== 交互层（追加在 lib/tui.sh 基础层之后）=====
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
    printf '\r  %s%s%s %s%s%s%s\n' "$C_OK" "$I_OK" "$C_RESET" "$C_GRAY" "$msg" "$C_RESET"
  else
    printf '\r  %s%s%s %s%s%s%s\n' "$C_ERR" "$I_ERR" "$C_RESET" "$C_GRAY" "$msg" "$C_RESET"
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
# 注意：整个菜单（选项列表 + 提示行）都打到 stdout，
# 调用方必须用【返回码】取选中项，不要捕获 stdout。
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
      IFS= read -rsn2 -t 0.2 seq || true
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
        IFS= read -rsn1 -t 0.35 more || more=''
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
  - `validate_hostname <str>` → `0`/`1`（SNI 主机名校验，纯函数）
  - `state_quote <str>` → stdout 单引号字面量（可被 shell 安全求值）
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
os_out=$(detect_os "$fake_os")
assert_contains "$os_out" "debian|12|" "detect_os 解析 id|version|arch"
rm -f "$fake_os"

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

# state_quote：状态文件会被 load_state 用 `.` 引入执行，
# 写入的值必须是可被 shell 安全求值的单引号字面量。
assert_eq "'443'"     "$(state_quote 443)"      "state_quote 产出单引号字面量"
assert_eq "''"       "$(state_quote '')"        "state_quote 空值产出空字面量"
assert_eq "'a'\''b'" "$(state_quote "a'b")"     "state_quote 转义内部单引号"
assert_eq "'\$(id)'" "$(state_quote '$(id)')"   "state_quote 不让命令替换在字面量内生效"

# save_state / load_state 往返：REMARK 来自用户输入（--name），
# 写入后再读回必须逐字节一致，且其中的 $(...) 不得在读取时被执行。
t_dir=$(mktemp -d)
t_state="$t_dir/deploy.env"
( STATE_DIR="$t_dir"; STATE_FILE="$t_state"; PORT=8443
  REMARK='$(touch '"$t_dir"'/pwned)'; SNI="a'b"
  save_state >/dev/null 2>&1 )
back=$( ( STATE_FILE="$t_state"; REMARK=''; load_state >/dev/null 2>&1; printf '%s' "$REMARK" ) )
assert_eq '$(touch '"$t_dir"'/pwned)' "$back" "load_state 读回的 REMARK 逐字节一致"
assert_contains "$(cat "$t_state")" "REMARK='" "状态文件以单引号字面量保存 REMARK"
[[ -e "$t_dir/pwned" ]]; rc=$?
assert_false "$rc" "load_state 不得执行状态文件中的命令替换"
rm -rf "$t_dir"
```

> **源码引入位置约定**：本任务及后续任务新增的 `source "$ROOT/lib/xxx.sh"` 一律放在
> `test/unit.sh` 顶部的 source 区域（`source "$ROOT/lib/tui.sh"` 之后），
> 不要追加到文件末尾——测试用例依赖函数在执行时已定义。

> 注：`detect_os` 接受可选参数 `os_release_path`，默认 `/etc/os-release`——这使它可测。

**Step 2: 运行测试确认失败**

```bash
bash test/unit.sh
```

预期：FAIL，`lib/core.sh: No such file or directory`。

**Step 3: 实现 `lib/core.sh`**

> ⚠️ **本任务是【整体重写】`lib/core.sh`，不是在其上追加。**
> 仓库里当前已存在一份早期草稿（`lib/core.sh`，约 295 行），它与本计划**冲突**，
> 下列内容**一律不保留**：
> - `require_root()` —— 按计划的「函数归属唯一」，`require_root` 属于 `install.sh`
>   （计划 Task 8）。core.sh 里再定义一份，两个文件都被 source 时后加载者会覆盖前者。
> - `is_modern_debian()` —— 计划中没有这个函数，不要保留。
> - `port_in_use()` 里的 `netstat` 回退分支 —— 属于 Task 4，本任务不写。
> - `APP_VERSION='1.2.0'` —— 计划统一为 `1.0.0`。
> - `detect_os()` 不接受 `os_release_path` 参数的旧写法 —— 计划要求接受该参数（可测）。
> - 草稿里的 `detect_public_ip` / `detect_local_ip` / `port_in_use` / `port_occupant` /
>   `random_free_port` / `target_supports_tls13` / `target_latency_ms` /
>   `apt_update_once` / `ensure_packages` / `service_run_user` —— 属于 Task 4，
>   本任务不写，Task 4 再按计划追加。

创建 `lib/core.sh`（本任务只写纯函数与状态部分，网络探测在 Task 4 追加）：

```bash
#!/usr/bin/env bash
# lib/core.sh — 环境探测与通用能力

APP_NAME='VLESS + REALITY 部署工具'
APP_VERSION='1.0.0'

LIB_DIR="${LIB_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)}"
STATE_DIR="${STATE_DIR:-/etc/vless-reality}"
STATE_FILE="${STATE_FILE:-$STATE_DIR/deploy.env}"
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
  # 回退实现：必须按【字节】遍历，否则多字节字符只会编码首字节。
  # local LC_ALL=C 让 ${#s} 与 ${s:i:1} 都按字节切分。
  local out='' i c len
  local LC_ALL=C
  len=${#s}
  for ((i = 0; i < len; i++)); do
    c=${s:$i:1}
    case "$c" in
      [a-zA-Z0-9.~_-]) out+="$c" ;;
      *) out+=$(printf '%%%02X' "'$c") ;;
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
  mkdir -p "$STATE_DIR"
  chmod 700 "$STATE_DIR"
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

# 端口判定：用一个必然空闲的高位端口。
# 注意：port_in_use / target_supports_tls13 的结果在【退出码】上，
# 不能写成 assert_false "$(port_in_use 59999)" —— $( ) 捕获的是 stdout（空串），
# 退出码被丢掉，断言会恒真通过（测不出任何东西）。
port_in_use 59999; rc=$?
assert_false "$rc" "高位端口 59999 判定为空闲"
assert_eq "" "$(port_occupant 59999)" "空闲端口无占用进程"

# 延迟解析：传入一个必然超时的域名，应返回 '?'
assert_eq "?" "$(target_latency_ms 'invalid.invalid.nonexistent' 2>/dev/null)" "不可达目标返回 ?"

# 真实目标：至少一个候选站点应支持 TLS1.3（网络不可用时跳过断言，不算失败）
if have_cmd openssl && curl -fsS --max-time 5 -o /dev/null https://www.microsoft.com 2>/dev/null; then
  target_supports_tls13 www.microsoft.com; rc=$?
  assert_true "$rc" "www.microsoft.com 支持 TLS 1.3"
fi

# apt update 失败必须中止：否则依赖装不上，调用方却以为装好了。
# 用 mock 覆盖 tui_run 让它失败（子 shell 内覆盖，不污染测试进程）。
# 若本机已存在标记文件则跳过（此时函数会提前返回 0，用例前提不成立）。
if [[ ! -f /var/lib/vless-reality/apt-updated ]]; then
  ( tui_run() { return 1; }; apt_update_once >/dev/null 2>&1 ); rc=$?
  assert_false "$rc" "apt update 失败时 apt_update_once 必须返回非零"
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
  touch /var/lib/vless-reality/apt-updated
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

追加到 `test/unit.sh`（`source "$ROOT/lib/deploy.sh"` 一行放在**顶部 source 区域**，见 Task 3 的约定）：

```bash
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
    # 兼容 "key: value" 与 "key=value" 两种写法
    if [[ "$line" == *=* && "$line" != *:* ]]; then
      key="${line%%=*}"
      val="${line#*=}"
    else
      key="${line%%:*}"
      val="${line#*:}"
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

# 未安装 xray 时 xray_installed 必须返回非零退出码
if [[ ! -x "$XRAY_BIN" ]]; then
  assert_fails "未安装时 xray_installed 返回非零" xray_installed
fi

# enable_bbr 在不支持 bbr 的内核上必须安全失败而非崩溃；输出必须提及 bbr
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

追加到 `test/unit.sh`（`source "$ROOT/lib/client.sh"` 一行放在**顶部 source 区域**）：

```bash
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
out=$(bash "$ROOT/install.sh" --definitely-not-a-real-flag 2>&1); rc=$?
assert_status 1 "$rc" "未知参数以非零码退出"
assert_contains "$out" "未知" "未知参数给出提示"

# --status 在未部署时应优雅退出而非崩溃（只读操作，不要求 root）
out=$(bash "$ROOT/install.sh" --status 2>&1); rc=$?
assert_status 0 "$rc" "未部署时 --status 退出码为 0"
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
  # SNI 会在后续被原样写进 config.json 与分享链接 —— 在【参数解析口】校验，
  # 避免把带引号/反斜杠的字符串送进 JSON 渲染。
  if [[ -n "$OPT_SNI" ]] && ! validate_hostname "$OPT_SNI"; then
    tui_err "--sni 不是合法的主机名：$OPT_SNI"
    tui_tip "示例：www.microsoft.com（只允许字母、数字、连字符与点，且必须含点）"
    exit 1
  fi
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
    # 只读操作，不要求 root —— 否则非 root 的 CI 环境会直接失败，
    # 与本任务「--status 退出码为 0」的测试断言相矛盾。
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
# 并发探测候选伪装目标：TLS1.3 支持 + 连通延迟，按延迟升序输出 "host|tls|latency"
# 未知延迟（'?'）视为最大，排在最后
probe_targets() {
  local host tmp sortkey h t l
  tmp=$(mktemp)
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
  for host in "${pids[@]}"; do wait "$host" 2>/dev/null || true; done
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
    # 自动挑选第一个支持 TLS1.3 且延迟已知的目标
    local pick=''
    while IFS='|' read -r host tls lat; do
      if [[ "$tls" == 'ok' && "$lat" != '?' ]]; then pick="$host"; break; fi
    done <<<"$probe"
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
  tui_menu "选择 REALITY 伪装目标（SNI）" "${labels[@]}" || rc=$?
  if (( rc == 255 )); then
    tui_warn "未选择伪装目标，回退到第一项"
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
    # 同上：用返回码取选中项，不要用 $(...) 捕获 stdout
    local choice=0 crc=0
    tui_menu "请选择操作" \
      "重新部署（重跑向导）" \
      "查看配置 / 分享链接 / 二维码" \
      "重启服务" \
      "实时日志（tail -f）" \
      "更新 Xray 内核" \
      "网络调优（BBR / 防火墙）" \
      "轮换密钥与 UUID" \
      "卸载" \
      "退出" || crc=$?
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

先创建 `.shellcheckrc`（本地与 CI 共用同一份豁免清单，避免两处行为不一致）：

```
# SC1090/SC1091：脚本在运行时 source 其它文件，shellcheck 无法静态解析
disable=SC1090,SC1091
# SC2034：全局状态变量在各模块间传递，单独看像是未使用
disable=SC2034
```

再创建 `.github/workflows/ci.yml`：

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
          shellcheck --severity=warning install.sh uninstall.sh build.sh demo.sh lib/*.sh test/*.sh test/helpers/*.sh

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
