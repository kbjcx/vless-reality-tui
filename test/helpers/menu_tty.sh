#!/usr/bin/env bash
# 用法: printf '按键序列' | bash menu_tty.sh "标题" "选项1" "选项2" ...
# 退出码 = tui_menu 的返回码（0-based 索引，取消为 255）
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/lib/tui.sh"
tui_init
# 必须在 tui_init 之后覆盖：tui_init 会按真实 TTY 把 TUI_TTY 置 0
TUI_TTY=1
# 把 lib/tui.sh 的两个按键读取超时放大到 2 秒：
# 默认的 0.2 / 0.35 秒是【墙钟截止点】→ 机器繁忙时会把方向键读丢、
# 把两位数输入截断 → 这些断言在 CI（共享 runner）上会【随机变红】。
# 放大窗口不改变被测逻辑，只把「时序运气」从测试里拿掉。
export TUI_KEY_TIMEOUT=2
export TUI_DIGIT_TIMEOUT=2
tui_menu "$@"
exit $?
