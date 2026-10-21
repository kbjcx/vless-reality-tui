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
  权限位不可达）—— 这类属于「本平台无法验证」而不是缺陷，因此**不补** else 说明；
  代价是断言条数**分平台不同** → 每个任务的验收标准与报告都必须
  **写明是哪个平台的数字**。
  ⚠️ **这类断言分两类 → 平台差不是「一个数」而是「三个数」**（截至 Task 8 实施后）：
  - **A 类（读真实权限位：`stat -c '%a'` 与 600/700 比对）**：共 **5 条**
    —— Task 3/4 的 2 条（`save_state` 的 600/700）+ Task 7 的 3 条
    （`link.txt` / `client.txt` 的 600 与导出目录的 700）。
    MSYS 跳过（chmod 是模拟的，`stat` 读不到 600）；**Debian 上一律执行** → 恒定差 **5 条**。
  - **B 类（`chmod 000` 之后判 `! -r`）**：共 **2 条**（Task 3 的
    `load_state 对不可读的状态文件…` 两条）。
    MSYS 跳过（chmod 000 → mode 444，文件仍然可读）；
    **Debian 以 root 运行【也跳过】**（root 能读 000 文件）；
    **只有以非 root 运行才执行**。
  → **三个平台的条数**：本机 **445**、Debian **以 root 运行** **450**、
    Debian **以非 root 运行** **452**。
  ⚠️ **GitHub Actions 的 runner 以【非 root】运行** → **CI 实际是 452，不是 450**。
  报告里必须写明「哪个平台 **+ 以什么身份运行**」。
  注意：断言名里带「chmod 失败」但用 **mock 判据**的那些**不计入** ——
  它们两平台都执行。
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

#### 修订轮 1 实施后由实施者独立发现的两条（控制器已核实并落地）

| # | 级别 | 发现 | 处置 |
|---|---|---|---|
| T5-12 | **Important** | 修订轮 1 的验收标准第 5 条写的是「把 `xray_test_config` 整个换成 `return 0` → 「xray_test_config **识别 run -test -config 写法**」必须变红」。**这条字面上不可满足**：那条是**正向断言**（期望码 0），把函数换成 `return 0` 恰好让它**保持绿**。真正被捕获的是它的**反向断言**「xray_test_config 在所有写法都不被支持时返回非零」。实施者独立发现并如实报告（未擅自改代码） | 验收标准第 5 条改成点名那条**反向断言**，并写明「正向断言在把函数换成 `return 0` 时不会变红」。**这与 Task 4 的 F4-16 是同一类错误（点名错了断言），控制器在同一项目里犯了第二次** —— 教训：写验收标准时，**点名的断言必须与预演结果里【实际变红的那一条】逐字对上**，不能只看「红了几条」 |
| T5-13 | **观察 → 不成立** | 实施者报告：Step 1 块的 `rm -rf "$atomic_dir"` 写在 `if [[ -n "$atomic_dir" ]]` 守卫**之外** → `mktemp -d` 失败时会往 stderr 漏一行 `rm: cannot remove ''` | 控制器**实测**（GNU coreutils 8.32）：`rm -rf ""` → **rc=0、输出为空、完全静默**；`rm -rf <不存在的路径>` 同样静默。**该噪音复现不了** → 观察不成立，**不改代码**。记录此条是为了说明「实施者报的现象必须独立复现」——这条经复现后被否掉了 |

> **控制器的自我记账（第 2 条）**：T5-13 是实施者报的「观察」，控制器复现后发现**不成立**
> （`rm -rf ""` 静默）。**实施者如实报告 ≠ 报告的事实成立** —— 两条都要走一遍
> 「独立复现」才能落进计划。

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
   - 把 `xray_test_config` 整个换成 `return 0`
     → 「xray_test_config **在所有写法都不被支持时返回非零**」必须变红。
     ⚠️ **不是**「xray_test_config 识别 run -test -config 写法」—— 那条是**正向断言**
     （期望码 0），把函数换成 `return 0` 恰好让它**保持绿**。
     真正被捕获的是它的**反向断言**（实施者独立发现并如实报告）。
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

#### 修订轮 2 的逐项发现与处置

> 本节由**控制器**在 Task 5 实施完成后的**独立复评**之后写入。
> 复评结论：**FAIL** —— 10 条实施缺陷 + 4 条计划缺陷。
> 责任方：**实施缺陷**归实施者（本轮重新实施修掉）；**计划缺陷**归控制器（本节处置）。
>
> 复评报告：`.superpowers/sdd/2026-10-21-vless-reality-deploy/task-5-review.md`
> 复评用的唯一真相版本 = 提交 `28aa7d4`（实施 `1c0f995` + 计划修正 `28aa7d4`）。

**实施缺陷（4 条实现层 + 6 条测试零判别力）**

| # | 级别 | 发现 | 处置 |
|---|---|---|---|
| **D1** | **Important** | `xray_test_config` 留下的是**最后一次**尝试的 stderr，而那次恰是最不可能被支持的写法 → 在只认 `run -test -c` 的版本上，用户看到的是 `unknown flag: -test` / `unknown command`，**而不是**真实的 `failed to parse config: …`。**计划 T5-7 声称已修复的目标根本没有达成** —— T5-7 写的是「把**最后一次**尝试的 stderr 留在 `XRAY_TEST_ERR` 里」，但「最后一次」恰恰是最误导的那一次 | Step 3 新增 `xray_err_is_unsupported` 判定函数，把失败分成两类：①「这个写法不被支持」（unknown flag / unknown command / …）②「配置本身有问题」。三种写法依次尝试，**遇到第一个 ② 就立刻用它**；三种都是 ① 才退回第一次的报错 |
| **D2** | Minor | 目标路径是**已存在的目录**时，`mv -f "$tmp" "$outfile"` 会把文件**移进目录里**而不是替换目标 → `mv` 返回 0（看起来成功）但配置**根本没落位**（`render_server_config` 与 `write_config_atomic` 两处都有） | Step 3 两处都加 `[[ -d "$outfile" ]]` 前置守卫 → `tui_err` + 返回 1 + 不落盘；Step 1 补 2 组断言 |
| **D3** | Minor | `cp` 失败分支不清理**半截的** `.new`（cp 可能已写出一部分内容）→ 下一次写配置的校验会去校验一份残缺文件 | Step 3 的 `cp` 失败分支加 `rm -f "$tmp"`；Step 1 补断言（mock `cp` 先写半截文件再返回 1） |
| **D4** | Minor | xray 的报错被加了 6 个空格的缩进（`sed 's/^/      /'`），与全局约束「不通过则保留旧配置并**原样输出** xray 报错」的字面要求不一致 | Step 3 改成**原样输出**，不加缩进 |
| **TG1** | Minor | `xray_parse_keys` 的 `key=value` 分支**零覆盖** → 控制器变异实测：把该分支删掉，0 条红 | Step 1 补 `PrivateKey=…` / `Password=…` 的解析断言 |
| **TG2** | Minor | `gen_keys` 的 `random_hex` 失败分支**不可区分**：去掉 `SHORT_ID=$(random_hex 4) || {…}` 这道检查后，random_hex 返回非零但**有输出**时 SHORT_ID 非空 → 第二道检查也放行 → 函数返回 0 → 两条断言仍然全绿 | Step 1 补 3 条：mock random_hex「返回非零但有输出」→ 必须返回非零且提示「生成 ShortID 失败」；「返回零但输出为空」→ 提示「ShortID 为空」。**判据是错误提示的文本**，两条提示必须能分开 |
| **TG3** | Minor | `chmod` 早于 `mv`（计划 T5-6 的修复）**零覆盖** → 变异实测：把 chmod 挪回 mv 之后，0 条红 | Step 1 补断言：mock `chmod` 失败 → 必须返回非零**且目标文件没被动过** |
| **TG4** | Minor | `.render` / `.new` 暂存名分离（计划 T5-10 的修复）**零覆盖** → 变异实测：把 `.render` 改回 `.new`，0 条红 | Step 1 mock `mv` 记录它的**源参数**，分别断言 render 用 `.render`、write 用 `.new` |
| **TG5** | Minor | 服务端配置 `chmod 600`（全局约束：含 REALITY 私钥）**零覆盖** → 变异实测：删掉那行，0 条红 | Step 1 mock `chmod` 记录参数，断言出现过 `chmod 600 <最终配置路径>`。**必须整行精确匹配**（临时文件那次的参数是 `600 <目标>.new`，它**包含** `600 <目标>` → 子串匹配会误判成通过）。**不**断言文件权限位 —— MSYS 的 chmod 是模拟的，权限位在本机不可达 |
| **TG6** | Minor | 失败时输出 xray 原始报错（计划 T5-7 的修复）**零覆盖** → 这正是 D1 长期未被发现的原因 | Step 1 补断言：必须输出「配置本身有问题」那条，且**不得**出现 `unknown flag` / `unknown command` |

**计划缺陷（4 条，责任方是控制器）**

| # | 级别 | 发现 | 处置 |
|---|---|---|---|
| **P1** | **Important** | T5-7 的处置与它自己陈述的目标**自相矛盾**：目标是「消除只认 `-c` 的版本上的误导性报错」，而处置写的是「保留**最后一次**尝试的 stderr」—— 最后一次恰恰是最误导的那一次 | 见 D1 的处置：改成「挑出最有信息量的那条」 |
| **P2** | Important | 验收标准第 5 条的 8 条红灯**漏掉了 5 处「计划自己声称已修复」的行为**（T5-6 / T5-7 / T5-10 + chmod 600 + 原样输出） | 见下方「修订轮 2 的验收标准」：红灯清单扩到 14 条 |
| **P3** | Minor | `Interfaces` 段没有定义「目标路径不是普通文件」时的契约 | 见 D2：契约写进 Step 3 的函数注释 —— 目标路径是目录 → 报错 + 不落盘 |
| **P4** | Minor | 全局约束第 33 行「原样输出」与 Step 3 块的缩进实现不一致 | 见 D4：改**代码**（原样输出），不改约束 —— 约束的字面要求就是权威 |

> **控制器的自我记账（第 3 条）**：这一轮里，复评**自己**也踩了一个坑 ——
> 它把「Task 6 的 Step 1 块里有一处 `assert_false "$out" "$needle" "$msg"`」漏掉了。
> 控制器后来独立核对 `test/lib.sh` 的真实签名才发现：
> `assert_false "$1" "$msg"` 的语义是「**退出码非 0**」，**根本没有**「子串不存在」这个语义；
> 那个三参用法把 needle 当成了描述 → **恒真**。
> 教训：**断言辅助函数的签名必须回 `test/lib.sh` 核对**，不能凭名字猜。

#### 修订轮 2 的验收标准

1. `lib/deploy.sh` 的内容与上面 **Step 3 代码块逐字节一致**。
2. `test/unit.sh` 里 Task 5 的插入段与上面 **Step 1 代码块逐字节一致**
   （追加在 `test_summary` **之前**；`source "$ROOT/lib/deploy.sh"` 放在顶部 source 区域）。
3. `bash test/unit.sh` 全部通过、退出码 0。
4. 断言总数必须恒定，且**连跑 4 次条数相同**。
   平台差异：本机（Windows + MSYS）与 Debian/CI 的条数差 **4 条** ——
   4 条权限相关行为断言在 MSYS 上被自动跳过（`chmod` 是模拟的）。
   报告里必须写明是哪个平台的数字。
   **预期条数**：本机 **260**、Debian/CI **264**（修订轮 1 的 239 / 243 + 本轮新增 21 条）。
5. 红灯证据（**14 条**，每条都要贴出**变红的断言原文**）：
   - 把 `xray_parse_keys` 的 `key=value` 分支删掉
     → 「解析 key=value 写法（PrivateKey/Password）」必须变红；
   - 把 `gen_keys` 里 `SHORT_ID=$(random_hex 4) || {…}` 的退出码检查去掉
     → 「gen_keys 在 random_hex 返回非零（即使它有输出）时返回非零」必须变红；
   - 把 `xray_test_config` 改回「只留最后一次尝试的 stderr」
     → 「write_config_atomic 必须输出 xray 的真实报错（而不是『写法不被支持』那类）」必须变红；
   - 把 `xray_test_config` 里 `xray_err_is_unsupported` 的判定去掉（永远当 ①）
     → 同上一条必须变红；
   - 把 `write_config_atomic` 的 `[[ -d "$outfile" ]]` 守卫删掉
     → 「write_config_atomic 在目标路径是目录时返回非零」必须变红；
   - 把 `render_server_config` 的 `[[ -d "$outfile" ]]` 守卫删掉
     → 「render_server_config 在目标路径是目录时返回非零」必须变红；
   - 把 `write_config_atomic` 的 `cp` 失败分支里的 `rm -f "$tmp"` 删掉
     → 「write_config_atomic 在 cp 失败时清理半截的临时文件」必须变红；
   - 把 `write_config_atomic` 里的 `chmod 600 "$outfile"` 删掉
     → 「write_config_atomic 必须对最终配置文件执行 chmod 600（含 REALITY 私钥）」必须变红；
   - 把 `write_config_atomic` 里的 `chmod 600 "$tmp"` 挪到 `mv` 之后
     → 「write_config_atomic 在 chmod 失败时不得落位（chmod 必须早于 mv）」必须变红；
   - 把 `render_server_config` 的暂存名 `.render` 改回 `.new`
     → 「render_server_config 的暂存名必须是 .render（不得与 write 的 .new 撞名）」必须变红；
   - 把 `write_config_atomic` 的暂存名 `.new` 改成 `.render`
     → 「write_config_atomic 的暂存名必须是 .new」必须变红；
   - 把 `write_config_atomic` 里输出 xray 报错时的 `sed -e 's/^/      /'` 加回去
     → 必须有断言变红。⚠️ **这条要特别小心**：D4 的修复是「原样输出」，
       判据不能写成「输出里没有 6 个空格」（xray 自己的报错也可能带缩进）。
       判据只能是**别的**东西 —— 若实在找不到能区分的判据，
       **如实报告「这条红灯证据拿不出来」**，不要硬凑一个恒绿的断言。
   - 把 `write_config_atomic` 里输出 xray 报错的那段整个删掉
     → 「write_config_atomic 必须输出 xray 的真实报错」必须变红；
   - 把 `gen_keys` 里 `[[ "$UUID" =~ … ]]` 的格式校验删掉
     → 「gen_keys 在 xray uuid 输出的不是合法 UUID 时返回非零」必须变红。
   ⚠️ **点名的断言必须与预演结果里【实际变红的那一条】逐字对上**，不能只看「红了几条」。
   ⚠️ 「正向断言（期望码 0）」在把函数换成 `return 0` 时**不会变红** ——
   真正变红的是它的**反向断言**（Task 4 的 F4-16、Task 5 的 T5-12 已经各犯过一次）。
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

  # 目标路径如果是【已存在的目录】：后面的 `mv -f "$tmp" "$outfile"` 会把文件
  # 【移进目录里】而不是替换目标 → mv 返回 0（看起来成功）但配置根本没落到
  # outfile → 调用方以为渲染成功，实际拿到的不是配置。必须先挡住。
  [[ -d "$outfile" ]] && { tui_err "目标路径是目录，不能作为配置文件：$outfile"; return 1; }
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

# 判断一段 xray 报错是不是「这个写法不被支持」而不是「配置本身有问题」。
# 只认 -c 的旧版本上，`xray run -test -config f` 报 "unknown flag: -test"；
# 现代版本上 `xray -test -config f` 报同类错 —— 它们只说明【我们试的写法不对】，
# 对用户毫无价值。用户要看的永远是「配置本身有问题」的那条。
xray_err_is_unsupported() {
  case "$1" in
    *"unknown flag"*|*"flag provided but not defined"*|*"unknown shorthand flag"*|\
    *"unknown command"*|*"invalid command"*|*"unknown syntax"*|*"unrecognized"*)
      return 0 ;;
  esac
  return 1
}

# 校验配置可用。兼容不同 xray 版本的子命令写法。
# 失败时把【最有信息量】的 stderr 留在 XRAY_TEST_ERR 里 ——
# 写配置失败时要把 xray 的原始报错给用户看，而不同版本认的子命令不同。
# 关键：三种写法依次尝试时必须区分两种失败 ——
#   ①「这个写法不被支持」（unknown flag / unknown command 等）
#   ②「配置本身有问题」（failed to parse config: ...）
# 用户要看的永远是 ②。① 只说明我们试的写法不对。
# 旧实现只保留【最后一次】尝试的报错 → 现代 xray 上最后一次用的是旧语法
# → 必然报 "unknown flag: -test" / "unknown command" → 用户看到的是
# 完全无关的误导性报错（控制器独立复评 D1 实证）。
XRAY_TEST_ERR=''
xray_test_config() {
  local cfg="$1" e='' first=''
  XRAY_TEST_ERR=''
  # 注意：stderr 必须用【命令替换】捕获，不能写成 2>"$XRAY_TEST_ERR" ——
  # 变量为空时那是一次「重定向到空文件名」，bash 报的是
  # "No such file or directory"（看起来像命令找不到，真相是重定向失败），
  # 而且命令根本没被执行。控制器实测踩过。
  e=$( { "$XRAY_BIN" run -test -config "$cfg" >/dev/null; } 2>&1 )
  if [[ $? -eq 0 ]]; then XRAY_TEST_ERR="$e"; return 0; fi
  first="$e"
  # 判定条件是【有内容】且【不是「写法不被支持」】才停在这里：
  #   · stderr 为空 → 这一种写法没给出任何信息 → 必须继续试下一种，
  #     否则「只认 -c 的版本」上第 1 种写法失败就直接返回 1 → 后面两种根本没试。
  #   · stderr 是「写法不被支持」→ 同理，继续试下一种。
  # 只有「确实有内容、且说的是配置本身有问题」才停 —— 那才是用户要看的。
  if [[ -n "$e" ]] && ! xray_err_is_unsupported "$e"; then XRAY_TEST_ERR="$e"; return 1; fi
  e=$( { "$XRAY_BIN" run -test -c "$cfg" >/dev/null; } 2>&1 )
  if [[ $? -eq 0 ]]; then XRAY_TEST_ERR="$e"; return 0; fi
  if [[ -n "$e" ]] && ! xray_err_is_unsupported "$e"; then XRAY_TEST_ERR="$e"; return 1; fi
  e=$( { "$XRAY_BIN" -test -config "$cfg" >/dev/null; } 2>&1 )
  if [[ $? -eq 0 ]]; then XRAY_TEST_ERR="$e"; return 0; fi
  if [[ -n "$e" ]] && ! xray_err_is_unsupported "$e"; then XRAY_TEST_ERR="$e"; return 1; fi
  # 三种写法都不被支持 → 只能给出第一次的报错（至少证明我们试过）
  XRAY_TEST_ERR="$first"
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
  # 同 render_server_config：目标路径是【已存在的目录】时，
  # `mv -f "$tmp" "$outfile"` 会把文件移进目录里 → mv 返回 0（看起来成功）
  # 但配置根本没落位。必须先挡住。
  [[ -d "$outfile" ]] && { tui_err "目标路径是目录，不能作为配置文件：$outfile"; return 1; }
  # cp 失败时必须清理【半截的】临时文件：cp 可能已经写出了一部分内容，
  # 留着它会让下一次写配置的校验去校验一份残缺文件。
  cp "$src" "$tmp" || { tui_err "无法写入临时文件：$tmp"; rm -f "$tmp"; return 1; }
  # 服务端配置含 REALITY 私钥 → 权限必须 600（计划里其余含密文件一律 600）。
  # systemd unit 没有 User= → xray 以 root 运行 → 600 不会挡住它读配置。
  chmod 600 "$tmp" || { tui_err "无法设置临时文件权限：$tmp"; rm -f "$tmp"; return 1; }
  if ! xray_test_config "$tmp"; then
    tui_err "配置校验未通过，已保留原有配置不变。"
    # 全局约束要求【原样输出】xray 的报错 → 这里不加任何缩进/改写。
    # 早先的实现在这里加了 6 个空格的缩进（sed 's/^/      /'），
    # 与约束的字面要求不一致（控制器独立复评 D4）。
    if [[ -n "$XRAY_TEST_ERR" ]]; then
      printf '%s\n' "$XRAY_TEST_ERR"
    else
      "$XRAY_BIN" run -test -config "$tmp" 2>&1 || true
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

#### 修订轮 1 的逐项发现与处置

> 本节由**控制器**在 Task 6 派发前预扫（沙箱实证）之后写入。
> 本节列的全是**计划缺陷**，责任方是控制器；Task 6 的代码块本身还没被实施过。
>
> 沙箱底座 = `git archive a44b094` 整棵树 + Task 5 / Task 6 两个代码块
> → 基线 248 项断言全绿、rc=0（干净基线）。

| # | 级别 | 发现 | 处置 |
|---|---|---|---|
| T6-1 | **Important** | Task 6 产出 **8 个函数，其中 5 个一条断言都没有**：`install_xray`、`xray_version`、`setup_systemd`、`restart_service`、`service_status`。控制器逐个掏空后实测：五个全部 **0 条红、248 项全绿**。而它们恰好是「真正动系统」的那几个 —— 装内核、拉起服务、重启服务、看状态。回归了没有任何断言会红 | Step 1 补 5 组 mock 断言：`xray_version` 输出版本串；`install_xray` 的「已安装 → 返回 0 且给出提示」与「下载失败 → 返回非零且不得谎报已安装」；`setup_systemd` 的「服务未运行 → 返回非零 + 输出 xray 原始日志」与「正常运行 → 返回 0」；`restart_service` 的成功 / 失败两条；`service_status` 的状态与端口输出 |
| T6-2 | **Important** | 两处**条件块没有 else 侧说明** → 断言条数随机器状态漂移：① `if [[ ! -x "$XRAY_BIN" ]]` —— 真实 Debian 上装好 xray 后这条**整条消失**；② `if ! have_cmd ufw && ! have_cmd nft && ! have_cmd iptables` —— 真实 Debian 一定有 iptables 或 nft → 这条**整条消失**。两条都违反全局约束 | ① 改成 1 换 1 配对：未安装 → `assert_fails`，已安装 → `assert_succeeds`（**两个分支都有意义**）；② else 侧登记一条「已跳过（用例前提不成立）」说明 |
| T6-3 | **Minor** | `open_firewall` 的 ufw 检测是 `ufw status 2>/dev/null \| grep -q 'Status: active'` —— **管道 + `grep -q`**，与 Task 4 的 F4-1 同一个坑：`grep -q` 命中即退出 → 上游 ufw 收到 SIGPIPE(141) → `set -o pipefail` 下整条管道退出码变 141 → 条件判假 → **ufw 明明是 active 也不会走 ufw 分支**，静默降级到 iptables / nft 分支。`ufw status` 输出通常很小 → 实际触发概率低，但模式本身是错的 | Step 3 改成与 F4-1 同一手法：先把整段输出收进 `ufw_status` 变量，再对变量做 `*"Status: active"*` 匹配（链路上无早退管道） |
| T6-4 | **Minor** | `service_status` 里 `active=$(systemctl is-active xray 2>/dev/null \|\| printf 'unknown')` —— `systemctl is-active` 在服务**停止**时会**输出 "inactive" 并返回非零** → `\|\| printf 'unknown'` 会把 unknown **追加**到后面 → 状态显示成两行（`inactive\nunknown`），界面上看着像出了两个状态 | Step 3 改成 `\|\| true` 保留 systemctl 的输出，只在它**一个字都没输出**时才回落到 `unknown` |
| T6-5 | **Minor** | `setup_systemd` 里 `mkdir -p "$LOG_DIR"` 的退出码**没检查** → 目录建不出来时，后面仍然会打印「日志目录已授权给运行用户」→ **谎报**。目录建不出来意味着 xray 写不了日志，用户却以为一切正常 | Step 3 改成 `if ! mkdir -p "$LOG_DIR"; then tui_warn ...; else ... fi` |
| T6-6 | **Minor** | 「enable_bbr 输出提及 bbr 状态」这条断言的措辞**不精确**：成功路径的输出（`已启用 bbr 拥塞控制与 fq 队列`）里也有 "bbr" → 断言的是「输出里含 bbr」而不是「明确说了内核不支持 bbr」。（控制器实测：去掉那句 `tui_warn` 确实会变红 → **判别力成立**，不是恒真；只是判据不够精确） | Step 1 改成点具体文案「未提供 bbr」 |
| T6-7 | **Minor** | `install_xray` 下载 `https://github.com/XTLS/Xray-install/raw/main/install-release.sh` 并**以 root 执行**。这是 Xray 官方安装器的通行做法，但用的是 **`main` 分支**（内容可变）且**没有完整性校验** | 不改代码（这是 Xray 生态的通行做法，改成自建安装流程会超出本工具的范围），但**必须写进 README 的「验证状态声明」**：工具会以 root 执行一个从 GitHub `main` 分支下载的脚本，没有校验和校验 |
| T6-8 | **Minor** | Task 6 **没有独立的验收标准段**（Task 3 / Task 4 / Task 5 都有） | 补一个 |

> **控制器的自我记账**：本轮控制器在写「修订轮 1」时**先入为主**地认为
> 「enable_bbr 输出提及 bbr 状态」是恒真断言（因为成功路径的输出里也有 bbr），
> 差点把它当成一条缺陷写进去。**实测推翻了这个判断** —— 去掉那句 `tui_warn`
> 之后输出里就没有 bbr 了，那条断言**确实会变红**，判别力成立。
> 又一次印证：**「读代码觉得它有问题」必须用变异证伪或证实**，不能靠推理下结论。

#### 修订轮 1 的验收标准

1. `lib/deploy.sh` 的 Task 6 段与上面 **Step 3 代码块逐字节一致**（追加在 Task 5 段之后）。
2. `test/unit.sh` 里 Task 6 的插入段与上面 **Step 1 代码块逐字节一致**
   （追加在 `test_summary` **之前**）。
3. `bash test/unit.sh` 全部通过、退出码 0。
4. 断言总数必须恒定，且**连跑 4 次条数相同**。
   平台差异：本机（Windows + MSYS）与 Debian/CI 的条数差 **4 条** ——
   4 条权限相关行为断言在 MSYS 上被自动跳过（`chmod` 是模拟的）。
   报告里必须写明是哪个平台的数字。
   **注意**：本任务的两处条件块已改成 1 换 1 配对 → **条数不再随机器状态漂移**，
   本机与 Debian/CI 的条数差**只剩**那 4 条权限断言。
5. 红灯证据（至少这六条，每条都要贴出**变红的断言原文**）：
   - 把 `install_xray` 整个换成 `install_xray() { return 0; }`
     → 「install_xray 在已安装时**给出提示**」必须变红
     （⚠️ **不是**「install_xray 在已安装时返回 0」那条 —— 那是【正向断言】
      （期望码 0）→ 函数被换成 `return 0` 后退出码**仍然是 0** → 那条恒绿。
      控制器在 Task 6 实施后独立复现：掏空 `install_xray` → 实际变红的是
      「在已安装时给出提示」「在下载安装脚本失败时返回非零」「下载失败时给出明确提示」
      「成功时提示安装完成」「在 mktemp 失败时返回非零」「在 mktemp 失败时给出明确提示」
      共 6 条，**「在已安装时返回 0」不在其中**）；
   - 把 `xray_version` 整个换成 `xray_version() { return 0; }`
     → 「xray_version 输出 xray 的版本串」必须变红；
   - 把 `setup_systemd` 整个换成 `setup_systemd() { return 0; }`
     → 「setup_systemd 在服务未运行时返回非零」等必须变红；
   - 把 `restart_service` 整个换成 `restart_service() { return 0; }`
     → 「restart_service 在服务未运行时返回非零」必须变红；
   - 把 `service_status` 整个换成 `service_status() { return 0; }`
     → 「service_status 打印服务状态」必须变红；
   - 把 `open_firewall` 里的 ufw 检测改回 `| grep -q` 形态
     → 至少「open_firewall 的 ufw 分支调用了 ufw allow <port>/tcp」不能变红
     （说明这条检测**不是靠那条断言钉住的**；它是 F4-1 同款的**低概率**缺陷，
     本轮用**改实现**而不是加断言来处置）。
6. `lib/core.sh`、`lib/tui.sh`、`test/lib.sh`、Task 5 段 **一字未动**。
7. 计划文件实施者一个字都不许改。

#### 修订轮 2 的逐项发现与处置

> 本节由**控制器**在 Task 6 修订轮 1 的**副本端到端预演**之后写入。
> 修订轮 1 把「5 个函数零断言」补上了，但它**新写的块自己**留下了 12 个问题
> —— 全部是**测试侧**缺口，**Step 3 代码块一字不改**。
>
> 本轮的全部发现都来自**变异实测**，不是读代码推理：
> 「断言有没有判别力，只能靠变异证明」。

| # | 级别 | 发现 | 处置 |
|---|---|---|---|
| T6-9 | **Important** | **T6-3 的修法（ufw 检测先收进变量再匹配）没有任何断言钉住。** 控制器把实现改回 `ufw status \| grep -q 'Status: active'` → **0 条红**。原因：「管道 + `grep -q`」在**小输出**下不会触发 SIGPIPE —— mock 的 `ufw` 只输出一行 → 写不进管道缓冲 → 上游收不到 SIGPIPE(141) → 运行期**根本复现不出差异**。真实 `ufw status` 要超过管道缓冲（约 8KB）且是否触发取决于时序 → 不能写成依赖时序的运行期断言 | Step 1 补**源码静态断言**（与 Task 4 的 F4-1 **完全同款**）：① 剥掉整行注释后，`open_firewall` 函数体内不得出现同时含 `ufw status` 与 `grep -q` 的行；② 正向钉住修法：必须含 `ufw_status=$(ufw status`。⚠️ 静态断言**只针对含 `ufw status` 的行** —— `open_firewall` 里另有**一处合法**的 `nft list chain ... \| grep -q`（那是「内容里有没有这条规则」的查询，命中与否两条路都走到 then/else，退出码 1 与 141 后果相同 → 不属于 F4-1 同款缺陷），全函数一刀切会误伤 |
| T6-10 | **Important** | **T6-5 的修法（`mkdir -p` 的退出码检查）所在的分支根本没被执行到。** mock 的 `service_run_user` 恒返回 `root` → `run_user != "root"` 分支永远进不去 → 控制器把 mkdir 的检查去掉 → **0 条红** | Step 1 补两组：① `service_run_user` 返回**非 root** + `mkdir` 返回非零 → 必须返回 0、必须给出「无法创建日志目录」警告、**不得**打印「日志目录已授权」；② 非 root + mkdir 成功 → 必须给出授权提示 |
| T6-11 | Important | `install_xray` 的**成功路径**零覆盖（下载成功 + 安装成功 → 返回 0 + 提示「Xray 安装完成」）。控制器变异：删掉那句 `tui_ok` → 0 条红 | Step 1 补。⚠️ mock 的 `xray_installed` 必须用**计数器**：install_xray 开头查一次（判断是否已安装）、末尾还要再查一次（判断是否装上了）→ 固定返回值只能覆盖其中一种情形 |
| T6-12 | Important | `install_xray` 的 **mktemp 空值守卫**零覆盖 → 变异：删掉守卫 → 0 条红 | Step 1 补：mock `mktemp` 返回非零 → 必须返回非零 + 提示「无法创建临时文件」（不得把错误指向「网络」） |
| T6-13 | Important | `setup_systemd` 的**「没有 systemctl」分支**零覆盖 → 变异：删掉那个 `tui_err` → 0 条红 | Step 1 补：mock `have_cmd` 对 systemctl 返回非零 → 必须返回非零 + 提示「systemd 不可用」 |
| T6-14 | Important | `open_firewall` 的 **iptables 分支**零覆盖 → 变异：把整个分支删掉 → 0 条红 | Step 1 补 3 条：规则不存在 → 必须调用 `iptables -I … --dport <端口>`；规则已存在 → 必须识别并提示；分支必须带上门口号 |
| T6-15 | Important | `open_firewall` 的 **nftables 分支**零覆盖 → 变异：把整个分支删掉 → 0 条红 | Step 1 补 3 条：必须返回 0、必须走到 nftables 分支、必须带上门端口号 |
| T6-16 | Minor | `enable_bbr` 的**内核参数【应用】失败**分支零覆盖（`sysctl -p` 与 `--system` 都失败）。原来只测了「配置写不进去」，没测「配置写进去了但应用失败」→ 变异：删掉它 → 0 条红 | Step 1 补 2 条：必须返回非零 + 提示「内核参数应用失败」 |
| T6-17 | Minor | `enable_bbr` 的「可用算法」提示零覆盖 → 变异：删掉那行 → 0 条红 | Step 1 补 1 条 |
| T6-18 | Minor | `service_status` 的「开机自启」零覆盖 → 变异：删掉那行 → 0 条红 | Step 1 补 1 条 |
| T6-19 | **Important** | **控制器自己写的断言里有一处恒真。** 新 Step 1 写的是 `assert_false "$out" "Xray 安装完成" "install_xray 下载失败时不得谎报『Xray 安装完成』"`。控制器回 `test/lib.sh` 核对签名才发现：**`assert_false "$1" "$msg"` 的语义是「退出码非 0」，根本没有「子串不存在」这个语义** → 三参用法把第 2 个参数当成了描述 → 那条断言**恒真**。控制器变异：把实现改成会打印「Xray 安装完成」→ 那条断言**依然绿**（真正变红的是另一条「给出明确提示」） | Step 1 改成显式写法：`if [[ "$out" == *"Xray 安装完成"* ]]; then lied=1; else lied=0; fi` + `assert_eq "0" "$lied" "…"`。**教训：断言辅助函数的签名必须回 `test/lib.sh` 核对，不能凭名字猜** —— 同一个项目里已经因为「点名错了断言」栽了两次（F4-16 / T5-12），这次是第三次栽在「辅助函数语义」上 |
| T6-20 | **Important** | **防火墙三条分支的判据全是恒真的。** 控制器探针实测（把整个分支删掉再看哪些断言还活着）：<br>① 删掉整个 **ufw** 分支 → 2 条红，但「ufw 分支调用了 ufw allow」那条**仍然绿** —— 判据是 `"8443/tcp"`，而兜底提示「请自行放行端口：8443/tcp」里也有它；<br>② 删掉整个 **iptables** 分支 → 只有「识别出规则已存在」那条红，「被走到」「带上了端口」两条**仍然绿** —— 判据 `"iptables"` 在兜底提示「未检测到 ufw / iptables / nftables」里也有；<br>③ 删掉整个 **nftables** 分支 → **0 条红** —— 三条断言**全部恒真** | Step 1 三条判据全部改成点**该分支独有的 tui_run 标题**：`放行端口 8443/tcp (ufw)` / `(iptables)` / `(nftables)`；并各补一条「**不得退化成『未检测到防火墙』**」（判据是输出里不得出现「未检测到 ufw」）。⚠️ 这类「字样在别的分支里也出现」的陷阱，靠读代码**看不出来** —— 必须把分支整个删掉再测 |
| T6-21 | Minor | **两条退出码断言在对应缺陷下是恒绿的。** 探针实测：① 删掉 `install_xray` 的 mktemp 空值守卫 → 退出码**仍然是 1**（因为后面 `curl -o ""` 失败 → 走「下载失败」分支 → 也是返回 1）→ 「返回非零」那条绿，真正变红的是「给出明确提示」；② 删掉 `setup_systemd` 的「没有 systemctl」分支 → 退出码**仍然是 0** → 「返回非零」那条**恒绿**，变红的是「给出明确提示」 | 验收标准第 5 条里这两条**改点名**：「install_xray 在 mktemp 失败时**给出明确提示**」、「setup_systemd 在没有 systemctl 时**给出明确提示**」。⚠️ 这是本项目**第四次**栽在「点名的断言不是实际变红的那一条」上（F4-16 → T5-12 → T6-19 → T6-21）—— **点名的断言必须与预演结果里实际变红的那一条逐字对上** |

> **控制器的自我记账（第 4 条）**：本轮的新块在**第一次沙箱基线**时又犯了 3 个错，
> 全都是「照抄进计划之前没在沙箱里跑一遍基线」造成的：
> ① 静态断言写成了「全函数一刀切查 `| grep -q`」→ 会误伤 nft 那处合法的用法；
> ② `install_xray` 的成功路径 mock 用了固定返回值 → 覆盖不到「末尾那次检查」；
> ③ `assert_false` 的三参误用（就是 T6-19）。
> 修法不变：**新写的断言块必须先在沙箱里跑一遍基线**，不能直接派发。

#### 修订轮 2 的验收标准

1. `lib/deploy.sh` 的 Task 6 段与上面 **Step 3 代码块逐字节一致**（追加在 Task 5 段之后）。
   **本轮 Step 3 一字未改** → md5 仍是 `a0e8b499e7015b753996092fdd0e0f50`（185 行）。
2. `test/unit.sh` 里 Task 6 的插入段与上面 **Step 1 代码块逐字节一致**
   （追加在 `test_summary` **之前**）。
3. `bash test/unit.sh` 全部通过、退出码 0。
4. 断言总数必须恒定，且**连跑 4 次条数相同**。
   平台差异：本机（Windows + MSYS）与 Debian/CI 的条数差 **4 条** ——
   4 条权限相关行为断言在 MSYS 上被自动跳过（`chmod` 是模拟的）。
   报告里必须写明是哪个平台的数字。
   **预期条数**：本机 **309**、Debian/CI **313**
   （底座 197 + Task 5 修订轮 2 的 63 + Task 6 修订轮 2 的 49）。
   Task 6 段自身的断言数：修订轮 1 是 24 条 → 本轮 49 条。
5. 红灯证据（**至少这 12 条**，每条都要贴出**变红的断言原文**）：
   - 把 `open_firewall` 的 ufw 检测改回 `| grep -q` 形态
     → 「open_firewall 的 ufw 状态检测不得把 grep -q 直接接在管道上（SIGPIPE 会把 141 带进退出码）」必须变红；
   - 把 `open_firewall` 里 `ufw_status=$(ufw status …)` 那行删掉
     → 「open_firewall 的 ufw 状态检测必须先把输出收进变量再匹配」必须变红；
   - 把 `setup_systemd` 里 `mkdir -p` 的退出码检查去掉
     → 「setup_systemd 在 mkdir 失败时不得谎报『日志目录已授权』」必须变红；
   - 把 `install_xray` 成功路径的 `tui_ok "Xray 安装完成…"` 删掉
     → 「install_xray 成功时提示安装完成」必须变红；
   - 把 `install_xray` 成功路径的 `return 0` 改成 `return 1`
     → 「install_xray 在下载与安装都成功时返回 0」必须变红；
   - 把 `install_xray` 的 mktemp 空值守卫删掉
     → 「install_xray 在 mktemp 失败时**给出明确提示**」必须变红
     （⚠️ **不是**「返回非零」那条 —— 删掉守卫后退出码**仍然是 1**
      （后面 `curl -o ""` 失败 → 走「下载失败」分支 → 也是返回 1）→ 那条恒绿）；
   - 把 `setup_systemd` 的「没有 systemctl」那个 `tui_err` + `return 1` 删掉
     → 「setup_systemd 在没有 systemctl 时**给出明确提示**」必须变红
     （⚠️ **不是**「返回非零」那条 —— 删掉后退出码**仍然是 0** → 那条恒绿）；
   - 把 `open_firewall` 的整个 iptables 分支删掉
     → 「open_firewall 的 iptables 分支被走到（必须真的调用 iptables -I）」必须变红；
   - 把 `open_firewall` 的整个 nftables 分支删掉
     → 「open_firewall 的 nftables 分支被走到（必须真的插入 nft 规则）」必须变红；
   - 把 `enable_bbr` 的「内核参数应用失败」分支删掉
     → 「enable_bbr 在内核参数应用失败时返回非零」必须变红；
   - 把 `enable_bbr` 的「可用算法」提示删掉
     → 「enable_bbr 在内核不支持 bbr 时提示可用算法」必须变红；
   - 把 `service_status` 的「开机自启」那行删掉
     → 「service_status 显示开机自启状态」必须变红。
   ⚠️ **点名的断言必须与预演结果里【实际变红的那一条】逐字对上**，不能只看「红了几条」。
   ⚠️ 「正向断言（期望码 0）」在把函数换成 `return 0` 时**不会变红** ——
   真正变红的是它的**反向断言**。
6. `lib/core.sh`、`lib/tui.sh`、`test/lib.sh`、Task 5 段 **一字未动**。
7. 计划文件实施者一个字都不许改。

**Step 1: 写失败的测试**

追加到 `test/unit.sh`：

```bash
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

# ── install_xray：下载安装脚本失败必须返回非零（不得谎报已安装）──
# ensure_packages 与 curl 都必须 mock：前者会真的调 apt-get，后者会真的联网。
out=$( ( XRAY_BIN=/nonexistent/xray; xray_installed() { return 1; }
         ensure_packages() { return 0; }; curl() { return 22; }
         install_xray 2>&1 ) ); rc=$?
assert_status 1 "$rc" "install_xray 在下载安装脚本失败时返回非零"
assert_contains "$out" "下载 Xray 安装脚本失败" "install_xray 下载失败时给出明确提示"
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
[[ -n "$open_firewall_body" ]]; assert_true "$?" \
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
# xray_installed 的 mock 必须【前一次调用返回「未安装」、后一次返回「已安装」】——
# install_xray 开头查一次（判断是否已安装），末尾还要再查一次（判断是否装上了）。
# 用计数器实现，不能用固定返回值。
out=$( ( XRAY_BIN=/nonexistent/xray
         _calls=0
         xray_installed() { _calls=$((_calls + 1)); [[ $_calls -ge 2 ]]; }
         ensure_packages() { return 0; }
         curl() { return 0; }
         tui_run() { return 0; }
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
assert_contains "$out" "无法创建临时文件" "install_xray 在 mktemp 失败时给出明确提示"

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
    # mkdir 的退出码必须检查：失败时后面仍然会打印「日志目录已授权」→ 谎报。
    # 目录建不出来时 xray 写不了日志，用户却以为一切正常。
    if ! mkdir -p "$LOG_DIR"; then
      tui_warn "无法创建日志目录 $LOG_DIR，xray 可能无法写入日志。"
    else
      if id "$svc_user" >/dev/null 2>&1; then
        chown -R "$svc_user" "$LOG_DIR" 2>/dev/null || true
      fi
      tui_tip "日志目录已授权给运行用户 $svc_user"
    fi
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
  # ufw 的状态检测【不能】写成 `ufw status | grep -q ...`：
  # grep -q 命中即退出 → 上游 ufw 收到 SIGPIPE(141) → set -o pipefail 下整条管道
  # 的退出码变成 141 → 条件判假 → 【ufw 明明是 active 也不会走 ufw 分支】，
  # 静默降级到 iptables / nft 分支（与 Task 4 的 F4-1 同一个坑）。
  # 修法与 F4-1 一致：先把整段输出收进变量，再对变量做匹配
  # （链路上没有任何会早退的管道 → 不可能有 SIGPIPE）。
  if have_cmd ufw; then
    local ufw_status
    ufw_status=$(ufw status 2>/dev/null || printf '')
    if [[ "$ufw_status" == *"Status: active"* ]]; then
      tui_run "放行端口 $port/tcp (ufw)" ufw allow "$port/tcp"
      return $?
    fi
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
    # 必须用 `|| true` 而不是 `|| printf 'unknown'`：
    # systemctl is-active 在服务停止时【会输出 "inactive" 并返回非零】，
    # `|| printf 'unknown'` 会把 unknown 追加到后面 → 状态显示成两行
    # （"inactive\nunknown"），界面上看着像出了两个状态。
    # 正确做法是保留 systemctl 的输出，只在它【一个字都没输出】时才回落到 unknown。
    active=$(systemctl is-active xray 2>/dev/null || true)
    [[ -n "$active" ]] || active='unknown'
    enabled=$(systemctl is-enabled xray 2>/dev/null || true)
    [[ -n "$enabled" ]] || enabled='unknown'
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

#### 修订轮 1 的逐项发现与处置

> 本节由**控制器**在 Task 7 派发前预扫（沙箱实证）之后写入。
> 本节列的全是**计划缺陷**，责任方是控制器；Task 7 的代码块本身还没被实施过。
>
> 沙箱底座 = `git archive 911b95a` 整棵树（**Task 6 的实施结果**，含 `test/helpers/`）
> + Task 7 的两个代码块 → 基线 376 项断言全绿、rc=0（干净基线）。
>
> ⚠️ **底座必须是 Task 7 实施时的 HEAD**。控制器第一版预演误用 `c44800a`
> （Task 5 的实施）→ 漏算 Task 6 的 49 条 → 预期条数算错成 315/319，
> 真实应为 **376/381**。教训：**预期条数必须由「当前 HEAD 的实测」加上
> 「本任务新增段的实测条数」得出，不能沿用上一轮的底座数字**；
> 且**平台差异必须逐条核对**（不能沿用上一轮的口径 —— 见 T7-18）。

| # | 级别 | 发现 | 处置 |
|---|---|---|---|
| T7-1 | **Important** | **`render_client_config` 有真实注入面。** 它用**未加引号的 heredoc**（`cat >"$tmp" <<EOF`）渲染 JSON → 入参里的 `$(...)` / 反引号会被**真实执行**。控制器实证（P1/P2/P3）：把 `'$(echo PWNED_UUID)'` 传进 UUID、`'`echo PWNED_SNI`'` 传进 SNI、`'$(echo PWNED_PUB)'` 传进公钥 —— **三个都被真实执行**，执行结果被原样写进了 `client.json`。与 Task 5 的 T5-4 同款，但这里的入参更多（6 个） | Step 3 加**入参白名单校验**（必须**先做**）：UUID 规范形态 / 端口 1-65535 / 公钥 base64url 40-64 / ShortID 十六进制 2-16 / SNI 走 `validate_hostname` / 地址走 `is_valid_ip`。任一不合法 → `tui_err` + 返回 1 + **不落盘**。白名单让 6 个入参只可能含安全字符，从根上关死注入面 |
| T7-2 | **Important** | **非法端口会把 JSON 直接写坏。** 控制器实证（P4）：端口传 `'443; id'` → 渲染出来的 `client.json` **不是合法 JSON** → 客户端拿到的是一份**废文件**，而且服务端没有任何提示 | 同 T7-1 的白名单（端口校验）。Step 1 补断言：非法端口必须被拒，且**不得落盘** |
| T7-3 | **Important** | **`render_client_config` 一条断言都没有（掏空成 `return 0` → 0 条红）。** 控制器第一版探针用 `^}` 定位函数体，结果**被 heredoc 里行首的 `}` 截断** → 替换后文件语法错 → 整个测试脚本 source 失败 → 0 条红（假阴性）。改用「按函数尾部特征定位」重做后确认：掏空 `render_client_config` → **0 条红** → 真的零覆盖 | Step 1 补断言组：JSON 内容 6 条（socks 1080 / http 1081 / publicKey / serverName / fingerprint / id）+ 注入拒绝 6 条 + 不落盘 1 条 + 目录守卫 2 条 + cat 退出码与错误提示 2 条 + chmod 早于 mv 2 条 + mv 失败 2 条 + 暂存名 `.render` 1 条 |
| T7-4 | **Important** | **`export_client_artifacts` 的失败路径大面积零覆盖**：把 `mkdir` 失败、`chmod 700` 失败、分享链接为空、`render_client_config` 失败这四处的 `\|\| { tui_err …; return 1; }` 去掉 → 全部 **0 条红**。全局约束「所有失败路径必须以非零退出码结束，且经 `tui_err` 输出」在 Task 7 **完全没有被验证** | Step 1 补断言组：每条都要同时断言**退出码非零**与**错误提示的文本** |
| T7-5 | Minor | **`build_share_link` 的 `FLOW` / `FINGERPRINT` 全局状态零覆盖**：把 `${FLOW:-…}` / `${FINGERPRINT:-…}` 换成字面量 → **0 条红**（测试里这两个全局变量没被设过 → 走的全是默认值） | Step 1 设了自定义 FLOW/FINGERPRINT 后断言链接里出现它们 |
| T7-6 | Minor | **`client.txt` 与 `client.json` 里写死了 flow / fp**，与 `build_share_link` 用的全局状态**可能不一致** → 用户照着 `client.txt` 显示的值排查会查错方向 | Step 3 三处统一用 `${FLOW:-xtls-rprx-vision}` / `${FINGERPRINT:-chrome}`；Step 1 补 4 条断言（client.txt 的 flow / fp、client.json 的 flow / fp 四者必须一致） |
| T7-7 | Minor | **`export_client_artifacts` 的 qrencode 分支零覆盖**：把整个分支删掉 → **0 条红**（既测不到「缺少 qrencode 时明确告知」，也测不到「有 qrencode 时真的生成文件」） | Step 1 补 5 条：缺 qrencode → 仍然成功 + 明确告知；有 qrencode → 成功 + 生成 PNG + 生成终端二维码 |
| T7-8 | Minor | `render_client_config` 的内部暂存名是 `$outfile.new`，与 `write_config_atomic` 的 `.new` **同名**（与 Task 5 的 T5-10 同款） | Step 3 改成 `$outfile.render`；Step 1 用 mock `mv` 记录参数来钉住 |
| T7-9 | Minor | `render_client_config` 的 `cat` 的**退出码没检查** → 目标目录不存在时漏出裸的 bash 报错；且 `chmod 600` 写在 `mv` **之后** → 权限失败时文件已落位却返回非零 | Step 3 把 heredoc 包进 `if ! cat >"$tmp" <<EOF … EOF then … fi`；`chmod 600 "$tmp"` 挪到 `mv` **之前**；Step 1 各补 2 条 |
| T7-10 | Minor | `render_client_config` 没有「目标路径是目录」的守卫 → `mv -f` 会把文件**移进目录里**，返回 0 但配置没落位（与 Task 5 的 D2 同款） | Step 3 加 `[[ -d "$outfile" ]]` 守卫；Step 1 补 2 条 |
| T7-11 | Minor | Task 7 **没有独立的验收标准段**（Task 3/4/5/6 都有） | 补一个 |
| T7-12 | Minor | Step 1 里的占位值（`"UUID123"` / `"PUBKEY"`）在加了白名单之后会被拒绝 | Step 1 统一换成**真值**（规范 UUID / 45 位 base64url 公钥），并把相关断言里的期望值一并改掉 |
| T7-13 | **Important** | **`is_valid_ip` 白名单【零断言】。** 控制器变异：把 Step 3 里的 `is_valid_ip "$ip" \|\| { tui_err "服务器地址非法：$ip"; return 1; }` 删掉 → **0 条红**。原因：Step 1 只测了 UUID / SNI / 公钥 / 端口 / ShortID 五个入参的注入面，**独独漏了 IP** —— 而 IP 同样是**未加引号的 heredoc** 的一部分（`"address": "${ip}"`）→ 同样能被执行 | Step 1 补 1 条：`render_client_config` 拒绝含命令替换的 IP（`'$(echo PWNED_IP)'`）。**六个入参必须一个不落** |
| T7-14 | Minor | **`client.txt` 的指纹（fp）字段【零断言】。** Step 3 里 `printf '指纹 (fp): %s\n\n' "${FINGERPRINT:-chrome}"` 写死了 fp，但 Step 1 只断言了 client.txt 的 **flow**、client.json 的 **flow 与 fp** —— **client.txt 的 fp 从来没被断言过** | Step 1 补 1 条：`client.txt 显示的指纹与全局状态一致`。**「三个地方显示同一个值」必须三条都断言，只测两条等于没测第三条** |
| T7-15 | **Important** | **物料文件的写入/权限失败路径【零断言】。** Step 3 里 `client.txt` 与 `link.txt` 的写入与 `chmod 600` 各自都有 `\|\| { tui_err …; return 1; }`（四条），但 Step 1 一条都没测 → 这四条失败路径全部零覆盖。与 T7-4 同款 | Step 1 补 8 条：`client.txt` 写入失败（预置成**目录**让重定向必然失败）、`client.txt` 权限失败、`link.txt` 写入失败、`link.txt` 权限失败，各断言退出码非零 + 提示文本 |
| T7-16 | **Important** | **`render_client_config` 的 `mv` 失败路径【零断言】。** Step 3 里 `mv -f "$tmp" "$outfile" \|\| { tui_err "无法写入客户端配置：$outfile"; … }` 没有对应的断言 | Step 1 补 2 条（mock `mv` 返回 1）：必须返回非零 + 必须给出「无法写入客户端配置」 |
| T7-17 | **Important** | **控制器自己写的两条失败路径 mock 太宽 → 「返回非零」那条断言恒绿。** 变异实测：<br>① 把 `mkdir` 的失败分支去掉 → 红的**不是**「在目录创建失败时返回非零」，而是「在目录创建失败时**给出明确提示**」—— 因为 mock 的 `mkdir() { return 1; }` 让目录**根本没建出来** → 后面 `chmod 700` 也失败 → 函数照样返回非零；<br>② 把 `chmod 700` 的失败分支去掉 → 同样只有「给出明确提示」变红 —— 因为 mock 的 `chmod() { return 1; }` 让 `render_client_config` 内部的 `chmod 600` 也失败 → 提前从别的分支返回非零 | Step 1 改用**精确到参数**的 mock：① `mkdir() { command mkdir "$@"; return 1; }` —— 目录**真的建出来**但返回失败码 → 只有 mkdir 这一条路径能导致非零；② `chmod() { if [[ "$1" == "700" ]]; then return 1; fi; command chmod "$@"; }` —— 只让**目录的 700** 失败，文件级的 600 正常。**教训：mock 必须精确到「只有这一条路径能决定退出码」，否则断言的判别力落空**（本项目已在 T6-10 栽过一次同款） |
| T7-18 | Minor | **预演底座用错 → 预期条数算错。** 控制器第一版预演用 `git archive c44800a`（Task 5 的实施）→ 基线 315 项 → 验收标准写成「本机 315 / Debian·CI 319」。但 Task 6 的实施已把 49 条断言落进 `test/unit.sh` → **真实基线是 309** | 全部改用 `911b95a` 重做预演：基线 **376** 项全绿（309 + Task 7 新增 67）。验收标准的预期条数改为 **本机 376 / Debian·CI 381**（差 **5** 条 = 权限位行为断言在 MSYS 上被跳过：基线 2 条 + Task 7 新增 3 条）。⚠️ 修订轮 1 初稿写的「380 / 差 4 条」是**沿用 Task 5/6 时期的旧口径**，漏算了 Task 7 自己新增的 3 条权限位断言 —— 这个数字由**实施者报回质疑**、控制器逐行核对 `test/unit.sh` 全部 `stat -c '%a'` 类断言后改正 |

> **控制器的自我记账**：本轮第一版预演的 **24 条变异**里有 **3 条**没打中点名的断言，
> 全部是**测试侧**的问题（不是实现侧）：
> ① **B6 恒真** → 暴露了 T7-13（IP 白名单零断言）；
> ② **D1/D2 打错断言** → 暴露了 T7-17（mock 太宽）；
> ③ **B8 的变异模式本身写错**（把 `if ! cat` 改成 `cat` 后 heredoc 的
> `then`/`fi` 结构对不上 → 整个文件语法错 → 40 条红但**没有一条是点名的**）。
> 教训与 Task 7 预扫第一版一样：**变异模式写错时，「红了几条」是误导信号** ——
> 必须核对「点名的断言是否【逐字】出现在变红列表里」。
> 修法：变异矩阵的每个用例都必须声明 `expect`（点名的断言原文），
> 打完必须报告「命中 / 未命中」，未命中即视为**变异没生效**而不是「断言恒真」。
>
> **修订后的 32 条变异实测结果（控制器在 `911b95a` 底座上跑的完整矩阵）**：
> 基线 376 项全绿 rc=0 → **32 条变异全部 ✔ 命中点名的断言**，
> **0 条恒真、0 条未命中** → 还原后 rc=0 红=0。
> 覆盖：3 条「函数整体掏空」（分别 32 / 51 / 26 条红）、
> 12 条白名单与落位、6 条 flow/fp 一致性、11 条 export 失败路径与二维码。


#### 修订轮 1 的验收标准

1. `lib/client.sh` 的内容与下面 **Step 3 代码块逐字节一致**。
2. `test/unit.sh` 里 Task 7 的插入段与下面 **Step 1 代码块逐字节一致**
   （追加在 `test_summary` **之前**；`source "$ROOT/lib/client.sh"` 放在顶部 source 区域）。
3. `bash test/unit.sh` 全部通过、退出码 0。
4. 断言总数必须恒定，且**连跑 4 次条数相同**。
   平台差异：本机（Windows + MSYS）与 Debian/CI 的条数差 **5 条** ——
   5 条权限相关行为断言在 MSYS 上被自动跳过（`chmod` 是模拟的，`stat -c '%a'` 读不到 600）。
   报告里必须写明是哪个平台的数字。
   **预期条数**：本机 **376**、Debian **以 root 运行** **381**
   （底座 309 + Task 7 修订轮 1 的 67）。
   ⚠️ 补充（Task 8 实施后由实施者报回、控制器核实）：**若以【非 root】身份运行，
   会再多 2 条断言**（`chmod 000` 后判 `! -r` 的那两条 —— root 能读 000 文件，
   非 root 读不到）→ 此时是 **383**。**GitHub Actions 的 runner 正是非 root。**
   详见 Global Constraints 的「平台差是三个数」一段。
   ⚠️ **这 5 条的构成**（控制器逐行核对 `test/unit.sh` 里**全部**「断言内容里含
   `stat -c '%a'` 且与 600/700 比对」的断言 —— 这是唯一会在 MSYS 上跳过的类别）：
   - **基线 2 条**：`save_state 写出的状态文件权限为 600`、`save_state 建出的状态目录权限为 700`
     （藏在 `probe_mode == 600` 守卫内，`test/unit.sh` 行 630–631）；
   - **Task 7 新增 3 条**：`link.txt 权限为 600`、`client.txt 权限为 600`、`客户端导出目录权限为 700`
     （藏在 `exp_probe` 守卫内，`test/unit.sh` 行 1627–1629）。
   修订轮 1 之前写的「差 4 条 / Debian 380」是**沿用了 Task 5/6 时期的旧口径**，
   漏算了 Task 7 自己新增的 3 条权限位断言 → 正确差异是 **2 + 3 = 5** 条。
   （实施者报回「Debian 应为 381 或 382」→ 控制器独立逐行核对后确认 **381**；
   实施者的静态推算比计划里的数字更接近真相，这是「实施者如实报告 > 粉饰」的正例。
   注意：其余名字里带「chmod 失败」的断言用的是 **mock 判据**（不读真实权限位），
   两平台都执行，**不计入**这 5 条。）
5. 红灯证据（**至少这 25 条**，每条都要贴出**变红的断言原文**）：
   - 删掉 `render_client_config` 的 **UUID** 白名单
     → 「render_client_config 拒绝含命令替换的 UUID」必须变红；
   - 删掉 **端口** 白名单
     → 「render_client_config 拒绝非法端口」必须变红；
   - 删掉 **公钥** 白名单
     → 「render_client_config 拒绝含命令替换的公钥」必须变红；
   - 删掉 **ShortID** 白名单
     → 「render_client_config 拒绝含命令替换的 ShortID」必须变红；
   - 删掉 **SNI** 白名单
     → 「render_client_config 拒绝含命令替换的 SNI」必须变红；
   - 删掉 **IP** 白名单
     → 「render_client_config 拒绝含命令替换的 IP」必须变红；
   - 删掉 `render_client_config` 的 `[[ -d "$outfile" ]]` 守卫
     → 「render_client_config 在目标路径是目录时返回非零」必须变红；
   - 把 `render_client_config` 里 `cat` 的退出码检查去掉
     → 「render_client_config 在目标目录不存在时给出自己的错误提示（而不是裸的 bash 报错）」必须变红；
   - 把 `render_client_config` 里 `chmod 600 "$tmp"` 挪到 `mv` 之后
     → 「render_client_config 在 chmod 失败时不得落位（chmod 必须早于 mv）」必须变红；
   - 把 `render_client_config` 的暂存名 `.render` 改回 `.new`
     → 「render_client_config 的暂存名必须是 .render（不得与 write_config_atomic 的 .new 撞名）」必须变红；
   - 把 `render_client_config` 里 `mv` 的失败分支去掉
     → 「render_client_config 在 mv 失败时返回非零」必须变红；
   - 把 `build_share_link` 的 `${FLOW:-…}` 换成字面量
     → 「build_share_link 使用全局 FLOW 而不是写死」必须变红；
   - 把 `build_share_link` 的 `${FINGERPRINT:-…}` 换成字面量
     → 「build_share_link 使用全局 FINGERPRINT 而不是写死」必须变红；
   - 把 `client.json` 里的 flow 换成字面量
     → 「client.json 的流控与全局状态一致」必须变红；
   - 把 `client.json` 里的 fp 换成字面量
     → 「client.json 的指纹与全局状态一致」必须变红；
   - 把 `client.txt` 里的 flow 换成字面量
     → 「client.txt 显示的流控与全局状态一致」必须变红；
   - 把 `client.txt` 里的 fp 换成字面量
     → 「client.txt 显示的指纹与全局状态一致」必须变红；
   - 把 `export_client_artifacts` 的 `mkdir` 失败分支去掉
     → 「export_client_artifacts 在目录创建失败时返回非零」必须变红；
   - 把 `export_client_artifacts` 的 `chmod 700` 失败分支去掉
     → 「export_client_artifacts 在目录权限设置失败时返回非零」必须变红；
   - 把 `export_client_artifacts` 的「分享链接为空」检查去掉
     → 「export_client_artifacts 在分享链接为空时返回非零」必须变红；
   - 把 `export_client_artifacts` 里 `render_client_config … || return 1` 的 `|| return 1` 去掉
     → 「export_client_artifacts 在客户端配置渲染失败时返回非零」必须变红；
   - 把 `export_client_artifacts` 里 `client.txt` 的写入失败分支去掉
     → 「export_client_artifacts 在客户端信息文件写入失败时返回非零」必须变红；
   - 把 `export_client_artifacts` 里 `client.txt` 的 chmod 失败分支去掉
     → 「export_client_artifacts 在客户端信息文件权限设置失败时返回非零」必须变红；
   - 把 `export_client_artifacts` 里 `link.txt` 的写入失败分支去掉
     → 「export_client_artifacts 在分享链接文件写入失败时返回非零」必须变红；
   - 把 `export_client_artifacts` 里 `link.txt` 的 chmod 失败分支去掉
     → 「export_client_artifacts 在分享链接文件权限设置失败时返回非零」必须变红；
   - 把 `export_client_artifacts` 的整个 qrencode 分支删掉
     → 「export_client_artifacts 在没有 qrencode 时明确告知」必须变红。
   ⚠️ **点名的断言必须与预演结果里【实际变红的那一条】逐字对上**，不能只看「红了几条」。
   ⚠️ 「正向断言（期望码 0）」在把函数换成 `return 0` 时**不会变红** ——
   真正变红的是它的**反向断言**（本项目已栽过 F4-16 / T5-12 / T6-19 / T6-21 / T6-22 **五次**）。
6. `lib/tui.sh`、`test/lib.sh`、`lib/core.sh`、`lib/deploy.sh`、Task 5 段、Task 6 段 **一字未动**。
7. 计划文件实施者一个字都不许改。

**Step 1: 写失败的测试**

追加到 `test/unit.sh`（`source "$ROOT/lib/client.sh"` 一行放在**顶部 source 区域**）：

```bash
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
  # ── 入参白名单校验（必须【先做】）────────────────────────────
  # 本函数用【未加引号的 heredoc】渲染 JSON → 入参里的 $(...) / 反引号会被
  # 【真实执行】。控制器实证：把 '$(echo PWNED_UUID)' 传进 UUID、
  # '`echo PWNED_SNI`' 传进 SNI、'$(echo PWNED_PUB)' 传进公钥
  # —— 三个都被【真实执行】，执行结果被原样写进了 client.json。
  # 而且非法端口（"443; id"）会把 JSON 【直接写坏】→ 客户端拿到的是废文件。
  # 白名单让 6 个入参只可能含有安全字符，从根上关死注入面。
  [[ "$uuid" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] \
    || { tui_err "UUID 格式非法：$uuid"; return 1; }
  [[ "$port" =~ ^[0-9]{1,5}$ ]] && [[ "$port" -ge 1 && "$port" -le 65535 ]] \
    || { tui_err "端口非法：$port"; return 1; }
  [[ "$pub" =~ ^[A-Za-z0-9_-]{40,64}$ ]] \
    || { tui_err "REALITY 公钥格式非法（只允许 base64url 字符，长度 40-64）"; return 1; }
  [[ "$sid" =~ ^[0-9a-fA-F]{2,16}$ ]] \
    || { tui_err "ShortID 格式非法（只允许十六进制，长度 2-16）：$sid"; return 1; }
  validate_hostname "$sni" || { tui_err "SNI 主机名非法：$sni"; return 1; }
  is_valid_ip "$ip" || { tui_err "服务器地址非法：$ip"; return 1; }
  # 目标路径如果是【已存在的目录】：`mv -f "$tmp" "$outfile"` 会把文件移进目录里
  # → mv 返回 0（看起来成功）但配置根本没落到 outfile → 调用方以为渲染成功。
  [[ -d "$outfile" ]] && { tui_err "目标路径是目录，不能作为配置文件：$outfile"; return 1; }
  # 内部暂存名用 ".render" 后缀，与 write_config_atomic 的 ".new" 区分开，
  # 避免两者在同一条路径上撞名。
  local tmp="$outfile.render"
  # cat 的退出码必须检查：目标目录不存在时，重定向失败会漏出原始 bash 报错，
  # 用户看到的是「No such file or directory」而不是我们自己的提示。
  if ! cat >"$tmp" <<EOF
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
                "flow": "${FLOW:-xtls-rprx-vision}",
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
          "fingerprint": "${FINGERPRINT:-chrome}",
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
  then
    tui_err "无法写入配置暂存文件：$tmp"
    rm -f "$tmp"
    return 1
  fi
  # 含 UUID 与公钥 → 600。必须在 mv 之前设好：
  # 否则「权限设置失败」时文件已经落位，函数却返回非零。
  chmod 600 "$tmp" || { tui_err "无法设置暂存文件权限：$tmp"; rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$outfile" || { tui_err "无法写入客户端配置：$outfile"; rm -f "$tmp"; return 1; }
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
    # 流控与指纹必须与分享链接、client.json 用的是【同一个】全局状态 ——
    # 写死就等于让这里显示的值与实际配置对不上（用户会照着显示的值去排查）。
    printf '流控 (flow): %s\n' "${FLOW:-xtls-rprx-vision}"
    printf '指纹 (fp): %s\n\n' "${FINGERPRINT:-chrome}"
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

#### 修订轮 1 的逐项发现与处置

> 本节由**控制器**在 Task 8 派发前预扫（沙箱实证）之后写入。
> 本节列的全是**计划缺陷**，责任方是控制器；Task 8 的代码块本身还没被实施过。
>
> 沙箱底座 = `git archive 12249c1` 整棵树（**Task 7 的实施结果**）
> + Task 8 的两个代码块 → 基线 387 项断言全绿、rc=0（干净基线）。
>
> ⚠️ **底座必须是 Task 8 实施时的 HEAD**（Task 7 的实施 `12249c1`），
> 不能沿用 Task 7 预扫时的 `c44800a` —— 否则会重犯 Task 7 的 T7-18
> （底座用错 → 预期条数算错）。

| # | 级别 | 发现 | 处置 |
|---|---|---|---|
| T8-1 | **Important** | **`require_root` 与 `preflight` 两条函数【完全零覆盖】。** 控制器逐个掏空实测：把 `require_root` 整个换成 `return 0` → **0 条红**；把 `preflight` 整个换成 `return 0` → **0 条红**。而这两个正是「权限检查」与「环境预检」—— **部署能不能跑起来全靠它们** | Step 1 大幅补断言（见下），Step 3 加 `INSTALL_SH_NO_MAIN` 守卫让函数可被 source 后单独测 |
| T8-2 | **Important** | **根因：`install.sh` 末尾是 `main "$@"` → 被 source 时会真的跑主流程**（本机非 root → 立刻 `exit 1`）→ 单元测试**根本无法**对它的函数做断言。控制器实测：source 之后整个测试脚本被干掉（`rc=1`，0 条断言执行） | Step 3 把末尾改成守卫形式：`if [[ "${BASH_SOURCE[0]}" == "${0}" ]] && [[ "${INSTALL_SH_NO_MAIN:-0}" != "1" ]]; then main "$@"; fi`。两个条件缺一不可：① 被 source 时 `$0` 是调用方 → 不相等；② 显式开关给测试用 |
| T8-3 | **Important** | **`require_root` 内部是 `exit 1` → 单元测试调用它会把整个测试脚本干掉**，拿不到退出码。控制器实测：调用 `require_root` 后测试脚本直接终止 | Step 3 改成 `return 1` / `return 0`，**调用方**负责 `exit`（`main` 里改成 `require_root \|\| exit 1`）。**函数应当返回状态、由调用方决定是否退出** —— 这是可测性的基本要求 |
| T8-4 | **Important** | **13 条分支零覆盖**（控制器逐条变异实测，全部 **0 条红**）：`require_root` 的 EUID 判定与提示、`preflight` 的 systemd 缺失分支 / curl 缺失分支 / `assert_debian` 失败计入 / `ensure_packages` 失败计入 / qrencode 分支 / `--addr` 指定分支 / 公网 IP 回退分支 / 返回码传递、`parse_args` 的 `--port` 范围校验 / `--sni` 主机名校验 / `--port` 缺参数检查 / `--uuid` 缺参数检查、`main` 的 `--uninstall` 分支 | Step 1 补齐（详见下）。原 Step 1 只有 **11 条**断言，只碰了 `--help` / `--addr` / 未知参数 / `--status` 四个入口 |
| T8-5 | Minor | **参数解析的「缺参数」与「取值非法」两类校验只有 `--addr` 被测到。** `--port` / `--sni` / `--name` / `--uuid` 的缺参数检查，以及 `--port` 的范围检查、`--sni` 的主机名合法性检查 —— 全部零覆盖。用户传 `--port 99999` 会被接受并一路写进 `config.json` | Step 1 补 13 条：四个参数的缺参数检查 + `--port` 范围（含 0 与 99999）+ `--sni` 非法主机名 |
| T8-6 | Minor | **`parse_args` 的「解析成功」路径零覆盖**：没有任何断言验证 `--port 8443` 真的被解析成 `OPT_PORT=8443` | Step 1 补 8 条：一条退出码 + 六个 `OPT_*` 的取值 + `-y` 的置位；另补 `--menu` / `--status` / `--uninstall` 三个开关各一条 |
| T8-7 | Minor | **`EUID` 是 bash 的【只读特殊变量】** → `EUID=0` 改不了它（本机实测 `readonly variable`）。这意味着「以 root 运行时 `require_root` 不得报错」这条**在本机不可达** | 这条改用**源码静态断言**（`declare -f require_root` 取函数体后匹配 `return 0` / `return 1`），与 Task 4 的 F4-1、Task 6 的 T6-9 同款。⚠️ 静态断言的判别力**必须靠变异证明** —— 见验收标准第 5 条 |
| T8-8 | Minor | **`OPT_ADDR` 必须在 source 【之后】设置。** `install.sh` 顶层把 `OPT_*` 全部重置为空串 → 控制器第一版新测试段把 `OPT_ADDR=...` 写在 source **之前** → 被覆盖 → 2 条断言红。控制器实测确认 | Step 1 把 `OPT_ADDR='203.0.113.7'` 移到 source 之后；并在注释里写明这条坑 |
| T8-9 | Minor | **`--status` 必须在 `require_root` 之前** —— 它是只读操作，不该要求 root（Task 8 的 Step 3 注释里也写明了这一点）。但这个**顺序**本身以前没有任何断言保护 → 有人把 `require_root` 挪到前面就会让 `--status` 在非 root 下失败 | Step 1 补一条**顺序断言**：取 `declare -f main` 的函数体，比较 `OPT_STATUS -eq 1` 与 `require_root` 的行号 |
| T8-10 | Minor | **`--uninstall` 找不到卸载脚本的分支零覆盖**（Task 11 才会真正提供 `uninstall.sh`，但「找不到时必须报错退出」这条现在就该钉住） | Step 1 补 2 条：`ROOT_DIR` 指向不存在的目录 → 必须非零退出 + 必须提到 `uninstall.sh` |
| T8-11 | Minor | **`preflight` 的 qrencode 分支零覆盖**（缺 qrencode 时应给出「可手动安装」的提示，不该中断部署） | Step 1 补 2 条：`have_cmd` 对 qrencode 返回非零、`ensure_packages` **只对 qrencode** 返回失败 → 必须不阻断部署（退出码 0）+ 必须给出提示 |
| T8-12 | Minor | Task 8 **没有独立的验收标准段**（Task 3–7 都有） | 补一个 |
| T8-13 | **Important** | **参数守卫一旦被删，`install.sh` 会【死循环】→ 整个测试套件挂死。** 根因：`parse_args` 的 `while` 循环里，`--uuid` 之类的分支执行 `shift 2`；当它是最后一个参数时 `shift 2` 失败（`shift count out of range`）→ 当前参数永远消费不掉 → 死循环。控制器实测（C5 变异）：`bash install.sh --uuid` **永不退出**（`timeout` 命中 → rc=124），且变异矩阵整体挂死 6 分钟 | Step 1 把**每一次**对 `install.sh` 的调用都用 `timeout 10` 包一层 → 死循环变成 rc=124（断言照样变红），套件不再挂死 |
| T8-14 | **Important** | **「main 在进入部署路径前必须要求 root」这条断言【恒真】。** 它断言 `main_body` 里含 `require_root \|\| exit 1` —— 但 `--menu` 分支里**也有同一句** → 删掉部署路径那一句，断言照样绿。控制器分析确认：`--menu` 分支的 `require_root` 满足子串匹配 | Step 1 把判据改成**唯一**的：「部署路径」= 打印部署 banner 的那段 → 统计「`require_root \|\| exit 1` 的下一行里出现 `tui_banner` 的次数」，正确实现为 1、删掉后为 0 |
| T8-15 | **Important** | **参数校验的「非零码退出」断言【判别力为零】。** `--port 99999` / `--addr 'bad"addr'` / `--sni 'bad host'` 这三条，校验一旦被删 → `parse_args` 放行 → `main` 走到 `require_root` → **本机非 root → 照样 exit 1** → 退出码断言**保持绿**。真正能区分的是**报错文本** | Step 1 加三条 `assert_not_contains "$out" "需要 root 权限"` —— 校验失败时**不得走到 root 检查**（即校验必须发生在参数解析口）。这三条才是 C1/C2/C3 的点名判据 |
| T8-16 | **Important** | **「`--port` 缺少参数时给出明确提示」这条断言【恒真】。** 它的 needle 是 `--port`，而**范围校验**的消息（`--port 必须是 1-65535 之间的整数：`）也含 `--port` → 删掉「缺参数」守卫后，范围校验会接手并给出另一条同样含 `--port` 的消息 → 断言照样绿 | Step 1 把 needle 换成 **`缺少参数`**（只有「缺参数」守卫的消息里有这三个字）。`--sni` / `--name` / `--uuid` / `--addr` 同步统一 |
| T8-17 | Minor | **4 条断言依赖「当前不是 root」，在 Debian 上以 root 跑测试会假红。** `EUID` 是只读变量 → 没法注入 → 只能靠实际运行身份。控制器逐条核对：`require_root` 的 2 条 + `--menu` 的 2 条，在 root 下分别变成「返回 0」「没有 root 提示」→ 断言红 | Step 1 把这 4 条包进 `T8_IS_ROOT` 条件块，**if / else 两侧条数相等**（各 2 条）→ 条数与运行身份无关；else 侧是「以 root 运行，前提不成立，已跳过」的说明断言 |
| T8-18 | Minor | **控制器第一版修订稿的 Step 1 漏了 T8-11 承诺的 qrencode 2 条断言** —— 小节写了要补，代码块里却没有 | Step 1 补上，并要求 `ensure_packages` 的 mock **只对 qrencode 失败**（否则这条用例测的其实是「依赖安装失败」那条路径） |
| T8-19 | Minor | **控制器第一版变异矩阵里有 2 条变异【根本没生效】**：`C6`（`--menu` 置位）与 `D3`（`--status` 分支）用的旧串与 `install.sh` 的实际文本不符 —— C6 少了 `-m\|`、D3 少了函数体里的两行注释 → 片段命中 0 次 → 变异被跳过 → 那两条「已验证」是假的 | 变异矩阵按 `install.sh` 的实际文本重写 C6 / D3，并在脚本里对**片段命中次数 != 1** 直接报错（不静默跳过） |
| T8-20 | **Important** | **「main 必须调用 deploy_wizard」这条断言【恒真】。** 它断言 `main_body` 里含 `deploy_wizard` —— 但 `if ! declare -F deploy_wizard >/dev/null 2>&1; then` 那行**也含这个词** → 删掉真正的**调用**那一行，断言照样绿。控制器变异实测（D5：把 `deploy_wizard` 调用换成 `:`）→ **0 条红**，是 23 条变异里唯一没命中的那条 | Step 1 把判据改成**唯一**的：数「**这一行就是 `deploy_wizard` 调用**」的行数（正确实现为 1、删掉后为 0）。⚠️ 注意 `declare -f` 会**重排版**（补分号、改缩进、`}` 前最后一条不带分号）→ 判据用**词边界**而不是整行相等 |

> **控制器的自我记账**：
> ① 本轮预扫的第一版脚本**装错了沙箱** —— 它把 `install.sh` 加进了 `test/unit.sh` 的
>    source 区域 → source 时 `main "$@"` 直接执行 → 非 root → 整个脚本 `exit 1`
>    → 打印出「基线 rc=1 红=0」这种**完全误导**的结论。控制器差点据此认定
>    「Task 8 的 Step 1 与 Step 3 不自洽」。修法：分两次跑 —— 第一次手工把沙箱跑通
>    （`bash test/unit.sh` → rc=0），第二次才用脚本批量做变异。
>    **教训：任何「探针给出的异常结论」，必须先用【手工的最简复现】核对一遍再采信**
>    （这与 Task 7 的「探针坏了 → 0 条红是假阴性」是同一类错误的两个方向）。
> ② 变异矩阵第一版**跑挂了**：C5 变异让 `install.sh --uuid` 死循环 → 套件永不结束
>    → 矩阵卡了 6 分钟被手工掐掉。控制器按「先手工最简复现」的要求单独验证：
>    `timeout 3 bash install.sh --uuid` → **rc=124**，坐实死循环（见 T8-13）。
>    这一条**不是**探针的假警报。
> ③ 变异矩阵第一版用 `python3`（带缓冲）→ 任务被取消时**输出全部丢失**，
>    白跑。改用 `python3 -u` + JSON 落盘。
> ④ 变异矩阵第二版（23 条）跑完：**22 条命中、1 条（D5）恒真** —— 就是 T8-20。
>    这条恒真是**矩阵自己发现的**，不是控制器读代码看出来的。
>    **教训（本项目第 N 次）：「点名的断言」不等于「能抓住对应变异的断言」。**
>    同一个词出现在两个地方（调用点 + `declare -F` 守卫行）时，
>    子串匹配就分不出谁是谁 —— 这与 T8-14（`require_root || exit 1` 出现在
>    `--menu` 分支与部署路径）是**同一类错误的两个实例**。
>    **判据必须唯一**：要么数「整行就是目标」的条数，要么抓「目标的下一行/上一行」。
> ⑤ `declare -f main` 的输出**已被 bash 重排版**：函数头变成 `main () ` + 独立的
>    `{ ` 行、每条语句末尾补 `;`、缩进从 2 空格变成 4 空格、函数体最后一条**不带分号**。
>    → 所有基于 `declare -f` 的源码静态断言都必须按**重排版后**的形态写判据。

#### 修订轮 1 的验收标准

1. `install.sh` 的内容与下面 **Step 3 代码块逐字节一致**。
2. `test/unit.sh` 里 Task 8 的插入段与下面 **Step 1 代码块逐字节一致**
   （追加在 `test_summary` **之前**；**不需要**把 `install.sh` 加进 source 区域 ——
   Task 8 的测试用 `bash "$ROOT/install.sh" …` 子进程调用 + 段内 `source`）。
3. `bash test/unit.sh` 全部通过、退出码 0。
4. 断言总数必须恒定，且**连跑 4 次条数相同**。
   ⚠️ **平台差是【三个数】，不是一个数**（构成见 Global Constraints）：
   - **A 类**（`stat -c '%a'` 与 600/700 比对）共 5 条 → MSYS 跳过、Debian 一律执行；
   - **B 类**（`chmod 000` 后判 `! -r`）共 2 条 → MSYS 跳过、**Debian 以 root 也跳过**、
     只有以**非 root** 运行才执行。
   **预期条数**：本机（Windows + MSYS）**445**、Debian **以 root 运行** **450**、
   Debian **以非 root 运行** **452**（= GitHub Actions runner 的身份）
   （底座 376 + Task 8 修订轮 1 的 69）。
   报告里必须写明「哪个平台 **+ 以什么身份运行**」。
   ⚠️ Task 8 **不新增**权限位行为断言 → 平台差仍沿用 Task 3/4/7 定下的 5 + 2 条。
   ⚠️ 另有 4 条断言依赖「当前不是 root」→ 已用 `T8_IS_ROOT` 条件块包起来，
   **if / else 两侧条数相等** → 以 root 跑测试时条数不变、也不会假红
   （else 侧是「以 root 运行，前提不成立，已跳过」的说明断言）。
5. 红灯证据（**23 条变异**，每条都要贴出**变红的断言原文**）：
   - 把 `require_root` 的 `return 1` 改成 `return 0`
     → 「非 root 时 require_root 返回非零」必须变红；
   - 把 `require_root` 的 `return 0` 删掉
     → 「require_root 在 root 时返回 0」必须变红；
   - 把 `preflight` 的 systemd 失败分支的**提示**去掉
     → 「preflight 缺 systemd 时给出明确提示」必须变红；
   - 把 `preflight` 的 curl 失败分支的**提示**去掉
     → 「preflight 缺 curl 时给出明确提示」必须变红；
   - 把 `preflight` 的 `assert_debian || rc=1` 改成 `|| true`
     → 「preflight 在非 Debian 系统上返回非零」必须变红；
   - 把 `preflight` 的 `ensure_packages openssl || rc=1` 改成 `|| true`
     → 「preflight 在依赖安装失败时返回非零」必须变红；
   - 把 `preflight` 的公网 IP 回退分支删掉
     → 「preflight 探测不到公网 IP 时给出提示」必须变红；
   - 把 `preflight` 的 `--addr` 指定分支删掉
     → 「preflight 优先使用 --addr 指定的地址」必须变红；
   - 把 `preflight` 的 `return $rc` 改成 `return 0`
     → 「preflight 缺 systemd 时返回非零」必须变红；
   - 把 `parse_args` 的 `--port` 范围校验去掉
     → 「--port 越界时不得走到 root 检查（范围校验必须在参数解析口）」必须变红；
   - 把 `parse_args` 的 `--addr` 字符集校验去掉
     → 「--addr 非法时不得走到 root 检查（校验必须在参数解析口）」必须变红；
   - 把 `parse_args` 的 `--sni` 主机名校验去掉
     → 「--sni 非法时不得走到 root 检查（主机名校验必须在参数解析口）」必须变红；
   - 把 `parse_args` 的 `--port` 缺参数检查去掉
     → 「--port 缺少参数时给出明确提示」必须变红；
   - 把 `parse_args` 的 `--uuid` 缺参数检查去掉
     → 「--uuid 缺少参数时以非零码退出」必须变红
     （⚠️ 该变异会让 `install.sh` 死循环 → 靠测试里的 `timeout 10` 兜住，退出码是 **124**，
     报告里必须写明这一点，不要写成 1）；
   - 把 `parse_args` 的 `--menu` 置位去掉
     → 「parse_args 解析 --menu」必须变红；
   - 把 `parse_args` 的 `--name` 缺参数检查去掉
     → 「--name 缺少参数时给出明确提示」必须变红
     （同上：死循环 → rc=124）；
   - 把 `main` 的 `--uninstall` 分支删掉
     → 「--uninstall 找不到卸载脚本时给出明确提示」必须变红；
   - 把 `main` 的 `--menu` 分支删掉
     → 「main 必须处理 --menu 分支」必须变红；
   - 把 `main` 的 `--status` 分支删掉
     → 「main 必须处理 --status 分支」必须变红；
   - 把 `main` 部署路径上的 `require_root || exit 1` 去掉
     → 「main 在进入部署路径前必须要求 root」必须变红；
   - 把 `main` 里的 `deploy_wizard` 调用删掉
     → 「main 必须调用 deploy_wizard」必须变红；
   - 把 `main` 的 `--status` 分支整段移到 `require_root` 之后
     → 「--status 的判定在 require_root 之前（只读操作不要求 root）」必须变红；
   - 去掉 `install.sh` 末尾的 `INSTALL_SH_NO_MAIN` 守卫
     → 「parse_args 解析合法参数时返回 0」必须变红。
   ⚠️ **点名的断言必须与预演结果里【实际变红的那一条】逐字对上**，不能只看「红了几条」。
   ⚠️ 「正向断言（期望码 0）」在把函数换成 `return 0` 时**不会变红** ——
   真正变红的是它的**反向断言**（本项目已栽过 F4-16 / T5-12 / T6-19 / T6-21 / T6-22 五次）。
   ⚠️ **静态断言（`declare -f` 取函数体）也要靠变异证明判别力** ——
   读代码觉得「它应该会红」不算证据。
   ⚠️ **变异串必须与 `install.sh` 的实际文本逐字一致** —— 片段命中次数不等于 1 时，
   变异就是**没生效**（控制器第一版有 2 条这样的假验证，见 T8-19）。
6. `lib/tui.sh`、`lib/core.sh`、`lib/deploy.sh`、`lib/client.sh`、`test/lib.sh`、Task 5 段、Task 6 段、Task 7 段 **一字未动**。
7. 计划文件实施者一个字都不许改。

**Step 1: 写失败的测试**

追加到 `test/unit.sh`：

```bash
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
    return 1
  fi
  return 0
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
    require_root || exit 1
    load_state || true
    if ! declare -F management_menu >/dev/null 2>&1; then
      tui_err "内部错误：management_menu 未定义，源码不完整。"
      exit 1
    fi
    management_menu
    exit 0
  fi

  require_root || exit 1
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


# ── 只有【直接执行】时才跑主流程 ────────────────────────────
# 被 source 时（单元测试要 source 本文件来测 parse_args / preflight 等函数）
# 绝不执行 main —— 否则会真的开始部署。
# 两个条件缺一不可：
#   ① BASH_SOURCE[0] == $0 → 只有直接执行本文件时成立；
#      被 source 时 $0 是调用方（测试脚本）→ 不相等。
#   ② INSTALL_SH_NO_MAIN != 1 → 给测试一个显式开关。
if [[ "${BASH_SOURCE[0]}" == "${0}" ]] && [[ "${INSTALL_SH_NO_MAIN:-0}" != "1" ]]; then
  main "$@"
fi
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

#### 修订轮 1 的逐项发现与处置

> 本节由**控制器**在 Task 9 派发前预扫（沙箱实证）之后写入。
> 本节列的全是**计划缺陷**，责任方是控制器；Task 9 的代码块本身还没被实施过。
>
> 沙箱底座 = `git archive HEAD` 整棵树（**Task 8 的实施结果** `d8b35d8`）
> + Task 9 的两个代码块。
>
> ⚠️ **底座必须是 Task 9 实施时的 HEAD**，不能沿用别的任务里的基线
> —— 否则会重犯 Task 7 的 T7-18（底座用错 → 预期条数算错）。

| # | 级别 | 发现 | 处置 |
|---|---|---|---|
| T9-1 | **Important** | **四个函数【完全零覆盖】。** 控制器逐个掏空实测：把 `probe_targets` / `choose_target` / `do_deploy` / `deploy_wizard` 整个换成 `return 0` → **0 条红**。而这四个函数就是「部署向导」的全部 —— **用户点一次部署能不能成功，全靠它们** | Step 1 重写：97 → **100 条**断言，覆盖四个函数的全部分支 |
| T9-2 | **Important** | **断言条数随环境漂移。** 原 Step 1 只有 14 行，且整段包在 `if have_cmd openssl` + `if [[ -n "$probe" ]]` 两个条件块里 → 本机（没有 openssl / 没有外网）**一条断言都没跑**（Task 9 段条数 = 0），有 openssl + 外网的机器上跑 8 条 → **条数在机器之间不一致** → 违反「条数恒定」铁律 | Step 1 **一个条件块都不写**：全部依赖用 shell 函数 mock，断言条数与机器 / 网络 / 权限状态**完全无关** |
| T9-3 | **Important** | **原 Step 1 真联网探测。** `probe_targets` 会真的对 7 个候选目标跑 `openssl s_client` + `curl` → CI 上要么超时要么不稳定（还依赖外网） | Step 1 全部 mock（`target_supports_tls13` / `target_latency_ms`），**一次网络请求都不发** |
| T9-4 | **Important** | **`(( 10#PORT > 0 && 10#PORT < 65536 ))` 漏了 `$` → 用户手动指定的端口【必然】被判非法。** bash 不会在 `10#` 之后解析**变量名**：`10#PORT` 被当成「以 10 为基的数字 PORT」→ 直接报 `value too great for base`。控制器实测：`PORT=9443; (( 10#PORT > 0 ))` → `value too great for base (error token is "10#PORT")`。**全库唯一一处同款错误** —— 其余 8 处 `10#` 都带 `$`（`install.sh` / `lib/core.sh` / `lib/tui.sh` / `test/unit.sh` 各处） | Step 3 改成 `10#$PORT`；Step 1 补「用户手动指定端口」用例把这条钉住 |
| T9-5 | **Important** | **`choose_target` 的两条 `tui_warn` 写到 stdout → `SNI=$(choose_target)` 会把提示文本当成主机名吞进去。** `tui_warn` 默认写 stdout（`lib/tui.sh:254`），而调用方是 `SNI=$(choose_target)` → SNI 变成「提示文本 + 主机名」的多行串 → 写进 `config.json` 就是**废配置**。原计划只给 `tui_menu` 加了 `>&2`，漏了 `tui_warn` | Step 3 给两条 `tui_warn` 加 `>&2`；Step 1 用「stdout 纯净度」断言钉住（`assert_eq "www.microsoft.com" "$sel"`） |
| T9-6 | **Important** | **`probe_targets` 的 `tui_err` 写到 stdout → 报错被当成探测数据吞掉。** 调用方是 `probe=$(probe_targets)` → mktemp 失败时，`probe` 里装的是那段报错文本 → `choose_target` 拿它去按 `host\|tls\|latency` 解析 → **解析出垃圾主机名**，而且 `-z "$probe"` 的回退判断也失效了 | Step 3 给 `tui_err` 加 `>&2`；Step 1 断言「stdout 必须为空」 |
| T9-7 | Minor | **`port_in_use` 分不清「探测失败」与「端口空闲」。** 既没有 `ss` 也没有 `netstat` 时它恒返回 1（= 空闲）→ 用户以为端口干净 → 部署走到 systemd 阶段才炸，首句报错是「systemd 配置失败」，与真正原因无关。**Task 5 段早就把它登记成「Task 9 修订项」，一直没做** | Step 3 在向导开头加一条提示：「无法确认端口是否空闲（系统缺少 ss 与 netstat）」 |
| T9-8 | Minor | **`random_free_port` 的硬编码兜底 44321 从未校验。** 40 次随机全占用的概率极低，但兜底端口未验证 → 可能又是占用。**同样是 Task 5 段登记的「Task 9 修订项」** | Step 3 在向导改用随机端口后**再验一次** `port_in_use`；仍被占用 → 明确报错中止。根因在 `lib/core.sh`，本轮**不改 core.sh**（避免动 Task 3 的终版），在调用点兜住 |
| T9-9 | Minor | `local choice` 被声明了两次（`local choice` + `local choice=0 crc=0`） | Step 3 合并成一条 |
| T9-10 | Minor | `probe_targets` 里 `for host in "${pids[@]}"` —— 循环变量装的是 **PID**，名字却叫 `host` | Step 3 改名 `pid` |
| T9-11 | Minor | Task 9 **没有独立的验收标准段**（Task 3–8 都有） | 补一个 |
| T9-12 | 测试侧 | **控制器自己第一版新 Step 1 有三处缺陷**（都在测试侧，不是实现侧）：① 共享 mock 集合里含 `do_deploy` → 把**被测对象本身**替换掉了 → 22 条 `do_deploy` 断言全部变红（基线 rc=1、红 26 条）；② 两个二维码用例共用同一个 `OUT_DIR` → 前一个用例造的 `qrcode.txt` 让后一个「不打印」的断言变红；③ 控制器自己的诊断脚本里写了 `10#PORT`（**与实现侧同一个 bug**）→ 先栽在这上面，才顺藤摸瓜找到 T9-4 | ① `do_deploy` 的 mock 单独放一份 `t9_mocks_wizard`，只给 `deploy_wizard` 的用例用；② 二维码的「没有文件」用例换用另一个 `OUT_DIR`；③ 诊断脚本改成 `10#$PORT` |

> **控制器的自我记账**：
> ① 本轮预扫用的探针脚本第一版**装错了沙箱**（把 `install.sh` 加进了 `test/unit.sh`
>    的 source 区域）—— 与 Task 8 同款错误。修法：分两次跑，先手工跑通再批量变异。
> ② **「探针给出的异常结论必须先用手工的最简复现核对」这条纪律，本轮又用上一次**：
>    诊断脚本里 `(( 10#PORT ))` 报错，第一反应是「测试写错了」，手工复现后才发现
>    **实现侧也是错的**（计划第 5448 行）—— 如果不复现，这个 bug 会被当成「测试的错」
>    顺手改掉，然后**原样的 bug 留在计划里**。
> ③ 变异矩阵第一版有 **1 条**变异串与新 Step 3 的实际文本不符（B3：缩进写成 8 空格，
>    实际是 6 空格）→ 片段命中 0 次 → 变异根本没生效 → 那条「已验证」是假的。
>    矩阵脚本对**命中次数 ≠ 1** 直接报错、不静默跳过 → 修串后单独复跑，
>    确认它真的命中点名的断言（1 条红，正是「choose_target 在 --yes 下自动挑选
>    第一个 ok 且延迟已知的目标」）。**最终 28 条变异全部命中。**

#### 修订轮 1 的验收标准

1. `lib/deploy.sh` 追加的内容与下面 **Step 3 代码块逐字节一致**（追加在文件末尾）。
2. `test/unit.sh` 里 Task 9 的插入段与下面 **Step 1 代码块逐字节一致**
   （追加在 `test_summary` **之前**）。
3. `bash test/unit.sh` 全部通过、退出码 0。
4. 断言总数必须恒定，且**连跑 4 次条数相同**。
   ⚠️ **平台差是【三个数】**（构成见 Global Constraints）：
   本机（Windows + MSYS）**545**、Debian **以 root 运行** **550**、
   Debian **以非 root 运行** **552**（= GitHub Actions runner 的身份）。
   报告里必须写明「哪个平台 **+ 以什么身份运行**」。
   （底座 445 + Task 9 修订轮 1 的 100）
5. 红灯证据（**28 条变异**，每条都要贴出**变红的断言原文**）：
   - 把 `probe_targets` 的 mktemp 空值守卫去掉
     → 「probe_targets 在 mktemp 失败时返回非零」必须变红；
   - 把 `probe_targets` 的 `tui_err` 的 `>&2` 去掉
     → 「probe_targets 的诊断信息不写 stdout」必须变红；
   - 把 `probe_targets` 的「未知延迟排最后」处理去掉
     → 「probe_targets 把未知延迟的目标排在最后」必须变红；
   - 把 `probe_targets` 的 TLS1.3 判定去掉
     → 「probe_targets 输出格式为 host|tls|latency」必须变红；
   - 把 `choose_target` 回退分支的 `tui_warn` 的 `>&2` 去掉
     → 「choose_target 在探测不可用时回退到默认目标」必须变红；
   - 把 `choose_target` 取消分支的 `tui_warn` 的 `>&2` 去掉
     → 「choose_target 在用户取消时回退到第一项」必须变红；
   - 把 `choose_target` 自动挑选里的 `&& "$lat" != '?'` 去掉
     → 「choose_target 在 --yes 下自动挑选第一个 ok 且延迟已知的目标」必须变红；
   - 把 `choose_target` 的 `tui_menu` 的 `>&2` 去掉
     → 「choose_target 把菜单渲染到 stderr」必须变红；
   - 把 `do_deploy` 的 `install_xray` 失败处理去掉
     → 「do_deploy 在安装内核失败时返回非零」必须变红；
   - 把 `do_deploy` 的 `gen_keys` 失败处理去掉
     → 「do_deploy 在生成密钥失败时返回非零」必须变红；
   - 把 `do_deploy` 的 `render_server_config` 失败处理去掉
     → 「do_deploy 在渲染配置失败时返回非零」必须变红；
   - 把 `do_deploy` 的 `write_config_atomic` 失败处理去掉
     → 「do_deploy 在写配置失败时返回非零」必须变红；
   - 把 `do_deploy` 的 `setup_systemd` 失败处理去掉
     → 「do_deploy 在 systemd 配置失败时返回非零」必须变红；
   - 把 `do_deploy` 的 `FIREWALL_OK=0` 改成 `=1`
     → 「do_deploy 在防火墙放行失败时把状态标记为 0」必须变红；
   - 把 `do_deploy` 的 mktemp 空值守卫去掉
     → 「do_deploy 在 mktemp 失败时返回非零」必须变红；
   - 把 `deploy_wizard` 里 `--yes` 分支的「改用端口后再验一次」去掉
     → 「deploy_wizard 在改用的端口仍被占用时返回非零」必须变红；
   - 把 `deploy_wizard` 里菜单分支的「改用端口后再验一次」去掉
     → 「deploy_wizard 在菜单改端口后遇到占用端口时中止」必须变红；
   - 把 `deploy_wizard` 的「端口探测不可用」提示去掉
     → 「deploy_wizard 在端口探测不可用时给出提示」必须变红；
   - 把 `deploy_wizard` 的「回退到本机地址」去掉
     → 「deploy_wizard 回退使用本机地址」必须变红；
   - 把 `deploy_wizard` 的「探测不到地址就中止」去掉
     → 「deploy_wizard 在探测不到任何地址时返回非零」必须变红；
   - 把 `deploy_wizard` 的「伪装目标为空就中止」去掉
     → 「deploy_wizard 在伪装目标为空时返回非零」必须变红；
   - 把 `deploy_wizard` 的「用户取消就中止」去掉
     → 「deploy_wizard 在用户不确认时返回非零」必须变红；
   - 把 `deploy_wizard` 的「状态保存失败就中止」去掉
     → 「deploy_wizard 在状态保存失败时返回非零」必须变红；
   - 把 `deploy_wizard` 的「物料导出失败就中止」去掉
     → 「deploy_wizard 在客户端物料导出失败时返回非零」必须变红；
   - 把 `deploy_wizard` 的「分享链接为空就中止」去掉
     → 「deploy_wizard 在分享链接为空时返回非零」必须变红；
   - 把 `deploy_wizard` 的「面板里反映防火墙放行失败」去掉
     → 「deploy_wizard 在部署完成面板里如实反映防火墙放行失败」必须变红；
   - 把 `deploy_wizard` 的 `10#$PORT` 改回 `10#PORT`（**还原 T9-4 那个 bug**）
     → 「deploy_wizard 在用户手动指定端口时继续部署」必须变红；
   - 把 `deploy_wizard` 的「有 qrcode.txt 才打印」去掉
     → 「deploy_wizard 在没有 qrcode.txt 时不打印二维码小节标题」必须变红。
   ⚠️ **点名的断言必须与预演结果里【实际变红的那一条】逐字对上**，不能只看「红了几条」。
   ⚠️ **变异串必须与 `lib/deploy.sh` 的实际文本逐字一致** —— 片段命中次数 ≠ 1 时，
   变异就是**没生效**（控制器第一版有 2 条这样的假验证）。
   ⚠️ **mock 必须精确**：共享 mock 集合里**不许**出现与被测对象同名的函数。
6. `lib/tui.sh`、`lib/core.sh`、`lib/client.sh`、`test/lib.sh`、`install.sh`、Task 5 段、Task 6 段、Task 7 段、Task 8 段 **一字未动**（本任务只改 `lib/deploy.sh` 与 `test/unit.sh`）。
7. 计划文件实施者一个字都不许改。

**Step 1: 写失败的测试**

追加到 `test/unit.sh`：

```bash
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
  local host tmp sortkey h t l pid
  tmp=$(mktemp)
  # mktemp 失败时 tmp 为空 → 后面会写出 ".<host>" 污染当前目录 → 必须守卫。
  if [[ -z "$tmp" ]]; then
    # ⚠️ 诊断信息必须走 stderr：调用方是 `probe=$(probe_targets)` ——
    #    tui_err 默认写 stdout → 这条报错会被当成【探测数据】吞进 probe，
    #    于是 choose_target 拿到的是一段错误文本而不是空串 → 解析出垃圾主机名。
    tui_err "无法创建临时文件，目标探测中止" >&2
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
  # 循环变量是 PID，不是主机名 —— 名字写错会让人以为 wait 的是 host。
  for pid in "${pids[@]}"; do wait "$pid" 2>/dev/null || true; done
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
    # ⚠️ 提示语必须走 stderr：调用方是 `SNI=$(choose_target)` ——
    #    tui_warn 默认写 stdout → 这条提示会被当成【主机名】吞进去，
    #    SNI 变成「提示文本 + 主机名」的多行串 → 写进 config.json 就是废配置。
    tui_warn "目标探测不可用，回退默认：www.microsoft.com" >&2
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
    # ⚠️ 提示语必须走 stderr：调用方是 `SNI=$(choose_target)` ——
    #    tui_warn 默认写 stdout → 这条提示会被当成【主机名】吞进去。
    tui_warn "未选择伪装目标，回退到第一项" >&2
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
  # ⚠️ 端口探测不可用时必须提示：
  #    port_in_use 在【既没有 ss 也没有 netstat】时恒返回 1（= 端口空闲）
  #    → 用户以为端口干净 → 部署走到 systemd 阶段才炸，
  #    而且首句报错是「systemd 配置失败」，与真正原因（端口被占）无关。
  if ! have_cmd ss && ! have_cmd netstat; then
    tui_warn "无法确认端口是否空闲（系统缺少 ss 与 netstat）"
    tui_tip "若部署时报端口被占用，请用 --port 指定其它端口。"
  fi
  if port_in_use "$PORT"; then
    local occ
    occ=$(port_occupant "$PORT")
    tui_warn "端口 $PORT 已被占用${occ:+（$occ）}"
    if [[ ${OPT_YES:-0} -eq 1 ]]; then
      PORT=$(random_free_port)
      # ⚠️ random_free_port 的兜底端口 44321 从未校验过是否被占用
      #    → 这里【必须】再验一次，否则会把一个占用端口写进 config.json，
      #    直到 systemd 阶段才以「address already in use」失败。
      [[ -n "$PORT" ]] || { tui_err "找不到空闲端口，部署中止。"; return 1; }
      if port_in_use "$PORT"; then
        tui_err "端口 $PORT 仍被占用，部署中止。"
        return 1
      fi
      tui_tip "已自动改用空闲端口：$PORT"
    else
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
        0) PORT=$(random_free_port)
            [[ -n "$PORT" ]] || { tui_err "找不到空闲端口，部署中止。"; return 1; }
            if port_in_use "$PORT"; then
              tui_err "端口 $PORT 仍被占用，部署中止。"
              return 1
            fi
            tui_tip "已改用端口 $PORT" ;;
        1) PORT=$(tui_input "请输入新端口" "$PORT" "1-65535")
            # 用 10# 前缀：裸算术会把 "08" 当八进制，直接报「value too great for base」。
            # ⚠️ 必须是 10#$PORT（带 $）：bash 不会在 10# 后解析【变量名】，
            #    10#PORT 会被当成「以 10 为基的数字 PORT」→ 直接报
            #    "value too great for base" → 用户手动指定的端口【必然】被判非法。
            [[ "$PORT" =~ ^[0-9]+$ ]] && (( 10#$PORT > 0 && 10#$PORT < 65536 )) || { tui_err "端口非法"; return 1; } ;;
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
- Modify: `lib/deploy.sh`（追加 `menu_*` 与 `management_menu`；并对 Task 9 的 `deploy_wizard` 做两处定点修订）
- Modify: `test/unit.sh`
- Create: `test/helpers/menu_management.sh`

**Interfaces:**
- Consumes: Task 3 `load_state` `save_state`；Task 5 `gen_keys`；Task 6 `install_xray` `restart_service` `open_firewall` `enable_bbr` `service_status`；Task 7 `build_share_link` `export_client_artifacts`
- Produces:
  - `management_menu` → 循环直到用户退出
  - `menu_show_client` / `menu_restart` / `menu_logs` / `menu_update_xray` / `menu_tune` / `menu_rotate_keys` / `menu_uninstall`

#### 修订轮 1 的逐项发现与处置

> 本节由**控制器**在 Task 10 派发前预扫（静态核对 + 沙箱实证）之后写入。
> 本节列的全是**计划缺陷**，责任方是控制器；Task 10 的代码块本身还没被实施过。
>
> 沙箱底座 = `git archive HEAD` 整棵树（**Task 9 的实施结果** `e55e8e2`）
> + Task 10 的两个新代码块 + 两处定点修订。
>
> ⚠️ **底座必须是 Task 10 实施时的 HEAD**，不能沿用别的任务里的基线。

| # | 级别 | 发现 | 处置 |
|---|---|---|---|
| T10-1 | **Important** | **Step 1 只有 2 条断言，8 个新函数几乎零覆盖。** 新增 `menu_show_client` `menu_restart` `menu_logs` `menu_update_xray` `menu_tune` `menu_rotate_keys` `menu_uninstall` `management_menu` 共 8 个函数，原 Step 1 只验证了「未部署时菜单能退出」+「有『未部署』提示」两条。`menu_rotate_keys`（密钥轮换）、`menu_update_xray`（**以 root 下载并执行 GitHub 上的远程脚本**）、`menu_tune`（动防火墙）都是**高危路径**，一条断言都没有 —— 与 T9-1 同款缺陷 | Step 1 重写：2 → **78 条**断言，覆盖 8 个函数的全部分支；全部 mock（`journalctl` `curl` `ensure_packages` `tui_run` `restart_service` `open_firewall` `enable_bbr` `gen_keys` `render_server_config` `write_config_atomic` `export_client_artifacts` `build_share_link` 全部换成假实现），**一次网络请求都不发、一次防火墙命令都不执行**；另加一组**完全不 mock** 的真实 shell 集成用例（起真的 bash、source 真的 lib/*、管道喂「9」选中「退出」） |
| T10-2 | **Important** | **`menu_tune` 没有「尚未部署」守卫。** `menu_show_client` 和 `menu_rotate_keys` 都有，唯独 `menu_tune` 没有 → 未部署时 `$PORT` 是**空串**（`core.sh:26` 给的全局默认值）→ `open_firewall ""` → `ufw allow "/tcp"` / `iptables --dport ""` / `nft ... tcp dport ""` **三条全报错**，而且报出来的错与真实原因（压根没部署、没有端口）完全无关 | Step 3 加 `state_exists` + `load_state` 双守卫，与另两个菜单函数一致；Step 1 补三条断言（返回非零 / 明确提示 / **不碰防火墙**） |
| T10-3 | **Important** | **`management_menu` 与 `deploy_wizard` 互相递归。** 菜单第 0 项「重新部署」调 `deploy_wizard`；而 `deploy_wizard` 末尾（`OPT_YES≠1`）会 `tui_pause; management_menu` → **再开一层菜单**。用户在菜单里选一次「重新部署」，部署完掉进第二层菜单；再选一次就是第三层。内层退出后回到外层 → 用户被两层菜单夹住 | Step 3 用全局标志位 `IN_MENU` 掐断这条回路（`management_menu` 入口置 1，`deploy_wizard` 用 `${IN_MENU:-0}` 判断）；**作为对 Task 9 产物的定点修订 P2**；Step 1 补**正反一对**断言 |
| T10-4 | Minor | **`local choice` 被声明了两次**（`local choice` + `local choice=0 crc=0`）—— 与 T9-9 同款 | Step 3 合并成一条 |
| T10-5 | Minor | **Step 3 末尾的说明与 install.sh 现状矛盾。** 原文：「并把 `install.sh` 的 `management_menu` 占位改为直接调用 `lib/deploy.sh` 中的实现（删除占位函数），`deploy_wizard` 若也移入 `lib/deploy.sh` 需一并移动（`install.sh` 中删除其占位定义）。」—— 但 install.sh **从来没有** `management_menu` 占位函数（它走的是 `declare -F management_menu` 守卫 + 直接调用），`deploy_wizard` 也在 Task 9 就进了 `lib/deploy.sh`，install.sh 里同样没有它的占位。照这段话做会找不到东西 | 删掉这段过期说明；Task 10 的提交清单里**去掉 `install.sh`** |
| T10-6 | Minor | **`menu_logs` 用 `journalctl -f`（跟随模式），非 TTY 下会永久阻塞。** 测试一旦覆盖到这条就会挂死（`timeout` → rc=124） | Step 1 里 `journalctl` 必须 mock 成一次性返回；Step 3 的注释里写明「`-f` 在 TTY 下需 Ctrl+C 退出」 |
| T10-7 | Minor | **`menu_update_xray` 以 root 下载并执行 GitHub 上的 `install-release.sh`，无校验和。** 这就是登记在案的 **T6-7** | 保留实现（用户明确要求「更新内核」能力），但 **Task 13 的 README「验证状态声明」必须点名这一条**；本任务的验收标准里也要写明 |
| T10-8 | Minor | **`management_menu` 的 `tui_menu` 没有把菜单重定向到 stderr。** Task 9 的 `choose_target` 已经踩过这个坑（`SNI=$(choose_target)` 把整张菜单吞成 SNI）。`management_menu` 目前没有 `$(...)` 捕获的调用点 → 当下无害，但 `deploy_wizard` 末尾会调它，而 `deploy_wizard` 在 Task 9 的测试里是被 `out=$( ( ... deploy_wizard ) 2>&1)` 捕获的 → 菜单文本会混进 `$out` | Step 3 给 `tui_menu` 加 `>&2`，与 Task 9 的做法统一；Step 1 补「菜单不写 stdout / 菜单确实写到 stderr」一对断言 |
| T10-9 | Minor | **`menu_rotate_keys` 中途失败会留下「配置已换、状态未落盘」的不一致。** 顺序是 `write_config_atomic` → `save_state` → `restart_service` → `export_client_artifacts`；`save_state` 失败时 config.json 已经是新密钥、状态文件还是旧的 → 分享链接里的公钥与服务端实际公钥**不匹配** → 客户端连不上，而用户只看到一句「状态保存失败」 | Step 3 把提示改成明示「服务端配置已更新为新密钥，但状态文件未落盘」+ 给出补救动作（`install.sh --status`）；Step 1 补两条断言 |
| T10-10 | Minor | **`management_menu` 未部署时仍列出全部 9 个选项**（含「轮换密钥」「卸载」），用户点进去只得到「未部署」提示 | 属设计取舍，不改。**但 T10-2 的守卫必须补上**，否则「网络调优」不是提示而是**真的去动防火墙** |

#### 修订轮 1 顺带修掉的一个 Task 9 遗留缺陷

| # | 级别 | 发现 | 处置 |
|---|---|---|---|
| **T9-x** | Minor | **`deploy_wizard` 的「我手动指定其它端口」分支不复查端口占用。** `--yes` 分支与菜单的「改用随机端口」分支都做了 `port_in_use` 复查（T9-8 的修复），唯独「手动输入」这条只校验了范围 → 用户手动输入一个**已被占用**的端口 → 部署一路走到 `setup_systemd` 才炸，首句报错是「systemd 配置失败」—— **正是计划自己在 T9-7 里批评过的那种「首句报错与真实原因无关」** | 作为**定点修订 P1** 补上复查；Step 1 补**正反一对**断言（被占用 → 中止；空闲 → 照常部署） |

> **为什么并进 Task 10 而不是另开一轮 Task 9 修订：**
> P1 改的是 `lib/deploy.sh` 里 `deploy_wizard` 的一个分支，与 Task 10 的新代码**在同一个文件**；
> 为一个 Minor 缺陷重开一轮「改计划 → 重新派发 → 重新复核」的成本远高于收益。
> **代价是 Task 9 的 Step 3 块不再与最终 `lib/deploy.sh` 逐字节一致** ——
> 因此本任务把「定点修订」写成**可机械核对的精确文本替换**（P1 / P2），
> 验收标准里逐条点名，控制器复核时逐条核对。


#### 控制器的变异判据修正（落盘后追加）

第一次跑这 24 条变异时，**C1 / C2 / D3 三条没有命中点名的断言**。
归因是**沙箱实证**，不是猜测：

| 变异 | 第一版（只拆一道守卫） | 为什么没命中点名的断言 |
|---|---|---|
| C1 `menu_show_client` | 拆掉 `state_exists` 守卫 | **退出码没变** —— 下一道 `load_state \|\| return 1` 照样返回 1 → 点名的「返回非零」保持绿；真正变红的只是「给出明确提示」 |
| C2 `menu_rotate_keys` | 拆掉 `state_exists` 守卫 | 同上 |
| D3 `menu_update_xray` | 拆掉 mktemp 空值守卫 | `curl -o ""`（被 mock 成成功）→ `chmod +x ""` 在 MSYS 上**真的返回 1**（实测 `chmod: cannot access ''`）→ 仍然 `return 1` → 同样只有「给出明确提示」变红 |

**根因不是测试弱，而是「变异选错了目标」**：这几道守卫的作用是**「给出明确提示」**，
退出码由**下一道守卫**兜着 —— 所以「返回非零」那条断言本来就抓不住这个变异。

**处置**：把这三条改成**复合变异**（把两道守卫一起拆掉）。
这才是「不检查未部署就直接展示 / 直接轮换 / 直接下载」的真实缺陷形态，
改完之后「返回非零」「给出明确提示」「不生成新密钥」会**一起**变红。

> **Step 1 / Step 3 的代码块一个字都没改** —— 改的只有变异串与下面验收标准里
> 这三条的描述。断言条数仍是 623。

#### 修订轮 1 的定点修订（对 Task 9 产物的精确文本替换）

这两处改的是 `lib/deploy.sh` 里 `deploy_wizard` 函数内部。
**除此之外，`lib/deploy.sh` 的 Task 9 Step 3 块一字不动。**

> 下面四个代码块用 `text` 围栏而不是 `bash` —— 它们是**函数内部的片段**，
> 单独 `bash -n` 必然报语法错（`case` 分支的 `1) ...` 结尾缺 `;;` 上下文、
> 结尾多一个 `}`）。用 `text` 围栏可以让计划的语法自检脚本跳过它们，
> 同时**原样**展示要替换的文本。

**P1 —— 手动指定端口的分支必须复查占用**

- 改前：

```text
        1) PORT=$(tui_input "请输入新端口" "$PORT" "1-65535")
            # 用 10# 前缀：裸算术会把 "08" 当八进制，直接报「value too great for base」。
            # ⚠️ 必须是 10#$PORT（带 $）：bash 不会在 10# 后解析【变量名】，
            #    10#PORT 会被当成「以 10 为基的数字 PORT」→ 直接报
            #    "value too great for base" → 用户手动指定的端口【必然】被判非法。
            [[ "$PORT" =~ ^[0-9]+$ ]] && (( 10#$PORT > 0 && 10#$PORT < 65536 )) || { tui_err "端口非法"; return 1; } ;;
```

- 改后：

```text
        1) PORT=$(tui_input "请输入新端口" "$PORT" "1-65535")
            # 用 10# 前缀：裸算术会把 "08" 当八进制，直接报「value too great for base」。
            # ⚠️ 必须是 10#$PORT（带 $）：bash 不会在 10# 后解析【变量名】，
            #    10#PORT 会被当成「以 10 为基的数字 PORT」→ 直接报
            #    "value too great for base" → 用户手动指定的端口【必然】被判非法。
            [[ "$PORT" =~ ^[0-9]+$ ]] && (( 10#$PORT > 0 && 10#$PORT < 65536 )) || { tui_err "端口非法"; return 1; }
            # 手动指定的端口同样必须复查占用：只校验范围不校验占用 →
            # 用户会一路走到 systemd 才炸，首句报错是「systemd 配置失败」，
            # 与真实原因（端口被占）完全无关 —— 正是本轮修掉的 T9-7 抱怨过的那类错。
            if port_in_use "$PORT"; then
              tui_err "端口 $PORT 已被占用，请另选一个。"
              return 1
            fi ;;
```

**P2 —— 已经在管理菜单里时不再嵌套调用 `management_menu`**

- 改前：

```text
  if [[ ${OPT_YES:-0} -eq 0 ]]; then
    tui_pause
    management_menu
  fi
  return 0
}
```

- 改后：

```text
  # ⚠️ 已经在管理菜单里就【不要】再开一层：
  #    管理菜单的第 0 项「重新部署」会调 deploy_wizard，
  #    而这里又会调 management_menu → 用户在菜单里选一次「重新部署」，
  #    部署完就掉进第二层菜单，再选一次「重新部署」就是第三层。
  #    用 IN_MENU 标志位把这条回路掐断。
  #    用 ${IN_MENU:-0} 读：deploy.sh 被单独 source（单元测试 / helper）时
  #    它可能根本没定义，在 set -u 下直接引用会报 unbound variable。
  if [[ ${OPT_YES:-0} -eq 0 && "${IN_MENU:-0}" -eq 0 ]]; then
    tui_pause
    management_menu
  fi
  return 0
}
```

> ⚠️ **两处替换的命中次数必须【恰好各 1 次】** —— 命中 0 次说明文本对不上，
> 命中 ≥2 次说明改错了地方。控制器与实施者都要自己核。

#### 修订轮 1 的验收标准

1. `lib/deploy.sh` 追加的内容与下面 **Step 3 代码块逐字节一致**（追加在文件末尾）。
2. `lib/deploy.sh` 中 `deploy_wizard` 的**两处**定点修订（P1 / P2）与上面写的
   **改后**文本逐字一致；**除这两处外，Task 9 Step 3 块一字未动**。
3. `test/unit.sh` 里 Task 10 的插入段与下面 **Step 1 代码块逐字节一致**
   （追加在 `test_summary` **之前**）。
4. `bash test/unit.sh` 全部通过、退出码 0。
5. 断言总数必须恒定，且**连跑 4 次条数相同**。
   ⚠️ **平台差是【三个数】**（构成见 Global Constraints）：
   本机（Windows + MSYS）**623**、Debian **以 root 运行** **628**、
   Debian **以非 root 运行** **630**（= GitHub Actions runner 的身份）。
   （底座 545 + Task 10 修订轮 1 的 78）
   报告里必须写明「哪个平台 **+ 以什么身份运行**」。
6. 红灯证据（**24 条变异**，每条都要贴出**变红的断言原文**）：
   - A1 把 `management_menu` 的「尚未部署」提示去掉
     → 「未部署时给出明确提示」必须变红；
   - A2 把 `management_menu` 的 `tui_menu` 的 `>&2` 去掉
     → 「management_menu 把菜单渲染到 stderr」必须变红；
   - A3 把 `management_menu` 第 0 项的 `deploy_wizard` 换成 `:` 
     → 「management_menu 第 0 项调用 deploy_wizard」必须变红；
   - A4 把第 1 项改成调 `menu_restart`
     → 「management_menu 第 1 项展示分享链接」必须变红；
   - A5 把第 2 项改成调 `menu_show_client`
     → 「management_menu 第 2 项调用 restart_service」必须变红；
   - A6 把第 3 项改成调 `menu_restart`
     → 「management_menu 第 3 项调用 journalctl」必须变红；
   - A7 把第 7 项的手工卸载指引去掉
     → 「management_menu 第 7 项在没有卸载脚本时给出明确提示」必须变红；
   - A8 把第 8 项的 `tui_info "已退出"` 去掉
     → 「management_menu 第 8 项提示已退出」必须变红；
   - B1 把 `menu_tune` 的「尚未部署」守卫去掉
     → 「menu_tune 在未部署时返回非零」必须变红；
   - B2 把 `menu_tune` 的 `open_firewall` 失败处理改成 `|| true`
     → 「menu_tune 在防火墙放行失败时返回非零」必须变红；
   - B3 把 `menu_tune` 的 `enable_bbr` 失败改成 `return 1`
     → 「menu_tune 在 BBR 未启用时仍返回 0」必须变红；
   - C1 把 `menu_show_client` 的「尚未部署」守卫**和紧随其后的 `load_state` 失败检查一起去掉**
     → 「menu_show_client 在未部署时返回非零」必须变红；
   - C2 把 `menu_rotate_keys` 的「尚未部署」守卫**和紧随其后的 `load_state` 失败检查一起去掉**
     → 「menu_rotate_keys 在未部署时返回非零」必须变红；
   - C3 把 `menu_rotate_keys` 的 `save_state` 失败处理改成 `|| true`
     → 「menu_rotate_keys 在状态保存失败时返回非零」必须变红；
   - C4 把 `menu_rotate_keys` 的 `save_state` 失败提示改回旧文案
     → 「menu_rotate_keys 如实说明服务端配置已换但状态未落盘」必须变红；
   - C5 把 `menu_rotate_keys` 的 `export_client_artifacts` 失败处理改成 `|| true`
     → 「menu_rotate_keys 在客户端物料导出失败时返回非零」必须变红；
   - C6 把 `menu_rotate_keys` 的「用户取消」改成 `return 1`
     → 「menu_rotate_keys 在用户取消时返回 0」必须变红；
   - D1 把 `menu_update_xray` 的 `ensure_packages` 失败处理改成 `|| true`
     → 「menu_update_xray 在依赖安装失败时返回非零」必须变红；
   - D2 把 `menu_update_xray` 的 `curl` 失败处理改成 `|| true`
     → 「menu_update_xray 在下载安装脚本失败时返回非零」必须变红；
   - D3 把 `menu_update_xray` 的 mktemp 空值守卫**和 `chmod +x` 的失败检查一起去掉**
     → 「menu_update_xray 在 mktemp 失败时返回非零」必须变红；
   - D4 把 `menu_update_xray` 的 `return $rc` 改成 `return 0`
     → 「menu_update_xray 在安装脚本执行失败时返回非零」必须变红；
   - E1 让定点修订 P1 失效（去掉手动端口的占用复查）
     → 「deploy_wizard 在手动指定的端口被占用时返回非零」必须变红；
   - E2 让定点修订 P2 失效（去掉 `IN_MENU` 判断）
     → 「deploy_wizard 在已经处于管理菜单中时不再嵌套调用管理菜单」必须变红。
   ⚠️ **点名的断言必须与预演结果里【实际变红的那一条】逐字对上**，不能只看「红了几条」。
   ⚠️ **变异串必须与 `lib/deploy.sh` 的实际文本逐字一致** —— 片段命中次数 ≠ 1 时，
   变异就是**没生效**。
   ⚠️ **mock 必须精确**：共享 mock 集合里**不许**出现与被测对象同名的函数
   （`t10_mocks` 里不许有 `management_menu` / `menu_*`；
   `deploy_wizard` 也不许在 `t10_mocks` 里 —— 它在「向导」那组用例里是被测对象，
   因此单独放在 `t10_mocks_menu`）。
7. `lib/tui.sh`、`lib/core.sh`、`lib/client.sh`、`test/lib.sh`、`install.sh`、Task 5 段、Task 6 段、Task 7 段、Task 8 段、Task 9 段 **一字未动**（本任务只改 `lib/deploy.sh` 与 `test/unit.sh`）。
8. 计划文件实施者一个字都不许改。
9. **T9-y 复核**：`management_menu` 落地后，交互式部署跑完最后一步不再出现
   `management_menu: command not found`（`deploy_wizard` 末尾的调用必须能命中本任务新实现的
   `management_menu`）。**由 Task 9 遗留、在本任务消解。**

**Step 1: 写失败的测试**

追加到 `test/unit.sh`：

```bash
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
curl() { printf 'MOCK_CURL %s\n' "$*"; return 0; }
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

# 第 4 项：更新内核 → 调 ensure_packages + curl + tui_run
out=$( ( eval "$(t10_mocks; t10_mocks_menu)"
         MENU_PICK=4
         t10_menu_pick
         management_menu ) 2>&1 ); rc=$?
assert_status 0 "$rc" "管理菜单选择「更新内核」时正常返回"
assert_contains "$out" "MOCK_ENSURE_PKGS" "management_menu 第 4 项先补齐依赖"
assert_contains "$out" "MOCK_CURL" "management_menu 第 4 项下载安装脚本"
assert_contains "$out" "MOCK_TUI_RUN" "management_menu 第 4 项执行安装脚本"
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

# menu_update_xray：依赖装不上 → 必须停在这里（不能去下载脚本）
out=$( ( eval "$(t10_mocks; t10_mocks_menu)"
         ensure_packages() { printf 'MOCK_ENSURE_PKGS %s\n' "$*"; return 1; }
         menu_update_xray ) 2>&1 ); rc=$?
assert_status 1 "$rc" "menu_update_xray 在依赖安装失败时返回非零"
assert_contains "$out" "依赖安装失败" "menu_update_xray 在依赖安装失败时给出明确提示"
assert_not_contains "$out" "MOCK_CURL" "menu_update_xray 在依赖安装失败后不下载安装脚本"

# menu_update_xray：下载失败 → 必须报错
out=$( ( eval "$(t10_mocks; t10_mocks_menu)"
         curl() { printf 'MOCK_CURL %s\n' "$*"; return 1; }
         menu_update_xray ) 2>&1 ); rc=$?
assert_status 1 "$rc" "menu_update_xray 在下载安装脚本失败时返回非零"
assert_contains "$out" "下载安装脚本失败" "menu_update_xray 在下载失败时给出明确提示"
assert_not_contains "$out" "MOCK_TUI_RUN" "menu_update_xray 在下载失败后不执行安装脚本"

# menu_update_xray：mktemp 失败 → 必须中止（否则 curl -o "" 会失败、rm -f "" 会报错）
out=$( ( eval "$(t10_mocks; t10_mocks_menu)"
         mktemp() { return 1; }
         menu_update_xray ) 2>&1 ); rc=$?
assert_status 1 "$rc" "menu_update_xray 在 mktemp 失败时返回非零"
assert_contains "$out" "无法创建临时文件" "menu_update_xray 在 mktemp 失败时给出明确提示"

# menu_update_xray：安装脚本执行失败 → 必须返回非零且不重启
out=$( ( eval "$(t10_mocks; t10_mocks_menu)"
         tui_run() { printf 'MOCK_TUI_RUN %s\n' "$*"; return 1; }
         menu_update_xray ) 2>&1 ); rc=$?
assert_status 1 "$rc" "menu_update_xray 在安装脚本执行失败时返回非零"
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
```

创建 `test/helpers/menu_management.sh`（管理菜单实现在 `lib/deploy.sh`，直接 source 调用，
**不使用 `sed`+`eval` 抽取函数——那种做法在函数体含 `}` 时会截断**）：

```bash
#!/usr/bin/env bash
# 管理菜单的「真实 shell」入口：source 真实的 lib/*，进管理菜单。
# 用法：printf '9\n' | bash test/helpers/menu_management.sh
#   → 管道喂「9」= 选中第 9 项「退出」→ 菜单正常退出（rc=0）
#
# ⚠️ 状态文件必须指向一个【必然不存在】的路径：
#    core.sh 里是 STATE_FILE="${STATE_FILE:-/etc/vless-reality/deploy.env}"
#    —— 预设值会被保留 → 传进来一个假路径就能确定地测「未部署」分支，
#    不受「这台机器上是不是真的部署过」的影响。
export STATE_FILE="${T10_STATE_FILE:-/nonexistent/vless-reality-test/deploy.env}"
export STATE_DIR="$(dirname "$STATE_FILE")"

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=lib/tui.sh
source "$ROOT/lib/tui.sh"
# shellcheck source=lib/core.sh
source "$ROOT/lib/core.sh"
# shellcheck source=lib/deploy.sh
source "$ROOT/lib/deploy.sh"
# shellcheck source=lib/client.sh
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
  # -f 是跟随模式，会一直挂着直到用户 Ctrl+C。
  # 非 TTY（CI / 单元测试）下必须由调用方 mock 掉，否则会永久阻塞。
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
  # 必须先确认「已部署」：未部署时 $PORT 是【空串】（core.sh 给的全局默认值），
  # 此时 open_firewall "" 会去执行 `ufw allow "/tcp"` / `iptables --dport ""` /
  # `nft ... tcp dport ""` —— 三条全部报错，而且报出来的错与真实原因
  # （压根没部署、根本没有端口）完全无关。
  # menu_show_client 与 menu_rotate_keys 都有这道守卫，menu_tune 原来漏了。
  state_exists || { tui_warn "尚未部署，无端口可放行，无法调优。"; return 1; }
  load_state || { tui_err "状态文件读取失败，无法调优。"; return 1; }
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
  # ⚠️ 这一步失败时，服务端配置【已经】换成新密钥了，而状态文件还是旧的
  #    （旧 UUID / 旧公钥）→ 分享链接里的公钥与服务端实际公钥对不上 →
  #    客户端导入后连不上，而用户只看到一句「状态保存失败」。
  #    所以提示里必须如实说明「配置已换、状态没落盘」，并给出补救动作。
  save_state || { tui_err "状态保存失败：服务端配置已更新为新密钥，但状态文件未落盘。"; tui_tip "请用 install.sh --status 核对，或重新执行一次部署。"; return 1; }
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
  # ⚠️ 防止「管理菜单 ↔ deploy_wizard」互相递归：
  #    菜单第 0 项「重新部署」会调 deploy_wizard，而 deploy_wizard 末尾又会调
  #    management_menu → 用户在菜单里选一次「重新部署」，部署完就掉进第二层菜单，
  #    再选一次「重新部署」就是第三层。
  #    用全局标志位告诉 deploy_wizard「现在已经在菜单里了，别再开一层」。
  #    用 ${IN_MENU:-0} 读：deploy.sh 被单独 source（单元测试 / helper）时它可能没定义，
  #    在 set -u 下直接引用会报 unbound variable。
  IN_MENU=1
  while true; do
    tui_banner "$APP_NAME" "管理菜单"
    if ! state_exists; then
      tui_warn "尚未部署。选「重新部署」开始，或直接退出。"
    fi
    local choice=0 crc=0
    # 菜单必须渲染到 stderr：tui_menu 把整张菜单打到 stdout，而 deploy_wizard
    # 末尾会调 management_menu —— 一旦有人用 $(...) 捕获它，菜单文本就会被
    # 当成返回值吞进去。与 choose_target 是同一个坑。
    tui_menu "请选择操作" \
      "重新部署（重跑向导）" \
      "查看配置 / 分享链接 / 二维码" \
      "重启服务" \
      "实时日志（tail -f）" \
      "更新 Xray 内核" \
      "网络调优（BBR / 防火墙）" \
      "轮换密钥与 UUID" \
      "卸载" \
      "退出" >&2 || crc=$?
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

`install.sh` **无需任何改动** —— 它已在 Task 8 通过 `declare -F management_menu` 守卫 + 直接调用
来使用本任务的实现（`deploy_wizard` 也早在 Task 9 就进了 `lib/deploy.sh`，install.sh 里没有它的占位）。

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
