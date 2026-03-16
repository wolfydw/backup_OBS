#!/usr/bin/env bash
# 备份并上传到华为云 OBS
# - 从同目录 env.conf 加载配置，支持命令行覆盖
# - 打包多目录（支持 pigz），生成 SHA256 校验，obsutil 分片/并发上传
# - 上传 .tar.gz 以及 .tar.gz.sha256，并下载远端 .sha256 比对确保完整性
# - 成功/失败写入日志并 Telegram 通知（Markdown）
# - 支持 --dry-run / --verify / --keep-local / --concurrency / --rate / --label / --sse
# 退出码：0 成功；2 配置缺失；3 打包失败；4 上传失败；5 校验失败

set -Eeuo pipefail

#############################
# 通用工具函数
#############################
# 兼容性更好的脚本路径解析（在 set -u 下也安全）
SCRIPT_PATH="${BASH_SOURCE[0]:-$0}"
SCRIPT_DIR="$(cd "$(dirname -- "$SCRIPT_PATH")" && pwd -P)"
export PATH="$SCRIPT_DIR:$PATH"
cd "$SCRIPT_DIR"

# 记录日志到文件与终端
log_ts() { date '+%Y-%m-%d %H:%M:%S'; }
LOG_PREFIX="[BACKUP]"
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
  local status="${1-}"    # success | error | dryrun
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
    message="*备份成功通知*\n\n"
    message+="备份主机：${LABEL}\n"
    message+="备份时间：${current_date}\n"
    message+="备份内容：${BACKUP_DIR}\n"
    message+="文件大小：${BACKUP_SIZE_HUMAN}\n"
    message+="存储位置：obs://${OBS_BUCKET}/${OBS_BACKUP_DIR}/${ARCHIVE_BASE}\n"
    message+="打包用时：${PACK_SECONDS}s\n"
    message+="上传用时：${UP_SECONDS}s\n"
    message+="平均速率：${SPEED_HUMAN}"
  elif [[ "$status" == "dryrun" ]]; then
    message="*备份自检（Dry-run）*\n\n"
    message+="备份主机：${LABEL}\n"
    message+="备份时间：${current_date}\n"
    message+="备份内容：${BACKUP_DIR}\n"
    message+="归档名称：${ARCHIVE_BASE}\n"
    message+="文件大小：${BACKUP_SIZE_HUMAN}\n"
    message+="打包用时：${PACK_SECONDS}s"
  else
    message="*备份失败通知*\n\n${LABEL} 备份失败！"
    if [[ -n "$reason" ]]; then
      message+="\n原因：${reason}"
    fi
    if [[ -n "$error_log" ]]; then
      message+="\n错误日志：\n\`\`\`${error_log}\`\`\`"
    fi
  fi

  # 仅把字面 \n 转成 %0A；保留其他字符原样
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


# 失败统一处理（触发 trap）
on_error() {
  local exit_code=$?
  local line_no=${BASH_LINENO[0]:-}
  log "ERROR" "脚本异常退出（exit=$exit_code, line=${line_no})."
  local tail_log
  tail_log="$(tail -n 80 "${LOG_FILE:-./backup.log}" 2>/dev/null || true)"
  send_telegram "error" "脚本异常退出（exit=${exit_code}, line=${line_no}）" "$tail_log"
  exit "$exit_code"
}
trap on_error ERR

# 命令可用性检查
need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    log "ERROR" "未找到命令：$1"
    return 1
  }
}

# 通用重试（指数回退 2^n 秒）
retry() {
  local max="$1"; shift
  local desc="$1"; shift
  local n=1
  until "$@"; do
    local ec=$?
    if (( n >= max )); then
      log "ERROR" "重试用尽：${desc}（exit=$ec）"
      return "$ec"
    fi
    local backoff=$((2**n))
    log "WARN" "步骤失败，将在 ${backoff}s 后第 $((n+1)) 次重试：${desc}（exit=$ec）"
    sleep "$backoff"
    ((n++))
  done
}

#############################
# 加载配置与参数
#############################

CONF_FILE="${SCRIPT_DIR}/env.conf"
if [[ ! -f "$CONF_FILE" ]]; then
  echo "未找到配置文件 ${CONF_FILE}，请先复制/编辑 env.conf" >&2
  exit 2
fi

# shellcheck disable=SC1090
source "$CONF_FILE"

# 默认参数值（可被命令行覆盖）
KEEP_LOCAL=false
DRY_RUN=false
VERIFY_ONLY=false
CLI_LABEL=""
CLI_SSE="none"          # none|kms|aes256
CLI_CONCURRENCY=""      # 映射到 -j
CLI_RATE=""             # 速率限制（示例 10MB/s）
GPG_RECIPIENT=""
GPG_SYM=false

usage() {
  cat <<'USAGE'
用法：
  ./backup.sh [--dry-run] [--verify] [--keep-local]
              [--concurrency=N] [--rate=10MB/s]
              [--label=NAME]
              [--sse=none|kms|aes256]
              [--gpg-recipient=KMS_OR_PGP_ID | --gpg-symmetric]
USAGE
}

# 解析参数
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=true; shift;;
    --verify) VERIFY_ONLY=true; shift;;
    --keep-local) KEEP_LOCAL=true; shift;;
    --concurrency=*) CLI_CONCURRENCY="${1#*=}"; shift;;
    --rate=*) CLI_RATE="${1#*=}"; shift;;
    --label=*) CLI_LABEL="${1#*=}"; shift;;
    --sse=*) CLI_SSE="${1#*=}"; shift;;
    --gpg-recipient=*) GPG_RECIPIENT="${1#*=}"; shift;;
    --gpg-symmetric) GPG_SYM=true; shift;;
    -h|--help) usage; exit 0;;
    *) echo "未知参数：$1"; usage; exit 2;;
  esac
done

# 应用 label 覆盖（仅影响远端前缀，不改变本地）
if [[ -n "$CLI_LABEL" ]]; then
  LABEL="$CLI_LABEL"
  OBS_BACKUP_DIR="backup/${LABEL}"
fi

# 并发覆盖
if [[ -n "$CLI_CONCURRENCY" ]]; then
  OBS_JOBS="$CLI_CONCURRENCY"
fi

# 速率（obsutil 具体参数随版本可能不同，这里传递 --rate 或 -limit 的等价形式）
OBS_RATE_FLAG=""
if [[ -n "${CLI_RATE:-}" ]]; then
  OBS_RATE_FLAG="--rate=${CLI_RATE}"
fi

# 路径与文件
EXCLUDE_FILE="${SCRIPT_DIR}/exclude.list"
[[ -f "$EXCLUDE_FILE" ]] || touch "$EXCLUDE_FILE"

# 基础校验
: "${OBS_BUCKET:?缺少 OBS_BUCKET}"
: "${OBS_BACKUP_DIR:?缺少 OBS_BACKUP_DIR}"
: "${BACKUP_DIR:?缺少 BACKUP_DIR}"
: "${LOG_FILE:?缺少 LOG_FILE}"
: "${OBS_PARALLEL:?缺少 OBS_PARALLEL}" "${OBS_JOBS:?缺少 OBS_JOBS}"
: "${OBS_PARTSIZE:?缺少 OBS_PARTSIZE}" "${OBS_THRESHOLD:?缺少 OBS_THRESHOLD}"
: "${RETAIN_DAYS:?缺少 RETAIN_DAYS}"

#############################
# 依赖检查与自检
#############################
need_cmd tar
need_cmd sha256sum
need_cmd curl
need_cmd bash

if ! command -v obsutil >/dev/null 2>&1; then
  log "ERROR" "未找到 obsutil。请下载 obsutil，并确保其在 PATH 或与脚本同目录。"
  log "ERROR" "首次使用请执行：./obsutil config -interactive"
  exit 2
fi

# 严格按要求：配置文件位于 ~/.obsutilconfig
OBSUTIL_CONFIG_PATH="${HOME}/.obsutilconfig"
if [[ ! -f "$OBSUTIL_CONFIG_PATH" ]]; then
  log "ERROR" "未检测到 obsutil 配置文件：${OBSUTIL_CONFIG_PATH}"
  log "ERROR" "请先执行：./obsutil config -interactive 完成初始化（AK/SK、Endpoint、默认桶）"
  exit 2
fi

#############################
# verify-only: 远端可用性检查
#############################
if $VERIFY_ONLY; then
  log "INFO" "开始远端可用性检查（ls + stat）"
  set +e
  obsutil ls "obs://${OBS_BUCKET}/${OBS_BACKUP_DIR}/" > /dev/null 2>&1
  rc_ls=$?
  if (( rc_ls != 0 )); then
    log "ERROR" "obsutil 无法列举 obs://${OBS_BUCKET}/${OBS_BACKUP_DIR}/"
    exit 5
  fi
  one_obj="$(obsutil ls "obs://${OBS_BUCKET}/${OBS_BACKUP_DIR}/" 2>/dev/null | awk '/obs:\/\//{print $1; exit}')"
  if [[ -n "$one_obj" ]]; then
    obsutil stat "$one_obj" >/dev/null 2>&1 || { log "ERROR" "stat 失败：$one_obj"; exit 5; }
    log "INFO" "远端可访问，示例对象 stat 正常：$one_obj"
  else
    log "INFO" "远端可访问，但当前前缀下没有对象。"
  fi
  exit 0
fi
set -e

#############################
# 打包准备
#############################

# 组装要打包的 -C 与相对路径参数
build_tar_file_list() {
  local args=()
  for p in $BACKUP_DIR; do
    if [[ ! -e "$p" ]]; then
      log "WARN" "路径不存在，跳过：$p"
      continue
    fi
    local abs; abs="$(readlink -f "$p")"
    local parent; parent="$(dirname "$abs")"
    local base; base="$(basename "$abs")"
    args+=("-C" "$parent" "$base")
  done
  printf '%s\n' "${args[@]}"
}

# 粗略空间检查
check_space() {
  local total=0
  for p in $BACKUP_DIR; do
    [[ -e "$p" ]] || continue
    local sz
    sz=$(du -sb --apparent-size "$p" 2>/dev/null | awk '{s+=$1} END{print s+0}')
    total=$((total + sz))
  done
  local avail
  avail=$(df -P "$SCRIPT_DIR" | awk 'NR==2{print $4}') # KB
  avail=$((avail * 1024))
  local need=$(( total + total/10 + 100*1024*1024 ))
  if (( avail < need )); then
    log "ERROR" "磁盘空间不足。需要约 $need 字节，可用 $avail 字节。"
    return 1
  fi
}

log "INFO" "开始备份：bucket=${OBS_BUCKET} prefix=${OBS_BACKUP_DIR} 并发(-j)=${OBS_JOBS} 分片(-p)=${OBS_PARALLEL}"
check_space || { log "ERROR" "空间检查未通过"; exit 3; }

TS="$(date +%Y%m%d_%H%M%S)"
ARCHIVE_BASE="backup_${TS}.tar.gz"
ARCHIVE_PATH="${SCRIPT_DIR}/${ARCHIVE_BASE}"
SHA_PATH="${ARCHIVE_PATH}.sha256"
USE_PIGZ=false
if command -v pigz >/dev/null 2>&1; then USE_PIGZ=true; fi

# 打包与压缩
pack() {
  local start; start=$(date +%s)
  local tar_args; mapfile -t tar_args < <(build_tar_file_list)
  if [[ "${#tar_args[@]}" -eq 0 ]]; then
    log "ERROR" "没有可打包的路径（BACKUP_DIR 均不存在）"
    return 1
  fi

  log "INFO" "开始打包（支持 exclude.list），pigz=${USE_PIGZ}"
  if $USE_PIGZ; then
    tar --warning=no-file-changed --exclude-from="$EXCLUDE_FILE" \
      -c "${tar_args[@]}" | pigz > "$ARCHIVE_PATH"
  else
    tar --warning=no-file-changed --exclude-from="$EXCLUDE_FILE" \
      -czf "$ARCHIVE_PATH" "${tar_args[@]}"
  fi
  local end; end=$(date +%s)
  PACK_SECONDS=$((end - start))
  PACK_SIZE=$(stat -c '%s' "$ARCHIVE_PATH")
  log "INFO" "打包完成：$(numfmt --to=iec "$PACK_SIZE") 用时 ${PACK_SECONDS}s"
}

# 可选：GPG 加密
maybe_encrypt() {
  if [[ -n "$GPG_RECIPIENT" ]]; then
    log "INFO" "使用 GPG 收件人加密：$GPG_RECIPIENT"
    need_cmd gpg
    gpg --batch --yes --output "${ARCHIVE_PATH}.gpg" --encrypt --recipient "$GPG_RECIPIENT" "$ARCHIVE_PATH"
    rm -f "$ARCHIVE_PATH"
    ARCHIVE_PATH="${ARCHIVE_PATH}.gpg"
    ARCHIVE_BASE="${ARCHIVE_BASE}.gpg"
  elif $GPG_SYM; then
    log "INFO" "使用 GPG 对称加密"
    need_cmd gpg
    if [[ -n "${GPG_PASSPHRASE:-}" ]]; then
      gpg --batch --yes --passphrase "$GPG_PASSPHRASE" --symmetric --output "${ARCHIVE_PATH}.gpg" "$ARCHIVE_PATH"
    else
      gpg --batch --yes --symmetric --output "${ARCHIVE_PATH}.gpg" "$ARCHIVE_PATH"
    fi
    rm -f "$ARCHIVE_PATH"
    ARCHIVE_PATH="${ARCHIVE_PATH}.gpg"
    ARCHIVE_BASE="${ARCHIVE_BASE}.gpg"
  fi
}

# 生成 sha256
gen_sha() {
  sha256sum "$ARCHIVE_PATH" > "$SHA_PATH"
  log "INFO" "已生成校验文件：${SHA_PATH##*/}"
}

# 构建 obsutil 参数
build_obs_flags() {
  local flags=()
  flags+=("-f")
  flags+=("-p=${OBS_PARALLEL}")
  flags+=("-j=${OBS_JOBS}")
  flags+=("-ps=${OBS_PARTSIZE}")
  flags+=("-threshold=${OBS_THRESHOLD}")
  [[ -n "$OBS_RATE_FLAG" ]] && flags+=("$OBS_RATE_FLAG")
  case "$CLI_SSE" in
    aes256|AES256) flags+=("-h=x-obs-server-side-encryption:AES256");;
    kms|KMS)
      if [[ -z "${OBS_KMS_KEY_ID:-}" ]]; then
        log "WARN" "已选择 SSE-KMS，但未设置 OBS_KMS_KEY_ID，将只设置 kms 算法头。"
        flags+=("-h=x-obs-server-side-encryption:kms")
      else
        flags+=("-h=x-obs-server-side-encryption:kms")
        flags+=("-h=x-obs-server-side-encryption-kms-key-id:${OBS_KMS_KEY_ID}")
      fi
      ;;
    none|None|"") ;;
    *) log "WARN" "未知 --sse=$CLI_SSE，忽略。";;
  esac
  printf '%s\n' "${flags[@]}"
}

# 上传（含重试）
upload() {
  local start; start=$(date +%s)
  local dst_dir="obs://${OBS_BUCKET}/${OBS_BACKUP_DIR}/"
  local flags; mapfile -t flags < <(build_obs_flags)
  retry 3 "上传归档 ${ARCHIVE_BASE}" obsutil cp "$ARCHIVE_PATH" "${dst_dir}${ARCHIVE_BASE}" "${flags[@]}"
  retry 3 "上传校验 ${ARCHIVE_BASE}.sha256" obsutil cp "$SHA_PATH" "${dst_dir}${ARCHIVE_BASE}.sha256" "${flags[@]}"
  local end; end=$(date +%s)
  UP_SECONDS=$((end - start))
  if (( UP_SECONDS > 0 )); then
    AVG_SPEED="$(( PACK_SIZE / UP_SECONDS ))"
  else
    AVG_SPEED="$PACK_SIZE"
  fi
}

# 远端完整性校验（下载 .sha256 比对）
verify_remote() {
  local tmp_remote="${SHA_PATH}.remote"
  rm -f "$tmp_remote"
  local dst="obs://${OBS_BUCKET}/${OBS_BACKUP_DIR}/${ARCHIVE_BASE}.sha256"
  retry 3 "下载远端校验 ${ARCHIVE_BASE}.sha256" obsutil cp "$dst" "$tmp_remote" -f >/dev/null
  if ! cmp -s "$SHA_PATH" "$tmp_remote"; then
    log "ERROR" "远端 .sha256 与本地不一致"
    return 1
  fi
  rm -f "$tmp_remote"
  log "INFO" "远端完整性校验通过（.sha256 一致）"
}

#############################
# 主流程
#############################

SECONDS=0
PACK_SECONDS=0
UP_SECONDS=0
AVG_SPEED=0
PACK_SIZE=0
BACKUP_SIZE_HUMAN=""

log "INFO" "准备开始备份。DRY_RUN=${DRY_RUN} KEEP_LOCAL=${KEEP_LOCAL} SSE=${CLI_SSE}"

retry 3 "打包与压缩" pack || { log "ERROR" "打包失败"; exit 3; }
maybe_encrypt
gen_sha

# 计算人类可读大小
BACKUP_SIZE_HUMAN="$(numfmt --to=iec "$PACK_SIZE")"

if $DRY_RUN; then
  log "INFO" "Dry-run 模式：不执行上传。归档：${ARCHIVE_BASE} 大小：${BACKUP_SIZE_HUMAN}"
  log "INFO" "本次总用时：${SECONDS}s"
  send_telegram "dryrun"
  exit 0
fi

# 上传
retry 3 "上传到 OBS" upload || { log "ERROR" "上传失败"; exit 4; }

# 完整性校验
if ! verify_remote; then
  log "ERROR" "上传后完整性校验失败"
  local tail_log; tail_log="$(tail -n 80 "${LOG_FILE:-./backup.log}" 2>/dev/null || true)"
  send_telegram "error" "上传后完整性校验失败：${ARCHIVE_BASE}" "$tail_log"
  exit 5
fi

# 清理本地
if ! $KEEP_LOCAL; then
  rm -f "$ARCHIVE_PATH" "$SHA_PATH" || true
  log "INFO" "已删除本地临时归档与校验文件"
fi

# 汇总
TOTAL_SECS=$SECONDS
SPEED_HUMAN="$(numfmt --to=iec "$AVG_SPEED")/s"
log "INFO" "完成：归档大小=${BACKUP_SIZE_HUMAN} 打包=${PACK_SECONDS}s 上传=${UP_SECONDS}s 平均速率=${SPEED_HUMAN} 总用时=${TOTAL_SECS}s"
send_telegram "success"

exit 0
