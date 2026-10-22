#!/usr/bin/env bash
# build.sh — 把 lib/ 与 install.sh 内联成 dist/install.sh 单文件分发物
#
# 关键设计：入口代码**不在这里重写**，而是从 install.sh 抽取并剥离 source 行。
# 否则单文件版与开发版会立刻漂移，两条路径的行为将不再一致。
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
OUT="$ROOT/dist/install.sh"
# ⚠️ 不要用 `sed … | head -1`：head 命中即退出会让上游 sed 收到 SIGPIPE(141)，
#    而本脚本有 `set -euo pipefail` → 整条管道的退出码变成 141 → 构建【中止】。
#    （本仓库的既定约定见 lib/core.sh 的 port_occupant）
#    改成不接管道，再用 bash 取首行。
VERSION="$(sed -n "s/^APP_VERSION='\(.*\)'.*/\1/p" "$ROOT/lib/core.sh")"
VERSION="${VERSION%%$'\n'*}"
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
# SPDX-License-Identifier: MIT
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
      -e '/^# SPDX-License-Identifier:/d' \
      -e '/^# shellcheck source=lib\//d' \
      -e '/^source "\$ROOT_DIR\/lib\//d' \
      -e '/^ROOT_DIR=.*BASH_SOURCE/d' \
      -e '/^set -uo pipefail$/d' \
      "$ROOT/install.sh"
} >"$tmp"

# ⚠️ 产物必须以【100755】提交（Step 6 的 git update-index --chmod=+x）：
#    CI 的校验是 `git diff --exit-code dist/install.sh`，而 GitHub runner 上
#    core.fileMode=true → 索引模式（100644）与工作区模式（755）不一致
#    会被 git diff 报出来 → CI 每次都红。
#    顺带的好处：单文件分发物 clone 下来就是可执行的。
chmod +x "$tmp" || { printf '无法设置可执行权限：%s\n' "$tmp" >&2; rm -f "$tmp"; exit 1; }
mv -f "$tmp" "$OUT" || { printf '无法写入产物：%s\n' "$OUT" >&2; rm -f "$tmp"; exit 1; }
printf '已生成 %s (v%s)\n' "$OUT" "$VERSION"
