#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# install.sh — VLESS + REALITY 一键部署工具（入口）
#
# 用法:
#   sudo bash install.sh              交互式向导
#   sudo bash install.sh -y           全自动（用默认值）
#   sudo bash install.sh --menu       进入管理菜单
#   sudo bash install.sh --status     查看运行状态
#   sudo bash install.sh --uninstall  卸载
#
# ⚠️ 用 `bash install.sh` 而不是 `./install.sh`：
#    单文件分发版是 `curl -o` 下载来的 → 那个文件【没有执行位】，
#    ./install.sh 会 Permission denied。
#    （仓库里的 install.sh 提交模式是 100755，clone 下来就带执行位；
#      但 `bash install.sh` 两种情况都成立。）

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
OPT_MIRROR=''
OPT_PROXY=''
OPT_LOCAL=''

usage() {
  cat <<EOF
${APP_NAME} v${APP_VERSION}

用法:
  sudo bash install.sh [选项]

选项:
  -y, --yes          全自动无交互，使用内置默认值
  -p, --port <端口>   指定监听端口（默认 443）
  -s, --sni <域名>    指定 REALITY 伪装目标
  -n, --name <备注>   指定分享链接备注
      --uuid <UUID>   指定 UUID（默认自动生成）
      --addr <地址>   指定对外地址（NAT 后的服务器用；默认自动探测公网 IP）
      --mirror <前缀> GitHub 镜像前缀（例：https://gh.llkk.cc/）
      --proxy <地址>  下载走 HTTP/SOCKS5 代理（例：http://127.0.0.1:7890）
      --local <zip>   使用本地已有的 Xray 离线安装包（完全不联网）
  -m, --menu          直接进入管理菜单
      --status        查看运行状态并退出
      --uninstall     卸载并清理
  -h, --help          显示本帮助

网络受限时（GitHub 只有 IPv4、机器没有公网 IPv4）的三种走法：
  --proxy http://127.0.0.1:7890        走本机代理
  --mirror https://gh.llkk.cc/         走 GitHub 镜像
  --local /root/Xray-linux-64.zip      用事先下载好的离线安装包

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
      --mirror)       OPT_MIRROR="${2:-}"; [[ -n "$OPT_MIRROR" ]] || { tui_err "--mirror 缺少参数"; exit 1; }
                     # 镜像前缀会被直接拼在下载 URL 前面 → 必须是 http(s) 绝对地址，
                     # 否则拼出来的地址根本不是 URL，报错会指向 curl 的语法错误，
                     # 而不是「镜像地址写错了」。
                     if ! [[ "$OPT_MIRROR" =~ ^https?://[^[:space:]]+$ ]]; then
                       tui_err "--mirror 必须是 http(s) 镜像地址：$OPT_MIRROR"
                       tui_tip "示例：https://gh.llkk.cc/"
                       exit 1
                     fi
                     shift 2 ;;
      --proxy)        OPT_PROXY="${2:-}"; [[ -n "$OPT_PROXY" ]] || { tui_err "--proxy 缺少参数"; exit 1; }
                     if ! [[ "$OPT_PROXY" =~ ^(https?|socks5h?|socks4)://[^[:space:]]+$ ]]; then
                       tui_err "--proxy 必须是 http/https/socks5 代理地址：$OPT_PROXY"
                       tui_tip "示例：http://127.0.0.1:7890 或 socks5://127.0.0.1:1080"
                       exit 1
                     fi
                     shift 2 ;;
      --local)        OPT_LOCAL="${2:-}"; [[ -n "$OPT_LOCAL" ]] || { tui_err "--local 缺少参数"; exit 1; }
                     # 离线包必须【当场】可用：不能等到下载失败之后才发现路径写错了。
                     if [[ ! -f "$OPT_LOCAL" ]] || [[ ! -r "$OPT_LOCAL" ]]; then
                       tui_err "--local 指定的安装包不存在或不可读：$OPT_LOCAL"
                       tui_tip "示例：--local /root/Xray-linux-64.zip"
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
  # 下载参数落到全局：命令行优先于环境变量（core.sh 里 GITHUB_MIRROR 等
  # 已经能用环境变量预设，这里是覆盖而不是清空）。
  # 必须放在 parse_args 里而不是 main 里：--menu 进管理菜单时同样要用得上，
  # 因为菜单里的「更新 Xray 内核」走的是同一条下载链。
  if [[ -n "$OPT_MIRROR" ]]; then
    GITHUB_MIRROR="$OPT_MIRROR"
  fi
  if [[ -n "$OPT_PROXY" ]]; then
    XRAY_PROXY="$OPT_PROXY"
  fi
  if [[ -n "$OPT_LOCAL" ]]; then
    XRAY_LOCAL_FILE="$OPT_LOCAL"
  fi
  return 0
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

  # 下载通道：必须让用户看得见【实际走哪条路】，
  # 否则「装不上」时用户根本不知道自己是直连、镜像、代理还是离线包。
  if [[ -n "$XRAY_LOCAL_FILE" ]]; then
    tui_ok "下载通道：离线安装包 $XRAY_LOCAL_FILE"
  else
    if [[ -n "$XRAY_PROXY" ]]; then
      tui_ok "下载通道：代理 $XRAY_PROXY"
    else
      tui_ok "下载通道：直连（失败后自动回退内置镜像）"
    fi
    if [[ -n "$GITHUB_MIRROR" ]]; then
      tui_ok "下载镜像：$GITHUB_MIRROR"
    fi
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
    # 用 -f 判定而不是 -x：`-x` 依赖执行位，而执行位【不可靠】——
    # 单文件分发版里根本没有 uninstall.sh，curl 下载来的文件也没有执行位
    # → -x 永远判成「没有」→ 卸载入口是死的。
    # 用 `exec bash` 显式执行 → 完全不依赖执行位。
    if [[ -f "$ROOT_DIR/uninstall.sh" ]]; then
      exec bash "$ROOT_DIR/uninstall.sh"
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
