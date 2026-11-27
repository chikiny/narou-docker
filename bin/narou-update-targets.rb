#!/usr/bin/env ruby
# frozen_string_literal: true

# 更新を依頼する作品の ID を出力する（NAROU_EXCLUDE_SITES のサイトを外すため）。
# 小説フォルダは読むだけで書き込まない。
#
# 使い方: narou-update-targets.rb [--novel-dir DIR] [--exclude-sites LIST] [--include-frozen]
#   DIR               narou の小説フォルダ（.narou があるフォルダ）。既定は /novel
#   --exclude-sites   カンマ区切りのサイト名（database.yaml の sitename。例: ハーメルン）。これらの作品は出力しない
#   --include-frozen  凍結中の作品も出力する（指定しなければ出力しない。narou update と同じ）
#
# 出力: 1 行 1 件、ID の昇順
# 終了コード: 0 = 出力どおり（0 件のこともある）。2 = 小説フォルダではない。3 = 管理ファイルが読めない（あとでやり直す）

require "optparse"
require_relative "narou_novel_db"

novel_dir = "/novel"
exclude_sites = []
include_frozen = false
OptionParser.new do |opt|
  opt.on("--novel-dir DIR") { |v| novel_dir = v }
  opt.on("--exclude-sites LIST") { |v| exclude_sites = NarouNovelDb.parse_sites(v) }
  opt.on("--include-frozen") { include_frozen = true }
end.parse!(ARGV)

novels, frozen = NarouNovelDb.load!(novel_dir, "update-targets")

ids = novels.reject { |d| exclude_sites.include?(d["sitename"]) }
            .reject { |d| !include_frozen && NarouNovelDb.frozen?(frozen, d["id"]) }
            .map { |d| d["id"].to_i }
puts ids.sort
