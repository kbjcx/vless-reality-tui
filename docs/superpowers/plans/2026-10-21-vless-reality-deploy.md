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
  - 基础系统工具（Debian 基础系统自带，coreutils 等）：`awk` `sed` `grep` `tr` `cat` `od` `cut` `head` `sort` `seq` `sleep` `date` `uname` `hostname` `env` `timeout` `id` `sysctl` `dirname` `bash`（`bash` 就是本工具的解释器本身，Task 6 用 `bash "$installer" install` 调官方安装脚本）
  - 文件与权限：`mktemp` `cp` `mv` `rm` `mkdir` `chmod` `chown`
  - 网络与系统：`curl` `openssl` `systemctl` `journalctl` `ss` `ip`
  - 防火墙（三选一，缺失时只提示不改规则）：`ufw` `iptables` `nft`
  - 包管理：`apt-get`
  - 可选：`qrencode`（二维码）`python3`（仅 urlencode 回退）`netstat`（仅 `ss` 不可用时的端口探测回退）
  - 被部署的负载程序：`xray`（由官方 `install-release.sh` 安装，非系统自带，但显然是允许调用的）
  - **CI / 开发期脚本**（不随分发物发布，可用范围更宽）：`git` `find` `xargs` `diff` `docker` `stat` `wc`
- `lib/tui.sh` **不得**包含任何业务判断、文件写入或系统调用（例外仅两处：`mktemp`/`sed`/`rm` 用于 `tui_run` 捕获输出，`sleep` 用于 spinner 帧间隔）
- 状态文件 `/etc/vless-reality/deploy.env` 权限 `600`，状态目录 `700`；客户端导出目录 `/root/vless-reality/` 权限 `700`
- 服务端配置 `/usr/local/etc/xray/config.json` 含 REALITY **私钥** → 权限 `600`
  （systemd unit 没有 `User=`，xray 以 root 运行，`600` 不会挡住它读配置）
- 服务端配置写入流程恒为：**写临时文件 → `xray run -test` 校验 → 通过才 `mv` 原子替换**；不通过则保留旧配置并原样输出 xray 报错
- 不得使用 `jq`；不得用 `grep` 反解 JSON
- 所有 `.sh` 文件必须 LF 行尾（`.gitattributes` 已锁定）
- 非 TTY 环境（`nohup` / `curl | bash` / CI）必须降级为编号列表，**不得挂死**
- 所有失败路径必须以非零退出码结束，且经 `tui_err` 输出
- **所有任务的测试用例都必须追加在 `test/unit.sh` 的 `test_summary` 之前**
  （`test_summary` 必须是文件最后一行）。追加在它之后有两个后果：
  ① 断言条数统计偏小（`test_summary` 早就跑完了，后面的用例不计入）；
  ② **用例失败时脚本退出码仍是 0** —— `test_summary` 已经先返回过 0，
  失败被彻底吞掉 → CI 绿灯放行红灯。
  （Task 4 修订轮 1 首次组装沙箱时正是踩了这个坑：追加在末尾后
  摘要显示 155 项、实际执行了 184 项。）
- **条件块里的断言必须配一条 else 侧的「已跳过 / 前提不成立」说明断言**，
  使**断言总数与机器、网络、依赖是否可用无关**。只写 `if 条件; then 断言...; fi`
  会在条件不成立时**静默少算**断言 → 条数漂移 → CI 里写死条数必然 flake。
  正确写法：条件成立时跑真正的断言；条件不成立时**不断言失败**，
  而是登记一条 `assert_eq "说明文字" "说明文字" "某某已跳过（原因）：……"` 把条数补回来。
  全计划扫描结果（Task 4 修订轮 2 时点）：共 **57 条断言**落在条件块内。
  其中**没有** else 侧说明、会让条数漂移的有：Task 4 的 TLS 1.3（1 条）与
  apt update 守卫（1 条）、Task 5 的 python3 JSON 校验（8 条）、
  Task 7 的 python3 JSON 校验（1 条）—— 已在本轮全部补上。
  另外**故意**随平台变化的是**权限相关行为断言**（chmod 在 MSYS 上是模拟的、
  权限位不可达）：Task 3/4 的 4 条、Task 7 的 3 条等 —— 这类属于
  「本平台无法验证」而不是缺陷，因此**不补** else 说明；
  代价是断言条数**分平台不同** → 每个任务的验收标准与报告都必须
  **写明是哪个平台的数字**。
  （本条规则**不写代码示例**是有意的：全局约束里放 ```bash 围栏会被
  「全计划 bash 块语法检查」当成一个代码块，而片段不是合法 bash → 误报语法错。
  正确写法的实例见 Task 4 的 Step 1 代码块与「修订轮 2」小节。）
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
# 期望值必须是 "abc-123"：连字符 '-' 是 RFC 3986 的 unreserved 字符，
# Python 的 quote(s, safe="") 必然保留它，回退分支的安全集里也有 '-'。
# 原先写成 "abc123" 等于要求「把连字符删掉」，与它自己的描述自相矛盾。
assert_eq "abc-123" "$(urlencode 'abc-123')" "urlencode 保留安全字符（连字符不编码）"
assert_eq "abc123" "$(urlencode 'abc123')" "urlencode 保留字母与数字"

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
# 本文件只放【纯函数】与【状态持久化】；网络探测类函数属于 Task 4。
# 注意：本文件【不是自包含】的 —— assert_debian / save_state / load_state 会调用
# lib/tui.sh 的 tui_err / tui_tip / tui_ok。按计划的「函数归属唯一」约定，
# core.sh 不主动 source tui.sh，由 install.sh 统一按 tui → core 的顺序引入。

APP_NAME='VLESS + REALITY 部署工具'
APP_VERSION='1.0.0'

LIB_DIR="${LIB_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)}"
STATE_DIR="${STATE_DIR:-/etc/vless-reality}"
STATE_FILE="${STATE_FILE:-$STATE_DIR/deploy.env}"
OUT_DIR="${OUT_DIR:-/root/vless-reality}"
XRAY_BIN="${XRAY_BIN:-/usr/local/bin/xray}"
XRAY_CONFIG="${XRAY_CONFIG:-/usr/local/etc/xray/config.json}"
LOG_DIR="${LOG_DIR:-/var/log/xray}"

# 全局部署状态：Task 5/7/9 赋值，Task 3 的 save_state 负责持久化。
# 必须显式声明：install.sh 跑在 `set -u` 下，未声明又未赋值的变量一旦被引用
# 就会触发 unbound variable（实测：--menu 路径不经过 preflight → SERVER_IP 从未
# 探测，deploy_wizard 引用 $SERVER_IP、menu_tune 引用 $PORT 都会直接崩掉，
# 而且没有 tui_err 提示，用户只看到一句 "SERVER_IP: unbound variable"）。
# 用 ${VAR:-默认} 而不是 VAR='' ：前者既定义了变量（set -u 安全），
# 又【保留调用方在 source 之前预设的值】，后者会把预设值清空。
PORT="${PORT:-}"; UUID="${UUID:-}"; SNI="${SNI:-}"; TARGET="${TARGET:-}"
PRIVATE_KEY="${PRIVATE_KEY:-}"; PUBLIC_KEY="${PUBLIC_KEY:-}"; SHORT_ID="${SHORT_ID:-}"
SERVER_IP="${SERVER_IP:-}"; REMARK="${REMARK:-}"
MODE="${MODE:-native}"; FLOW="${FLOW:-xtls-rprx-vision}"; FINGERPRINT="${FINGERPRINT:-chrome}"

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
    # 必须用 sys.stdout.write 而不是 print：print 会多输出一个尾换行，
    # 而回退分支没有 —— 同一个函数的两个分支 stdout 字节不一致。
    python3 -c 'import sys,urllib.parse;sys.stdout.write(urllib.parse.quote(sys.argv[1],safe=""))' "$s" 2>/dev/null && return 0
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
      # ' 与 \ 的编码写死：printf '%%%02X' "'$c" 依赖 bash 对「以 ' 开头的字符常量」
      # 的解释，这一点【未在本机文档中确认】（bash 5.3.9 实测给出 39/92，
      # 但 help printf 只列了 %b %q %Q %(fmt)T 四个扩展，未提该形式）。
      # 把这两个字节的数值写死后，任意 bash 4.2+ 上结果一致，
      # 输出与原写法逐字节相同（其余字节仍走原写法）。
      "'")  out+='%27' ;;
      '\')  out+='%5C' ;;
      *) out+=$(printf '%%%02X' "'$c") ;;
    esac
  done
  printf '%s' "$out"
}

random_hex() {
  local n="${1:-8}" out=''
  [[ "$n" =~ ^[0-9]+$ ]] || return 1
  # 必须【先捕获输出再判断】，不能用 `openssl ... | tr ...; return 0`：
  # 管道的退出码取自最后一个命令（tr），openssl 失败时 tr 仍返回 0 →
  # random_hex 会【返回 0 但输出空串】→ 空 SHORT_ID 被原样写进 config.json →
  # xray run -test 失败 → 部署中止，且报错与真实原因（取不到随机数）完全无关。
  if have_cmd openssl; then
    out=$(openssl rand -hex "$n" 2>/dev/null) || out=''
  fi
  if [[ ! "$out" =~ ^[0-9a-f]+$ ]]; then
    # openssl 不可用或输出不可用 → 退回 /dev/urandom（od 是 coreutils，几乎必然存在）
    out=$(od -An -tx1 -N "$n" /dev/urandom 2>/dev/null) || out=''
  fi
  # 空格与 CR 一起删：od 的输出用空格分隔；某些 openssl 构建（含本开发机的
  # MSYS2 版本）输出的是 \r\n，只删 LF 会残留一个 \r，而这个 \r 会混进
  # SHORT_ID / 密钥，随后被原样写进 config.json（JSON 字符串里不允许裸控制
  # 字符）→ 直接让部署失败。Debian 自带的 openssl 只输出 \n，多删一个 \r
  # 对其无影响。
  out=$(printf '%s' "$out" | tr -d ' \r\n')
  # 必须是纯小写十六进制：脏输出（错误文本、半截输出）若被原样写进 config.json，
  # 失败点会被推迟到 xray 校验，报错与真实原因完全无关。
  [[ -n "$out" && "$out" =~ ^[0-9a-f]+$ ]] || return 1
  printf '%s' "$out"
}

read_file() {
  local f="$1"
  [[ -f "$f" ]] || return 1
  trim "$(cat "$f" 2>/dev/null)"
}

detect_os() {
  local os_release="${1:-/etc/os-release}" id='' ver='' arch='' pair=''
  if [[ -r "$os_release" ]]; then
    # 只接受受信任路径：os-release 是 shell 片段，`.` 引入等价于执行代码。
    # 本函数只用于 /etc/os-release 与测试用临时文件，不接受用户可控输入。
    # 只 source 一次，同时取出 ID 与 VERSION_ID。
    pair=$(. "$os_release" 2>/dev/null; printf '%s|%s' "${ID:-}" "${VERSION_ID:-}")
    # 连 CR 一起删：CRLF 行尾的 os-release 会让 ID 变成 "debian\r" →
    # assert_debian 误判成「不是 Debian」。Debian 自带的 os-release 是 LF，
    # 但 /etc 里也可能存在被 CRLF 改写过的副本。
    id=$(printf '%s' "${pair%%|*}" | tr -d '\r')
    ver=$(printf '%s' "${pair#*|}" | tr -d '\r')
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
  # 每一步都必须检查返回码：把「没写成功」伪装成「配置已保存」是最坏的失败模式
  # —— 状态没落盘，但用户以为成功了 → 之后 --status 显示未部署、卸载流程拿不到
  # 端口 → 防火墙规则被遗留。触发条件虽窄（root + 正常 /etc 时不会发生），
  # 但磁盘满、/etc 只读、STATE_DIR 配错都会触发。
  mkdir -p "$STATE_DIR" || { tui_err "无法创建状态目录：$STATE_DIR"; return 1; }
  chmod 700 "$STATE_DIR" || { tui_err "无法设置状态目录权限：$STATE_DIR"; return 1; }
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
  } >"$tmp" || { tui_err "无法写入状态临时文件：$tmp"; rm -f "$tmp"; return 1; }
  chmod 600 "$tmp" || { tui_err "无法设置状态文件权限：$tmp"; rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$STATE_FILE" || { tui_err "无法保存状态文件：$STATE_FILE"; rm -f "$tmp"; return 1; }
  tui_ok "配置已保存：$STATE_FILE"
}

load_state() {
  # 「读不到」与「格式错」必须分开报（复评 F-4）：
  # 早期写法是 [[ -f "$STATE_FILE" ]] || return 1 —— 静默返回，调用方无从判断
  # 是「还没部署过」还是「状态文件坏了」；而对「文件存在但不可读」的情况，
  # 子 shell 探测会把权限错误当成「格式错误」报出来，把人带偏。
  if [[ ! -f "$STATE_FILE" ]]; then
    tui_err "状态文件不存在：$STATE_FILE"
    return 1
  fi
  if [[ ! -r "$STATE_FILE" ]]; then
    tui_err "状态文件不可读：$STATE_FILE"
    return 1
  fi
  # 只【解析】不【执行】：用 bash -n 做语法检查。
  # 早期写法是在子 shell 里 source 一遍做「静默探测」，
  # 那会把状态文件【执行两次】（探测一次、正式读一次）——
  # 文件里一旦有副作用就会发生两次，且第一次的副作用对调用方不可见。
  # bash -n 只做语法分析、不执行任何语句，因此没有副作用
  # （实测：含 $(touch x) 的状态文件经 bash -n 之后副作用未发生）。
  # 实测：语法错误 → rc=2 且 stderr 有 "syntax error"；
  #       合法文件（含末条 false）→ rc=0 且 stderr 为空。
  local syntax_err=''
  syntax_err=$( "${BASH:-bash}" -n -- "$STATE_FILE" 2>&1 ) || true
  if [[ -n "$syntax_err" ]]; then
    tui_err "状态文件格式错误：$STATE_FILE"
    tui_tip "${syntax_err%%$'\n'*}"
    return 1
  fi
  # shellcheck disable=SC1090
  # 这里的返回码【不作为失败判据】：状态文件最后一条命令返回非零是合法的
  # （例如末尾是一条返回 1 的语句），真正坏掉的文件已在上面的语法检查里被拦下。
  . "$STATE_FILE" || true
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

### 修复轮 1/5（独立评审 FAIL 后追加）—— 本节是**本任务的最终真相**

> 本节由控制器在独立评审（结论 **FAIL**：2 条 Important + 7 条 Minor + 7 条范围外观察）后写入。
> **Step 3 的代码块已同步为最终权威版本**：`lib/core.sh` 必须与它**逐字节一致**。
> Step 1 的用例是本任务的**最低规格**；下面「新增断言」是必须补齐的部分，
> 与 Step 1 并集构成 `test/unit.sh` 里 Task 3 的全部用例。

#### 逐项发现与处置

| 编号 | 类别 | 处置 | 落在哪 |
|---|---|---|---|
| I-1 | **Important** | `lib/core.sh` 顶部常量区之后补全局状态变量声明块，用 `${VAR:-}` 形式（既 `set -u` 安全，又**保留调用方预设的值**） | Step 3 代码块 |
| I-2 | **Important** | `save_state` 每一步都检查返回码：失败 → `tui_err` + `return 1`，绝不打印「配置已保存」 | Step 3 代码块 |
| M-1 | Minor | `load_state` 对损坏的状态文件返回非零；用「子 shell 静默探测」区分**语法错误**与**末条命令返回非零** | Step 3 代码块 |
| M-2 / F-16 | Minor | `random_hex` 失败必须返回非零（不能静默返回空串）；openssl 输出非法时退回 `/dev/urandom` | Step 3 代码块 |
| M-3 | Minor（计划侧） | 运行时白名单补 `dirname`（`lib/core.sh` 的 `LIB_DIR` 在用） | Global Constraints |
| M-4 | Minor（计划侧） | `--port` 在 `parse_args` 里就做范围校验（`10#` 前缀），不能只校验交互式输入那条路径 | Task 8 |
| M-5 | Minor（测试强度） | ① 钉住 REALITY_TARGETS 的**全部 7 个**目标（换掉一个原先测不出来）；② 权限位补**行为断言**（`stat -c %a`），真机生效、本机自动跳过 | 新增断言 |
| M-6 | 流程 | 简报只作**派工原件**；一切修订落在**被 git 跟踪的计划**里。本节取代原先的「实施说明」 | 本节 |
| M-7 | Minor | `urlencode` 的 python 分支改用 `sys.stdout.write`（去掉尾换行），两分支 stdout 字节一致 | Step 3 代码块 |
| O-1 | 范围外 → **并入本轮** | `detect_os` 去掉 os-release 里的 CR（CRLF 会让 ID 变成 `debian\r` → 误判非 Debian），并只 source 一次 | Step 3 代码块 |
| O-2 | 范围外 | `lib/core.sh` 文件头注明「**不是自包含**的，需先 source `lib/tui.sh`」 | Step 3 代码块 |
| O-3 | 报告事实错误 | 实施报告称「`save_state` 会剥掉 REMARK 末尾换行」是**错的**（实测往返逐字节一致）——**更正报告，不改代码**，避免后续任务去「修」一个不存在的 bug | 更正报告 |
| O-6 | 范围外 | `detect_os` 的路径参数只接受受信任路径（os-release 是 shell 片段，`.` 引入等价于执行代码） | Step 3 代码块注释 |
| O-7 | 范围外 → **不改** | `lib/tui.sh` 里 9 处同样的 `printf '%%%02X' "'$c"` 惯用法**保持不动**：该写法是普通字符串（双引号里的单引号），并非 bash 的「字符常量」；bash 5.x 实测逐字节正确，而 `lib/tui.sh` 是已闭环评审的产物，为理论风险重开它不划算。记为 deferred minor | 账本 |
| F-18 | 文档 | 设计稿 4.1 的依赖图漏了 `core.sh → tui.sh` 这条边（计划正文的 File Structure 有） | 留到 Task 13 收尾补设计稿 |

#### 新增断言（追加到 `test/unit.sh`）

> 追加在 `test_summary` 之前，作为独立的一组。

```bash
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
```

#### 修复轮的验收标准

1. `lib/core.sh` 与本计划 Task 3 的 **Step 3 代码块逐字节一致**（`diff` 为空）。
2. `test/unit.sh` 含上面「新增断言」的**全部**用例，且 Task 1/2 的 52 条旧断言**一行未删**。
3. `bash test/unit.sh` 全部通过、退出码 0。
4. `lib/tui.sh` **一字未动**（Task 1/2 已评审通过，任何改动都要重开 Task 2）。
5. 红灯证据：把 Step 3 代码块里的 F-10 声明块 / `save_state` 错误处理 / `load_state` 错误处理
   / `random_hex` 返回码分别改回旧写法，对应新增断言必须**逐条变红**。

#### 顺带要求（不改代码，但必须做）

- **更正实施报告**：实施报告称「`save_state` 会剥掉 REMARK 末尾的换行」是**错的** ——
  命令替换只剥 `state_quote` 输出的末尾换行，而输出以 `'` 结尾，什么都没剥；
  save→load 往返实测逐字节一致。请更正 `.superpowers/sdd/.../task-3-report.md`，
  否则后续任务会去「修」一个不存在的 bug。

### 修复轮 2/5（修复轮 1 独立复评 PASS 后追加）—— 本节是**本任务的最终真相**

> 本节由控制器在修复轮 1 的独立复评（结论 **PASS**，限定修复轮 1 范围）之后追加。
> 复评在核对「修复轮 1 是否做对了」之外，顺带指出了 4 处**复评前就存在**的缺陷。
> 它们与修复轮 1 的改动无关，但同样会造成「断言恒真」或「谎报成功」，
> 因此一并在本轮修掉。
>
> **Step 3 的代码块已再次同步为最终权威版本**：`lib/core.sh` 必须与它**逐字节一致**。
> 下面的「新增断言」与 Step 1、修复轮 1 的「新增断言」三者并集，
> 构成 `test/unit.sh` 里 Task 3 的**必须齐备**用例集合。

#### 逐项发现与处置

| 编号 | 类别 | 处置 | 落在哪 |
|---|---|---|---|
| F-2 | **Important** | `save_state` 与 `export_client_artifacts` 的**调用方**忽略返回码：状态没落盘 / 物料没导出，流程却一路走到「部署完成」面板。Task 9 `deploy_wizard` 两处都要 `|| { tui_err ...; return 1; }`（Task 10 `menu_rotate_keys` 的 `save_state` 守卫在修复轮 1 已加；它的 `export_client_artifacts` 守卫由 Task 10 修订补上 —— 本轮复评发现当时只加了前者） | Task 9 代码块 + Task 10 代码块 |
| F-3 | **Important** | `load_state` 用「子 shell 静默探测」做语法检查 → 状态文件被**执行两次**（探测一次、正式读一次），副作用会双发且第一次对调用方不可见。改用 `bash -n`（只解析不执行），并补一条断言证明状态文件**只被执行一次** | Step 3 代码块 + 新增断言 |
| F-4 | Minor | `load_state` 把「读不到」与「格式错」混为一谈：文件存在但不可读（权限问题）也报「格式错误」，把人带偏。改为三态分开报：不存在 / 不可读 / 格式错误 | Step 3 代码块 + 新增断言 |
| F-5 | Minor | M-7 的「python 分支 vs 回退分支」断言在 python3 缺失或**存在但功能异常**（某些系统上 python3 只是个占位存根：`command -v` 找得到、一执行就失败）的机器上**恒真** —— 两侧其实都是回退分支。补「功能可用守卫」+「确定性 mock python3 基准」 | 新增断言 |

#### F-3 为什么必须换实现（加 `|| true` 解决不了）

子 shell 探测的本质是**再执行一遍状态文件**，目的是看它会不会往 stderr 吐东西。
这个副作用是设计固有的：`|| true` 只能盖住退出码，盖不住「被执行了第二次」。
`bash -n` 只做语法分析、不执行任何语句（实测：含 `$(touch x)` 的状态文件
经 `bash -n` 之后副作用未发生），因此是唯一能把「探测」与「执行」分开的做法。

实测记录（开发机 Git Bash，bash 5.x）：

| 输入 | `bash -n` 退出码 | stderr |
|---|---|---|
| `PORT=443` + `if then fi` | 2 | `... syntax error near unexpected token 'then'` |
| `PORT=443` + `false` | 0 | 空 |
| `save_state` 的真实产物 | 0 | 空 |
| 文件不存在 | 127 | `... No such file or directory` |

因此顺序必须是：**先判存在 → 再判可读 → 最后才 `bash -n` 判语法**。
「不存在」时不能拿 `bash -n` 的 127 去当语法错误。

#### F-5 的 mock 基准为什么不是恒真

mock python3 用的是**与 lib/core.sh 回退实现不同的算法**：回退实现靠 bash 的
`${s:i:1}` 取字符再逐个 case，mock 靠 `od -An -tx1` 取字节的十六进制码。
两条独立路径算出同一个串，才说明回退实现的字节级处理（含 `'` → `%27`、
`\` → `%5C`、多字节 UTF-8 逐字节编码）是对的。
若回退实现写错（例如把 `'` 编成 `%39`），两侧立刻不等 → 断言变红。

真实 python3 分支的覆盖由「功能可用守卫」负责：
`python3 -c 'import sys,urllib.parse'` 成功才做真实两分支对比，
否则登记一条说明（**不断言失败** —— python3 是可选依赖，回退分支正是为此存在）。

#### 本机 python3 的状态是【可变的】—— 不要把它写进结论

开发机上 `python3` 曾一度是 Microsoft Store 的占位存根（`command -v python3` 有值，
但执行退出码 49）—— 当时「python 分支从未被执行过」「M-7 断言恒真」是**实测事实**。
后来该占位存根恢复成正常的 Python 3.15.0（`-c`、stdin、`import urllib.parse` 全部可用），
于是「功能可用守卫」会通过、真实两分支对比**真的会执行并通过**。

这说明 F-5 的缺陷本质是**可复现性缺陷**，而不是「在任何机器上恒真」：
断言的有效性取决于运行机器上 python3 是否功能可用 —— 这是**不该依赖的环境状态**。
所以修法必须是「mock 基准（任何机器都有效）+ 功能可用守卫（有效时才比真实分支）」，
而不是指望某台机器上的 python3 恰好可用。

同理，**红灯证据里变体 D2 的预期结果依赖机器状态**，必须如实报告实际结果：

- 机器上 python3 **功能可用** → D2 的 M-7 对比断言**变红**
  （真实分支是对的、回退分支是错的）；
- 机器上 python3 **不可用 / 功能异常** → D2 的 M-7 对比断言**仍然是绿的**
  （两侧其实都是回退分支，一起错、一样对）—— 这就是原断言「恒真」的缺陷本体。

两种情形下**都成立**的事实是：同一个变异体（回退实现 `%27` → `%39`）在
**新的 mock 基准**下必定让 M-7 断言变红 —— 这才是 mock 基准的价值所在。

#### 本轮涉及的断言（三处，全部就地落在修复轮 1 的「新增断言」代码块里）

下列三段就是修复轮 2 之后、修复轮 1「新增断言」代码块里对应片段的**最终形态**。
以修复轮 1 章节里的代码块为准，本节只是把本轮的增量单独列出来，方便逐条核对。

**(a) T3-8 —— `random_hex` 的 openssl 分支（+2 条）**
```bash
# openssl 分支的静默失败必须单独覆盖：旧写法 `openssl ... | tr ...; return 0`
# 的末尾是【显式】return 0，管道退出码取的是 tr 的 → openssl 失败时返回 0
# 但输出为空。测试入口的 pipefail 也救不了它（显式 return 0 直接覆盖管道状态）。
# 只 mock「openssl 不存在」是抓不到这个缺陷的 —— 必须让 have_cmd 说 openssl 存在、
# 而 openssl 本身失败。
out=$( ( have_cmd() { return 0; }; openssl() { return 1; }; od() { return 1; }; random_hex 4 ) 2>&1 ); rc=$?
assert_status 1 "$rc" "random_hex 在 openssl 失败时返回非零（不得静默返回空串）"
assert_eq "" "$out" "random_hex 在 openssl 失败时不输出任何内容"
```

**(b) F-3 —— 状态文件只被执行一次（+2 条，紧接在 M-1 块末尾）**
```bash
  # F-3：load_state 绝不能把状态文件【执行两次】。
  # 旧写法先在子 shell 里 source 一遍做「静默探测」，再正式 source 一遍
  # → 文件里的副作用发生两次（且第一次发生在子 shell 里，调用方看不见）。
  # 计数方式：状态文件里放一条会追加一行的命令，source 一次就多一行。
  printf 'PORT=443\nprintf "x\\n" >> "%s/sidefx"\n' "$bad_dir" > "$bad_dir/sidefx.env"
  out=$( ( STATE_FILE="$bad_dir/sidefx.env"; load_state ) 2>&1 ); rc=$?
  assert_status 0 "$rc" "load_state 对带副作用的合法状态文件仍视为可读"
  assert_eq "1" "$(wc -l < "$bad_dir/sidefx" 2>/dev/null | tr -d ' ')" \
    "load_state 只把状态文件执行一次（不得用子 shell 探测导致双执行）"
```

**(c) F-4 —— 「读不到」与「格式错」分开报（+2 条）**
```bash
  # 「读不到」与「格式错」必须分开报：不可读是权限问题，提示去改格式会把人带偏。
  out=$( ( STATE_FILE="$bad_dir/absent.env"; load_state ) 2>&1 ); rc=$?
  assert_status 1 "$rc" "load_state 对不存在的状态文件返回非零（读不到 ≠ 格式错）"
  assert_contains "$out" "状态文件不存在" \
    "load_state 对读不到的状态文件报『不存在』而不是笼统失败"
```

**(d) F-5 —— M-7 块整体替换（3 条 → 4 条）**
```bash
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
```

#### 修复轮 2 的独立复评结论（PASS，限定范围）

独立复评（新的评审者，只读核对）结论：**PASS（限定范围）**，未发现阻塞项。
限定范围：Debian 真机端到端未验（计划已声明）；F-4 的「不可读」态在本平台不可达
（已补条件断言，在 Debian / CI 非 root 下会真正执行）；F-2 需带入 Task 9 / Task 10。

复评自己做的关键实验（比控制器更严格，做了控制器没做的「坏 python3 存根模拟」）：

| 探针 | 环境 | 结果 |
|---|---|---|
| E0 | 坏 python3 存根，未变异，mock 基准 | 156 全绿 ✓ |
| E1 | 坏 python3 存根 + `%27`→`%39` + **旧基准**（真实分支） | M-7 的对比断言**仍然绿** → **恒真缺陷的直接实证** |
| E2 | 坏 python3 存根 + `%27`→`%39` + **新基准**（mock） | M-7 的对比断言**变红** → 新基准有判别力 |

E1/E2 是本轮最关键的证据：**同一个变异体，在旧基准下恒绿、在新基准下变红**。

复评的 7 条非阻塞发现及其处置：

| # | 位置 | 处置 |
|---|---|---|
| 1 | 计划 Task 13 README 第 2 条把「本机 python3 状态」写成事实，与同提交新增的「状态是可变的」自相矛盾 | 已改：改成写「两层覆盖（mock 基准层 / 真实分支层）」，不把任何机器的现状写成事实 |
| 2 | 计划验收标准第 5 条写「删掉分支 → 两条断言变红」，实测只 1 条 | 已改：写明只 1 条并解释原因（`bash -n` 对不存在文件返回 127 → 落到「格式错误」分支 → 仍 `return 1`） |
| 3 | 报告 §3 表格的「计划预期」列把变体 B 写成「1 条变红」，与计划原文「两条」不符，报告未提这个分歧 | 交实施者更正报告 |
| 4 | 报告未记录**控制器**在计划侧做的更正提交（`98344cf`），提交清单止于 `d5609bd` | 交实施者更正报告 |
| 5 | F-4 第三态「不可读」无断言覆盖；本平台不可达（MSYS `chmod 000` → mode 444 且仍可读） | 已补条件断言（真机上真正执行）+ 断言条数说明精确化 |
| 6 | 计划 F-2 表格行「Task 10 menu_rotate_keys 在修复轮 1 已加」表述过宽 | 已改准确表述；Task 10 的 `export_client_artifacts` 守卫由 Task 10 修订补上 |
| 7 | 报告 §9「复现方式」仍写「期望：全部通过：130 项断言」 | 交实施者更正报告 |

复评另确认了 `lib/tui.sh` 的两处时间窗口（`tui.sh:497` 的 `read -rsn2 -t 0.2`、
`tui.sh:531` 的 `read -rsn1 -t 0.35`）**确实是**那次偶发「失败 1 项」的机制：
注入超过窗口的延迟后，对应断言会由绿变红。复评独立压测 **64 次（40 顺序 + 24 并发负载）
0 失败**，实施者压测 325+ 次也未复现。判定：**不构成本轮阻塞项**
（两处都在 Task 1/2 范围、Task 3 无一条断言依赖时序），
但对 Task 12 的 CI 是真实的易抖性风险 —— 已在账本记为 Task 12 的待评估项。

#### 修复轮 2 的验收标准

1. `lib/core.sh` 与本计划 Task 3 的 **Step 3 代码块逐字节一致**（`diff` 为空）。
2. `test/unit.sh` 含 Step 1 + 修复轮 1 + 修复轮 2 三处「新增断言」的**全部**用例，
   且 Task 1/2 的 52 条旧断言**一行未删**。
3. `bash test/unit.sh` 全部通过、退出码 0；断言总数由 149 增至 **156**
   （T3-8 +2、F-3 +2、F-4 +2、F-5 的 M-7 块 3 → 4 条即 +1）。
   **注意 156 是「本机实测值」**：其中 4 条是**权限相关行为断言**
   （状态文件 600 / 状态目录 700 / 「不可读」态 2 条），在 Windows + MSYS 上
   会被**自动跳过**（MSYS 的 chmod 是模拟的，且 root/Windows 上文件恒可读）；
   在 Debian / CI（以非 root 运行）上它们会真正执行，届时总数为 **160**。
   所以「断言总数」在不同平台本就不同 —— 报告里要写明是哪个平台的数字。
4. `lib/tui.sh` **一字未动**。
5. 红灯证据（至少给出这五条）：
   - 把 `load_state` 的 `bash -n` 换回子 shell 探测 → F-3 的「只执行一次」断言变红
     （副作用计数从 1 变成 2）；
   - 把 `load_state` 的「不存在 / 不可读」分支去掉 → **只有 1 条断言变红**
     （F-4 的「报『不存在』」那条），**不是 2 条**：删掉分支后流程落到
     `bash -n`，而 `bash -n` 对不存在的文件返回 127 且 stderr 非空 →
     走「格式错误」分支 → 仍然 `return 1` → 「返回非零」那条**依然是绿的**。
     （本条是复评实测出来的，原先计划写「两条变红」是事实错误。）
   - 把 `load_state` 换回旧写法（`[[ -f ]] || return 1` + 静默探测）→
     F-4 的「状态文件不存在」提示断言变红；
   - 把 `lib/core.sh` 回退实现里的 `out+='%27'` 改成 `out+='%39'`（即把回退实现弄错）
     → M-7 的 mock 基准断言必须变红（mock 用的是**独立算法**，抓得住回退实现的错）；
   - **恒真性反证**：同一个变异体（回退实现弄错）+ 把 M-7 的基准换回「真实 python 分支」。
     预期**取决于运行机器上 python3 是否功能可用**，必须如实报告实际结果：
     - python3 **功能可用** → M-7 那条对比断言**变红**（真实分支对、回退分支错）；
     - python3 **不可用 / 功能异常** → M-7 那条对比断言**仍然是绿的**
       （两侧其实都是回退分支，一起错、一样对）—— 这就是原断言「恒真」的缺陷本体。
     两种情形下都成立的是：同一个变异体在**新的 mock 基准**下必定让 M-7 断言变红。
     （同一变异下，「urlencode 编码单引号」等**直接的值断言**无论机器状态如何都照样变红。）
6. **更正实施报告**：`task-3-report.md` 的 §4「分项计数」少 1 条，
   按本节「修复轮 2 的验收标准」第 3 条的实际条数更正，并把本轮 4 项发现
   与对应处置补进报告的变更清单。

---

## Task 4: core.sh 网络探测

**Files:**
- Modify: `lib/core.sh`（追加网络探测函数）
- Modify: `test/unit.sh`

**Interfaces:**
- Consumes: Task 3 的 `have_cmd` `trim`
- Produces:
  - `is_valid_ip <str>` → `0`=像样的对外地址 / `1`=不是
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

追加到 `test/unit.sh` 的 `test_summary` **之前**（`test_summary` 必须是文件最后一行 —— 见全局约束）：

```bash
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
# 判定一个字符串是不是可用的对外地址。
# 存在的理由：旧的判定 `^[0-9a-fA-F:]+$` 太宽 —— HTTP 状态码响应体
# （代理/网关常返回 "404" / "403" / "200" 当正文）和 "cafebabe" / "12345"
# 这类纯十六进制串都会被当成 IP → 写进分享链接与配置后客户端必然连不上，
# 而用户完全看不出是「探测错了」而不是「服务没起来」。
is_valid_ip() {
  local ip="$1" o
  # IPv4：4 段十进制，每段 0-255
  if [[ "$ip" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]]; then
    for o in "${BASH_REMATCH[@]:1:4}"; do
      # 必须用 10# 前缀：裸算术会把 "08" 当八进制，直接报「value too great for base」。
      if (( 10#$o > 255 )); then return 1; fi
    done
    return 0
  fi
  # IPv6：必须含 ':'（否则 "404" 这类纯数字/纯十六进制串会被误收）。
  # 还必须是像样的 IPv6 形态：含 "::" 压缩写法，或至少 3 段十六进制组 ——
  # 否则 "dead:beef" / "cafe:babe" 这类只有两段的串会被误收成 IP。
  if [[ "$ip" == *"::"* ]]; then
    [[ "$ip" =~ ^[0-9a-fA-F:]+$ ]] && return 0
    return 1
  fi
  if [[ "$ip" =~ ^([0-9a-fA-F]{1,4}:){2,7}[0-9a-fA-F]{1,4}$ ]]; then
    return 0
  fi
  return 1
}

detect_public_ip() {
  local ip u
  # 候选源说明：
  #   · 故意【不】用 https://myip.ipip.net —— 它返回中文正文
  #     （「当前 IP：1.2.3.4 来自于：中国」），is_valid_ip 永远不可能接受 →
  #     该源【永远失败】，而且排在最后，只在前面全失败时才白等一次超时。
  #   · --max-time 取 5 秒：4 个源最坏合计 20 秒（旧的 5 源 × 8 秒 = 40 秒，
  #     在无网环境下预检会静默卡住近一分钟）。
  local urls=(
    'https://api.ipify.org'
    'https://ifconfig.me/ip'
    'https://icanhazip.com'
    'https://ipinfo.io/ip'
  )
  for u in "${urls[@]}"; do
    # tr -d '[:space:]' 是【承重逻辑】：真实 IP 服务返回的正文都带尾随 "\n"，
    # 而 bash 的 =~ 锚点不匹配尾随换行 → 不剥掉就一定判不出 IP。
    ip=$(curl -fsS --max-time 5 "$u" 2>/dev/null | tr -d '[:space:]')
    if is_valid_ip "$ip"; then
      printf '%s' "$ip"; return 0
    fi
  done
  return 1
}

detect_local_ip() {
  local ip
  ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')
  [[ -z "$ip" ]] && ip=$(hostname -I 2>/dev/null | awk '{print $1}')
  # 两个来源都没给出地址 → 必须返回非零：rc=0 却输出空串会让调用方
  # 分不清「探测到了空地址」和「探测成功」。
  if [[ -z "$ip" ]]; then
    tui_err "无法探测本机地址（ip 与 hostname 都不可用）"
    return 1
  fi
  printf '%s' "$ip"
}

port_in_use() {
  local port="$1" rows
  if have_cmd ss; then
    # 先把整段输出【收进变量】再匹配，不能写成 `ss | awk | grep -q`：
    # 管道里 grep -q 命中即退出 → 上游 awk 收到 SIGPIPE（141）→
    # 在 set -o pipefail 下整条管道的退出码变成 141 → `&& return 0` 不成立 →
    # 一个【已占用】的端口被误判成【空闲】→ 向导选了这个端口 →
    # 部署到一半才报 "address in use"，且错误信息与真实原因无关。
    # 改成「先收进变量、再对变量 grep」后，grep 读的是 here-string（临时文件），
    # 整条链路上没有任何会早退的管道 → 不可能有 SIGPIPE。
    #
    # 仍必须按【字段】精确匹配，不能对整行 grep ":$port"：
    # ":8080" 这个字符串里就含 ":80" → 全行 grep 会把 8080 误判成 80 已被占用，
    # 于是向导会以为端口 80 被占而改选别的端口。NR>1 跳过 ss 的表头行。
    rows=$(ss -ltn "sport = :$port" 2>/dev/null | awk 'NR>1{print $4}')
    [[ -n "$rows" ]] || return 1
    grep -qE "[:.]$port\$" <<<"$rows" && return 0
    return 1
  fi
  if have_cmd netstat; then
    # netstat 的输出【不受端口过滤】，行数可能很大 → 同样不能把 grep -q 接在管道上。
    rows=$(netstat -ltn 2>/dev/null | awk '{print $4}')
    [[ -n "$rows" ]] || return 1
    grep -qE "[:.]$port\$" <<<"$rows" && return 0
    return 1
  fi
  return 1
}

port_occupant() {
  local port="$1" rows
  if have_cmd ss; then
    # 用纯 bash 取首行，不用 `| head -1`：head 命中即退出会让上游 awk 收到
    # SIGPIPE（141）。原写法其实【输出是对的】（head 先读走第一行才退出，
    # 且函数末尾显式 return 0 覆盖了管道状态），改成纯 bash 后不再有任何管道，
    # 行为不变但不再依赖那个时序。
    rows=$(ss -ltnp "sport = :$port" 2>/dev/null | awk 'NR>1{print $NF}')
    rows="${rows%%$'\n'*}"
    printf '%s' "$rows"
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
  # 用 `: >` 而不是 touch：touch 不在运行时白名单里，而 `: >` 是 shell 重定向，
  # 不调用任何外部命令（效果等同「创建或清空该文件」）。
  : > /var/lib/vless-reality/apt-updated
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

> **注**：Task 3 的 Step 3 代码块是 `lib/core.sh` 的 **Task 3 部分**。
> 本任务在其**末尾追加**网络探测函数；追加之后，整份 `lib/core.sh` 不再与
> Task 3 的代码块逐字节相同（Task 3 修复轮的「diff 为空」验收只在 Task 3 期间有效）。

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

#### 修订轮 1 的逐项发现与处置

> 本节由**控制器**在派发 Task 4 实施者**之前**写入，依据是控制器自己跑的探针实验
> （见下方「证据」），不是推测。计划 = 真相：上面 Step 1 / Step 3 两处代码块
> 已是修订后的**权威终版**，实施者必须逐字照抄。

| # | 级别 | 发现 | 处置 |
|---|---|---|---|
| F4-1 | **Important** | `port_in_use` 把 `grep -q` 直接接在管道上（`ss \| awk \| grep -q`）。`grep -q` 命中即退出 → 上游 `awk` 收到 SIGPIPE（141）→ 在 `set -o pipefail` 下整条管道的退出码变成 141 → `&& return 0` 不成立 → **已占用**的端口被误判成**空闲** | 改成「先把整段输出收进 `rows` 变量，再对变量 grep」（`<<<` 是 here-string，不是管道）→ 链路上没有任何会早退的管道 → 不可能有 SIGPIPE |
| F4-2 | **Important** | `detect_public_ip` 的判定 `^[0-9a-fA-F:]+$` 太宽：HTTP 状态码响应体（`"404"` / `"403"` / `"200"`）与 `"cafebabe"` / `"12345"` 都会被当成 IP → 写进分享链接后客户端必然连不上，且用户完全看不出是「探测错了」 | 新增 `is_valid_ip`：IPv4 必须是 4 段十进制且每段 ≤255；IPv6 必须含 `':'`。`detect_public_ip` 改用它 |
| F4-3 | **Minor** | `port_occupant` 用 `\| head -1` 取首行。**原写法其实输出是对的**（`head` 先读走第一行才退出，且函数末尾显式 `return 0` 覆盖了管道状态），但它依赖那个时序 | 改成纯 bash 取首行（`rows="${rows%%$'\n'*}"`），行为不变但不再有任何管道 |
| F4-4 | **Minor** | Task 4 完全没有 `detect_public_ip` 的断言 —— 它只在真实网络下工作，没法验证 | 补 mock `curl` 的确定性断言（`"404"` → 返回非零且无输出；`"1.2.3.4"` / `"2001:db8::1"` → 正确输出） |
| F4-5 | **Important** | 计划只说「追加到 `test/unit.sh`」，**没说追加到哪个位置**。追加在 `test_summary` 之后 → 摘要条数偏小，而且**用例失败时脚本退出码仍是 0**（`test_summary` 已先返回过 0，失败被吞掉）→ CI 绿灯放行红灯 | 已在**全局约束**里写死「所有任务的测试用例都必须追加在 `test_summary` 之前」，并改写 Task 4 Step 1 的措辞 |
| F4-6 | **Minor** | Task 3 的**宽版**「越权函数」静态断言必须被 Task 4 的收窄版**替换**而不是并存 —— 计划正文已有说明，但没说「旧的这两行要删掉」 | 验收标准里写明：旧的 `offenders=` 与 `assert_eq` 两行**必须删掉**（实测：并存时旧的宽断言把 Task 4 的 10 个函数全当成越权 → 红灯） |

#### 修订轮 1 的证据（控制器自己跑的探针，不是推测）

| 探针 | 内容 | 结果 |
|---|---|---|
| P1 | `set -o pipefail` 下 `2000 行 \| grep -q`（grep 命中即退） | **rc=141**（SIGPIPE）→ 证实「管道 + `grep -q`」会把 141 带进退出码 |
| P2 | 同上但只有 1-2 行 | rc=0 → 解释为什么**测试里的 mock 场景测不出来**（mock 只有 1 行数据） |
| P3 | `netstat -ltn` 形态的 120 行输出 | rc=0 → netstat 路径要 >4000 行才稳定触发（低概率但真实） |
| P4 | 旧 IP 判定的正误表 | `"404"` / `"403"` / `"200"` / `"302"` / `"12345"` / `"cafebabe"` **全部被判为 IP**；`"1.2.3.4"` / `"::1"` 判对 |
| P5 | 旧写法 vs 修好后写法，在 2 行与 120 行输出下的判定 | 旧写法在 120 行时结论正确（靠运气），修好后**永远**正确 |

#### 修订轮 2 的逐项发现与处置

> 本节由**控制器**在 Task 4 实施完成（提交 `e2759ae`）、独立复评之后写入。
> 计划 = 真相：上面 Step 1 / Step 3 两个代码块是修订后的**权威终版**，
> 实施者必须逐字照抄。
> 复评结论：**PASS（限定范围）** —— 实施本身忠实且正确，**0 条实施阻塞项**；
> 本节列的都是**计划缺陷**，责任方是控制器。

| # | 级别 | 发现 | 处置 |
|---|---|---|---|
| F4-7 | **Important** | 修订轮 1 的验收标准第 6 条第 2 小项**写错了**：它写「把 `is_valid_ip` 的 IPv6 分支去掉 → `detect_public_ip 面对非 IP 响应体（HTTP 状态码 404）必须返回非零` 必须变红」。**这是假的** —— 去掉一个分支只会让判定**更严格**（少收一类地址），「404」照样被拒，那条断言**仍然是绿的**。实测（控制器与复评各自独立做）：去掉 IPv6 分支 → 3 条 IPv6 断言变红、「404」断言仍绿；要让「404」断言变红，必须把 `detect_public_ip` 换回旧的宽松正则 → 4 条变红 | 改正验收标准第 6 条第 2 小项。**责任方是计划，不是实施** —— Step 1 / Step 3 的代码块本身没问题 |
| F4-8 | **Important** | TLS 1.3 那条断言有两个问题：① 网络守卫 `curl -fsS --max-time 5 https://www.microsoft.com` 失败时**整条静默跳过** → 条数在 **183/184** 之间振荡（实施者实测 6 次里 2 次是 183，控制器与复评各复现一次）→ CI 里写死条数必然 flake；② 它**测的是环境而不是实现** —— 复评的 M10 把 `target_supports_tls13` 整个换成 `return 0`，**0 条变红** | ① mock 掉 `have_cmd` / `timeout` / `openssl` 补**两条确定性断言**（正反两向）；② 真实网络那条的 else 分支**登记一条「已跳过」说明** → 条数恒定且有判别力 |
| F4-9 | **Minor** | `apt update` 那条断言的守卫 `if [[ ! -f /var/lib/vless-reality/apt-updated ]]` —— 真实 Debian 上跑过一次 apt update 后标记文件就在了 → 这条断言**整条消失** → 条数随机器状态变 | else 分支登记一条「已跳过（用例前提不成立）」说明 |
| F4-10 | **Important** | 控制器全计划扫描发现：**57 条断言**落在条件块内，其中若干条**没有 else 侧说明** → 断言总数随机器 / 网络 / 依赖是否可用而漂移。这不只影响 Task 4：Task 5（python3 JSON 校验 8 条）、Task 7（python3 JSON 校验 1 条）同样中招 | ① 已在**全局约束**里立规矩：条件块里的断言必须配 else 侧说明断言；② 本轮把 Task 5 / Task 7 的两处 python3 守卫一并补上。**故意**随平台变化的只有权限相关行为断言（chmod 在 MSYS 上是模拟的）—— 这类属于「本平台无法验证」而非缺陷，不补 else 说明，代价是条数分平台不同，报告必须写明平台 |
| F4-11 | **Important** | `detect_public_ip` 里的 `tr -d '[:space:]'` 是**承重逻辑却零测试覆盖**：复评的 M14 删掉它 → **0 条变红、184 全绿**。但真实 IP 服务（ipify / ifconfig.me / icanhazip / ipinfo）返回的正文都带尾随 `\n`，而 bash 的 `=~` 锚点**不匹配**尾随换行 → 删掉 `tr` 就会在**任何真实网络下**探测失败 → 工具静默退化成内网 IP → 分享链接里的主机名是内网地址 → 客户端连不上，**而断言全绿**。根因：原 mock 全用 `printf '1.2.3.4'`（**无尾随空白**），`tr` 从未被真正约束 | mock 改成**带尾随换行**的形态（`printf '1.2.3.4\n'` 等），并加一条「带前后空白」的断言把 `tr` 的行为钉死。此时删掉 `tr` → 「detect_public_ip 输出正确的公网 IPv4」变红 |
| F4-12 | **Minor** | 计划 Interfaces 声明交付 11 个函数，Step 1 只测了 7 个。**完全没有断言**的有 `detect_local_ip`、`random_free_port`、`ensure_packages`、`service_run_user` —— 而它们恰好就是返回码语义异常的那几个（空输出 rc=0、未校验的硬编码兜底、恒返回 0）。**一旦回归，没有任何断言会红** | 补 4 组 mock 断言（各 2 条）：`detect_local_ip` 的 ip 路径 / hostname 回退 / 两者都失败时必须返回非零；`random_free_port` 的输出区间；`ensure_packages` 在 apt update 失败时必须中止且**不得**继续调用 apt-get install（用文件跨子 shell 记录调用）；`service_run_user` 的读取与 root 回退 |
| F4-13 | **Minor** | `detect_public_ip` 最坏耗时 **40 秒**（5 源 × `--max-time 8`）且**毫无输出**地卡住 —— Task 8 的预检是同步调用，TUI 看起来像死机。而且 `https://myip.ipip.net` 返回中文正文（「当前 IP：1.2.3.4 来自于：中国」）→ `is_valid_ip` 永远不可能接受 → **该源永远失败**，且排在最后，只在前面全失败时才白等一次超时 | 删掉这个死源，`--max-time` 从 8 降到 5 → 最坏 20 秒 |
| F4-14 | **Minor** | `is_valid_ip` 的 IPv6 分支只要求「含冒号 + 全是十六进制字符」→ `dead:beef` / `cafe:babe` 这类**只有两段、且没有 `::` 压缩写法**的串会被误收。复评的 M16（把该分支放宽成「只要求含冒号」）→ **0 条变红**，说明这条约束没有被任何断言钉住 | IPv6 分支收紧为：含 `::` 压缩写法，或至少 3 段十六进制组；并补两条「拒绝 dead:beef / cafe:babe」+ 一条「接受完整写法的 IPv6」的断言 |

#### 复评指出的、**本轮不改**的实现细节（观察，代价低）

| 变异 | 后果 | 为什么不改 |
|---|---|---|
| 删 `awk 'NR>1{print $4}'` 的 `NR>1`（不再跳表头） | 无害 —— 表头第 4 字段是 `Local`，永远匹配不上 `[:.]port$` | 无实际后果，不值得为它加断言 |
| 删掉 `netstat` 回退分支 | 无害（Debian 12 默认有 `ss`） | 同上 |
| `: > /var/lib/vless-reality/apt-updated` 改成 `:` | 标记文件不再生成 → 每次都重跑 apt update（慢但不出错） | 已在 Task 6 修订项里一并处理 |

#### 实施者报出的返回码语义问题（控制器已独立验证）

| 问题 | 控制器的独立判断 | 处置 |
|---|---|---|
| `port_in_use` 分不清「探测失败」与「端口空闲」（两者都 rc=1） | **不是静默成功**：探测失败 → 向导以为端口空闲 → 部署走到 systemd 阶段 xray 绑不上 → `setup_systemd` 会 `tui_err "xray 服务未能启动，最近日志如下："` 并输出 `journalctl -u xray -n 30`（含 xray 原始的 address already in use）→ `do_deploy` 中止 → 失败是**响亮**的，只是用户要先走完装内核 / 生成密钥 / 写配置才失败，且首句错误是「systemd 配置失败」而非真正原因 | 记为 **Task 9 修订项**（Minor）：向导在端口探测不可用时提示「无法确认端口是否空闲」 |
| `random_free_port` 的硬编码兜底 44321 没有校验 | 40 次随机全占用的概率极低；兜底端口未验证 → 可能又是占用 | 记为 **Task 9 修订项**（Minor）：兜底端口也要过一次 `port_in_use` |
| `apt_update_once` 没检查 `mkdir -p` 与 `: >` | 失败 → 标记文件没建 → 下次重跑 apt update（幂等、无害），但**原始 bash 报错直接漏到 stderr**、用户看不到明确提示 | 记为 **Task 6 修订项** |
| `port_occupant` 恒返回 0 | 描述由 stdout 承载，接口设计如此；调用方 `occ=$(port_occupant "$PORT")` 只用于拼提示语 → 行为正确 | 不改 |

#### 复评指出的「全局约束字面张力」（留给 Task 9 / Task 12 收口）

全局约束写的是「所有失败路径必须以非零退出码结束，且经 `tui_err` 输出」，
但本任务几个**探测类**函数的契约与之不完全一致：
`detect_public_ip`（rc=1 但不经过 `tui_err`）、`port_occupant`（恒 rc=0）。
探测函数的「探测失败」本身往往是合法答案（例如「这个目标不支持 TLS 1.3」）
→ 不是缺陷，而是**契约分层**问题。
→ 记为 **Task 9 / Task 12 的收口项**：把「探测类函数」与「部署流程类函数」的
失败语义在计划里明确分层，别让后来的实施者自己猜。

#### 修订轮 2 的验收标准

1. `lib/core.sh` 的 Task 4 段与上面 **Step 3 代码块逐字节一致**（本轮**改** `lib/core.sh`：
   IPv6 收紧、删死源、`--max-time` 5、`detect_local_ip` 失败返回非零）。
2. `test/unit.sh` 里 Task 4 的插入段必须被**替换**成修订后的 Step 1 代码块
   （**不是**追加 —— 追加会让两套用例并存、条数翻倍）。
3. `bash test/unit.sh` 全部通过、退出码 0。
   断言总数 **197**（本机 = Windows + MSYS）／**201**（Debian / CI，以非 root 运行）。
   报告里必须写明是哪个平台的数字。
4. **条数必须恒定**：网络抖动、python3 是否可用、apt 标记文件是否存在，
   都**不得**改变摘要里的条数。连跑 4 次，条数必须每次都是 197。
   （新块里有 5 条断言位于「条件不成立」的那一侧，但它们与条件成立那一侧
   是【1 换 1】的配对 → 无论走哪边，总数都不变。）
5. `lib/tui.sh`、`test/lib.sh` **一字未动**。
6. 红灯证据（至少这四条）：
   - 删掉 `detect_public_ip` 里的 `tr -d '[:space:]'` → 「detect_public_ip **会剥掉响应里的
     空白与换行**（真实 IP 服务都带尾随换行）」必须变红。
     注意：不是「detect_public_ip 输出正确的公网 IPv4」—— 那条在删掉 `tr` 后**仍然绿**：
     命令替换 `$(...)` 本身就会剥掉尾部的 `\n`，所以对 mock `printf '1.2.3.4\n'` 来说
     `tr` 没有作用；`tr` 真正承重的是**尾部空格与 CR**（控制器与实施者各自实测）；
   - 把 `target_supports_tls13` 里的 grep 模式改坏 → 「target_supports_tls13
     识别出 TLS 1.3 的握手输出」必须变红；
   - 把 `detect_local_ip` 的「失败返回非零」改回「rc=0 + 空输出」→
     「detect_local_ip 在 ip 与 hostname 都不可用时必须返回非零」必须变红；
   - 把 `ensure_packages` 的 `apt_update_once || return 1` 改成 `apt_update_once || true` →
     「ensure_packages 在 apt update 失败时必须返回非零」与
     「…不得继续调用 apt-get install」**两条**必须变红。
     ⚠️ 这两条要求 **F4-15 已修** —— 修之前第二条恒绿（mock 写的是空文件），
     变异后只可能红 1 条。
7. **计划文件实施者一个字都不许改** —— 计划修订是控制器的职责。

#### 修订轮 3 的逐项发现与处置

> 本节由**控制器**在 Task 4 修订轮 2 实施完成（提交 `3f51e8d`）、控制器独立复核之后写入。
> 修订轮 2 的代码块本身是对的 —— 本节修的是**验收标准**与**一条恒真断言**。

| # | 级别 | 发现 | 处置 |
|---|---|---|---|
| F4-15 | **Important** | Step 1 里 `ensure_packages` 那组的 mock 写的是 `tui_run() { : >"$called_file"; return 0; }` —— `: >file` **只创建空文件**（size 0），而判定用的是 `[[ -s "$called_file" ]]`（size > 0）→ 空文件恒为假 → 「ensure_packages 在 apt update 失败时**不得继续调用 apt-get install**」这条断言**永远绿、永远不可能变红**。这不是「实现有 bug」——实现是对的（`apt_update_once || return 1` 确实中止了）——而是**这条断言没有判别力** | mock 改成 `printf called >"$called_file"`（写 1 字节）。控制器与实施者**各自独立**实证：修之前把 `ensure_packages` 变异成 `|| true` 只红 1 条，修之后红 2 条 |
| F4-16 | **Important** | 修订轮 2 的验收标准第 6 条第 1 小项写的是「删掉 `tr -d '[:space:]'` → 「detect_public_ip 输出正确的公网 IPv4」必须变红」。**这条是错的**：命令替换 `$(...)` 本身就会剥掉尾部的 `\n`，所以对 mock `printf '1.2.3.4\n'` 而言 `tr` 没有作用 → 删掉 `tr` 后那条断言**仍然绿**。真正变红的是「detect_public_ip **会剥掉响应里的空白与换行**」—— `tr` 承重的是**尾部空格与 CR** | 验收标准第 6 条第 1 小项改成点名「会剥掉响应里的空白与换行」，并写明「输出正确的公网 IPv4」在删 `tr` 后仍绿的原因 |

> **控制器的自我记账**：修订轮 2 的沙箱预演当时就报出了「ensure_packages 不再中止 → **1 条**」，
> 而当时的验收标准写的是「**两条**必须变红」—— **这个矛盾当时就在眼前，控制器没有当场拦住**，
> 把它当成「预演通过」放过去了。实施者本轮独立复现时才发现。
> 教训：**验收标准里写死的条数必须与预演结果逐条对照**，对不上就是计划缺陷，
> 不能当成「预演失败就改预演」或「标准写错了但无所谓」。

#### 修订轮 3 的验收标准

1. `lib/core.sh` 与 `test/unit.sh` 里除下面那一行 mock 之外**一字不变**。
2. `bash test/unit.sh` 全部通过、退出码 0；断言总数仍是 **197**（本机 = Windows + MSYS）、
   **201**（Debian / CI，以非 root 运行）。报告里必须写明是哪个平台的数字。
3. 连跑 4 次，条数必须每次都是 197。
4. 红灯证据：`apt_update_once || return 1` → `|| true` 必须让**两条**断言变红
   （「ensure_packages 在 apt update 失败时必须返回非零」与
   「…不得继续调用 apt-get install」）。**这是本轮唯一要证明的事**。
5. `lib/tui.sh`、`test/lib.sh` **一字未动**。
6. 计划文件实施者一个字都不许改。

#### 修订轮 1 的验收标准

1. `lib/core.sh` 末尾追加的网络探测部分与上面 **Step 3 代码块逐字节一致**。
2. `test/unit.sh` 含上面 **Step 1 代码块的全部用例**（29 条断言），
   且 Task 1/2/3 现有的 156 条旧断言**一条未删** ——
   **唯一的例外**是 Task 3 那两条「越权函数」断言（`offenders=` 与配套的 `assert_eq`）：
   它们必须被 Task 4 的收窄版**替换掉**（删掉旧的这两行），不是并存。
3. 新用例必须插在 `test/unit.sh` 的 `test_summary` **之前**（`test_summary` 保持最后一行）。
4. `bash test/unit.sh` 全部通过、退出码 0。
   断言总数由 156 变为 **197**（基线 155 + 新块本机实际执行 42 条 = 197）。
   **197 是「本机实测值」**（Windows + MSYS）：那 4 条权限相关行为断言在本机被自动跳过，
   在 Debian / CI（以非 root 运行）上会真正执行，届时总数为 **201**。
   报告里要写明是哪个平台的数字。
   **条数必须恒定**：网络抖动、python3 是否可用、apt 标记文件是否存在，
   都**不得**改变摘要里的条数（见修订轮 2 的 F4-8）。
5. `lib/tui.sh`、`test/lib.sh` **一字未动**。
6. 红灯证据（至少给出这四条）：
   - 把 `port_in_use` 改回 `... \| awk \| grep -q` → **F4-1 的静态断言必须变红**
     （这是权威判据）；大输出那条**辅助**断言**可能**变红（时序相关），
     必须如实报告实际结果，不许把「可能」写成「一定」；
   - 把 `is_valid_ip` 的 IPv6 分支去掉 → **3 条 IPv6 断言**必须变红
     （`is_valid_ip 接受 IPv6 形态`、`detect_public_ip 遇到 IPv6 时返回 0`、
     `detect_public_ip 输出正确的 IPv6`）；
     **注意**：「detect_public_ip 面对非 IP 响应体（HTTP 状态码 404）必须返回非零」
     在这个变异下**仍然是绿的** —— 去掉一个分支只会让判定【更严格】。
     要让那条断言变红，必须把 `detect_public_ip` 换回旧的宽松正则
     （`if [[ "$ip" =~ ^[0-9a-fA-F:]+$ ]]`），此时会红 4 条；
   - 删掉 `detect_public_ip` 里的 `tr -d '[:space:]'` → 「detect_public_ip 输出正确的
     公网 IPv4」必须变红（真实 IP 服务都带尾随换行，而 bash 的 =~ 不匹配尾随换行）；
   - 把 `target_supports_tls13` 里的 grep 模式改坏 → 「target_supports_tls13
     识别出 TLS 1.3 的握手输出」必须变红；
   - 把 `is_valid_ip` 的 IPv4 段数检查去掉 → `is_valid_ip 拒绝五段 IPv4` 必须变红；
   - 把 `is_valid_ip` 的 `10#$o > 255` 去掉 → `is_valid_ip 拒绝每段都大于 255 的伪 IPv4`
     必须变红。
7. **计划文件实施者一个字都不许改** —— 计划修订是控制器的职责。

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
  - `render_server_config <outfile> <uuid> <priv> <sni> <port> <shortid>` → 把配置写到**调用方指定的路径**（实践中是暂存路径）并 chmod 600；**它不做 xray 校验** —— 校验与落位到正式路径由 `write_config_atomic` 负责；入参不合法时返回 `1` 且**不落盘**
  - `xray_test_config <cfgfile>` → `0`/`1`
  - `write_config_atomic <outfile> <srcfile>` → 复制到临时文件 → `xray run -test` 校验 → 原子替换；**写服务端配置的唯一入口**

#### 修订轮 1 的逐项发现与处置

> 本节由**控制器**在 Task 5 派发前预扫（沙箱实证）之后写入。
> 本节列的全是**计划缺陷**，责任方是控制器；Task 5 的代码块本身还没被实施过。

| # | 级别 | 发现 | 处置 |
|---|---|---|---|
| T5-1 | **Important** | `write_config_atomic` 的「**xray 校验失败**」路径**完全没被测到**：Step 1 传给它的源文件是**字面量** `'{"broken":'`，而函数第一步就是 `[[ -f "$src" ]] || return 1` → 直接把它挡在门外 → 后面那三条断言全是**恒真**。控制器 P1 实证：把「校验失败」分支改成【直接破坏目标文件】，**202 项断言仍然全绿、0 条红** | Step 1 改成先 `printf '{"broken":\n' > "$atomic_dir/broken.json"` 再传**路径**；并补一条「源文件不存在时**不得覆盖目标文件**」（原来只有「返回非零」，实现若写成「先覆盖再校验」仍会漏） |
| T5-2 | **Important** | `gen_keys` **一条断言都没有**。控制器 P3 实证：把 `gen_keys` 整个换成 `return 0`，**202 项全绿、0 条红**。而它恰好是「把 xray 的输出变成配置」的关键环节 | Step 1 补假 xray（用 **shell 函数**实现而不是「造脚本 + chmod +x」—— MSYS 的 chmod 位不可靠）+ 4 组断言：成功路径一次设置 4 个全局变量、x25519 失败、输出无法解析、`random_hex` 失败 |
| T5-3 | **Important** | `xray_test_config` **一条断言都没有**。控制器 P4 实证：整个换成 `return 0`，**202 项全绿、0 条红** | Step 1 补 3 条：`run -test -config` 写法、`run -test -c` 写法、两种都不支持 |
| T5-4 | **Minor** | `render_server_config` 用**未加引号的 heredoc**（`<<EOF`）渲染 → 5 个入参里任何 `$(...)` / 反引号都会被**真实执行**。控制器 P7/P8 实证：把 `'$(echo PWNED)'` 传进 ShortID 或 SNI，**该命令被执行并把结果写进了 config.json**。当前所有调用方恰好都校验过输入（Task 8 校验 `--sni`/`--port`，向导校验端口），所以**当前不可达**；但「安全性靠调用方自觉」不是函数契约 | Step 3 在 `render_server_config` 里加**入参白名单校验**（UUID / 私钥 base64url 40-64 / 端口 1-65535 / ShortID 十六进制 2-16 / SNI 走 `validate_hostname`），任一不合法 → `tui_err` + 返回 1 + **不落盘**；Step 1 补 4 条注入拒绝断言 |
| T5-5 | **Minor** | `cat >"$tmp" <<EOF` 的**退出码没检查** → 目标目录不存在时，原始 bash 报错（`No such file or directory`）直接漏到 stderr，用户看到的是裸报错而不是我们的提示（控制器 P9 实证） | Step 3 把 heredoc 包进 `if ! cat >"$tmp" <<EOF ... EOF then ... fi` |
| T5-6 | **Minor** | `chmod 600` 写在 `mv` **之后** → 权限设置失败时文件**已经落位**，函数却返回非零 → 调用方以为失败而重试 | Step 3 改成先 `chmod 600 "$tmp"` 再 `mv`（与 `write_config_atomic` 一致） |
| T5-7 | **Minor** | `write_config_atomic` 失败时打印的 xray 报错只用了 `run -test -config` 一种写法，而 `xray_test_config` 会依次试 3 种 → 在只认 `-c` 的版本上，给用户看的是「unknown flag」这种误导性报错 | Step 3 让 `xray_test_config` 把**最后一次尝试**的 stderr 留在 `XRAY_TEST_ERR` 里，失败时打印它 |
| T5-8 | **Minor** | `xray_parse_keys` 的那条断言描述写着「返回空串**且退出码非零**」，实际**只断言了空串**，退出码那一半从来没被测过 | Step 1 拆成两条：空串一条、退出码一条 |
| T5-9 | **Minor** | `gen_keys` 的 `UUID=$("$XRAY_BIN" uuid ...)` **不检查格式** → xray 失败时若把错误信息写进 stdout，那串文字会被原样写进 config.json，失败点被推迟到 xray 校验，报错与真实原因无关 | Step 3 加 UUID 正则校验 |
| T5-10 | **Minor** | `render_server_config` 的内部暂存名是 `$outfile.new`，与 `write_config_atomic` 的 `$outfile.new` **同名**。Task 9/10 目前的调用姿势（`render` 到 mktemp 路径、`write` 到正式路径）不会撞名，但一旦有人把正式路径直接传给 `render`，就会**绕过 xray 校验** | Step 3 把 `render` 的暂存名改成 `$outfile.render`，与 `.new` 区分开；Step 3 的函数注释写明**调用约定**（必须传暂存路径） |
| T5-11 | **Minor** | Task 5 **没有独立的验收标准段**（Task 3 / Task 4 都有） | 补一个 |

> **控制器的自我记账（与 Task 4 的 F4-15 同源）**：T5-1 的发现方法是**变异**，
> 不是读代码读出来的 —— 读代码时「`[[ -f "$src" ]]` 会挡住字面量」这层很容易看漏。
> **断言有没有判别力，只能靠变异证明。**

#### 修订轮 1 的验收标准

1. `lib/deploy.sh` 的内容与上面 **Step 3 代码块逐字节一致**。
2. `test/unit.sh` 里 Task 5 的插入段与上面 **Step 1 代码块逐字节一致**
   （追加在 `test_summary` **之前**；`source "$ROOT/lib/deploy.sh"` 放在顶部 source 区域）。
3. `bash test/unit.sh` 全部通过、退出码 0。
4. 断言总数必须恒定，且**连跑 4 次条数相同**。
   平台差异：本机（Windows + MSYS）与 Debian/CI 的条数差 **4 条** ——
   4 条权限相关行为断言在 MSYS 上被自动跳过（`chmod` 是模拟的）。
   报告里必须写明是哪个平台的数字。
5. 红灯证据（至少这六条，每条都要贴出**变红的断言原文**）：
   - 把 `write_config_atomic` 的「校验失败」分支改成**直接破坏目标文件**
     → 「write_config_atomic 校验失败时保留原有配置不变」必须变红
     （这条在修订前是 0 条红 —— 证明它恒真）；
   - 把 `gen_keys` 整个换成 `return 0` → 「gen_keys 设置 PRIVATE_KEY」等必须变红；
   - 把 `xray_test_config` 整个换成 `return 0` → 「xray_test_config 识别 run -test -config 写法」必须变红；
   - 把 `render_server_config` 的入参白名单校验删掉 → 「render_server_config 拒绝含命令替换的 ShortID」必须变红；
   - 把 `xray_test_config` 里 `run -test -c` 那一行删掉 → 「xray_test_config 识别 run -test -c 写法」必须变红；
   - 把 `gen_keys` 里的 UUID 格式校验删掉 → 「gen_keys 在 xray uuid 输出的不是合法 UUID 时返回非零」必须变红；
   - 把 `render_server_config` 里的**私钥**白名单校验删掉 → 「render_server_config 拒绝含命令替换的私钥」必须变红；
   - 把 `render_server_config` 里 `cat` 的退出码检查去掉（恢复成不检查）→ 「render_server_config 在目标目录不存在时给出自己的错误提示（而不是裸的 bash 报错）」必须变红。
     注意**不能**用「返回非零」那条来判断：`cat` 检查去掉后，函数仍会因为后面的
     `chmod 600 "$tmp"` 失败而返回 1 → 退出码一样是 1 → 那条断言**恒绿**、
     没有判别力。真正被 `cat` 检查守住的是**错误提示的文本**。
6. `lib/tui.sh`、`test/lib.sh`、`lib/core.sh` **一字未动**。
7. 计划文件实施者一个字都不许改。

#### 修订轮 1 的逐项发现与处置

> 本节由**控制器**在 Task 5 派发前预扫（沙箱实证）之后写入。
> 本节列的全是**计划缺陷**，责任方是控制器；Task 5 的代码块本身还没被实施过。

| # | 级别 | 发现 | 处置 |
|---|---|---|---|
| T5-1 | **Important** | `write_config_atomic` 的「**xray 校验失败**」路径**完全没被测到**：Step 1 传给它的源文件是**字面量** `'{"broken":'`，而函数第一步就是 `[[ -f "$src" ]] || return 1` → 直接把它挡在门外 → 后面那三条断言全是**恒真**。控制器 P1 实证：把「校验失败」分支改成【直接破坏目标文件】，**202 项断言仍然全绿、0 条红** | Step 1 改成先 `printf '{"broken":\n' > "$atomic_dir/broken.json"` 再传**路径**；并补一条「源文件不存在时**不得覆盖目标文件**」（原来只有「返回非零」，实现若写成「先覆盖再校验」仍会漏） |
| T5-2 | **Important** | `gen_keys` **一条断言都没有**。控制器 P3 实证：把 `gen_keys` 整个换成 `return 0`，**202 项全绿、0 条红**。而它恰好是「把 xray 的输出变成配置」的关键环节 | Step 1 补假 xray（用 **shell 函数**实现而不是「造脚本 + chmod +x」—— MSYS 的 chmod 位不可靠）+ 4 组断言：成功路径一次设置 4 个全局变量、x25519 失败、输出无法解析、`random_hex` 失败 |
| T5-3 | **Important** | `xray_test_config` **一条断言都没有**。控制器 P4 实证：整个换成 `return 0`，**202 项全绿、0 条红** | Step 1 补 3 条：`run -test -config` 写法、`run -test -c` 写法、两种都不支持 |
| T5-4 | **Minor** | `render_server_config` 用**未加引号的 heredoc**（`<<EOF`）渲染 → 5 个入参里任何 `$(...)` / 反引号都会被**真实执行**。控制器 P7/P8 实证：把 `'$(echo PWNED)'` 传进 ShortID 或 SNI，**该命令被执行并把结果写进了 config.json**。当前所有调用方恰好都校验过输入（Task 8 校验 `--sni`/`--port`，向导校验端口），所以**当前不可达**；但「安全性靠调用方自觉」不是函数契约 | Step 3 在 `render_server_config` 里加**入参白名单校验**（UUID / 私钥 base64url 40-64 / 端口 1-65535 / ShortID 十六进制 2-16 / SNI 走 `validate_hostname`），任一不合法 → `tui_err` + 返回 1 + **不落盘**；Step 1 补 4 条注入拒绝断言 |
| T5-5 | **Minor** | `cat >"$tmp" <<EOF` 的**退出码没检查** → 目标目录不存在时，原始 bash 报错（`No such file or directory`）直接漏到 stderr，用户看到的是裸报错而不是我们的提示（控制器 P9 实证） | Step 3 把 heredoc 包进 `if ! cat >"$tmp" <<EOF ... EOF then ... fi` |
| T5-6 | **Minor** | `chmod 600` 写在 `mv` **之后** → 权限设置失败时文件**已经落位**，函数却返回非零 → 调用方以为失败而重试 | Step 3 改成先 `chmod 600 "$tmp"` 再 `mv`（与 `write_config_atomic` 一致） |
| T5-7 | **Minor** | `write_config_atomic` 失败时打印的 xray 报错只用了 `run -test -config` 一种写法，而 `xray_test_config` 会依次试 3 种 → 在只认 `-c` 的版本上，给用户看的是「unknown flag」这种误导性报错 | Step 3 让 `xray_test_config` 把**最后一次尝试**的 stderr 留在 `XRAY_TEST_ERR` 里，失败时打印它 |
| T5-8 | **Minor** | `xray_parse_keys` 的那条断言描述写着「返回空串**且退出码非零**」，实际**只断言了空串**，退出码那一半从来没被测过 | Step 1 拆成两条：空串一条、退出码一条 |
| T5-9 | **Minor** | `gen_keys` 的 `UUID=$("$XRAY_BIN" uuid ...)` **不检查格式** → xray 失败时若把错误信息写进 stdout，那串文字会被原样写进 config.json，失败点被推迟到 xray 校验，报错与真实原因无关 | Step 3 加 UUID 正则校验 |
| T5-10 | **Minor** | `render_server_config` 的内部暂存名是 `$outfile.new`，与 `write_config_atomic` 的 `$outfile.new` **同名**。Task 9/10 目前的调用姿势（`render` 到 mktemp 路径、`write` 到正式路径）不会撞名，但一旦有人把正式路径直接传给 `render`，就会**绕过 xray 校验** | Step 3 把 `render` 的暂存名改成 `$outfile.render`，与 `.new` 区分开；Step 3 的函数注释写明**调用约定**（必须传暂存路径） |
| T5-11 | **Minor** | Task 5 **没有独立的验收标准段**（Task 3 / Task 4 都有） | 补一个 |

> **控制器的自我记账（与 Task 4 的 F4-15 同源）**：T5-1 的发现方法是**变异**，
> 不是读代码读出来的 —— 读代码时「`[[ -f "$src" ]]` 会挡住字面量」这层很容易看漏。
> **断言有没有判别力，只能靠变异证明。**

#### 修订轮 1 的验收标准

1. `lib/deploy.sh` 的内容与上面 **Step 3 代码块逐字节一致**。
2. `test/unit.sh` 里 Task 5 的插入段与上面 **Step 1 代码块逐字节一致**
   （追加在 `test_summary` **之前**；`source "$ROOT/lib/deploy.sh"` 放在顶部 source 区域）。
3. `bash test/unit.sh` 全部通过、退出码 0。
4. 断言总数必须恒定，且**连跑 4 次条数相同**。
   平台差异：本机（Windows + MSYS）与 Debian/CI 的条数差 **4 条** ——
   4 条权限相关行为断言在 MSYS 上被自动跳过（`chmod` 是模拟的）。
   报告里必须写明是哪个平台的数字。
5. 红灯证据（至少这六条，每条都要贴出**变红的断言原文**）：
   - 把 `write_config_atomic` 的「校验失败」分支改成**直接破坏目标文件**
     → 「write_config_atomic 校验失败时保留原有配置不变」必须变红
     （这条在修订前是 0 条红 —— 证明它恒真）；
   - 把 `gen_keys` 整个换成 `return 0` → 「gen_keys 设置 PRIVATE_KEY」等必须变红；
   - 把 `xray_test_config` 整个换成 `return 0` → 「xray_test_config 识别 run -test -config 写法」必须变红；
   - 把 `render_server_config` 的入参白名单校验删掉 → 「render_server_config 拒绝含命令替换的 ShortID」必须变红；
   - 把 `xray_test_config` 里 `run -test -c` 那一行删掉 → 「xray_test_config 识别 run -test -c 写法」必须变红；
   - 把 `gen_keys` 里的 UUID 格式校验删掉 → 「gen_keys 在 xray uuid 输出的不是合法 UUID 时返回非零」必须变红；
   - 把 `render_server_config` 里的**私钥**白名单校验删掉 → 「render_server_config 拒绝含命令替换的私钥」必须变红；
   - 把 `render_server_config` 里 `cat` 的退出码检查去掉（恢复成不检查）→ 「render_server_config 在目标目录不存在时给出自己的错误提示（而不是裸的 bash 报错）」必须变红。
     注意**不能**用「返回非零」那条来判断：`cat` 检查去掉后，函数仍会因为后面的
     `chmod 600 "$tmp"` 失败而返回 1 → 退出码一样是 1 → 那条断言**恒绿**、
     没有判别力。真正被 `cat` 检查守住的是**错误提示的文本**。
6. `lib/tui.sh`、`test/lib.sh`、`lib/core.sh` **一字未动**。
7. 计划文件实施者一个字都不许改。

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
    elif [[ "$line" == *:* ]]; then
      key="${line%%:*}"
      val="${line#*:}"
    else
      # 既无 ':' 也无 '=' 的行：上面两种取法都会把整行当成 key 和 val，
      # 例如单独一行 "PrivateKey" 会被误判成私钥 "PrivateKey" → 必须跳过。
      continue
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
  # UUID 必须是规范形态：xray uuid 失败时可能把错误信息写进 stdout，
  # 那样会被原样写进 config.json → 失败点被推迟到 xray 校验，
  # 报错与真实原因完全无关。
  [[ "$UUID" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] \
    || { tui_err "xray uuid 输出的 UUID 格式非法：$UUID"; return 1; }

  # random_hex 失败时返回非零（且输出可能为空）→ 必须检查，否则空 SHORT_ID
  # 会被原样写进 config.json，xray 校验失败时报错与真实原因无关。
  SHORT_ID=$(random_hex 4) || { tui_err "生成 ShortID 失败（openssl / od 不可用？）"; return 1; }
  [[ -n "$SHORT_ID" ]] || { tui_err "生成的 ShortID 为空"; return 1; }
  tui_ok "密钥对已生成"
  tui_kv "公钥 (pbk)" "$PUBLIC_KEY"
  tui_kv "ShortID (sid)" "$SHORT_ID"
  tui_kv "UUID" "$UUID"
  return 0
}

# 渲染服务端 config.json
#
# 契约（重要，Task 5 修订轮 1 补明）：
#   · 本函数只把配置写到【调用方指定的路径】并 chmod 600，**不做 xray 校验**；
#     校验与落位到正式路径由 write_config_atomic 负责。
#   · 调用方**必须**传一个【暂存路径】（例如 mktemp 出来的文件），
#     绝不能把正式配置路径直接传进来 —— 那会绕过 xray run -test 校验。
#   · 内部暂存名用 ".render" 后缀，与 write_config_atomic 的 ".new" 区分开，
#     避免两者在同一条路径上撞名。
render_server_config() {
  local outfile="$1" uuid="$2" priv="$3" sni="$4" port="$5" sid="$6"
  # ── 入参白名单校验（必须【先做】）────────────────────────────
  # 本函数用【未加引号的 heredoc】渲染 JSON → 入参里的 $(...) / 反引号会被
  # 【真实执行】。控制器实证：把 '$(echo PWNED)' 传进 ShortID 或 SNI，
  # 该命令被执行并把结果写进了 config.json。
  # 当前所有调用方恰好都校验过输入（Task 8 校验 --sni/--port，向导校验端口），
  # 但「安全性靠调用方自觉」不是函数契约 —— 下面的白名单让 5 个入参
  # 只可能含有安全字符，从根上关死注入面。
  [[ "$uuid" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] \
    || { tui_err "UUID 格式非法：$uuid"; return 1; }
  [[ "$priv" =~ ^[A-Za-z0-9_-]{40,64}$ ]] \
    || { tui_err "REALITY 私钥格式非法（只允许 base64url 字符，长度 40-64）"; return 1; }
  [[ "$port" =~ ^[0-9]{1,5}$ ]] && [[ "$port" -ge 1 && "$port" -le 65535 ]] \
    || { tui_err "端口非法：$port"; return 1; }
  [[ "$sid" =~ ^[0-9a-fA-F]{2,16}$ ]] \
    || { tui_err "ShortID 格式非法（只允许十六进制，长度 2-16）：$sid"; return 1; }
  validate_hostname "$sni" || { tui_err "SNI 主机名非法：$sni"; return 1; }

  local tmp="$outfile.render"
  # cat 的退出码必须检查：目标目录不存在时，重定向失败会漏出原始 bash 报错，
  # 用户看到的是「No such file or directory」而不是我们自己的提示。
  if ! cat >"$tmp" <<EOF
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
  then
    tui_err "无法写入配置暂存文件：$tmp"
    rm -f "$tmp"
    return 1
  fi
  # 含 REALITY 私钥 → 600。必须在 mv 之前设好：
  # 否则「权限设置失败」时文件已经落位，函数却返回非零 → 调用方以为失败而重试，
  # 留下一份权限不对的正式配置。
  chmod 600 "$tmp" || { tui_err "无法设置暂存文件权限：$tmp"; rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$outfile" || { tui_err "无法写入配置：$outfile"; rm -f "$tmp"; return 1; }
}

# 校验配置可用。兼容不同 xray 版本的子命令写法。
# 失败时把【最后一次尝试】的 stderr 留在 XRAY_TEST_ERR 里 ——
# 写配置失败时要把 xray 的原始报错给用户看，而不同版本认的子命令不同，
# 只打印其中一种写法会给出误导性的报错（比如只认 -c 的版本上会显示 unknown flag）。
XRAY_TEST_ERR=''
xray_test_config() {
  local cfg="$1" e=''
  XRAY_TEST_ERR=''
  # 注意：stderr 必须用【命令替换】捕获，不能写成 2>"$XRAY_TEST_ERR" ——
  # 变量为空时那是一次「重定向到空文件名」，bash 报的是
  # "No such file or directory"（看起来像命令找不到，真相是重定向失败），
  # 而且命令根本没被执行。控制器实测踩过。
  e=$( { "$XRAY_BIN" run -test -config "$cfg" >/dev/null; } 2>&1 )
  if [[ $? -eq 0 ]]; then XRAY_TEST_ERR="$e"; return 0; fi
  e=$( { "$XRAY_BIN" run -test -c "$cfg" >/dev/null; } 2>&1 )
  if [[ $? -eq 0 ]]; then XRAY_TEST_ERR="$e"; return 0; fi
  e=$( { "$XRAY_BIN" -test -config "$cfg" >/dev/null; } 2>&1 )
  if [[ $? -eq 0 ]]; then XRAY_TEST_ERR="$e"; return 0; fi
  XRAY_TEST_ERR="$e"
  return 1
}

# 写临时文件 → 校验 → 原子替换。校验失败保留旧文件并输出 xray 报错。
# 用法: write_config_atomic <目标文件> <源文件>
#   源文件是刚渲染出来的配置（尚未落位）；本函数负责把它校验后原子替换到目标。
#   这条路径是【唯一】的写服务端配置入口 —— do_deploy 与 menu_rotate_keys 都必须走它，
#   不得各自手写「渲染 → 校验 → mv」。两处手写必然分叉：menu_rotate_keys 那份当年
#   就漏了输出 xray 的原始报错，用户只看到一句「新配置校验未通过」。
write_config_atomic() {
  local outfile="$1" src="$2"
  local tmp="$outfile.new"
  [[ -f "$src" ]] || { tui_err "源配置不存在：$src"; return 1; }
  cp "$src" "$tmp" || { tui_err "无法写入临时文件：$tmp"; return 1; }
  # 服务端配置含 REALITY 私钥 → 权限必须 600（计划里其余含密文件一律 600）。
  # systemd unit 没有 User= → xray 以 root 运行 → 600 不会挡住它读配置。
  chmod 600 "$tmp" || { tui_err "无法设置临时文件权限：$tmp"; rm -f "$tmp"; return 1; }
  if ! xray_test_config "$tmp"; then
    tui_err "配置校验未通过，已保留原有配置不变。"
    if [[ -n "$XRAY_TEST_ERR" ]]; then
      printf '%s\n' "$XRAY_TEST_ERR" | sed -e 's/^/      /'
    else
      "$XRAY_BIN" run -test -config "$tmp" 2>&1 | sed -e 's/^/      /' || true
    fi
    rm -f "$tmp"
    return 1
  fi
  mv -f "$tmp" "$outfile" || { tui_err "无法写入配置文件：$outfile"; rm -f "$tmp"; return 1; }
  chmod 600 "$outfile" || { tui_err "无法设置配置文件权限：$outfile"; return 1; }
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

# enable_bbr 在不支持 bbr 的内核上必须安全失败而非崩溃；输出必须提及 bbr。
# 必须 mock 掉 sysctl 走「不支持 bbr」分支：真实调用会写
# /etc/sysctl.d/99-vless-reality-bbr.conf 并 `sysctl -p` 立即应用，
# 那是单元测试不该有的主机副作用（CI 上会真的改掉运行内核的拥塞控制）。
out=$( ( sysctl() { printf 'cubic\n'; }; enable_bbr 2>&1 ) ) || true
assert_contains "$out" "bbr" "enable_bbr 输出提及 bbr 状态"

# open_firewall 在无任何防火墙工具时必须明确告知而不是静默成功
if ! have_cmd ufw && ! have_cmd nft && ! have_cmd iptables; then
  out=$(open_firewall 443 2>&1) || true
  assert_contains "$out" "防火墙" "无防火墙工具时给出明确提示"
fi

# open_firewall：ufw 分支必须真的调用 ufw allow 且把失败码传出去。
# 用 mock 捕获 tui_run 的命令，【不碰真实防火墙】。
out=$( ( have_cmd() { case "$1" in ufw) return 0 ;; iptables|nft) return 1 ;; *) return 1 ;; esac; }
            ufw() { printf 'Status: active\n'; }
            tui_run() { printf '%s\n' "$*"; return 0; }
            open_firewall 8443 2>&1 ) )
assert_contains "$out" "8443/tcp" "open_firewall 的 ufw 分支调用了 ufw allow <port>/tcp"
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
else
  assert_eq "mktemp -d 能创建唯一临时目录" "失败（mktemp -d 返回空路径）" \
    "enable_bbr 用例前提：mktemp -d 必须能创建唯一临时目录"
fi
rm -rf "$bbr_dir"
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
  # 依赖装不上就必须中止：ensure_packages 会透传 apt 的失败码。
  ensure_packages curl ca-certificates || return 1
  local installer
  installer=$(mktemp 2>/dev/null)
  # mktemp 必须有空值守卫：失败时 installer 为空 → curl -o "" 失败，
  # 报错会指向「网络」而真实原因是 mktemp 不可用。
  if [[ -z "$installer" ]]; then
    tui_err "无法创建临时文件，Xray 安装中止。"
    return 1
  fi
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
      # 失败必须传播出去：原来这一分支不管 nft insert 成功与否都 return 0，
      # 调用方（do_deploy）会以为端口已放行。
      tui_run "放行端口 $port/tcp (nftables)" nft insert rule inet filter input tcp dport "$port" ct state new counter accept || return 1
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
  # 配置路径可被环境变量覆盖 —— 仅为让单元测试能在【不碰宿主机内核参数】的前提下
  # 覆盖成功路径；生产环境不要设置它。
  local conf="${VLESS_REALITY_SYSCTL_CONF:-/etc/sysctl.d/99-vless-reality-bbr.conf}"
  local bbr_conf
  bbr_conf='net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_fastopen = 3
net.core.somaxconn = 4096
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_slow_start_after_idle = 0'
  # 写失败必须报错并返回非零：原来 `cat >"$conf"` 的失败被后面的 `|| true` 吃掉，
  # 函数照样 tui_ok「已启用 bbr」并返回 0 —— 失败被伪装成成功。
  if ! printf '%s\n' "$bbr_conf" >"$conf"; then
    tui_err "无法写入 sysctl 配置：$conf"
    tui_tip "可能缺少 root 权限，或该目录不可写。"
    return 1
  fi
  if ! sysctl -p "$conf" >/dev/null 2>&1 && ! sysctl --system >/dev/null 2>&1; then
    tui_err "内核参数应用失败：$conf"
    tui_tip "可能缺少 root 权限。"
    return 1
  fi
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

# 同上：mktemp 失败时路径为空会写出 ".new" 污染仓库 → 必须守卫。
ccfg=$(mktemp)
if [[ -z "$ccfg" ]]; then
  assert_eq "mktemp 能创建临时文件" "失败（mktemp 返回空路径）" "客户端渲染用例前提：mktemp 必须可用"
else
render_client_config "$ccfg" "UUID123" "1.2.3.4" "443" "www.microsoft.com" "PUBKEY" "a1b2c3d4" >/dev/null
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
assert_contains "$(cat "$ccfg")" '"publicKey": "PUBKEY"' "客户端含公钥"
assert_contains "$(cat "$ccfg")" '"serverName": "www.microsoft.com"' "客户端含 serverName"
assert_contains "$(cat "$ccfg")" '"fingerprint": "chrome"' "客户端含 fingerprint"
rm -f "$ccfg"
fi

test_case "客户端物料导出"

# export_client_artifacts 此前【完全没有测试】—— 而它正是产出分享链接的函数。
exp_dir=$(mktemp -d 2>/dev/null)
if [[ -n "$exp_dir" ]]; then
  out=$( export_client_artifacts "$exp_dir" "UUID123" "1.2.3.4" "443" "www.microsoft.com" "PUBKEY" "a1b2c3d4" "我的节点" 2>&1 ); rc=$?
  assert_status 0 "$rc" "export_client_artifacts 成功返回 0"
  assert_contains "$(cat "$exp_dir/link.txt" 2>/dev/null)" "vless://UUID123@1.2.3.4:443" "link.txt 含分享链接"
  assert_contains "$(cat "$exp_dir/client.txt" 2>/dev/null)" "UUID: UUID123" "client.txt 含 UUID"
  # 备注不出现在 client.txt 的明文字段里（只作为分享链接的 fragment，URL 编码后出现）
  assert_contains "$(cat "$exp_dir/client.txt" 2>/dev/null)" "%E6%88%91%E7%9A%84%E8%8A%82%E7%82%B9" "client.txt 的分享链接里备注被 URL 编码"
  if [[ -s "$exp_dir/client.json" ]]; then jf=1; else jf=0; fi
  assert_eq "1" "$jf" "client.json 已生成且非空"
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

# IPv6 地址在分享链接里必须加方括号，否则客户端导入即废。
link6=$(build_share_link "UUID123" "2001:db8::1" "443" "www.microsoft.com" "PUBKEY" "a1b2c3d4" "v6")
assert_contains "$link6" "@[2001:db8::1]:443" "IPv6 地址在分享链接里加了方括号"
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
  local enc host
  enc=$(urlencode "$remark")
  # IPv6 地址在 URL 里必须写成 [addr]:port，否则 vless://uuid@2001:db8::1:443 是非法 URL
  # → 客户端导入即废。detect_public_ip 允许返回 IPv6，所以这里必须处理。
  host="$ip"
  if [[ "$host" == *:* && "$host" != \[*\] ]]; then
    host="[$host]"
  fi
  # FLOW / FINGERPRINT 是全局状态（状态文件里也记着），不能在这里写死 ——
  # 写死就等于让状态文件里的这两个字段变成死状态。
  printf 'vless://%s@%s:%s?encryption=none&flow=%s&security=reality&sni=%s&fp=%s&pbk=%s&sid=%s&type=tcp&headerType=none#%s' \
    "$uuid" "$host" "$port" "${FLOW:-xtls-rprx-vision}" "$sni" "${FINGERPRINT:-chrome}" "$pub" "$sid" "$enc"
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
  mv -f "$tmp" "$outfile" || { tui_err "无法写入客户端配置：$outfile"; rm -f "$tmp"; return 1; }
  chmod 600 "$outfile" || { tui_err "无法设置客户端配置权限：$outfile"; return 1; }
}

export_client_artifacts() {
  local outdir="$1" uuid="$2" ip="$3" port="$4" sni="$5" pub="$6" sid="$7" remark="$8"
  # 目录与文件都含敏感信息（分享链接、UUID、公钥）→ 每一步失败都必须报错并返回非零，
  # 绝不能让「导出失败」看起来像「导出成功」。
  mkdir -p "$outdir" || { tui_err "无法创建客户端导出目录：$outdir"; return 1; }
  chmod 700 "$outdir" || { tui_err "无法设置客户端导出目录权限：$outdir"; return 1; }

  local link
  link=$(build_share_link "$uuid" "$ip" "$port" "$sni" "$pub" "$sid" "$remark")
  [[ -n "$link" ]] || { tui_err "分享链接生成为空"; return 1; }

  render_client_config "$outdir/client.json" "$uuid" "$ip" "$port" "$sni" "$pub" "$sid" || return 1

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
  } >"$outdir/client.txt" || { tui_err "无法写入客户端信息文件：$outdir/client.txt"; return 1; }
  chmod 600 "$outdir/client.txt" || { tui_err "无法设置客户端信息文件权限：$outdir/client.txt"; return 1; }

  printf '%s' "$link" >"$outdir/link.txt" || { tui_err "无法写入分享链接文件：$outdir/link.txt"; return 1; }
  chmod 600 "$outdir/link.txt" || { tui_err "无法设置分享链接文件权限：$outdir/link.txt"; return 1; }

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
  - `install.sh` 支持 `-y/--yes` `-p/--port` `-s/--sni` `-n/--name` `--uuid` `--addr` `-m/--menu` `--status` `--uninstall` `-h/--help`
  - `parse_args "$@"` → 设置 `OPT_YES` `OPT_PORT` `OPT_SNI` `OPT_NAME` `OPT_UUID` `OPT_ADDR` `OPT_MODE`
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
assert_contains "$run_help" "--addr" "帮助信息含 --addr"

# --addr 的字符集校验：会原样进分享链接与客户端 JSON → 必须拒绝引号/空格/$
out=$(bash "$ROOT/install.sh" --addr 'bad"addr' 2>&1); rc=$?
assert_status 1 "$rc" "--addr 含引号时以非零码退出"
assert_contains "$out" "--addr" "--addr 非法时给出明确提示"
out=$(bash "$ROOT/install.sh" --addr 'a b' 2>&1); rc=$?
assert_status 1 "$rc" "--addr 含空格时以非零码退出"
out=$(bash "$ROOT/install.sh" --addr 2>&1); rc=$?
assert_status 1 "$rc" "--addr 缺少参数时以非零码退出"

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
OPT_ADDR=''

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
      --addr <地址>   指定对外地址（NAT 后的服务器用；默认自动探测公网 IP）
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
      -p|--port)     OPT_PORT="${2:-}"; [[ -n "$OPT_PORT" ]] || { tui_err "--port 缺少参数"; exit 1; }
                     # 端口范围必须在【参数解析口】就拦一次：只校验交互式输入那条路径不够，
                     # --port 99999 会被接受并写进 config.json → 部署晚一步才因 xray 报错而中止。
                     # 10# 前缀：用户输入 "08" 时不能被当成八进制。
                     if ! [[ "$OPT_PORT" =~ ^[0-9]+$ ]] || (( 10#$OPT_PORT < 1 || 10#$OPT_PORT > 65535 )); then
                       tui_err "--port 必须是 1-65535 之间的整数：$OPT_PORT"
                       exit 1
                     fi
                     shift 2 ;;
      -s|--sni)      OPT_SNI="${2:-}"; [[ -n "$OPT_SNI" ]] || { tui_err "--sni 缺少参数"; exit 1; }; shift 2 ;;
      -n|--name)     OPT_NAME="${2:-}"; [[ -n "$OPT_NAME" ]] || { tui_err "--name 缺少参数"; exit 1; }; shift 2 ;;
      --uuid)        OPT_UUID="${2:-}"; [[ -n "$OPT_UUID" ]] || { tui_err "--uuid 缺少参数"; exit 1; }; shift 2 ;;
      --addr)        OPT_ADDR="${2:-}"; [[ -n "$OPT_ADDR" ]] || { tui_err "--addr 缺少参数"; exit 1; }
                     # 地址会原样进入分享链接与客户端 JSON → 字符集必须受限：
                     # 只允许 IP 字面量与 DNS 主机名会用到的字符（字母数字 . : _ -），
                     # 引号/反斜杠/空格/$ 一律拒绝（否则破坏 JSON 与 URL）。
                     if ! [[ "$OPT_ADDR" =~ ^[A-Za-z0-9._:-]+$ ]]; then
                       tui_err "--addr 只能是 IP 地址或主机名：$OPT_ADDR"
                       tui_tip "示例：1.2.3.4 / example.com / 2001:db8::1"
                       exit 1
                     fi
                     shift 2 ;;
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

  # 对外地址：优先用 --addr 指定的（NAT 后的服务器探测不到公网 IP，
  # 探测到的只是内网地址 → 分享链接里的主机名是内网 IP → 客户端根本连不上）。
  if [[ -n "${OPT_ADDR:-}" ]]; then
    SERVER_IP="$OPT_ADDR"
    tui_ok "使用指定的对外地址：$SERVER_IP"
  else
    SERVER_IP=$(detect_public_ip || true)
    if [[ -z "$SERVER_IP" ]]; then
      SERVER_IP=$(detect_local_ip || true)
      tui_warn "未能探测到公网 IP，回退使用本机地址：${SERVER_IP:-未知}"
      tui_tip "若服务器位于 NAT 后，请用 --addr 指定对外地址后再配置客户端。"
    else
      tui_ok "公网 IP：$SERVER_IP"
    fi
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
  # mktemp 失败时 tmp 为空 → 后面会写出 ".<host>" 污染当前目录 → 必须守卫。
  if [[ -z "$tmp" ]]; then
    tui_err "无法创建临时文件，目标探测中止"
    return 1
  fi
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

  # 用 ${OPT_YES:-0} 而不是 $OPT_YES：OPT_* 是 install.sh 的全局，
  # deploy.sh 单独被 source（单元测试 / helper）时它们可能根本没定义，
  # 在 `set -u` 下会直接报 unbound variable。
  if [[ ${OPT_YES:-0} -eq 1 ]]; then
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
  # 必须把 tui_menu 的输出重定向到 stderr：tui_menu 会把【整张菜单】打到 stdout，
  # 而调用方是 `SNI=$(choose_target)` —— 不重定向的话，SNI 会变成
  # 「菜单标题 + 选项列表 + 选中的 host」的多行字符串，随后被原样写进
  # config.json → JSON 非法 → xray run -test 失败 → 部署以一句看不懂的报错中止。
  # 选中项一律用【返回码】取，stdout 只留最后 printf 的那个 host。
  tui_menu "选择 REALITY 伪装目标（SNI）" "${labels[@]}" >&2 || rc=$?
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
  [[ -n "${OPT_UUID:-}" ]] && UUID="${OPT_UUID:-}"

  tui_step "③ 生成服务端配置"
  mkdir -p "$(dirname "$XRAY_CONFIG")" || { tui_err "无法创建配置目录：$(dirname "$XRAY_CONFIG")"; return 1; }
  local cfg
  # mktemp 必须有空值守卫：失败时 cfg 为空 → render_server_config 会写到 ".new"
  # 污染当前目录（还可能在仓库里），而 mv 会因为空路径而失败。
  cfg=$(mktemp 2>/dev/null)
  if [[ -z "$cfg" ]]; then
    tui_err "无法创建临时文件，部署中止。"
    return 1
  fi
  render_server_config "$cfg" "$UUID" "$PRIVATE_KEY" "$SNI" "$PORT" "$SHORT_ID" || { rm -f "$cfg"; return 1; }
  # 写服务端配置【必须】走 write_config_atomic（复制到临时文件 → xray 校验 → 原子替换），
  # 不要在这里手写「校验 + 替换」：两处手写会分叉（menu_rotate_keys 当年就漏了
  # 输出 xray 的原始报错），而且手写版本漏掉了 mv/chmod 的失败检查。
  write_config_atomic "$XRAY_CONFIG" "$cfg" || { rm -f "$cfg"; return 1; }
  rm -f "$cfg"
  tui_ok "服务端配置已写入：$XRAY_CONFIG"

  tui_step "④ 配置 systemd 服务"
  setup_systemd || { tui_err "systemd 配置失败，部署中止"; return 1; }

  tui_step "⑤ 放行防火墙端口 $PORT/tcp"
  # 防火墙放行失败【不中止】部署（用户可能用云安全组/云防火墙管端口），
  # 但必须把失败状态带进最终的「部署完成」面板 ——
  # 否则用户看到「部署完成」就以为端口通了，实际客户端连不上。
  FIREWALL_OK=1
  if ! open_firewall "$PORT"; then
    tui_warn "防火墙放行未成功，请手工确认"
    FIREWALL_OK=0
  fi

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
    if [[ ${OPT_YES:-0} -eq 1 ]]; then
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
            # 用 10# 前缀：裸算术会把 "08" 当八进制，直接报「value too great for base」。
            [[ "$PORT" =~ ^[0-9]+$ ]] && (( 10#PORT > 0 && 10#PORT < 65536 )) || { tui_err "端口非法"; return 1; } ;;
        *) tui_info "已取消部署"; return 1 ;;
      esac
    fi
  fi

  # SERVER_IP 由 preflight 负责探测，但 --menu 路径【不经过 preflight】
  # （install.sh 的 --menu 分支只有 require_root + load_state + management_menu）。
  # 未部署时 load_state 什么都没赋值 → SERVER_IP 未绑定：
  #   · 引用它 → set -u 下 bash 直接退出，用户只看到 "SERVER_IP: unbound variable"；
  #   · 即使补了全局声明，空的 SERVER_IP 也会让分享链接变成 "vless://uuid@:443?..."
  #     → 主机名为空 → 客户端导入即废。
  # 所以这里必须自己兜底探测一次。
  if [[ -n "${OPT_ADDR:-}" ]]; then
    # 用户手工指定了对外地址 → 优先用它（NAT 后的服务器探测到的只是内网 IP）
    SERVER_IP="$OPT_ADDR"
  elif [[ -z "${SERVER_IP:-}" ]]; then
    SERVER_IP=$(detect_public_ip 2>/dev/null || true)
    [[ -n "$SERVER_IP" ]] || SERVER_IP=$(detect_local_ip 2>/dev/null || true)
    if [[ -z "$SERVER_IP" ]]; then
      tui_err "无法探测到本机地址，部署中止。"
      tui_tip "可用 --addr 手工指定对外地址，或检查出网是否正常。"
      return 1
    fi
    tui_warn "未能自动探测到公网地址，已回退使用本机地址：$SERVER_IP"
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

  if [[ ${OPT_YES:-0} -eq 0 ]]; then
    tui_confirm "确认开始部署？" "y" || { tui_info "已取消"; return 1; }
  fi

  do_deploy || return 1

  # 保存状态
  MODE='native'
  FLOW='xtls-rprx-vision'
  FINGERPRINT='chrome'
  # 状态没落盘就必须停在这里：继续往下走会打印「部署完成」面板，
  # 而 --status 会显示未部署、卸载流程拿不到端口 → 防火墙规则被遗留。
  save_state || { tui_err "状态保存失败，部署状态未落盘。"; return 1; }

  # 客户端物料
  tui_section "客户端物料"
  # 同理：物料导出失败必须报错退出，不能让「部署完成」面板指向不存在的 client.json。
  export_client_artifacts "$OUT_DIR" "$UUID" "$SERVER_IP" "$PORT" "$SNI" "$PUBLIC_KEY" "$SHORT_ID" "$REMARK" \
    || { tui_err "客户端物料导出失败。"; return 1; }

  local link
  link=$(build_share_link "$UUID" "$SERVER_IP" "$PORT" "$SNI" "$PUBLIC_KEY" "$SHORT_ID" "$REMARK")
  # 生成为空说明参数不全（缺 UUID/公钥/地址）→ 空的分享链接框用户会直接复制走，
  # 粘到客户端就是一条废链接。必须报错退出。
  [[ -n "$link" ]] || { tui_err "分享链接生成为空，部署结果不可用。"; return 1; }
  # 防火墙那一行必须如实反映 do_deploy ⑤ 的结果。
  local fw_row="已放行 $PORT/tcp"
  [[ "${FIREWALL_OK:-1}" -eq 1 ]] || fw_row="放行失败，请手工放行 $PORT/tcp"
  tui_panel "部署完成" \
    "地址|$SERVER_IP:$PORT" \
    "UUID|$UUID" \
    "SNI|$SNI" \
    "公钥 pbk|$PUBLIC_KEY" \
    "ShortID sid|$SHORT_ID" \
    "防火墙|$fw_row" \
    "客户端配置|$OUT_DIR/client.json" \
    "二维码|$OUT_DIR/qrcode.png"

  tui_box "分享链接（可直接粘贴到客户端导入）"
  tui_box_line "$link"
  tui_box_end

  if [[ -f "$OUT_DIR/qrcode.txt" ]]; then
    tui_section "终端二维码"
    cat "$OUT_DIR/qrcode.txt"
  fi

  if [[ ${OPT_YES:-0} -eq 0 ]]; then
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
- Modify: `install.sh`（删除 `management_menu` / `deploy_wizard` 的占位实现）
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
  # 生成为空说明参数有问题（缺 UUID/公钥/地址）→ 必须报错，不能展示一片空白。
  [[ -n "$link" ]] || { tui_err "分享链接生成为空，状态文件可能不完整。"; return 1; }
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
  # 依赖装不上就必须停在这里：继续往下走会下载安装脚本、失败，
  # 报出来的却是「下载失败」——错误信息与真实原因无关。
  ensure_packages curl ca-certificates || { tui_err "依赖安装失败，无法更新 Xray。"; return 1; }
  local installer
  # mktemp 可能失败（磁盘满 / 目录不可写）→ 拿到空路径后 curl -o "" 会失败，
  # 而且 rm -f "" 会报 "cannot remove ''"。必须先守卫。
  installer=$(mktemp 2>/dev/null)
  if [[ -z "$installer" ]]; then
    tui_err "无法创建临时文件，更新中止。"
    return 1
  fi
  curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh -o "$installer" || {
    tui_err "下载安装脚本失败"; rm -f "$installer"; return 1; }
  chmod +x "$installer" || { tui_err "无法设置安装脚本权限"; rm -f "$installer"; return 1; }
  tui_run "更新 Xray 内核" bash "$installer" install
  local rc=$?
  rm -f "$installer"
  [[ $rc -eq 0 ]] && restart_service
  return $rc
}

menu_tune() {
  # 不能用 `|| true` 吞掉失败：防火墙没放行、BBR 没开，
  # 用户却只看到 service_status 的输出 → 以为调优成功了。
  # 两个动作互相独立，所以各自报错、最后统一返回。
  local rc=0
  open_firewall "$PORT" || { tui_err "防火墙放行失败，请检查 ufw/iptables/nft。"; rc=1; }
  enable_bbr || { tui_warn "BBR 未启用（内核不支持或权限不足），不影响部署可用性。"; }
  service_status
  return $rc
}

menu_rotate_keys() {
  state_exists || { tui_warn "尚未部署，无密钥可轮换"; return 1; }
  # load_state 自 Task 3 修复轮 1 起会对损坏的状态文件返回非零 → 必须检查，
  # 否则会用空值渲染出一份非法配置，再被 xray 校验拒绝，报错与真实原因无关。
  load_state || { tui_err "状态文件读取失败，无法轮换密钥。"; return 1; }
  tui_confirm "轮换密钥与 UUID 会使所有旧客户端失效，继续？" "n" || { tui_info "已取消"; return 0; }
  gen_keys || return 1
  local cfg
  cfg=$(mktemp 2>/dev/null)
  if [[ -z "$cfg" ]]; then
    tui_err "无法创建临时文件，密钥轮换中止。"
    return 1
  fi
  render_server_config "$cfg" "$UUID" "$PRIVATE_KEY" "$SNI" "$PORT" "$SHORT_ID" || { rm -f "$cfg"; return 1; }
  # 与 do_deploy 走同一个入口：write_config_atomic（校验 → 原子替换 → 600）
  write_config_atomic "$XRAY_CONFIG" "$cfg" || { rm -f "$cfg"; return 1; }
  rm -f "$cfg"
  save_state || { tui_err "状态保存失败"; return 1; }
  restart_service || return 1
  # 物料导出失败必须报错：否则「密钥已轮换」这条提示会让人以为
  # client.json / link.txt 已经是新的，实际还是旧的（甚至根本没生成）。
  export_client_artifacts "$OUT_DIR" "$UUID" "$SERVER_IP" "$PORT" "$SNI" "$PUBLIC_KEY" "$SHORT_ID" "$REMARK" \
    || { tui_err "客户端物料导出失败，密钥已轮换但客户端文件未更新。"; return 1; }
  tui_ok "密钥已轮换，请使用新的分享链接更新客户端"
}

menu_uninstall() {
  # 单文件分发版（dist/install.sh）里没有 uninstall.sh → exec 会失败并让菜单崩掉。
  if [[ ! -x "$ROOT_DIR/uninstall.sh" ]]; then
    tui_warn "当前目录没有 uninstall.sh（单文件分发版不含卸载脚本）。"
    tui_tip "请手动执行：systemctl disable --now xray && rm -f $XRAY_CONFIG"
    return 1
  fi
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
git add lib/deploy.sh install.sh test/unit.sh test/helpers/
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
  # 备份失败时【绝不能】继续删原配置：否则用户的服务端配置直接丢失、
  # 且没有任何可回滚的副本。备份失败就停在这里，让用户自己决定。
  if ! mkdir -p "$OUT_DIR/backup"; then
    tui_err "无法创建备份目录：$OUT_DIR/backup"
    tui_err "为避免丢失配置，未删除原配置：$XRAY_CONFIG"
    exit 1
  fi
  backup_file="$OUT_DIR/backup/config.json.$(date +%Y%m%d%H%M%S)"
  if ! cp -f "$XRAY_CONFIG" "$backup_file"; then
    tui_err "备份配置失败：$XRAY_CONFIG"
    tui_err "为避免丢失配置，未删除原配置。请检查 $OUT_DIR 的剩余空间与权限。"
    exit 1
  fi
  if ! rm -f "$XRAY_CONFIG"; then
    tui_err "备份已保存到 $backup_file，但原配置删除失败：$XRAY_CONFIG"
    exit 1
  fi
  tui_ok "配置已备份并移除：$backup_file"
fi

tui_section "撤销防火墙规则"
# 必须用 load_state（Task 3 提供的唯一读状态入口），不要直接 `. "$STATE_FILE"`：
#   ① 直接 source 会把状态文件【执行】一遍（Task 3 修复轮 2 刚把这条改掉）；
#   ② 没有语法检查，状态文件损坏时报错与真实原因无关；
#   ③ load_state 能区分「读不到」与「格式错」。
PORT=''
if [[ -f "$STATE_FILE" ]]; then
  load_state || tui_warn "状态文件读取失败，无法确定端口（防火墙规则可能残留）。"
  PORT="${PORT:-}"
fi
if [[ -n "$PORT" ]]; then
  if have_cmd ufw && ufw status 2>/dev/null | grep -q 'Status: active'; then
    # 失败必须有提示：静默跳过会让人以为规则已撤销，实际还开着。
    if ufw delete allow "$PORT/tcp" >/dev/null 2>&1; then
      tui_ok "已撤销 ufw 规则 $PORT/tcp"
    else
      tui_warn "ufw 规则 $PORT/tcp 撤销失败（可能本来就没有该规则）。"
    fi
  elif have_cmd iptables; then
    # 必须数一数真删了几条：循环一次都没进也报「已撤销」就是谎报成功。
    local ipt_removed=0
    while iptables -C INPUT -p tcp --dport "$PORT" -j ACCEPT 2>/dev/null; do
      iptables -D INPUT -p tcp --dport "$PORT" -j ACCEPT 2>/dev/null || break
      ipt_removed=$((ipt_removed + 1))
    done
    if (( ipt_removed > 0 )); then
      tui_ok "已撤销 iptables 规则 $PORT/tcp（$ipt_removed 条）"
    else
      tui_warn "未找到 iptables 规则 $PORT/tcp（可能本来就没有）。"
    fi
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
# 提取不到就报错退出：静默回落成 0.0.0 会让产物带着错误的版本号发布出去，
# 而 CI 的 dist 同步校验只比对内容、不会发现版本号是错的。
if [[ -z "$VERSION" ]]; then
  printf '无法从 lib/core.sh 提取 APP_VERSION，构建中止。\n' >&2
  exit 1
fi

# 先确认 4 个源文件都在：缺文件时 sed 会报一句晦涩的 "No such file or directory"，
# 没人看得出是哪个文件缺了。
for f in tui.sh core.sh client.sh deploy.sh; do
  if [[ ! -f "$ROOT/lib/$f" ]]; then
    printf '缺少源文件：lib/%s\n' "$f" >&2
    exit 1
  fi
done

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
#
# 注意：此处【不能】嵌入构建时间戳。CI 用
#   bash build.sh && git diff --exit-code dist/install.sh
# 来校验「dist 与源码同步」——一旦产物里带时间戳，每次构建都不同，
# 这条校验【永远失败】。构建时间以 git 提交时间为准。
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

chmod +x "$tmp" || { printf '无法设置可执行权限：%s\n' "$tmp" >&2; rm -f "$tmp"; exit 1; }
mv -f "$tmp" "$OUT" || { printf '无法写入产物：%s\n' "$OUT" >&2; rm -f "$tmp"; exit 1; }
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
          find . -name '*.sh' -not -path './.git/*' -not -path './.worktrees/*' -print0 | xargs -0 -n1 bash -n

      - name: ShellCheck
        run: |
          sudo apt-get update -qq
          sudo apt-get install -y -qq shellcheck
          # 用 find 而不是写死文件名：写死 uninstall.sh / demo.sh 的话，
          # 在这两个文件还没创建的提交上跑 CI 必然失败（shellcheck 找不到文件就退出非零）。
          # dist/ 是构建产物，不重复检查。
          find . -name '*.sh' -not -path './.git/*' -not -path './.worktrees/*' \
               -not -path './dist/*' -print0 | xargs -0 -r shellcheck --severity=warning

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

# 必须给 demo.sh 接上 </dev/null：demo.sh 会调用 tui_menu / tui_input /
# tui_confirm，这三个在【非 TTY 分支里仍然 read stdin】。
# 不接 /dev/null 时，本地交互式跑测试（stdin 是终端）会直接挂死。
out=$(bash "$ROOT/demo.sh" </dev/null 2>&1)
assert_status 0 "$?" "demo.sh 正常退出"
assert_contains "$out" "分享链接" "demo 展示分享链接样例"
assert_eq 0 "$(grep -c 'systemctl ' <<<"$out")" "demo 不调用 systemctl"
assert_eq 0 "$(grep -c 'apt-get' <<<"$out")" "demo 不调用 apt-get"
# 只看输出不够：demo.sh 若把命令输出重定向到 /dev/null，上面的断言就漏掉了。
# 再直接查一次 demo.sh 的源码。
assert_eq 0 "$(grep -cE '^[^#]*(systemctl|apt-get|ufw|iptables|nft|rm -f|systemctl disable)' "$ROOT/demo.sh" || true)" \
  "demo.sh 源码里不含任何改系统的命令"
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
  echo "==> [SKIPPED] 容器内端到端部署未通过：普通容器没有 systemd，属预期。"
  echo "==>          这一段必须在真机或 --privileged 容器里验证；本仓库的 CI 不覆盖它。"
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
- **验证状态声明**（**必须逐条列出**下面这 5 项未验证内容，不得含糊成一句「仅供参考」；
  同时列出已验证的项，让读者能自己判断哪些结论可信）
  1. **权限位 600/700 未在 Debian 真机验证** —— 开发环境是 Windows + Git Bash，
     它的 `chmod` 是**模拟**的（`stat -c '%a'` 恒为 644），所以
     「状态文件 600 / 状态目录 700 / 客户端导出目录 700 / 客户端物料文件 600」
     这些权限位断言在开发机上会**自动跳过**，只有 Debian 真机上才会真正执行。
  2. **`urlencode` 的 python3 分支的覆盖范围** —— python3 是**可选依赖**，
     所以这一项分两层写清楚：
     (a) **mock 基准层**（任何机器都会执行）：一条用**独立算法**（按字节取十六进制码）
         算出来的 mock python3，与回退分支的结果**逐字节比对** ——
         两条独立路径算出同一个串才算通过，因此不依赖 python3 是否存在；
     (b) **真实分支层**（受「功能可用守卫」控制）：只有
         `python3 -c 'import sys,urllib.parse'` 成功时才拿真实 python3 的输出
         与回退分支对比；不可用时登记一条说明（**不断言失败**）。
     → 目标机若没装 python3，只有 (a) 生效；(b) 是否执行取决于目标机。
     （开发机上 python3 的可用性是**会变的** —— 本条不把任何机器的现状写成既定事实。）
  3. **`detect_os` 对真实 `/etc/os-release` 未验证** —— 单元测试只用临时构造的
     os-release 文件（含 CRLF 变体），没有对真实系统文件跑过。
  4. **`assert_debian` 的真机判定未验证** —— 单元测试覆盖的是构造出来的假 os-release；
     真实 Debian 上 `ID=debian` / `VERSION_ID` 的判定结果尚未实测。
  5. **shellcheck 未在本机运行** —— 开发环境没有 shellcheck，
     GitHub Actions 的 shellcheck 步骤**尚未实际执行过**（仓库还没在远端跑过 CI）。

  必须同时写明**整体**验证边界：
  **Debian 真机端到端部署尚未在本开发环境验证** —— 开发环境是 Windows + Git Bash，
  没有 Debian、没有 Docker、没有真 TTY。因此以下环节**都没有**在真实目标机上跑过：
  `apt-get` 安装 Xray-core、systemd 单元的启停、防火墙放行（ufw/iptables/nft）、
  REALITY 握手、真实终端下的 TUI 交互与按键响应。
  **已验证**的只有：所有 `.sh` 的 `bash -n` 语法检查、`bash test/unit.sh` 单元测试全部通过、
  以及用 `TUI_TTY=1` + 管道喂按键模拟真终端的 TUI 渲染与交互路径。
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
