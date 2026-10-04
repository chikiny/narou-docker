#!/bin/bash
# narou コンテナの初期化。
# - 新規の小説フォルダなら narou の設定を作る
# - 既存の小説フォルダ（Mac から移したもの）なら、ホスト固有のパスをコンテナ内のパスに合わせる
set -euo pipefail

NOVEL_DIR=/novel
AOZORAEPUB3_DIR=/aozoraepub3
CONVERT_OUTPUT_DIR=${CONVERT_OUTPUT_DIR:-/convert_output}

# kfx-watcher / scheduler は小説フォルダを触らない
if [[ "${NAROU_SKIP_INIT:-}" == "1" ]]; then
  exec "$@"
fi

cd "$NOVEL_DIR"

if [[ ! -d .narou ]]; then
  echo "[init] 新しい小説フォルダとして初期化します: $NOVEL_DIR"
  mkdir -p .narou .narousetting
  cat > .narousetting/global_setting.yaml <<EOF
---
aozoraepub3dir: "$AOZORAEPUB3_DIR"
line-height: 1.8
over18: true
server-port: 33000
server-bind: 0.0.0.0
EOF
  narou s convert.no-open=true
  narou s device=epub
fi

mkdir -p .narousetting
[[ -f .narousetting/server_setting.yaml ]] || printf -- "---\nalready-server-boot: true\n" > .narousetting/server_setting.yaml

# global_setting.yaml の値をコンテナに合わせる（値が違うときだけ書き換える）
ruby -ryaml -e '
  path = ".narousetting/global_setting.yaml"
  data = File.exist?(path) ? (YAML.unsafe_load_file(path) || {}) : {}
  want = { "aozoraepub3dir" => ARGV[0], "server-port" => 33000, "server-bind" => "0.0.0.0" }
  changed = want.reject { |k, v| data[k] == v }
  unless changed.empty?
    changed.each { |k, v| puts "[init] global_setting: #{k}: #{data[k].inspect} -> #{v.inspect}" }
    File.write(path, YAML.dump(data.merge(want)))
  end
' "$AOZORAEPUB3_DIR"

# 変換した EPUB のコピー先（kfx-watcher が監視する）
current_copy_to=$(ruby -ryaml -e 'puts((YAML.unsafe_load_file(".narou/local_setting.yaml") || {})["convert.copy-to"].to_s) rescue puts ""')
if [[ "$current_copy_to" != "$CONVERT_OUTPUT_DIR" ]]; then
  echo "[init] local_setting: convert.copy-to: \"$current_copy_to\" -> \"$CONVERT_OUTPUT_DIR\""
  narou s "convert.copy-to=$CONVERT_OUTPUT_DIR" >/dev/null
fi

exec "$@"
