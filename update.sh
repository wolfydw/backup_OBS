#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_PATH="${BASH_SOURCE[0]:-$0}"
SCRIPT_DIR="$(cd "$(dirname -- "$SCRIPT_PATH")" && pwd -P)"
cd "$SCRIPT_DIR"

usage() {
  cat <<'USAGE'
用法：
  ./update.sh [branch-or-tag]

说明：
  - 不带参数时，默认更新 stable 分支
  - 带参数时，可以切换到指定分支或 tag
  - 更新后会自动执行一次 ./backup.sh --dry-run 自检
USAGE
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "缺少命令：$1" >&2
    exit 2
  }
}

need_cmd git
need_cmd bash

TARGET_REF="${1:-}"
if [[ -z "$TARGET_REF" ]]; then
  TARGET_REF="stable"
fi

git fetch --tags origin

if git show-ref --verify --quiet "refs/tags/${TARGET_REF}"; then
  git checkout "${TARGET_REF}"
else
  git checkout "${TARGET_REF}"
  git pull --ff-only origin "${TARGET_REF}"
fi

chmod 755 \
  "${SCRIPT_DIR}/backup.sh" \
  "${SCRIPT_DIR}/clean_backups.sh" \
  "${SCRIPT_DIR}/lib/telegram.sh" \
  "${SCRIPT_DIR}/install.sh" \
  "${SCRIPT_DIR}/update.sh"

bash "${SCRIPT_DIR}/backup.sh" --dry-run
