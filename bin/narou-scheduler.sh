#!/bin/bash
# 決まった時刻に narou の WEB UI へ「すべて更新」を依頼する。
# CLI の narou update を別プロセスで動かすと WEB UI と同じ管理ファイルを同時に書き換えてしまうため、
# WEB UI の API（POST /api/update）経由で WEB UI 自身のキューに積む。
set -uo pipefail

NAROU_URL=${NAROU_URL:-http://narou:33000}
UPDATE_TIMES=${NAROU_UPDATE_TIMES:-05:00}   # 空白区切りで複数可（例: "05:00 17:00"）

log() { printf '%s [scheduler] %s\n' "$(date '+%F %T')" "$*"; }

for t in $UPDATE_TIMES; do
  [[ "$t" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] || { log "NAROU_UPDATE_TIMES の書式が不正です（HH:MM）: $t"; exit 1; }
done

seconds_until_next() {
  local now best=-1 t target diff
  now=$(date +%s)
  for t in $UPDATE_TIMES; do
    target=$(date -d "today $t" +%s)
    (( target <= now )) && target=$(date -d "tomorrow $t" +%s)
    diff=$(( target - now ))
    (( best < 0 || diff < best )) && best=$diff
  done
  echo "$best"
}

request_update() {
  local auth=()
  if [[ -n "${NAROU_WEB_USER:-}" ]]; then
    auth=(--digest -u "${NAROU_WEB_USER}:${NAROU_WEB_PASSWORD:-}")
  fi
  local code
  code=$(curl -sS -o /dev/null -w '%{http_code}' "${auth[@]}" --data "" "$NAROU_URL/api/update")
  if [[ "$code" == 2* ]]; then
    log "更新を依頼しました（HTTP $code）"
  else
    log "更新の依頼に失敗しました（HTTP $code）"
  fi
}

if [[ "${1:-}" == "--now" ]]; then
  request_update
  exit 0
fi

log "毎日 $UPDATE_TIMES に $NAROU_URL へ更新を依頼します"
while true; do
  wait_seconds=$(seconds_until_next)
  log "次の更新まで ${wait_seconds} 秒"
  sleep "$wait_seconds"
  request_update
  sleep 1
done
