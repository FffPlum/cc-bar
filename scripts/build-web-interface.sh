#!/bin/bash
# 构建同一份 React 静态资源，供 Xcode、SwiftPM 与正式打包共用。
# 默认不安装依赖；首次或 lockfile 变化后显式传入 --install 执行 npm ci。
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOST_API_DIR="$REPO_ROOT/packages/host-api"
INTERFACE_DIR="$REPO_ROOT/packages/interface"
OUTPUT_DIR="$REPO_ROOT/Sources/CCBar/Resources/WebInterface"
INSTALL=0

case "${1:-}" in
  "") ;;
  --install) INSTALL=1 ;;
  *)
    echo "用法: scripts/build-web-interface.sh [--install]" >&2
    exit 1
    ;;
esac

# Xcode launched from Finder does not inherit a shell's nvm/Homebrew PATH.
# An explicit executable wins; otherwise look only in standard install locations.
if [[ -n "${CCBAR_NODE_BINARY:-}" ]]; then
  [[ -x "$CCBAR_NODE_BINARY" ]] || { echo "CCBAR_NODE_BINARY 不是可执行文件" >&2; exit 1; }
  export PATH="$(dirname "$CCBAR_NODE_BINARY"):$PATH"
elif ! command -v npm >/dev/null 2>&1; then
  for NODE_DIR in /opt/homebrew/bin /usr/local/bin "$HOME/.volta/bin" "$HOME"/.nvm/versions/node/v22*/bin "$HOME"/.nvm/versions/node/v24*/bin; do
    if [[ -x "$NODE_DIR/node" && -x "$NODE_DIR/npm" ]]; then
      export PATH="$NODE_DIR:$PATH"
      break
    fi
  done
fi
command -v npm >/dev/null 2>&1 || {
  echo "未找到 npm；请先安装 Node.js 22 或兼容版本。" >&2
  exit 1
}
[[ -f "$HOST_API_DIR/package.json" ]] || { echo "缺少 packages/host-api/package.json" >&2; exit 1; }
[[ -f "$INTERFACE_DIR/package.json" ]] || {
  echo "缺少 packages/interface/package.json；React 页面由前端任务提供，不生成占位页面。" >&2
  exit 1
}

if [[ "$INSTALL" == 1 ]]; then
  echo "==> 安装 Host API 与 React 前端锁定依赖"
  npm --prefix "$HOST_API_DIR" ci
  npm --prefix "$INTERFACE_DIR" ci
else
  [[ -d "$HOST_API_DIR/node_modules" && -d "$INTERFACE_DIR/node_modules" ]] || {
    echo "前端依赖尚未安装；请先运行 scripts/build-web-interface.sh --install" >&2
    exit 1
  }
fi

echo "==> 构建 Host API"
npm --prefix "$HOST_API_DIR" run build
echo "==> 构建 React 静态资源"
npm --prefix "$INTERFACE_DIR" run build

INDEX="$OUTPUT_DIR/index.html"
[[ -s "$INDEX" ]] || {
  echo "React 构建未生成 $INDEX；请检查 packages/interface 的 Vite outDir。" >&2
  exit 1
}
python3 - "$INDEX" <<'PY'
from html.parser import HTMLParser
from pathlib import Path
import sys
from urllib.parse import urlsplit

class EntryValidator(HTMLParser):
    def handle_starttag(self, tag, attrs):
        values = dict(attrs)
        if tag == "script":
            src = values.get("src", "")
            if not src or urlsplit(src).scheme or urlsplit(src).netloc or src.startswith("//"):
                raise ValueError("index.html 必须只引用本地、显式的外部 script；禁止内联或远程脚本")

index = Path(sys.argv[1])
validator = EntryValidator()
validator.feed(index.read_text(encoding="utf-8"))
validator.close()
PY

echo "==> React 资源已就绪: $OUTPUT_DIR"
