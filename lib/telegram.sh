#!/usr/bin/env bash

# 统一的 Telegram 通知模块：
# - 负责消息模板拼装
# - 负责把动态内容放进代码块，降低 MarkdownV2 出错概率
# - 供 backup.sh 和 clean_backups.sh 共用

tg_code_block() {
  local text="${1-}"
  text="$(printf '%s' "$text" | sed -e 's/\\/\\\\/g' -e 's/`/\\`/g')"
  printf '```text\n%s\n```' "$text"
}

tg_send_message() {
  local message="${1-}"
  local response primary_api fallback_api

  if [[ -z "${TG_BOT_TOKEN:-}" || -z "${TG_USER_ID:-}" ]]; then
    log "INFO" "未配置Telegram通知，跳过发送"
    return 0
  fi

  primary_api="https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage"
  response="$(curl -sS -X POST "$primary_api" \
    --data-urlencode "chat_id=${TG_USER_ID}" \
    --data-urlencode "parse_mode=MarkdownV2" \
    --data-urlencode "disable_web_page_preview=true" \
    --data-urlencode "text=${message}" 2>&1 || true)"

  if echo "$response" | grep -q '"ok":true'; then
    log "INFO" "Telegram通知发送成功（official）"
    return 0
  fi

  log "WARN" "Telegram官方API发送失败: $response"

  if [[ -z "${TG_API_BASE_FALLBACK:-}" ]]; then
    log "WARN" "未配置Telegram备用API，通知发送失败"
    return 1
  fi

  fallback_api="${TG_API_BASE_FALLBACK%/}/bot${TG_BOT_TOKEN}/sendMessage"
  response="$(curl -sS -X POST "$fallback_api" \
    --data-urlencode "chat_id=${TG_USER_ID}" \
    --data-urlencode "parse_mode=MarkdownV2" \
    --data-urlencode "disable_web_page_preview=true" \
    --data-urlencode "text=${message}" 2>&1 || true)"

  if echo "$response" | grep -q '"ok":true'; then
    log "INFO" "Telegram通知发送成功（fallback）"
    return 0
  fi

  log "WARN" "Telegram备用API发送失败: $response"
  log "WARN" "Telegram通知发送失败"
  return 1
}

tg_read_user_excludes() {
  local file="${1-}"
  local out="" rule

  [[ -f "$file" ]] || {
    printf '无'
    return 0
  }

  while IFS= read -r rule; do
    [[ -n "$rule" ]] || continue
    [[ "$rule" =~ ^[[:space:]]*# ]] && continue
    out+="${rule}"$'\n'
  done < "$file"

  if [[ -z "$out" ]]; then
    printf '无'
  else
    printf '%s' "${out%$'\n'}"
  fi
}

tg_backup_success() {
  local label="$1" current_date="$2" backup_dirs="$3" user_excludes="$4" backup_size="$5" archive_name="$6" location="$7" pack_time="$8" upload_time="$9" speed="${10}"
  local archive_info message
  archive_info=$(
    cat <<EOF
文件大小: ${backup_size}
归档名称: ${archive_name}
存储位置: ${location}
打包用时: ${pack_time}
上传用时: ${upload_time}
平均速率: ${speed}
EOF
  )
  message="*备份成功*"$'\n\n'
  message+="*主机*"$'\n'"$(tg_code_block "$label")"$'\n'
  message+="*时间*"$'\n'"$(tg_code_block "$current_date")"$'\n'
  message+="*备份内容*"$'\n'"$(tg_code_block "$backup_dirs")"$'\n'
  message+="*用户排除*"$'\n'"$(tg_code_block "$user_excludes")"$'\n'
  message+="*归档信息*"$'\n'"$(tg_code_block "$archive_info")"
  tg_send_message "$message"
}

tg_backup_dryrun() {
  local label="$1" current_date="$2" backup_dirs="$3" user_excludes="$4" archive_name="$5" backup_size="$6" pack_time="$7"
  local archive_info message
  archive_info=$(
    cat <<EOF
归档名称: ${archive_name}
文件大小: ${backup_size}
打包用时: ${pack_time}
EOF
  )
  message="*备份自检*"$'\n\n'
  message+="*主机*"$'\n'"$(tg_code_block "$label")"$'\n'
  message+="*时间*"$'\n'"$(tg_code_block "$current_date")"$'\n'
  message+="*备份内容*"$'\n'"$(tg_code_block "$backup_dirs")"$'\n'
  message+="*用户排除*"$'\n'"$(tg_code_block "$user_excludes")"$'\n'
  message+="*归档信息*"$'\n'"$(tg_code_block "$archive_info")"
  tg_send_message "$message"
}

tg_backup_error() {
  local label="$1" current_date="$2" reason="$3" error_log="$4"
  local message
  message="*备份失败*"$'\n\n'
  message+="*主机*"$'\n'"$(tg_code_block "$label")"$'\n'
  message+="*时间*"$'\n'"$(tg_code_block "$current_date")"$'\n'
  message+="*原因*"$'\n'"$(tg_code_block "$reason")"
  if [[ -n "$error_log" ]]; then
    message+=$'\n'"*错误日志*"$'\n'"$(tg_code_block "$error_log")"
  fi
  tg_send_message "$message"
}

tg_clean_success() {
  local label="$1" current_date="$2" prefix="$3" retain_days="$4" keep_count="$5" del_ok="$6" del_fail="$7"
  local summary message
  summary=$(
    cat <<EOF
前缀: ${prefix}
保留天数: ${retain_days}
保留对象数: ${keep_count}
删除成功: ${del_ok}
删除失败: ${del_fail}
EOF
  )
  message="*清理完成*"$'\n\n'
  message+="*主机*"$'\n'"$(tg_code_block "$label")"$'\n'
  message+="*时间*"$'\n'"$(tg_code_block "$current_date")"$'\n'
  message+="*结果*"$'\n'"$(tg_code_block "$summary")"
  tg_send_message "$message"
}

tg_clean_error() {
  local label="$1" current_date="$2" reason="$3" error_log="$4"
  local message
  message="*清理失败*"$'\n\n'
  message+="*主机*"$'\n'"$(tg_code_block "$label")"$'\n'
  message+="*时间*"$'\n'"$(tg_code_block "$current_date")"$'\n'
  message+="*原因*"$'\n'"$(tg_code_block "$reason")"
  if [[ -n "$error_log" ]]; then
    message+=$'\n'"*错误日志*"$'\n'"$(tg_code_block "$error_log")"
  fi
  tg_send_message "$message"
}
