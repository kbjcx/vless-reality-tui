#!/usr/bin/env bash
# uninstall.sh — 卸载 VLESS + REALITY 部署
#
# 用法:
#   sudo bash uninstall.sh            交互式（卸载前确认）
#   sudo bash uninstall.sh --yes      跳过确认直接卸载
#   sudo bash uninstall.sh --purge    同时删除状态文件
#
# ⚠️ 用 `bash uninstall.sh` 而不是 `./uninstall.sh`：
#    单文件分发版是 `curl -o` 下载来的 → 那个文件【没有执行位】，
#    ./uninstall.sh 会 Permission denied。
#    （仓库里的 uninstall.sh 提交模式是 100755，clone 下来就带执行位；
#      但 `bash uninstall.sh` 两种情况都成立。）
set -uo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/tui.sh
source "$ROOT_DIR/lib/tui.sh"
# shellcheck source=lib/core.sh
source "$ROOT_DIR/lib/core.sh"

PURGE=0
ASSUME_YES=0

usage() {
  cat <<EOF
卸载 VLESS + REALITY 部署

用法:
  sudo bash uninstall.sh [选项]

选项:
      --purge    同时删除状态文件 $STATE_FILE（默认保留）
  -y, --yes      跳过卸载前的确认（用于无人值守场景）
  -h, --help     显示本帮助
EOF
}

parse_args() {
  for a in "$@"; do
    case "$a" in
      --purge) PURGE=1 ;;
      -y|--yes) ASSUME_YES=1 ;;
      -h|--help) usage; exit 0 ;;
      *) tui_err "未知参数：$a"; usage; exit 1 ;;
    esac
  done
  return 0
}

require_root() {
  # EUID 是 bash 的只读变量，无法在测试里注入 → 返回状态、由调用方决定退出码。
  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    tui_err "需要 root 权限，请使用 sudo 重新执行。"
    return 1
  fi
  return 0
}

stop_service() {
  tui_section "停止服务"
  if ! have_cmd systemctl; then
    tui_warn "未找到 systemctl，跳过停止服务。"
    return 0
  fi
  if systemctl disable --now xray >/dev/null 2>&1; then
    tui_ok "xray 服务已停止并取消开机自启"
  else
    tui_warn "xray 服务停止失败（可能未安装）"
  fi
  return 0
}

backup_and_remove_config() {
  tui_section "备份并移除配置"
  if [[ ! -f "$XRAY_CONFIG" ]]; then
    tui_info "服务端配置不存在，跳过。"
    return 0
  fi
  # 备份失败时【绝不能】继续删原配置：否则用户的服务端配置直接丢失、
  # 且没有任何可回滚的副本。备份失败就停在这里，让用户自己决定。
  if ! mkdir -p "$OUT_DIR/backup"; then
    tui_err "无法创建备份目录：$OUT_DIR/backup"
    tui_err "为避免丢失配置，未删除原配置：$XRAY_CONFIG"
    return 1
  fi
  # 备份名带 PID：同一秒内卸载两次也不会互相覆盖。
  local backup_file
  backup_file="$OUT_DIR/backup/config.json.$(date +%Y%m%d%H%M%S).$$"
  if ! cp -f "$XRAY_CONFIG" "$backup_file"; then
    tui_err "备份配置失败：$XRAY_CONFIG"
    tui_err "为避免丢失配置，未删除原配置。请检查 $OUT_DIR 的剩余空间与权限。"
    return 1
  fi
  if ! rm -f "$XRAY_CONFIG"; then
    tui_err "备份已保存到 $backup_file，但原配置删除失败：$XRAY_CONFIG"
    return 1
  fi
  tui_ok "配置已备份并移除：$backup_file"
  return 0
}

revoke_firewall() {
  tui_section "撤销防火墙规则"
  # 必须用 load_state（Task 3 提供的唯一读状态入口），不要直接 `. "$STATE_FILE"`：
  #   ① 直接 source 会把状态文件【执行】一遍（Task 3 修复轮 2 刚把这条改掉）；
  #   ② 没有语法检查，状态文件损坏时报错与真实原因无关；
  #   ③ load_state 能区分「读不到」与「格式错」。
  # 用局部变量 port，不去污染全局的 PORT。
  local port=''
  if [[ -f "$STATE_FILE" ]]; then
    if load_state; then
      port="${PORT:-}"
    else
      tui_warn "状态文件读取失败，无法确定端口（防火墙规则可能残留）。"
    fi
  fi
  if [[ -z "$port" ]]; then
    tui_warn "未能确定监听端口，跳过防火墙规则撤销（规则可能残留）。"
    return 0
  fi

  if have_cmd ufw; then
    # 先把整段输出【收进变量】再匹配，不要写 `ufw status | grep -q`：
    # grep -q 命中即退出 → 上游 ufw 收到 SIGPIPE(141) → 在 set -o pipefail 下
    # 整条管道的退出码变成 141 → 条件判假 → ufw 明明是 active 也走错分支
    # → 规则撤不掉（卸载后端口还开着）。
    # （实测 ufw status 的输出很小、暂时不会真的触发 SIGPIPE，
    #   但与本仓库 open_firewall 的既定写法保持一致，避免以后输出变大时踩同一个坑。）
    local ufw_status=''
    ufw_status=$(ufw status 2>/dev/null || printf '')
    if [[ "$ufw_status" == *"Status: active"* ]]; then
      if ufw delete allow "$port/tcp" >/dev/null 2>&1; then
        tui_ok "已撤销 ufw 规则 $port/tcp"
      else
        tui_warn "ufw 规则 $port/tcp 撤销失败（可能本来就没有该规则）。"
      fi
      return 0
    fi
  fi

  if have_cmd iptables; then
    # 必须数一数真删了几条：循环一次都没进也报「已撤销」就是谎报成功。
    # ⚠️ 这个变量必须是函数内的普通局部变量：原计划写的是【函数外的】
    #    `local ipt_removed=0` → bash 报 "local: can only be used in a function"
    #    且【赋值根本不发生】→ 变量保持未定义 → `(( ipt_removed > 0 ))` 在 set -u 下
    #    报 "unbound variable" → 卸载脚本在 iptables 分支【中途死亡】(rc=127)，
    #    此时服务已停、配置已删，但防火墙规则没撤、状态没清。
    local ipt_removed=0
    while iptables -C INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null; do
      iptables -D INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null || break
      ipt_removed=$((ipt_removed + 1))
    done
    if (( ipt_removed > 0 )); then
      tui_ok "已撤销 iptables 规则 $port/tcp（$ipt_removed 条）"
    else
      tui_warn "未找到 iptables 规则 $port/tcp（可能本来就没有）。"
    fi
    return 0
  fi

  if have_cmd nft; then
    # ⚠️ nft 的 handle 是【规则自身的编号】，不是它在清单里的行号：
    #    原来用 `grep -n ... | head -1 | cut -d: -f1` 取的是行号 →
    #    `nft delete rule ... handle <行号>` 必然删错或删不到。
    #    正确做法：用 `nft -a list chain` 打出带 handle 的清单，再取 handle。
    local nft_out='' nft_handle=''
    nft_out=$(nft -a list chain inet filter input 2>/dev/null || printf '')
    nft_handle=$(printf '%s\n' "$nft_out" | awk -v p="$port" '
      index($0, "tcp dport " p) { for (i = 1; i <= NF; i++) if ($i == "handle") { print $(i+1); exit } }')
    if [[ -n "$nft_handle" ]]; then
      if nft delete rule inet filter input handle "$nft_handle" 2>/dev/null; then
        tui_ok "已撤销 nftables 规则 $port/tcp（handle $nft_handle）"
      else
        tui_warn "nftables 规则 $port/tcp 撤销失败（handle $nft_handle）。"
      fi
    else
      tui_warn "未找到 nftables 规则 $port/tcp（可能本来就没有）。"
    fi
    return 0
  fi

  tui_warn "未检测到 ufw / iptables / nftables，防火墙规则未改动。"
  return 0
}

remove_tuning() {
  tui_section "移除网络调优"
  # 必须与 enable_bbr 用【同一个】路径变量：默认一致，但环境变量覆盖后不能漏删。
  local conf="${VLESS_REALITY_SYSCTL_CONF:-/etc/sysctl.d/99-vless-reality-bbr.conf}"
  rm -f "$conf"
  # sysctl 没有「按文件撤销」的接口，只能 --system 重载 —— 它会连带重载
  # /etc/sysctl.conf 里的其它设置（一般无害）。
  sysctl --system >/dev/null 2>&1 || true
  tui_ok "已移除 sysctl 调优文件：$conf"
  return 0
}

clean_state() {
  tui_section "清理状态"
  if [[ $PURGE -eq 1 ]]; then
    rm -f "$STATE_FILE"
    tui_ok "已删除状态文件：$STATE_FILE"
    # 状态目录【保留】：rmdir 不在运行时白名单里，而且目录里可能还有
    # 用户自己放的东西 → 擅自删目录比留一个空目录更危险。
    tui_tip "状态目录 $STATE_DIR 已保留（如需删除请手工处理）。"
  else
    tui_ok "保留状态文件：$STATE_FILE（如需删除请加 --purge）"
  fi
  return 0
}

main() {
  parse_args "$@"
  tui_init
  require_root || exit 1
  tui_banner "卸载工具" "VLESS + REALITY"

  # ⚠️ 这是全项目唯一会【删除用户配置、撤销防火墙规则】的脚本 →
  #    必须让用户确认（--yes / -y 可跳过，用于无人值守）。
  if [[ $ASSUME_YES -eq 0 ]]; then
    local state_row="保留（如需删除请加 --purge）"
    [[ $PURGE -eq 1 ]] && state_row="一并删除"
    tui_panel "即将执行的卸载动作" \
      "停止并禁用|xray 服务" \
      "备份并删除|$XRAY_CONFIG" \
      "撤销防火墙规则|监听端口" \
      "移除网络调优|sysctl 配置" \
      "状态文件|$state_row"
    tui_confirm "确认执行卸载？" "n" || { tui_info "已取消"; exit 0; }
  fi

  stop_service
  # 备份失败必须【中止】整个卸载：配置没备份成功就不能删原文件。
  backup_and_remove_config || exit 1
  revoke_firewall
  remove_tuning
  clean_state

  tui_warn "Xray 内核二进制与 systemd unit 未删除，内核仍位于 $XRAY_BIN。"
  tui_tip "如需彻底清理可手动执行：rm -f $XRAY_BIN && rm -f /etc/systemd/system/xray.service"

  tui_section "结果"
  tui_ok "卸载完成。客户端导出目录保留于 $OUT_DIR"
  exit 0
}

# ── 只有【直接执行】时才跑主流程 ────────────────────────────
# 被 source 时（单元测试要 source 本文件来测各个函数）绝不执行 main。
# 两个条件缺一不可：
#   ① BASH_SOURCE[0] == $0 → 只有直接执行本文件时成立；
#   ② 环境变量开关 → 给测试一个显式的显式开关。
if [[ "${BASH_SOURCE[0]}" == "${0}" ]] && [[ "${UNINSTALL_SH_NO_MAIN:-0}" != "1" ]]; then
  main "$@"
fi
