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
