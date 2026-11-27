# frozen_string_literal: true

# narou-freeze-review.rb / narou-update-targets.rb が共通で使う、小説フォルダの管理ファイルの読み込み。
# 小説フォルダは読むだけで書き込まない。

require "date"
require "time"
require "yaml"

module NarouNovelDb
  EXIT_NOT_NAROU_DIR = 2
  EXIT_RETRY = 3

  module_function

  # [database, frozen] を返す。小説フォルダでなければ 2、管理ファイルが読めなければ 3 で終了する
  # （narou は作品ごとに database.yaml を保存し直すので、途中まで書かれたものを読むことがある）
  def load!(novel_dir, tag)
    narou_dir = File.join(File.expand_path(novel_dir), ".narou")
    unless File.directory?(narou_dir)
      warn "[#{tag}] #{narou_dir} がありません（narou の小説フォルダを指定してください）"
      exit EXIT_NOT_NAROU_DIR
    end
    begin
      database = YAML.unsafe_load(File.read(File.join(narou_dir, "database.yaml")))
      freeze_path = File.join(narou_dir, "freeze.yaml")
      frozen = File.exist?(freeze_path) ? (YAML.unsafe_load(File.read(freeze_path)) || {}) : {}
      raise "database.yaml の形が違います" unless database.is_a?(Hash)
      raise "freeze.yaml の形が違います" unless frozen.is_a?(Hash)
    rescue StandardError, Psych::Exception => e
      warn "[#{tag}] 管理ファイルを読めませんでした: #{e.message}（あとでやり直します）"
      exit EXIT_RETRY
    end
    [database.values.select { |d| d.is_a?(Hash) }, frozen]
  end

  def frozen?(frozen, id)
    frozen.key?(id) && frozen[id] ? true : false
  end

  # "ハーメルン,カクヨム" → ["ハーメルン", "カクヨム"]
  def parse_sites(value)
    value.to_s.split(",").map(&:strip).reject(&:empty?)
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
end
