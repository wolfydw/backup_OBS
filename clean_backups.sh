#!/usr/bin/env bash
# 清理 OBS 历史备份：按文件名前缀与日期，仅保留最近 N 天
# - 从同目录 env.conf 加载配置；支持 --retain-days / --prefix 覆盖
# - 删除匹配 backup_YYYYmmdd_HHMMSS.tar.gz[.gpg] 以及对应 .sha256
# - 记录日志并发送 Telegram 摘要（Markdown）
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

#############################
# Telegram 通知（Markdown）
#############################
send_telegram() {
  local status="${1-}"    # success | error
  local reason="${2-}"    # 错误原因（可选）
  local error_log="${3-}" # 详细错误日志（可选）

  if [[ -z "${TG_BOT_TOKEN:-}" || -z "${TG_USER_ID:-}" ]]; then
    log "INFO" "未配置Telegram通知，跳过发送"
    return 0
  fi

  local api="https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage"
  local current_date; current_date="$(date +'%Y-%m-%d %H:%M:%S')"
  local message

  if [[ "$status" == "success" ]]; then
    message="*清理完成通知*\n\n"
    message+="主机：${LABEL}\n"
    message+="时间：${current_date}\n"
    message+="前缀：obs://${OBS_BUCKET}/${TARGET_PREFIX}\n"
    message+="保留天数：${RETAIN_DAYS}\n"
    message+="保留对象数：${#TO_KEEP[@]}\n"
    message+="删除成功：${DEL_OK}\n"
    message+="删除失败：${DEL_FAIL}"
  else
    message="*清理失败通知*\n\n${LABEL} 清理任务失败！"
    if [[ -n "$reason" ]]; then
      message+="\n原因：${reason}"
    fi
    if [[ -n "$error_log" ]]; then
      message+="\n错误日志：\n\`\`\`${error_log}\`\`\`"
    fi
  fi

  # 转换换行符 \n -> %0A
  local encoded_message=${message//\\n/%0A}

  local response
  response="$(curl -sS -X POST "$api" \
    -d "chat_id=${TG_USER_ID}" \
    -d "parse_mode=Markdown" \
    -d "disable_web_page_preview=true" \
    -d "text=${encoded_message}" 2>&1 || true)"

  if echo "$response" | grep -q '"ok":true'; then
    log "INFO" "Telegram通知发送成功"
  else
    log "WARN" "Telegram通知发送失败: $response"
  fi
}

on_error() {
  local exit_code=$?
  log "ERROR" "清理异常退出（exit=${exit_code})"
  local tail_log; tail_log="$(tail -n 80 "${LOG_FILE:-./backup.log}" 2>/dev/null || true)"
  send_telegram "error" "脚本异常退出（exit=${exit_code}）" "$tail_log"
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

# 严格按要求：配置文件位于 ~/.obsutilconfig
OBSUTIL_CONFIG_PATH="${HOME}/.obsutilconfig"
if [[ ! -f "$OBSUTIL_CONFIG_PATH" ]]; then
  log "ERROR" "未检测到 obsutil 配置文件：${OBSUTIL_CONFIG_PATH}"
  log "ERROR" "请先执行：./obsutil config -interactive 完成初始化（AK/SK、Endpoint、默认桶）"
  exit 2
fi

# 覆盖参数
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

# 计算截止日期（N 天前零点，格式 YYYYmmdd）
CUTOFF_DATE="$(date -d "-${RETAIN_DAYS} days" +%Y%m%d)"

# 列举对象
LIST_OUT="$(mktemp)"
if ! obsutil ls "obs://${OBS_BUCKET}/${TARGET_PREFIX}" >"$LIST_OUT" 2>/dev/null; then
  log "ERROR" "无法列举 obs://${OBS_BUCKET}/${TARGET_PREFIX}"
  rm -f "$LIST_OUT"
  send_telegram "error" "无法列举 obs://${OBS_BUCKET}/${TARGET_PREFIX}" ""
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

# 去重
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

# 通知与退出码
send_telegram "success"
if (( DEL_FAIL > 0 )); then
  exit 6
fi
exit 0
