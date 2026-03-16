#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_PATH="${BASH_SOURCE[0]:-$0}"
SCRIPT_DIR="$(cd "$(dirname -- "$SCRIPT_PATH")" && pwd -P)"
INSTALL_MODE="system"
INSTALL_USER="root"
SYSTEMD_DIR="/etc/systemd/system"
DRY_RUN=false

usage() {
  cat <<'USAGE'
用法：
  ./install.sh [--user=NAME] [--mode=system|user] [--dry-run]

说明：
  - 若未检测到仓库内 obsutil，会自动调用 lib/obsutil.sh 安装
  - system 模式会安装到 /etc/systemd/system
  - user 模式会安装到 ~/.config/systemd/user
  - 不会覆盖已有 env.conf 和 exclude.user.list
  - dry-run 只打印将执行的动作，不实际写入 systemd
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --user=*) INSTALL_USER="${1#*=}"; shift;;
    --mode=*) INSTALL_MODE="${1#*=}"; shift;;
    --dry-run) DRY_RUN=true; shift;;
    -h|--help) usage; exit 0;;
    *) echo "未知参数：$1" >&2; usage; exit 2;;
  esac
done

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "缺少命令：$1" >&2
    exit 2
  }
}

need_cmd systemctl
need_cmd install
need_cmd sed

if [[ "$INSTALL_MODE" != "system" && "$INSTALL_MODE" != "user" ]]; then
  echo "无效 --mode：$INSTALL_MODE" >&2
  exit 2
fi

if [[ "$INSTALL_MODE" == "system" && "$(id -u)" -ne 0 ]]; then
  echo "system 模式需要 root 权限" >&2
  exit 2
fi

if [[ "$INSTALL_MODE" == "user" ]]; then
  HOME_DIR="$(getent passwd "$INSTALL_USER" | cut -d: -f6)"
  if [[ -z "$HOME_DIR" ]]; then
    echo "无法找到用户：$INSTALL_USER" >&2
    exit 2
  fi
  SYSTEMD_DIR="${HOME_DIR}/.config/systemd/user"
fi

if [[ -f "${SCRIPT_DIR}/obsutil" ]]; then
  chmod 755 "${SCRIPT_DIR}/obsutil"
  echo "已检测到仓库内 obsutil：${SCRIPT_DIR}/obsutil"
else
  chmod 755 "${SCRIPT_DIR}/lib/obsutil.sh"
  if $DRY_RUN; then
    bash "${SCRIPT_DIR}/lib/obsutil.sh" --dry-run
  else
    bash "${SCRIPT_DIR}/lib/obsutil.sh"
  fi
fi

mkdir -p "${SCRIPT_DIR}/systemd"

if [[ ! -f "${SCRIPT_DIR}/env.conf" ]]; then
  if $DRY_RUN; then
    echo "[dry-run] 将创建 ${SCRIPT_DIR}/env.conf"
  else
    cp "${SCRIPT_DIR}/env.conf.example" "${SCRIPT_DIR}/env.conf"
    echo "已创建 ${SCRIPT_DIR}/env.conf"
  fi
fi

if [[ ! -f "${SCRIPT_DIR}/exclude.user.list" ]]; then
  if $DRY_RUN; then
    echo "[dry-run] 将创建 ${SCRIPT_DIR}/exclude.user.list"
  else
    cp "${SCRIPT_DIR}/exclude.user.list.example" "${SCRIPT_DIR}/exclude.user.list"
    echo "已创建 ${SCRIPT_DIR}/exclude.user.list"
  fi
fi

chmod 755 \
  "${SCRIPT_DIR}/backup.sh" \
  "${SCRIPT_DIR}/clean_backups.sh" \
  "${SCRIPT_DIR}/lib/obsutil.sh" \
  "${SCRIPT_DIR}/lib/telegram.sh" \
  "${SCRIPT_DIR}/install.sh" \
  "${SCRIPT_DIR}/update.sh"

if [[ -f "${SCRIPT_DIR}/obsutil" ]]; then
  chmod 755 "${SCRIPT_DIR}/obsutil"
fi

if $DRY_RUN; then
  echo "[dry-run] 目标 systemd 目录：$SYSTEMD_DIR"
else
  mkdir -p "$SYSTEMD_DIR"
fi

render_unit() {
  local src="$1"
  local dst="$2"
  if $DRY_RUN; then
    echo "[dry-run] 将渲染 $(basename "$src") -> $dst"
    return 0
  fi
  sed \
    -e "s|__WORKDIR__|${SCRIPT_DIR}|g" \
    -e "s|__RUN_USER__|${INSTALL_USER}|g" \
    "$src" > "$dst"

  if [[ "$INSTALL_MODE" == "user" ]]; then
    sed -i '/^User=__RUN_USER__$/d;/^User=/d' "$dst"
  fi
}

render_unit "${SCRIPT_DIR}/systemd/backup-obs-update.service" "${SYSTEMD_DIR}/backup-obs-update.service"
render_unit "${SCRIPT_DIR}/systemd/backup-obs-update.timer" "${SYSTEMD_DIR}/backup-obs-update.timer"

if $DRY_RUN; then
  echo "[dry-run] 将执行 systemctl daemon-reload"
  echo "[dry-run] 将启用 backup-obs-update.timer"
elif [[ "$INSTALL_MODE" == "system" ]]; then
  systemctl daemon-reload
  systemctl enable --now backup-obs-update.timer
  echo "已启用 system timer：backup-obs-update.timer"
  echo "查看状态：systemctl status backup-obs-update.timer"
  echo "查看日志：journalctl -u backup-obs-update.service -n 100"
else
  systemctl --user daemon-reload
  systemctl --user enable --now backup-obs-update.timer
  echo "已启用 user timer：backup-obs-update.timer"
  echo "查看状态：systemctl --user status backup-obs-update.timer"
  echo "查看日志：journalctl --user -u backup-obs-update.service -n 100"
fi
