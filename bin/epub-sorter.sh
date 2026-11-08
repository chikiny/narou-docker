#!/bin/bash
# convert_output を監視し、narou が置いた EPUB を作品の状態で振り分ける。
# narou には変換後に処理を差し込むフックが無いので、convert.copy-to の先を inotify で見張る。
#
# - 04_epub/     連載中で凍結していない作品
# - 05_epub_end/ 完結した作品、または凍結した作品
# - 作品の特定と状態の判定は epub-sorter-classify.rb（narou のライブラリで小説フォルダを読むだけ）
# - 行き先へ上書きで移し、もう一方のフォルダに同じ名前の EPUB があれば消す（どちらか一方にだけ置く）
# - 作品が特定できない EPUB は直下に残し、ファイルが更新されるまで再試行しない
# - 書き込み途中を拾わないよう、イベントが EPUB_SETTLE_SECONDS 秒途切れるまで待ってから振り分ける
#
# 使い方: epub-sorter.sh [--once]
#   --once  監視せず、いま直下にある EPUB を 1 回だけ振り分けて終わる
set -uo pipefail

OUTPUT_DIR=${CONVERT_OUTPUT_DIR:-/convert_output}
NOVEL_DIR=${EPUB_SORTER_NOVEL_DIR:-/novel}
SETTLE_SECONDS=${EPUB_SETTLE_SECONDS:-15}
RESCAN_SECONDS=${EPUB_RESCAN_SECONDS:-600}
CLASSIFY=${EPUB_SORTER_CLASSIFY:-"$(dirname -- "${BASH_SOURCE[0]}")/epub-sorter-classify.rb"}

ONGOING_DIR=04_epub
END_DIR=05_epub_end

declare -A failed   # path -> "mtime:size"

log() { printf '%s [epub-sorter] %s\n' "$(date '+%F %T')" "$*"; }

signature() { stat -c '%Y:%s' -- "$1" 2>/dev/null; }

mark_failed() {
  local epub=$1 message=$2 sig
  sig=$(signature "$epub") || return 0
  failed[$epub]=$sig
  log "$message（ファイルが更新されるまで再試行しません）: ${epub##*/}"
}

# 1 冊を行き先へ移し、反対側の同名ファイルを消す
move_epub() {
  local epub=$1 dest=$2 reason=$3 name other
  name=${epub##*/}
  case "$dest" in
    "$ONGOING_DIR") other=$END_DIR ;;
    "$END_DIR") other=$ONGOING_DIR ;;
    *) mark_failed "$epub" "振り分け先が不正です（$dest）"; return 1 ;;
  esac
  if ! mkdir -p -- "$OUTPUT_DIR/$dest" || ! mv -f -- "$epub" "$OUTPUT_DIR/$dest/$name"; then
    mark_failed "$epub" "移動に失敗しました"
    return 1
  fi
  unset 'failed[$epub]'
  log "振り分け: $name -> $dest（$reason）"
  if [[ -e "$OUTPUT_DIR/$other/$name" ]]; then
    if rm -f -- "$OUTPUT_DIR/$other/$name"; then
      log "古い EPUB を消しました: $other/$name"
    else
      log "古い EPUB を消せませんでした: $other/$name"
    fi
  fi
}

sort_pending() {
  local epub sig path dest reason
  shopt -s nullglob nocaseglob
  local epubs=("$OUTPUT_DIR"/*.epub)
  shopt -u nullglob nocaseglob
  local pending=()
  for epub in "${epubs[@]}"; do
    [[ -f "$epub" ]] || continue
    sig=$(signature "$epub") || continue
    if [[ "${failed[$epub]-}" == "$sig" ]]; then
      continue
    fi
    pending+=("$epub")
  done
  (( ${#pending[@]} )) || return 0

  local result
  if ! result=$(ruby "$CLASSIFY" --novel-dir "$NOVEL_DIR" "${pending[@]}"); then
    # 管理ファイルが読めないなど。次のイベントか再走査でやり直す
    log "作品の判定に失敗しました（${#pending[@]} 冊は直下に残します）"
    return 0
  fi
  while IFS=$'\t' read -r path dest reason; do
    [[ -n "$path" && -f "$path" ]] || continue
    if [[ "$dest" == unknown ]]; then
      mark_failed "$path" "振り分けできません: $reason"
    else
      move_epub "$path" "$dest" "$reason"
    fi
  done <<< "$result"
}

wait_for_epub() {
  # 変化を待つ。RESCAN_SECONDS で一度タイムアウトさせて取りこぼしを拾う
  inotifywait -qq -t "$RESCAN_SECONDS" -e close_write -e moved_to "$OUTPUT_DIR"
  # 続けて書き込まれる間は待つ
  while inotifywait -qq -t "$SETTLE_SECONDS" -e close_write -e moved_to -e modify -e create "$OUTPUT_DIR"; do
    :
  done
}

if [[ "${1:-}" == "--once" ]]; then
  sort_pending
  exit 0
fi

mkdir -p "$OUTPUT_DIR"
log "監視を開始します: $OUTPUT_DIR (settle=${SETTLE_SECONDS}s, rescan=${RESCAN_SECONDS}s)"
while true; do
  sort_pending
  wait_for_epub
done
