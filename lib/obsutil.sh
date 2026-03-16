#!/usr/bin/env bash
# 下载或更新仓库内的 obsutil 二进制。
# - 默认安装到仓库根目录下的 ./obsutil
# - 若系统已有 obsutil，不会覆盖；只管理仓库内副本
# - install.sh 和手动维护都可复用这个脚本

set -Eeuo pipefail

SCRIPT_PATH="${BASH_SOURCE[0]:-$0}"
LIB_DIR="$(cd "$(dirname -- "$SCRIPT_PATH")" && pwd -P)"
ROOT_DIR="$(cd "${LIB_DIR}/.." && pwd -P)"
TARGET_BIN="${ROOT_DIR}/obsutil"
DRY_RUN=false

usage() {
  cat <<'USAGE'
用法：
  ./lib/obsutil.sh [--dry-run]

说明：
  - 下载并安装或更新仓库内的 ./obsutil
  - 默认覆盖仓库里的旧版本
  - dry-run 只打印将执行的动作，不实际下载
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "未知参数：$1" >&2; usage; exit 2 ;;
  esac
done

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "缺少命令：$1" >&2
    exit 2
  }
}

download_file() {
  local url="$1"
  local output="$2"

  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$url" -o "$output"
    return 0
  fi

  if command -v wget >/dev/null 2>&1; then
    wget -qO "$output" "$url"
    return 0
  fi

  echo "缺少下载工具：curl 或 wget" >&2
  exit 2
}

resolve_package_name() {
  case "$(uname -m)" in
    x86_64|amd64) printf '%s\n' "obsutil_linux_amd64.tar.gz" ;;
    aarch64|arm64) printf '%s\n' "obsutil_linux_arm64.tar.gz" ;;
    *)
      echo "不支持的 CPU 架构：$(uname -m)" >&2
      echo "请手动安装 obsutil 后再试" >&2
      exit 2
      ;;
  esac
}

need_cmd install
need_cmd tar

PACKAGE_NAME="$(resolve_package_name)"
DOWNLOAD_URL="https://obs-community-intl.obs.ap-southeast-1.myhuaweicloud.com/obsutil/current/${PACKAGE_NAME}"

if $DRY_RUN; then
  if [[ -x "$TARGET_BIN" ]]; then
    echo "[dry-run] 将更新仓库内 obsutil：${TARGET_BIN}"
  else
    echo "[dry-run] 将安装仓库内 obsutil：${TARGET_BIN}"
  fi
  echo "[dry-run] 下载地址：${DOWNLOAD_URL}"
  exit 0
fi

TMP_DIR="$(mktemp -d)"
ARCHIVE_PATH="${TMP_DIR}/${PACKAGE_NAME}"
trap 'rm -rf "$TMP_DIR"' EXIT

if [[ -x "$TARGET_BIN" ]]; then
  echo "开始更新仓库内 obsutil：${TARGET_BIN}"
else
  echo "开始安装仓库内 obsutil：${TARGET_BIN}"
fi

download_file "$DOWNLOAD_URL" "$ARCHIVE_PATH"
tar -xzf "$ARCHIVE_PATH" -C "$TMP_DIR"

BINARY_PATH="$(find "$TMP_DIR" -type f -name obsutil | head -n 1)"
if [[ -z "$BINARY_PATH" ]]; then
  echo "下载包中未找到 obsutil 可执行文件" >&2
  exit 2
fi

install -m 755 "$BINARY_PATH" "$TARGET_BIN"
VERSION_OUTPUT="$("$TARGET_BIN" version 2>/dev/null || true)"
if [[ -z "$VERSION_OUTPUT" ]]; then
  echo "obsutil 已安装，但运行校验失败：${TARGET_BIN}" >&2
  exit 2
fi

echo "obsutil 已就绪：${TARGET_BIN}"
echo "$VERSION_OUTPUT" | head -n 1
