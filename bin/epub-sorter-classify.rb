#!/usr/bin/env ruby
# frozen_string_literal: true

# convert_output の EPUB がどの作品のものかを narou 自身の命名から割り出し、振り分け先を出力する。
# 移動は epub-sorter.sh が行う。ここでは小説フォルダを読むだけで書き込まない。
#
# 使い方: epub-sorter-classify.rb [--novel-dir DIR] EPUB...
#   DIR は narou の小説フォルダ（.narou があるフォルダ）。既定は /novel
#
# 出力: 入力の順に 1 行 1 件、タブ区切り
#   <EPUB のパス>\t<04_epub|05_epub_end|unknown|error>\t<理由>\t<作品のファイル名（拡張子なし）>
#   - 理由は 連載中 / 完結 / 凍結 / 完結・凍結。unknown / error のときは、そうなったわけ
#   - unknown: 一致する作品が 0 件か 2 件以上（ファイルが変わるまで結果は同じ）
#   - error:   その 1 冊の判定中に例外が出た（次の回にやり直してよい）
#   - 4 列目は一致した作品の narou のファイル名。分割ファイル（_2 など）の掃除に使う。unknown / error では空
#
# 終了コード: 0 = 出力どおり。3 = 何も出力しない（全体をあとでやり直す）。2 = 小説フォルダではない
#   3 になるのは次のとき:
#   - 管理ファイル（database.yaml / freeze.yaml / local_setting.yaml）が読めない・形が違う・"end" の無い作品がある
#     （narou は作品ごとに database.yaml を保存し直すので、途中まで書かれたものを読むことがある）
#   - 判定している間に管理ファイルが書き換わった
#   - ファイル名を求められない作品がある（保存フォルダが無いなど）
#
# 作品の特定:
#   database.yaml の各作品について Narou.create_novel_filename(data, ".epub") の拡張子なしの名前を求め、
#   EPUB のファイル名（拡張子なし）と照合する。一致しなければ末尾の「_数字」（narou の分割ファイルは _2 から）を
#   外した名前で照合する。一致が 1 件のときだけ振り分け先を決める。
#   照合は Unicode NFC にそろえて行う（Samba 経由などで NFD の名前になっても一致させるため）。

# narou の gem を先に有効にする（先に yaml を読むと、narou が要求する版と違う psych が有効になってしまう）
gem "narou"
require "yaml"

EXIT_NOT_NAROU_DIR = 2
EXIT_RETRY = 3

def fail_retry(message)
  warn "[epub-sorter-classify] #{message}（あとでやり直します）"
  exit EXIT_RETRY
end

# 引数は手で読む（OptionParser は不正な UTF-8 のファイル名で例外になるため）
novel_dir = "/novel"
if ARGV[0] == "--novel-dir"
  ARGV.shift
  novel_dir = ARGV.shift or abort "Usage: #{File.basename($PROGRAM_NAME)} [--novel-dir DIR] EPUB..."
end

novel_dir = File.expand_path(novel_dir)
unless File.directory?(File.join(novel_dir, ".narou"))
  warn "[epub-sorter-classify] #{novel_dir}/.narou がありません（narou の小説フォルダを指定してください）"
  exit EXIT_NOT_NAROU_DIR
end

# 読む前と判定したあとで管理ファイルの状態を比べ、変わっていたら結果を捨てる
DATABASE_PATH, FREEZE_PATH, LOCAL_SETTING_PATH = WATCHED_FILES =
  %w[database.yaml freeze.yaml local_setting.yaml].map { |n| File.join(novel_dir, ".narou", n) }.freeze

def file_states
  WATCHED_FILES.to_h do |path|
    st = File.stat(path)
    [path, [st.ino, st.size, st.mtime.to_r]]
  rescue Errno::ENOENT
    [path, nil]
  end
end

states_before = file_states

# narou に読ませる前に、自分で読んで形を確かめる
def load_yaml(path, default)
  return default unless File.exist?(path)
  YAML.unsafe_load_file(path)
rescue Psych::SyntaxError, ArgumentError => e
  fail_retry("#{File.basename(path)} を読めません: #{e.message.lines.first&.strip}")
end

database_raw = load_yaml(DATABASE_PATH, nil)
fail_retry("database.yaml がありません") if database_raw.nil?
fail_retry("database.yaml の形が想定と違います") unless database_raw.is_a?(Hash)
database_raw.each do |id, data|
  fail_retry("database.yaml の作品 #{id.inspect} の形が想定と違います") unless data.is_a?(Hash)
  fail_retry("database.yaml の作品 ID #{id}（#{data["title"]}）に \"end\" がありません") unless data.key?("end")
end
fail_retry("freeze.yaml の形が想定と違います") unless load_yaml(FREEZE_PATH, {}).is_a?(Hash)
fail_retry("local_setting.yaml の形が想定と違います") unless load_yaml(LOCAL_SETTING_PATH, {}).is_a?(Hash)

# Narou.root_dir はカレントディレクトリから .narou を探し、Downloader は読み込み時に database を開くので、
# narou のライブラリを読み込む前に移動する
Dir.chdir(novel_dir)
Encoding.default_external = Encoding::UTF_8
# narou のロガー（narou_logger）は読み込まない。logging が有効だと小説フォルダの log/ に書き込むため。
# $stdout2 を $stdout と同じにしておくと、narou は同時実行用のワーカーを起動しない
$stdout2 = $stdout

require "narou"
require "downloader"
require "novelsetting"

# 読むだけにする。
# - narou は保存フォルダの無い作品を見つけると database から消して保存しようとする → 保存させない
# - narou は壊れた YAML を .backup から書き戻そうとする → 書き戻させない
module EpubSorterReadOnlyInventory
  class ReadOnlyError < StandardError; end

  def save
    raise ReadOnlyError, "#{@inventory_file_path} は読み取り専用で開いています"
  end

  def restore(_path)
    nil
  end
end
Inventory.prepend(EpubSorterReadOnlyInventory)

def nfc(str)
  str.unicode_normalize(:nfc)
rescue ArgumentError, Encoding::CompatibilityError
  str
end

EXT = ".epub"
# narou の分割ファイルは「名前_2」から（Narou.get_ebook_file_paths_from_components）
SPLIT_SUFFIX = /\A(.+)_(?:[2-9]|[1-9]\d+)\z/

begin
  novels = Database.instance.get_object.values.map(&:dup)
rescue StandardError => e
  fail_retry("database.yaml を読めません: #{e.message}")
end
index = Hash.new { |h, k| h[k] = [] }
novels.each do |data|
  name = File.basename(Narou.create_novel_filename(data, EXT), EXT)
  index[nfc(name)] << [data, name]
rescue StandardError => e
  fail_retry("作品 ID #{data["id"]}（#{data["title"]}）のファイル名を求められません: #{e.message}")
end

def classify(path, index)
  stem = nfc(File.basename(path).sub(/\.epub\z/i, ""))
  matches = index.fetch(stem, [])
  if matches.empty? && stem =~ SPLIT_SUFFIX
    matches = index.fetch(Regexp.last_match(1), [])
  end

  case matches.size
  when 0
    ["unknown", "一致する作品がありません", ""]
  when 1
    data, name = matches.first
    completed = data["end"] ? true : false
    frozen = Narou.novel_frozen?(data["id"])
    reason = [("完結" if completed), ("凍結" if frozen)].compact.join("・")
    reason.empty? ? ["04_epub", "連載中", name] : ["05_epub_end", reason, name]
  else
    ids = matches.map { |d, _| d["id"] }.join(", ")
    ["unknown", "一致する作品が #{matches.size} 件あります（ID: #{ids}）", ""]
  end
rescue StandardError => e
  ["error", "判定に失敗しました: #{e.message}", ""]
end

rows = ARGV.map { |path| [path, *classify(path, index)] }

if ENV["EPUB_SORTER_TEST_DELAY"]
  # テスト用: 判定のあとで待ち、そのあいだに管理ファイルを書き換えられるようにする
  sleep ENV["EPUB_SORTER_TEST_DELAY"].to_f
end

fail_retry("判定している間に管理ファイルが書き換わりました") unless file_states == states_before

# パスは不正な UTF-8 でもそのまま返す（bash がそのファイルを動かすため）。バイト列として扱う
rows.each do |row|
  $stdout.write(row.map { |col| col.to_s.b.gsub(/[\t\n\r]/n, " ") }.join("\t".b) + "\n".b)
end
