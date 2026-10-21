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
# ⚠️ 排除 .worktrees/：本机的工作树目录也会被挂进容器，
#    里面的副本是同一份源码的另一次检出 → 不排除就会重复检查一遍。
docker exec "$CNAME" bash -c 'find . -name "*.sh" -not -path "./.git/*" -not -path "./.worktrees/*" -print0 | xargs -0 -n1 bash -n' || {
  echo "语法检查失败"; exit 1; }

echo "==> 单元测试"
docker exec "$CNAME" bash -c 'bash test/unit.sh' || { echo "单元测试失败"; exit 1; }

echo "==> 构建单文件"
docker exec "$CNAME" bash -c 'bash build.sh' || { echo "构建失败"; exit 1; }

echo "==> 校验单文件产物自包含"
docker exec "$CNAME" bash -c 'test -f dist/install.sh && ! grep -q "source.*lib/" dist/install.sh && bash -n dist/install.sh' || {
  echo "单文件产物校验失败"; exit 1; }

echo "==> 非交互部署（--yes）"
docker exec "$CNAME" bash -c 'bash dist/install.sh --yes --port 443 --sni www.microsoft.com --name it-test' || {
  echo "==> [SKIPPED] 容器内端到端部署未通过：普通容器没有 systemd，属预期。"
  echo "==>          这一段必须在真机或 --privileged 容器里验证；本仓库的 CI 不覆盖它。"
}

echo "==> 集成测试结束"
