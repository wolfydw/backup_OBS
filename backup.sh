#!/usr/bin/env bash
# 备份并上传到华为云 OBS
# - 从同目录 env.conf 加载配置，支持命令行覆盖
# - 打包多目录（支持 pigz），生成 SHA256 校验，obsutil 分片/并发上传
# - 上传 .tar.gz 以及 .tar.gz.sha256，并下载远端 .sha256 比对确保完整性
# - 成功/失败写入日志并 Telegram 通知
# - 支持 --dry-run / --self-check / --verify / --keep-local / --concurrency / --rate / --label / --sse
# 退出码：0 成功；2 配置缺失；3 打包失败；4 上传失败；5 校验失败

set -Eeuo pipefail

SCRIPT_PATH="${BASH_SOURCE[0]:-$0}"
SCRIPT_DIR="$(cd "$(dirname -- "$SCRIPT_PATH")" && pwd -P)"
export PATH="$SCRIPT_DIR:$PATH"
cd "$SCRIPT_DIR"

LOG_PREFIX="[BACKUP]"
log_ts() { date '+%Y-%m-%d %H:%M:%S'; }
log() {
  local level="$1"; shift
  local line
  line="$(log_ts) ${LOG_PREFIX}[$level] $*"
  echo "$line" | tee -a "${LOG_FILE:-./backup.log}"
}

# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/telegram.sh"

RUNTIME_EXCLUDE_FILE=""

cleanup_tmp() {
  [[ -n "${RUNTIME_EXCLUDE_FILE:-}" ]] && rm -f "$RUNTIME_EXCLUDE_FILE"
}
trap cleanup_tmp EXIT

on_error() {
  local exit_code=$?
  local line_no=${BASH_LINENO[0]:-}
  local tail_log
  log "ERROR" "脚本异常退出（exit=$exit_code, line=${line_no})."
  tail_log="$(tail -n 80 "${LOG_FILE:-./backup.log}" 2>/dev/null || true)"
  tg_backup_error "$LABEL" "脚本异常退出（exit=${exit_code}, line=${line_no}）" "$tail_log"
  exit "$exit_code"
}
trap on_error ERR

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    log "ERROR" "未找到命令：$1"
    return 1
  }
}

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

CONF_FILE="${SCRIPT_DIR}/env.conf"
if [[ ! -f "$CONF_FILE" ]]; then
  echo "未找到配置文件 ${CONF_FILE}，请先复制/编辑 env.conf" >&2
  exit 2
fi

# shellcheck disable=SC1090
source "$CONF_FILE"

BACKUP_PATHS=()

KEEP_LOCAL=false
DRY_RUN=false
SELF_CHECK=false
VERIFY_ONLY=false
CLI_LABEL=""
CLI_SSE="none"
CLI_CONCURRENCY=""
CLI_RATE=""
GPG_RECIPIENT=""
GPG_SYM=false

usage() {
  cat <<'USAGE'
用法：
  ./backup.sh [--dry-run] [--self-check] [--verify] [--keep-local]
              [--concurrency=N] [--rate=10MB/s]
              [--label=NAME]
              [--sse=none|kms|aes256]
              [--gpg-recipient=KMS_OR_PGP_ID | --gpg-symmetric]
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=true; shift;;
    --self-check) DRY_RUN=true; SELF_CHECK=true; shift;;
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

if [[ -n "$CLI_LABEL" ]]; then
  LABEL="$CLI_LABEL"
  OBS_BACKUP_DIR="backup/${LABEL}"
fi

if [[ -n "$CLI_CONCURRENCY" ]]; then
  OBS_JOBS="$CLI_CONCURRENCY"
fi

OBS_RATE_FLAG=""
if [[ -n "${CLI_RATE:-}" ]]; then
  OBS_RATE_FLAG="--rate=${CLI_RATE}"
fi

DEFAULT_EXCLUDE_FILE="${SCRIPT_DIR}/exclude.list"
USER_EXCLUDE_FILE="${SCRIPT_DIR}/exclude.user.list"
[[ -f "$DEFAULT_EXCLUDE_FILE" ]] || touch "$DEFAULT_EXCLUDE_FILE"
[[ -f "$USER_EXCLUDE_FILE" ]] || cp -f "${SCRIPT_DIR}/exclude.user.list.example" "$USER_EXCLUDE_FILE"

: "${OBS_BUCKET:?缺少 OBS_BUCKET}"
: "${OBS_BACKUP_DIR:?缺少 OBS_BACKUP_DIR}"
: "${LOG_FILE:?缺少 LOG_FILE}"
: "${OBS_PARALLEL:?缺少 OBS_PARALLEL}" "${OBS_JOBS:?缺少 OBS_JOBS}"
: "${OBS_PARTSIZE:?缺少 OBS_PARTSIZE}" "${OBS_THRESHOLD:?缺少 OBS_THRESHOLD}"
: "${RETAIN_DAYS:?缺少 RETAIN_DAYS}"

if [[ -z "${BACKUP_DIRS:-}" && -n "${BACKUP_DIR:-}" ]]; then
  BACKUP_DIRS="$(printf '%s\n' "$BACKUP_DIR")"
fi

if [[ -z "${BACKUP_DIRS:-}" ]]; then
  echo "缺少 BACKUP_DIRS 配置" >&2
  exit 2
fi

while IFS= read -r path; do
  [[ -n "$path" ]] || continue
  [[ "$path" =~ ^[[:space:]]*# ]] && continue
  BACKUP_PATHS+=("$path")
done <<< "$BACKUP_DIRS"

if [[ "${#BACKUP_PATHS[@]}" -eq 0 ]]; then
  echo "BACKUP_DIRS 没有有效目录" >&2
  exit 2
fi

need_cmd tar
need_cmd sha256sum
need_cmd curl
need_cmd bash

if ! command -v obsutil >/dev/null 2>&1; then
  log "ERROR" "未找到 obsutil。请下载 obsutil，并确保其在 PATH 或与脚本同目录。"
  log "ERROR" "首次使用请执行：./obsutil config -interactive"
  exit 2
fi

OBSUTIL_CONFIG_PATH="${HOME}/.obsutilconfig"
if [[ ! -f "$OBSUTIL_CONFIG_PATH" ]]; then
  log "ERROR" "未检测到 obsutil 配置文件：${OBSUTIL_CONFIG_PATH}"
  log "ERROR" "请先执行：./obsutil config -interactive 完成初始化（AK/SK、Endpoint、默认桶）"
  exit 2
fi

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

build_tar_file_list() {
  local args=()
  local p abs parent base
  for p in "${BACKUP_PATHS[@]}"; do
    if [[ ! -e "$p" ]]; then
      log "WARN" "路径不存在，跳过：$p"
      continue
    fi
    abs="$(readlink -f "$p")"
    parent="$(dirname "$abs")"
    base="$(basename "$abs")"
    args+=("-C" "$parent" "$base")
  done
  printf '%s\n' "${args[@]}"
}

archive_path_for_abs() {
  # 将真实文件系统绝对路径映射为 tar 归档内路径。
  local abs_input="$1"
  local root abs_root root_base rel

  for root in "${BACKUP_PATHS[@]}"; do
    abs_root="$(readlink -f "$root")"
    root_base="$(basename "$abs_root")"

    if [[ "$abs_input" == "$abs_root" ]]; then
      printf '%s\n' "$root_base"
      return 0
    fi

    if [[ "$abs_input" == "$abs_root"/* ]]; then
      rel="${abs_input#"$abs_root"/}"
      printf '%s/%s\n' "$root_base" "$rel"
      return 0
    fi
  done

  return 1
}

append_exclude_path() {
  local archive_path="$1"
  local path_type="$2"

  printf '%s\n' "$archive_path" >> "$RUNTIME_EXCLUDE_FILE"
  if [[ "$path_type" == "dir" ]]; then
    printf '%s/*\n' "$archive_path" >> "$RUNTIME_EXCLUDE_FILE"
  fi
}

match_user_rule() {
  # 用户规则支持两类写法：
  # 1. 绝对路径，如 /root/data/dify
  # 2. 通配规则，如 */.halo
  # 解析后统一转换成 tar 能识别的实际排除项。
  local rule="$1"
  local matched=0
  local root abs_root root_base entry archive_path path_type
  local rule_tail find_name has_glob

  if [[ "$rule" == /* ]]; then
    if [[ ! -e "$rule" ]]; then
      log "WARN" "用户排除规则未命中任何现有路径：$rule"
      return 0
    fi

    if ! archive_path="$(archive_path_for_abs "$(readlink -f "$rule")")"; then
      log "WARN" "用户排除规则不在任何备份根目录内：$rule"
      return 0
    fi

    if [[ -d "$rule" ]]; then
      path_type="dir"
    else
      path_type="file"
    fi
    append_exclude_path "$archive_path" "$path_type"
    return 0
  fi

  has_glob=false
  if [[ "$rule" == *'*'* || "$rule" == *'?'* || "$rule" == *'['* ]]; then
    has_glob=true
  fi

  for root in "${BACKUP_PATHS[@]}"; do
    abs_root="$(readlink -f "$root")"
    root_base="$(basename "$abs_root")"

    if ! $has_glob; then
      entry=""
      if [[ "$rule" == "$root_base" ]]; then
        entry="$abs_root"
      elif [[ "$rule" == "$root_base"/* ]]; then
        entry="${abs_root}/${rule#"$root_base"/}"
      fi

      if [[ -n "$entry" && -e "$entry" ]]; then
        matched=1
        if [[ -d "$entry" ]]; then
          path_type="dir"
        else
          path_type="file"
        fi
        append_exclude_path "$rule" "$path_type"
      fi
      continue
    fi

    rule_tail="${rule##*/}"
    if [[ "$rule_tail" == *'*'* || "$rule_tail" == *'?'* || "$rule_tail" == *'['* ]]; then
      while IFS= read -r -d '' entry; do
        archive_path="$(archive_path_for_abs "$entry" || true)"
        [[ -n "$archive_path" ]] || continue
        if [[ "$archive_path" == $rule ]]; then
          matched=1
          if [[ -d "$entry" ]]; then
            path_type="dir"
          else
            path_type="file"
          fi
          append_exclude_path "$archive_path" "$path_type"
        fi
      done < <(find "$abs_root" -mindepth 1 -print0 2>/dev/null)
    else
      find_name="$rule_tail"
      while IFS= read -r -d '' entry; do
        archive_path="$(archive_path_for_abs "$entry" || true)"
        [[ -n "$archive_path" ]] || continue
        if [[ "$archive_path" == $rule ]]; then
          matched=1
          if [[ -d "$entry" ]]; then
            path_type="dir"
          else
            path_type="file"
          fi
          append_exclude_path "$archive_path" "$path_type"
        fi
      done < <(find "$abs_root" -mindepth 1 -name "$find_name" -print0 2>/dev/null)
    fi
  done

  if (( matched == 0 )); then
    log "WARN" "用户排除规则未命中任何路径：$rule"
  fi
}

build_runtime_exclude_file() {
  # 默认规则直接交给 tar。
  # 用户规则先解析成真实命中路径，再换算为归档内排除项。
  local rule
  RUNTIME_EXCLUDE_FILE="$(mktemp)"
  cat "$DEFAULT_EXCLUDE_FILE" > "$RUNTIME_EXCLUDE_FILE"

  [[ -f "$USER_EXCLUDE_FILE" ]] || return 0

  while IFS= read -r rule; do
    [[ -n "$rule" ]] || continue
    [[ "$rule" =~ ^[[:space:]]*# ]] && continue
    match_user_rule "$rule"
  done < "$USER_EXCLUDE_FILE"

  awk '!seen[$0]++' "$RUNTIME_EXCLUDE_FILE" > "${RUNTIME_EXCLUDE_FILE}.dedup"
  mv "${RUNTIME_EXCLUDE_FILE}.dedup" "$RUNTIME_EXCLUDE_FILE"
}

check_space() {
  local total=0
  local p sz avail need
  for p in "${BACKUP_PATHS[@]}"; do
    [[ -e "$p" ]] || continue
    sz="$(du -sb --apparent-size "$p" 2>/dev/null | cut -f1)"
    total=$((total + sz))
  done
  avail=$(df -P "$SCRIPT_DIR" | awk 'NR==2{print $4}')
  avail=$((avail * 1024))
  need=$(( total + total/10 + 100*1024*1024 ))
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

pack() {
  local start end
  local tar_args
  start=$(date +%s)
  mapfile -t tar_args < <(build_tar_file_list)
  if [[ "${#tar_args[@]}" -eq 0 ]]; then
    log "ERROR" "没有可打包的路径（BACKUP_DIRS 均不存在）"
    return 1
  fi

  log "INFO" "开始打包（支持默认与用户排除规则），pigz=${USE_PIGZ}"
  build_runtime_exclude_file
  if $USE_PIGZ; then
    tar --warning=no-file-changed \
      --exclude-from="$RUNTIME_EXCLUDE_FILE" \
      -c "${tar_args[@]}" | pigz > "$ARCHIVE_PATH"
  else
    tar --warning=no-file-changed \
      --exclude-from="$RUNTIME_EXCLUDE_FILE" \
      -czf "$ARCHIVE_PATH" "${tar_args[@]}"
  fi
  end=$(date +%s)
  PACK_SECONDS=$((end - start))
  PACK_SIZE="$(stat -c '%s' "$ARCHIVE_PATH")"
  BACKUP_SIZE_HUMAN="$(numfmt --to=iec "$PACK_SIZE")"
  log "INFO" "打包完成：${BACKUP_SIZE_HUMAN} 用时 ${PACK_SECONDS}s"
}

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

  PACK_SIZE="$(stat -c '%s' "$ARCHIVE_PATH")"
  BACKUP_SIZE_HUMAN="$(numfmt --to=iec "$PACK_SIZE")"
}

gen_sha() {
  sha256sum "$ARCHIVE_PATH" > "$SHA_PATH"
  log "INFO" "已生成校验文件：${SHA_PATH##*/}"
}

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

upload() {
  local start end dst_dir
  local flags
  start=$(date +%s)
  dst_dir="obs://${OBS_BUCKET}/${OBS_BACKUP_DIR}/"
  mapfile -t flags < <(build_obs_flags)
  retry 3 "上传归档 ${ARCHIVE_BASE}" obsutil cp "$ARCHIVE_PATH" "${dst_dir}${ARCHIVE_BASE}" "${flags[@]}"
  retry 3 "上传校验 ${ARCHIVE_BASE}.sha256" obsutil cp "$SHA_PATH" "${dst_dir}${ARCHIVE_BASE}.sha256" "${flags[@]}"
  end=$(date +%s)
  UP_SECONDS=$((end - start))
  if (( UP_SECONDS > 0 )); then
    AVG_SPEED="$(( PACK_SIZE / UP_SECONDS ))"
  else
    AVG_SPEED="$PACK_SIZE"
  fi
}

verify_remote() {
  local tmp_remote dst
  tmp_remote="${SHA_PATH}.remote"
  rm -f "$tmp_remote"
  dst="obs://${OBS_BUCKET}/${OBS_BACKUP_DIR}/${ARCHIVE_BASE}.sha256"
  retry 3 "下载远端校验 ${ARCHIVE_BASE}.sha256" obsutil cp "$dst" "$tmp_remote" -f >/dev/null
  if ! cmp -s "$SHA_PATH" "$tmp_remote"; then
    log "ERROR" "远端 .sha256 与本地不一致"
    return 1
  fi
  rm -f "$tmp_remote"
  log "INFO" "远端完整性校验通过（.sha256 一致）"
}

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

if $DRY_RUN; then
  log "INFO" "Dry-run 模式：不执行上传。归档：${ARCHIVE_BASE} 大小：${BACKUP_SIZE_HUMAN}"
  log "INFO" "本次总用时：${SECONDS}s"
  tg_backup_dryrun "$LABEL" "$(printf '%s\n' "${BACKUP_PATHS[@]}")" "$(tg_read_user_excludes "$USER_EXCLUDE_FILE")" "$ARCHIVE_BASE" "$BACKUP_SIZE_HUMAN" "${PACK_SECONDS}s"
  if $SELF_CHECK; then
    rm -f "$ARCHIVE_PATH" "$SHA_PATH" || true
    log "INFO" "Self-check 模式：已删除本地自检归档与校验文件"
  fi
  exit 0
fi

retry 3 "上传到 OBS" upload || { log "ERROR" "上传失败"; exit 4; }

if ! verify_remote; then
  local_tail_log="$(tail -n 80 "${LOG_FILE:-./backup.log}" 2>/dev/null || true)"
  log "ERROR" "上传后完整性校验失败"
  tg_backup_error "$LABEL" "上传后完整性校验失败：${ARCHIVE_BASE}" "$local_tail_log"
  exit 5
fi

if ! $KEEP_LOCAL; then
  rm -f "$ARCHIVE_PATH" "$SHA_PATH" || true
  log "INFO" "已删除本地临时归档与校验文件"
fi

TOTAL_SECS=$SECONDS
SPEED_HUMAN="$(numfmt --to=iec "$AVG_SPEED")/s"
log "INFO" "完成：归档大小=${BACKUP_SIZE_HUMAN} 打包=${PACK_SECONDS}s 上传=${UP_SECONDS}s 平均速率=${SPEED_HUMAN} 总用时=${TOTAL_SECS}s"
tg_backup_success "$LABEL" "$(printf '%s\n' "${BACKUP_PATHS[@]}")" "$(tg_read_user_excludes "$USER_EXCLUDE_FILE")" "$BACKUP_SIZE_HUMAN" "$ARCHIVE_BASE" "obs://${OBS_BUCKET}/${OBS_BACKUP_DIR}/${ARCHIVE_BASE}" "${PACK_SECONDS}s" "${UP_SECONDS}s" "$SPEED_HUMAN"

exit 0
