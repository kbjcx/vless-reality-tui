#!/usr/bin/env bash
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/lib/tui.sh"
tui_init
tui_menu "选择" "选项一" "选项二" "选项三"
exit $?
