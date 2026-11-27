#!/bin/bash
# 決まった時刻に narou の WEB UI へ「すべて更新」を依頼する。
# CLI の narou update を別プロセスで動かすと WEB UI と同じ管理ファイルを同時に書き換えてしまうため、
# WEB UI の API（POST /api/update）経由で WEB UI 自身のキューに積む。
#
# 毎日 1 回（NAROU_FULL_UPDATE_TIME）は次の「毎日の処理」を行う:
#   1. キューが空になるまで待つ
#   2. 凍結済みも含めてすべて更新（/api/update force=true）し、終わるまで待つ
#   3. 2 で更新を確認できた作品について、narou-freeze-review.rb で、サイトの最終投稿日が NAROU_FREEZE_AFTER_DAYS 日以内の凍結中の作品は凍結を解除し、
#      それより前の未凍結の作品は凍結する（/api/freeze_off・/api/freeze_on）
#   毎日の処理の最中に来た毎時の更新は飛ばす（同じ作品を二重に取りに行かないため）。
#
# 使い方: narou-scheduler.sh [--now | --daily-now]
#   --now        いますぐ「すべて更新」を 1 回依頼して終わる
#   --daily-now  いますぐ毎日の処理を 1 回行って終わる
set -uo pipefail

NAROU_URL=${NAROU_URL:-http://narou:33000}
UPDATE_TIMES=${NAROU_UPDATE_TIMES:-05:00}           # 空白区切りで複数可（例: "05:00 17:00"）
FULL_UPDATE_TIME=${NAROU_FULL_UPDATE_TIME-03:30}    # 空にすると毎日の処理をしない
FREEZE_AFTER_DAYS=${NAROU_FREEZE_AFTER_DAYS:-30}
QUEUE_WAIT_MAX=${NAROU_QUEUE_WAIT_MAX:-21600}       # キューが空になるのを待つ上限（秒）
QUEUE_POLL_SECONDS=${NAROU_QUEUE_POLL_SECONDS:-30}
NOVEL_DIR=${NAROU_NOVEL_DIR:-/novel}

log() { printf '%s [scheduler] %s\n' "$(date '+%F %T')" "$*"; }

for t in $UPDATE_TIMES $FULL_UPDATE_TIME; do
  [[ "$t" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] || { log "時刻の書式が不正です（HH:MM）: $t"; exit 1; }
done
[[ "$FREEZE_AFTER_DAYS" =~ ^[1-9][0-9]*$ ]] || { log "NAROU_FREEZE_AFTER_DAYS が正の整数ではありません: $FREEZE_AFTER_DAYS"; exit 1; }

# 指定した時刻（複数可）のうち、いちばん近い次の時刻（エポック秒）
next_epoch() {
  local now best=-1 t target
  now=$(date +%s)
  for t in "$@"; do
    target=$(date -d "today $t" +%s)
    (( target <= now )) && target=$(date -d "tomorrow $t" +%s)
    (( best < 0 || target < best )) && best=$target
  done
  echo "$best"
}

# count_slots <開始エポック> <終了エポック>: その間（開始は含まない）に来た NAROU_UPDATE_TIMES の回数
count_slots() {
  local from=$1 to=$2 count=0 day t e
  day=$(date -d "@$from" +%F)
  while [[ $(date -d "$day" +%s) -le $to ]]; do
    for t in $UPDATE_TIMES; do
      e=$(date -d "$day $t" +%s)
      (( e > from && e <= to )) && count=$(( count + 1 ))
    done
    day=$(date -d "$day + 1 day" +%F)
  done
  echo "$count"
}

auth_args() {
  if [[ -n "${NAROU_WEB_USER:-}" ]]; then
    printf '%s\n' --digest -u "${NAROU_WEB_USER}:${NAROU_WEB_PASSWORD:-}"
  fi
}

# api_post <パス> [curl の --data に渡す値...]。HTTP 2xx なら 0。HTTP コードは API_CODE に入る
api_post() {
  local path=$1 d auth=() data=()
  shift
  mapfile -t auth < <(auth_args)
  for d in "$@"; do data+=(--data "$d"); done
  (( ${#data[@]} )) || data=(--data "")
  API_CODE=$(curl -sS -o /dev/null -w '%{http_code}' "${auth[@]}" "${data[@]}" "$NAROU_URL$path")
  [[ "$API_CODE" == 2* ]]
}

request_update() {
  if api_post /api/update; then
    log "更新を依頼しました（HTTP $API_CODE）"
  else
    log "更新の依頼に失敗しました（HTTP $API_CODE）"
  fi
}

# WEB UI のキューが空（[0,0]）になるまで待つ。上限を超えたら 1
wait_queue_empty() {
  local deadline body auth=()
  deadline=$(( $(date +%s) + QUEUE_WAIT_MAX ))
  mapfile -t auth < <(auth_args)
  while true; do
    body=$(curl -sS "${auth[@]}" "$NAROU_URL/api/get_queue_size" 2>/dev/null)
    [[ "$(tr -d ' \n' <<<"$body")" == "[0,0]" ]] && return 0
    if (( $(date +%s) >= deadline )); then
      log "キューが ${QUEUE_WAIT_MAX} 秒たっても空になりません（最後の応答: ${body:-なし}）"
      return 1
    fi
    sleep "$QUEUE_POLL_SECONDS"
  done
}

# run_freeze_review <開始エポック>: 判定スクリプトを実行し、結果を REVIEW_OUTPUT に入れる。
# 開始より後に更新を確認できた作品だけを判定する（403 などで失敗した作品は最終投稿日が古いままのため）。
# 管理ファイルの保存中で読めなければ（終了コード 3）少し待ってやり直す
run_freeze_review() {
  local since=$1 i out rc
  for i in 1 2 3 4 5; do
    out=$(narou-freeze-review.rb --novel-dir "$NOVEL_DIR" --days "$FREEZE_AFTER_DAYS" --checked-since "$since")
    rc=$?
    if (( rc == 0 )); then
      REVIEW_OUTPUT=$out
      return 0
    fi
    (( rc == 3 )) || { log "凍結の判定に失敗しました（終了コード $rc）"; return 1; }
    sleep 10
  done
  log "管理ファイルを読めないため、凍結の見直しをやめます"
  return 1
}

# apply_freeze <on|off>: REVIEW_OUTPUT のうち該当する作品の凍結を付け外しする
apply_freeze() {
  local action=$1 label act id date title ids=()
  if [[ "$action" == on ]]; then label="凍結"; else label="凍結を解除"; fi
  while IFS=$'\t' read -r act id date title; do
    [[ "$act" == "$action" ]] || continue
    ids+=("ids[]=$id")
    log "  ${label}: ID:$id ${title}（最終投稿 $date）"
  done <<<"$REVIEW_OUTPUT"
  if (( ${#ids[@]} == 0 )); then
    log "${label}する作品はありません"
    return 0
  fi
  if api_post "/api/freeze_$action" "${ids[@]}"; then
    log "${#ids[@]} 件を${label}するよう依頼しました（HTTP $API_CODE）"
  else
    log "${label}の依頼に失敗しました（HTTP $API_CODE）"
  fi
}

daily_job() {
  log "毎日の処理を始めます（凍結済みも含めて更新 → 最終投稿から ${FREEZE_AFTER_DAYS} 日を基準に凍結を見直し）"
  log "前の処理が終わるのを待ちます"
  wait_queue_empty || { log "毎日の処理をやめます"; return 1; }
  local started
  started=$(date +%s)
  if ! api_post /api/update "force=true"; then
    log "凍結済みも含めた更新の依頼に失敗しました（HTTP $API_CODE）。毎日の処理をやめます"
    return 1
  fi
  log "凍結済みも含めた更新を依頼しました（HTTP $API_CODE）。終わるまで待ちます"
  sleep 5
  wait_queue_empty || { log "更新が終わらないため、凍結の見直しをやめます"; return 1; }
  log "更新が終わりました。凍結を見直します"
  run_freeze_review "$started" || return 1
  apply_freeze off
  apply_freeze on
  wait_queue_empty || true
  log "毎日の処理が終わりました"
}

case "${1:-}" in
  --now) request_update; exit 0 ;;
  --daily-now) daily_job; exit $? ;;
  "") ;;
  *) echo "Usage: $(basename "$0") [--now | --daily-now]" >&2; exit 2 ;;
esac

log "毎日 $UPDATE_TIMES に $NAROU_URL へ更新を依頼します"
if [[ -n "$FULL_UPDATE_TIME" ]]; then
  log "毎日 $FULL_UPDATE_TIME に凍結済みも含めて更新し、凍結を見直します（最終投稿から ${FREEZE_AFTER_DAYS} 日）"
fi
while true; do
  next_hourly=$(next_epoch $UPDATE_TIMES)
  next_daily=-1
  [[ -n "$FULL_UPDATE_TIME" ]] && next_daily=$(next_epoch "$FULL_UPDATE_TIME")
  # 同じ時刻なら毎日の処理を優先する（毎日の処理は通常の更新も兼ねる）
  if (( next_daily >= 0 && next_daily <= next_hourly )); then
    target=$next_daily kind=毎日の処理
  else
    target=$next_hourly kind=更新
  fi
  wait_seconds=$(( target - $(date +%s) ))
  (( wait_seconds < 0 )) && wait_seconds=0
  log "次の${kind}まで ${wait_seconds} 秒"
  sleep "$wait_seconds"
  if [[ $kind == 毎日の処理 ]]; then
    daily_job
    skipped=$(count_slots "$target" "$(date +%s)")
    (( skipped > 0 )) && log "毎日の処理の間に来た ${skipped} 回分の更新は飛ばしました"
  else
    request_update
  fi
  sleep 1
done
