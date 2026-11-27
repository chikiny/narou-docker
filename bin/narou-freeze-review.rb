#!/usr/bin/env ruby
# frozen_string_literal: true

# サイト上の最終投稿日（database.yaml の general_lastup）を見て、凍結を付け外しすべき作品を出力する。
# 付け外しは narou-scheduler.sh が WEB UI の API で行う。ここでは小説フォルダを読むだけで書き込まない。
#
# 使い方: narou-freeze-review.rb [--novel-dir DIR] [--days N] [--checked-since EPOCH] [--exclude-sites LIST] [--now EPOCH]
#   DIR  narou の小説フォルダ（.narou があるフォルダ）。既定は /novel
#   N    この日数より前に最終投稿があった作品を凍結する。既定は 30
#   --checked-since  last_check_date（narou が更新を確認できた時刻）がこれより前の作品は出力しない。
#                    更新に失敗した作品は最終投稿日が古いままかもしれないため
#   --exclude-sites  カンマ区切りのサイト名（database.yaml の sitename。例: ハーメルン）。これらの作品は出力しない
#   --now            基準にする現在時刻（テスト用）
#
# 判定（完結かどうかは見ない）:
#   - general_lastup が N 日以内で凍結中 → off（凍結を解除する）
#   - general_lastup が N 日より前で凍結されていない → on（凍結する）
#   - general_lastup が無い作品は出力しない
#
# 出力: 1 行 1 件、ID の昇順、タブ区切り
#   <on|off>\t<ID>\t<general_lastup の YYYY-MM-DD>\t<題名>
#
# 終了コード: 0 = 出力どおり。2 = 小説フォルダではない。3 = 管理ファイルが読めない（何も出力しない。あとでやり直す）

require "optparse"
require_relative "narou_novel_db"

novel_dir = "/novel"
days = 30
now = Time.now
checked_since = nil
exclude_sites = []
OptionParser.new do |opt|
  opt.on("--novel-dir DIR") { |v| novel_dir = v }
  opt.on("--days N", Integer) { |v| days = v }
  opt.on("--checked-since EPOCH", Integer) { |v| checked_since = Time.at(v) }
  opt.on("--exclude-sites LIST") { |v| exclude_sites = NarouNovelDb.parse_sites(v) }
  opt.on("--now EPOCH", Integer) { |v| now = Time.at(v) }
end.parse!(ARGV)

novels, frozen = NarouNovelDb.load!(novel_dir, "freeze-review")

threshold = now - days * 86_400
rows = []
novels.each do |data|
  next if exclude_sites.include?(data["sitename"])
  lastup = NarouNovelDb.to_time(data["general_lastup"]) or next
  if checked_since
    checked = NarouNovelDb.to_time(data["last_check_date"])
    next if checked.nil? || checked < checked_since
  end
  id = data["id"]
  is_frozen = NarouNovelDb.frozen?(frozen, id)
  action =
    if lastup < threshold
      "on" unless is_frozen
    elsif is_frozen
      "off"
    end
  next unless action
  rows << [id.to_i, action, lastup.localtime.strftime("%F"), data["title"].to_s.tr("\t\n", "  ")]
end

rows.sort_by(&:first).each do |id, action, date, title|
  puts [action, id, date, title].join("\t")
end
