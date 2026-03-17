#!/usr/bin/env bash
# 清理 OBS 历史备份：按文件名前缀与日期，仅保留最近 N 天
# - 从同目录 env.conf 加载配置；支持 --retain-days / --prefix 覆盖
# - 删除匹配 backup_YYYYmmdd_HHMMSS.tar.gz[.gpg] 以及对应 .sha256
# - 记录日志并发送 Telegram 摘要
# 退出码：0 成功；2 配置缺失/依赖缺失；6 清理失败

set -Eeuo pipefail

SCRIPT_PATH="${BASH_SOURCE[0]:-$0}"
SCRIPT_DIR="$(cd "$(dirname -- "$SCRIPT_PATH")" && pwd -P)"
export PATH="$SCRIPT_DIR:$PATH"
cd "$SCRIPT_DIR"

log_ts() { date '+%Y-%m-%d %H:%M:%S'; }
LOG_PREFIX="[CLEAN]"
log() {
  local level="$1"; shift
  local line
  line="$(log_ts) ${LOG_PREFIX}[$level] $*"
  echo "$line" | tee -a "${LOG_FILE:-./backup.log}"
}

# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/telegram.sh"

on_error() {
  local exit_code=$?
  local tail_log
  log "ERROR" "清理异常退出（exit=${exit_code})"
  tail_log="$(tail -n 80 "${LOG_FILE:-./backup.log}" 2>/dev/null || true)"
  tg_clean_error "$LABEL" "脚本异常退出（exit=${exit_code}）" "$tail_log"
  exit "$exit_code"
}
trap on_error ERR

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    log "ERROR" "未找到命令：$1"
    return 1
  }
}

CONF_FILE="${SCRIPT_DIR}/env.conf"
[[ -f "$CONF_FILE" ]] || { echo "缺少配置 ${CONF_FILE}" >&2; exit 2; }
# shellcheck disable=SC1090
source "$CONF_FILE"

: "${OBS_BUCKET:?缺少 OBS_BUCKET}"
: "${OBS_BACKUP_DIR:?缺少 OBS_BACKUP_DIR}"
: "${RETAIN_DAYS:?缺少 RETAIN_DAYS}"
: "${LOG_FILE:?缺少 LOG_FILE}"

need_cmd obsutil

OBSUTIL_CONFIG_PATH="${HOME}/.obsutilconfig"
if [[ ! -f "$OBSUTIL_CONFIG_PATH" ]]; then
  log "ERROR" "未检测到 obsutil 配置文件：${OBSUTIL_CONFIG_PATH}"
  log "ERROR" "请先执行：./obsutil config -interactive 完成初始化（AK/SK、Endpoint、默认桶）"
  exit 2
fi

CLI_RETAIN=""
CLI_PREFIX=""
usage() {
  cat <<'USAGE'
用法：
  ./clean_backups.sh [--retain-days=N] [--prefix=SUBDIR]
USAGE
}
while [[ $# -gt 0 ]]; do
  case "$1" in
    --retain-days=*) CLI_RETAIN="${1#*=}"; shift;;
    --prefix=*) CLI_PREFIX="${1#*=}"; shift;;
    -h|--help) usage; exit 0;;
    *) echo "未知参数：$1"; usage; exit 2;;
  esac
done

if [[ -n "$CLI_RETAIN" ]]; then RETAIN_DAYS="$CLI_RETAIN"; fi
TARGET_PREFIX="${OBS_BACKUP_DIR%/}/"
if [[ -n "$CLI_PREFIX" ]]; then TARGET_PREFIX="${TARGET_PREFIX}${CLI_PREFIX%/}/"; fi

log "INFO" "开始清理：bucket=${OBS_BUCKET} prefix=${TARGET_PREFIX} 保留最近 ${RETAIN_DAYS} 天"

CUTOFF_DATE="$(date -d "-${RETAIN_DAYS} days" +%Y%m%d)"

LIST_OUT="$(mktemp)"
if ! obsutil ls "obs://${OBS_BUCKET}/${TARGET_PREFIX}" >"$LIST_OUT" 2>/dev/null; then
  log "ERROR" "无法列举 obs://${OBS_BUCKET}/${TARGET_PREFIX}"
  rm -f "$LIST_OUT"
  tg_clean_error "$LABEL" "无法列举 obs://${OBS_BUCKET}/${TARGET_PREFIX}" ""
  exit 6
fi

mapfile -t OBJECTS < <(awk '{for(i=1;i<=NF;i++){if($i~/^obs:\/\//)print $i}}' "$LIST_OUT")
rm -f "$LIST_OUT"

TO_DELETE=()
TO_KEEP=()

for obj in "${OBJECTS[@]}"; do
  fname="${obj##*/}"
  if [[ "$fname" =~ ^backup_([0-9]{8})_[0-9]{6}\.tar\.gz(\.gpg)?(\.sha256)?$ ]]; then
    day="${BASH_REMATCH[1]}"
    if [[ "$day" -lt "$CUTOFF_DATE" ]]; then
      TO_DELETE+=("$obj")
      if [[ ! "$fname" =~ \.sha256$ ]]; then
        TO_DELETE+=("${obj}.sha256")
      fi
    else
      TO_KEEP+=("$obj")
    fi
  fi
done

if [[ "${#TO_DELETE[@]}" -gt 0 ]]; then
  mapfile -t TO_DELETE < <(printf '%s\n' "${TO_DELETE[@]}" | awk '!a[$0]++')
fi

DEL_OK=0
DEL_FAIL=0

if [[ "${#TO_DELETE[@]}" -eq 0 ]]; then
  log "INFO" "没有过期对象需要清理。"
else
  log "INFO" "准备删除 ${#TO_DELETE[@]} 个对象（含 sha256）"
  for o in "${TO_DELETE[@]}"; do
    if obsutil rm "$o" -f >/dev/null 2>&1; then
      ((DEL_OK++))
      log "INFO" "删除：$o"
    else
      ((DEL_FAIL++))
      log "WARN" "删除失败：$o"
    fi
  done
fi

tg_clean_success "$LABEL" "obs://${OBS_BUCKET}/${TARGET_PREFIX}" "${RETAIN_DAYS}" "${#TO_KEEP[@]}" "${DEL_OK}" "${DEL_FAIL}"
if (( DEL_FAIL > 0 )); then
  exit 6
fi
exit 0
