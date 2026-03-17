#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_PATH="${BASH_SOURCE[0]:-$0}"
SCRIPT_DIR="$(cd "$(dirname -- "$SCRIPT_PATH")" && pwd -P)"
cd "$SCRIPT_DIR"
CONF_FILE="${SCRIPT_DIR}/env.conf"

if [[ -f "$CONF_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$CONF_FILE"
fi

usage() {
  cat <<'USAGE'
用法：
  ./update.sh [branch-or-tag]

说明：
  - 不带参数时，默认更新 stable 分支
  - 带参数时，可以切换到指定分支或 tag
  - 默认从 origin 更新；如果失败且配置了 GIT_REMOTE_FALLBACK，则自动回退到备用仓库
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
UPDATE_SOURCE="origin"
if [[ -z "$TARGET_REF" ]]; then
  TARGET_REF="stable"
fi

fetch_from_origin() {
  git fetch --tags origin
}

fetch_from_fallback() {
  [[ -n "${GIT_REMOTE_FALLBACK:-}" ]] || return 1
  git fetch --tags "${GIT_REMOTE_FALLBACK}" \
    "+refs/heads/*:refs/remotes/fallback/*" \
    "+refs/tags/*:refs/tags/*"
}

if fetch_from_origin; then
  UPDATE_SOURCE="origin"
elif fetch_from_fallback; then
  UPDATE_SOURCE="fallback"
  echo "origin 更新失败，已回退到备用仓库：${GIT_REMOTE_FALLBACK}"
else
  echo "更新失败：origin 不可用，且备用仓库也不可用" >&2
  exit 2
fi

if git show-ref --verify --quiet "refs/tags/${TARGET_REF}"; then
  git checkout "${TARGET_REF}"
else
  if ! git show-ref --verify --quiet "refs/remotes/${UPDATE_SOURCE}/${TARGET_REF}"; then
    echo "未找到目标分支：${TARGET_REF}（来源：${UPDATE_SOURCE}）" >&2
    exit 2
  fi

  if git show-ref --verify --quiet "refs/heads/${TARGET_REF}"; then
    git checkout "${TARGET_REF}"
    git merge --ff-only "refs/remotes/${UPDATE_SOURCE}/${TARGET_REF}"
  else
    git checkout -B "${TARGET_REF}" "refs/remotes/${UPDATE_SOURCE}/${TARGET_REF}"
  fi
fi

chmod 755 \
  "${SCRIPT_DIR}/backup.sh" \
  "${SCRIPT_DIR}/clean_backups.sh" \
  "${SCRIPT_DIR}/obsutil" \
  "${SCRIPT_DIR}/lib/obsutil.sh" \
  "${SCRIPT_DIR}/lib/telegram.sh" \
  "${SCRIPT_DIR}/install.sh" \
  "${SCRIPT_DIR}/update.sh"
