#!/usr/bin/env ruby
# frozen_string_literal: true

# convert_output の EPUB がどの作品のものかを narou 自身の命名から割り出し、振り分け先を出力する。
# 移動は epub-sorter.sh が行う。ここでは小説フォルダを読むだけで書き込まない。
#
# 使い方: epub-sorter-classify.rb [--novel-dir DIR] EPUB...
#   DIR は narou の小説フォルダ（.narou があるフォルダ）。既定は /novel
#
# 出力: 入力の順に 1 行 1 件、タブ区切り
#   <EPUB のパス>\t<04_epub|05_epub_end|unknown>\t<理由>
#   理由は 連載中 / 完結 / 凍結 / 完結・凍結、unknown のときは特定できなかったわけ
#
# 作品の特定:
#   database.yaml の各作品について Narou.create_novel_filename(data, ".epub") の拡張子なしの名前を求め、
#   EPUB のファイル名（拡張子なし）と照合する。一致しなければ末尾の「_数字」（narou の分割ファイル）を
#   外した名前で照合する。一致が 1 件のときだけ振り分け先を決める。
#   照合は Unicode NFC にそろえて行う（Samba 経由などで NFD の名前になっても一致させるため）。

require "optparse"

novel_dir = "/novel"
OptionParser.new do |opt|
  opt.banner = "Usage: #{File.basename($PROGRAM_NAME)} [--novel-dir DIR] EPUB..."
  opt.on("--novel-dir DIR", "narou の小説フォルダ（既定: /novel）") { |v| novel_dir = v }
end.parse!(ARGV)

novel_dir = File.expand_path(novel_dir)
unless File.directory?(File.join(novel_dir, ".narou"))
  warn "[epub-sorter-classify] #{novel_dir}/.narou がありません（narou の小説フォルダを指定してください）"
  exit 2
end

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

# 読むだけにする。narou は保存フォルダの無い作品を見つけると database から消して保存しようとするが、
# ここでは保存させない（その作品は照合の対象から外す）
module EpubSorterReadOnlyInventory
  class ReadOnlyError < StandardError; end

  def save
    raise ReadOnlyError, "#{@inventory_file_path} は読み取り専用で開いています"
  end
end
Inventory.prepend(EpubSorterReadOnlyInventory)

def nfc(str)
  str.unicode_normalize(:nfc)
rescue ArgumentError, Encoding::CompatibilityError
  str
end

EXT = ".epub"

novels = Database.instance.get_object.values.map(&:dup)
index = Hash.new { |h, k| h[k] = [] }
novels.each do |data|
  name = Narou.create_novel_filename(data, EXT)
  index[nfc(File.basename(name, EXT))] << data
rescue StandardError => e
  warn "[epub-sorter-classify] 作品 ID #{data["id"]}（#{data["title"]}）のファイル名を求められません: #{e.message}"
end

def classify(path, index)
  stem = nfc(File.basename(path).sub(/\.epub\z/i, ""))
  matches = index.fetch(stem, [])
  if matches.empty? && stem =~ /\A(.+)_\d+\z/
    matches = index.fetch(Regexp.last_match(1), [])
  end

  case matches.size
  when 0
    ["unknown", "一致する作品がありません"]
  when 1
    data = matches.first
    completed = data["end"] ? true : false
    frozen = Narou.novel_frozen?(data["id"])
    reason = [("完結" if completed), ("凍結" if frozen)].compact.join("・")
    reason.empty? ? ["04_epub", "連載中"] : ["05_epub_end", reason]
  else
    ids = matches.map { |d| d["id"] }.join(", ")
    ["unknown", "一致する作品が #{matches.size} 件あります（ID: #{ids}）"]
  end
rescue StandardError => e
  ["unknown", "判定に失敗しました: #{e.message}"]
end

ARGV.each do |path|
  dest, reason = classify(path, index)
  puts [path, dest, reason.tr("\t\n", "  ")].join("\t")
end
