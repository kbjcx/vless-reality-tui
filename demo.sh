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

tui_section "圆角内容框（内容放得下就画框）"
tui_box "内容框"
tui_box_line "vless://203.0.113.10:443"
tui_box_end

# ⚠️ 分享链接有 150+ 字符，框内净宽只有 TUI_WIDTH-6（默认 74）→
#    硬塞进框里会把右边框顶出去（框线必须恰好等于 TUI_WIDTH 才合得拢）；
#    也不能折行（用户要复制这一行，折行后粘到客户端是废链接）。
#    → tui_box_text：放得下就画框，放不下就整行输出，
#      终端的软换行只是显示效果、不会往内容里插字符 → 复制出来仍是完整的一行。
tui_section "超宽内容（放不下就不画框，整行输出）"
tui_box_text "分享链接（示例）" \
  "vless://8f3a1c22-4b6d-4e51-9b2c-7a0e5d3f1c88@203.0.113.10:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.microsoft.com&fp=chrome&pbk=xQ0G2k7F0l3mN8pQ2rS5tU7vW9xY1zA3bC5dE7fG&sid=1a2b3c4d&type=tcp#my-node"

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
