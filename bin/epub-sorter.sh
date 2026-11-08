#!/bin/bash
# convert_output を監視し、narou が置いた EPUB を作品の状態で振り分ける。
# narou には変換後に処理を差し込むフックが無いので、convert.copy-to の先を inotify で見張る。
#
# - 04_epub/     連載中で凍結していない作品
# - 05_epub_end/ 完結した作品、または凍結した作品
# - 作品の特定と状態の判定は epub-sorter-classify.rb（narou のライブラリで小説フォルダを読むだけ）
# - 行き先へ上書きで移し、もう一方のフォルダにある同じ作品の EPUB（本体と分割ファイル _2, _3 …）を消す
#   （各作品の EPUB はどちらか一方にだけ置く）
# - 作品が特定できない EPUB（一致が 0 件か 2 件以上）は直下に残し、ファイルが更新されるまで再試行しない
# - 判定中の一時的な失敗（管理ファイルが保存中だった、など）は記録せず、次の回にやり直す
# - 名前に制御文字（改行・タブなど）を含む EPUB は判定に渡さず直下に残す（ファイルが更新されるまで再試行しない）
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

# 反対側のフォルダから、作品の EPUB（<base>.epub と分割ファイル <base>_<2 以上>.epub）を消す
remove_from_other_side() {
  local other=$1 base=$2 file rest
  shopt -s nullglob
  local files=("$OUTPUT_DIR/$other"/*)
  shopt -u nullglob
  for file in "${files[@]}"; do
    [[ -f "$file" ]] || continue
    # base は「[作者] 題名」のように [] を含むので、引用符で囲んで文字どおりに比べる
    [[ "${file##*/}" == "$base"* ]] || continue
    rest=${file##*/}
    rest=${rest:${#base}}
    [[ "$rest" =~ ^(_([2-9]|[1-9][0-9]+))?\.[Ee][Pp][Uu][Bb]$ ]] || continue
    if rm -f -- "$file"; then
      log "古い EPUB を消しました: $other/${file##*/}"
    else
      log "古い EPUB を消せませんでした: $other/${file##*/}"
    fi
  done
}

# 1 冊を行き先へ移し、反対側にある同じ作品の EPUB を消す
move_epub() {
  local epub=$1 dest=$2 reason=$3 base=$4 name other
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
  # 同じ名前は必ず消す。base が分かれば分割ファイルも消す
  if [[ -e "$OUTPUT_DIR/$other/$name" ]]; then
    if rm -f -- "$OUTPUT_DIR/$other/$name"; then
      log "古い EPUB を消しました: $other/$name"
    else
      log "古い EPUB を消せませんでした: $other/$name"
    fi
  fi
  [[ -n "$base" ]] && remove_from_other_side "$other" "$base"
  return 0
}

sort_pending() {
  local epub sig path dest reason base name
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
    # 判定の出力は 1 行 1 件のタブ区切りなので、改行やタブを含む名前は渡せない
    name=${epub##*/}
    if [[ "$name" == *[[:cntrl:]]* ]]; then
      mark_failed "$epub" "ファイル名に制御文字が含まれるため振り分けません"
      continue
    fi
    pending+=("$epub")
  done
  (( ${#pending[@]} )) || return 0

  local result
  if ! result=$(ruby "$CLASSIFY" --novel-dir "$NOVEL_DIR" "${pending[@]}"); then
    # 管理ファイルが保存中だった・読めないなど。記録せず、次のイベントか再走査でやり直す
    log "作品の判定に失敗しました（${#pending[@]} 冊は直下に残し、次の回にやり直します）"
    return 0
  fi
  while IFS=$'\t' read -r path dest reason base; do
    [[ -n "$path" && -f "$path" ]] || continue
    case "$dest" in
      unknown) mark_failed "$path" "振り分けできません: $reason" ;;
      error) log "判定できませんでした（次の回にやり直します）: ${path##*/}（$reason）" ;;
      *) move_epub "$path" "$dest" "$reason" "$base" ;;
    esac
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
