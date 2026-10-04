#!/bin/bash
# convert_output を監視し、置かれた EPUB を boko で KFX に変換する。
# narou には変換後に処理を差し込むフックが無いので、convert.copy-to の先を inotify で見張る。
#
# - EPUB は 1 冊ずつ convert_epub_kfx.zsh に渡す（1 冊の失敗が他の冊を止めないように）
# - 書き込み途中を拾わないよう、イベントが KFX_SETTLE_SECONDS 秒途切れるまで待ってから変換する
# - 失敗した EPUB は、更新されるまで再試行しない
set -uo pipefail

OUTPUT_DIR=${CONVERT_OUTPUT_DIR:-/convert_output}
SETTLE_SECONDS=${KFX_SETTLE_SECONDS:-15}
RESCAN_SECONDS=${KFX_RESCAN_SECONDS:-600}

declare -A failed   # path -> "mtime:size"

log() { printf '%s [kfx-watcher] %s\n' "$(date '+%F %T')" "$*"; }

signature() { stat -c '%Y:%s' -- "$1" 2>/dev/null; }

convert_pending() {
  local epub sig
  shopt -s nullglob nocaseglob
  local epubs=("$OUTPUT_DIR"/*.epub)
  shopt -u nullglob nocaseglob
  for epub in "${epubs[@]}"; do
    [[ -f "$epub" ]] || continue
    sig=$(signature "$epub") || continue
    if [[ "${failed[$epub]-}" == "$sig" ]]; then
      continue
    fi
    if convert_epub_kfx.zsh "$epub"; then
      unset 'failed[$epub]'
    else
      failed[$epub]=$sig
      log "変換に失敗しました（ファイルが更新されるまで再試行しません）: ${epub##*/}"
    fi
  done
}

wait_for_epub() {
  # 変化を待つ。RESCAN_SECONDS で一度タイムアウトさせて取りこぼしを拾う
  inotifywait -qq -t "$RESCAN_SECONDS" -e close_write -e moved_to "$OUTPUT_DIR"
  # 続けて書き込まれる間は待つ
  while inotifywait -qq -t "$SETTLE_SECONDS" -e close_write -e moved_to -e modify -e create "$OUTPUT_DIR"; do
    :
  done
}

mkdir -p "$OUTPUT_DIR"
log "監視を開始します: $OUTPUT_DIR (settle=${SETTLE_SECONDS}s, rescan=${RESCAN_SECONDS}s)"
while true; do
  convert_pending
  wait_for_epub
done
