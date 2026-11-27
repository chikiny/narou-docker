#!/usr/bin/env ruby
# frozen_string_literal: true

# サイト上の最終投稿日（database.yaml の general_lastup）を見て、凍結を付け外しすべき作品を出力する。
# 付け外しは narou-scheduler.sh が WEB UI の API で行う。ここでは小説フォルダを読むだけで書き込まない。
#
# 使い方: narou-freeze-review.rb [--novel-dir DIR] [--days N] [--now EPOCH]
#   DIR  narou の小説フォルダ（.narou があるフォルダ）。既定は /novel
#   N    この日数より前に最終投稿があった作品を凍結する。既定は 30
#   EPOCH 基準にする現在時刻（テスト用）
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
require "time"
require "yaml"

EXIT_NOT_NAROU_DIR = 2
EXIT_RETRY = 3

novel_dir = "/novel"
days = 30
now = Time.now
OptionParser.new do |opt|
  opt.on("--novel-dir DIR") { |v| novel_dir = v }
  opt.on("--days N", Integer) { |v| days = v }
  opt.on("--now EPOCH", Integer) { |v| now = Time.at(v) }
end.parse!(ARGV)

novel_dir = File.expand_path(novel_dir)
narou_dir = File.join(novel_dir, ".narou")
unless File.directory?(narou_dir)
  warn "[freeze-review] #{narou_dir} がありません（narou の小説フォルダを指定してください）"
  exit EXIT_NOT_NAROU_DIR
end

def load_yaml(path)
  YAML.unsafe_load(File.read(path))
end

def to_time(value)
  case value
  when Time then value
  when Date then value.to_time
  when String then Time.parse(value)
  when Integer then Time.at(value)
  end
rescue ArgumentError
  nil
end

begin
  database = load_yaml(File.join(narou_dir, "database.yaml"))
  freeze_path = File.join(narou_dir, "freeze.yaml")
  frozen = File.exist?(freeze_path) ? (load_yaml(freeze_path) || {}) : {}
  raise "database.yaml の形が違います" unless database.is_a?(Hash)
  raise "freeze.yaml の形が違います" unless frozen.is_a?(Hash)
rescue StandardError, Psych::Exception => e
  warn "[freeze-review] 管理ファイルを読めませんでした: #{e.message}（あとでやり直します）"
  exit EXIT_RETRY
end

threshold = now - days * 86_400
rows = []
database.each_value do |data|
  next unless data.is_a?(Hash)
  lastup = to_time(data["general_lastup"]) or next
  id = data["id"]
  is_frozen = frozen.key?(id) && frozen[id]
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
