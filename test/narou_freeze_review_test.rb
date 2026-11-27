# frozen_string_literal: true

# bin/narou-freeze-review.rb のテスト。実行方法は test_helper.rb の冒頭を参照。

require_relative "test_helper"

class NarouFreezeReviewTest < Minitest::Test
  include EpubSorterTestHelper

  REVIEW = File.join(EpubSorterTestHelper::BIN_DIR, "narou-freeze-review.rb")
  NOW = Time.new(2026, 11, 27, 4, 0, 0, "+09:00")
  DAY = 86_400

  def setup
    @tmp = Dir.mktmpdir("narou-freeze-review")
  end

  def teardown
    make_writable(@tmp)
    FileUtils.rm_rf(@tmp)
  end

  def novel_dir(novels)
    make_novel_dir(File.join(@tmp, "novel"), novels)
  end

  def run_review(dir, *args)
    Open3.capture3({ "TZ" => "Asia/Tokyo" }, "ruby", REVIEW, "--novel-dir", dir, "--now", NOW.to_i.to_s, *args)
  end

  def lines(out)
    out.lines.map { |l| l.chomp.split("\t") }
  end

  def test_unfreezes_recent_and_freezes_stale
    dir = novel_dir([
      { id: 0, author: "A", title: "最近更新・凍結中", frozen: true, general_lastup: NOW - 3 * DAY },
      { id: 1, author: "B", title: "古い・未凍結", general_lastup: NOW - 31 * DAY },
      { id: 2, author: "C", title: "最近更新・未凍結", general_lastup: NOW - 1 * DAY },
      { id: 3, author: "D", title: "古い・凍結中", frozen: true, general_lastup: NOW - 100 * DAY },
      { id: 4, author: "E", title: "完結・最近更新・凍結中", end: true, frozen: true, general_lastup: NOW - 2 * DAY },
    ])
    out, err, status = run_review(dir)
    assert_equal 0, status.exitstatus, err
    assert_equal [
      ["off", "0", "2026-11-24", "最近更新・凍結中"],
      ["on", "1", "2026-10-27", "古い・未凍結"],
      ["off", "4", "2026-11-25", "完結・最近更新・凍結中"],
    ], lines(out)
  end

  def test_exactly_on_boundary_is_not_frozen
    dir = novel_dir([{ id: 0, author: "A", title: "ちょうど30日前", general_lastup: NOW - 30 * DAY }])
    out, err, status = run_review(dir)
    assert_equal 0, status.exitstatus, err
    assert_equal "", out
  end

  def test_without_general_lastup_is_untouched
    dir = novel_dir([
      { id: 0, author: "A", title: "日付なし・未凍結" },
      { id: 1, author: "B", title: "日付なし・凍結中", frozen: true },
    ])
    out, err, status = run_review(dir)
    assert_equal 0, status.exitstatus, err
    assert_equal "", out
  end

  def test_days_option
    dir = novel_dir([{ id: 0, author: "A", title: "8日前", general_lastup: NOW - 8 * DAY }])
    out, _err, status = run_review(dir, "--days", "7")
    assert_equal 0, status.exitstatus
    assert_equal [["on", "0", "2026-11-19", "8日前"]], lines(out)
  end

  def test_broken_database_exits_retry
    dir = novel_dir([{ id: 0, author: "A", title: "x", general_lastup: NOW }])
    File.write(File.join(dir, ".narou", "database.yaml"), "--- {\n  0: [")
    out, _err, status = run_review(dir)
    assert_equal 3, status.exitstatus
    assert_equal "", out
  end

  def test_not_narou_dir
    FileUtils.mkdir_p(File.join(@tmp, "empty"))
    _out, _err, status = run_review(File.join(@tmp, "empty"))
    assert_equal 2, status.exitstatus
  end

  def test_does_not_write_novel_dir
    dir = novel_dir([{ id: 0, author: "A", title: "古い", general_lastup: NOW - 40 * DAY }])
    before = snapshot(dir)
    make_read_only(dir)
    _out, err, status = run_review(dir)
    assert_equal 0, status.exitstatus, err
    make_writable(dir)
    assert_equal before, snapshot(dir)
  end

  # 毎日の処理で更新を確認できなかった作品（403 などで失敗した作品）は、最終投稿日が古いままかもしれないので触らない
  def test_checked_since_skips_novels_not_checked
    dir = novel_dir([
      { id: 0, author: "A", title: "確認済み・古い", general_lastup: NOW - 40 * DAY, last_check_date: NOW - 600 },
      { id: 1, author: "B", title: "未確認・古い", general_lastup: NOW - 40 * DAY, last_check_date: NOW - 2 * DAY },
      { id: 2, author: "C", title: "未確認・日付なし", general_lastup: NOW - 40 * DAY },
      { id: 3, author: "D", title: "確認済み・新しい・凍結中", frozen: true, general_lastup: NOW - DAY, last_check_date: NOW - 60 },
    ])
    out, err, status = run_review(dir, "--checked-since", (NOW - 3600).to_i.to_s)
    assert_equal 0, status.exitstatus, err
    assert_equal [
      ["on", "0", "2026-10-18", "確認済み・古い"],
      ["off", "3", "2026-11-26", "確認済み・新しい・凍結中"],
    ], lines(out)
  end

  def test_exclude_sites_are_untouched
    dir = novel_dir([
      { id: 0, author: "A", title: "ハーメルン・古い", sitename: "ハーメルン", general_lastup: NOW - 40 * DAY },
      { id: 1, author: "B", title: "ハーメルン・新しい・凍結中", sitename: "ハーメルン", frozen: true, general_lastup: NOW - DAY },
      { id: 2, author: "C", title: "なろう・古い", general_lastup: NOW - 40 * DAY },
    ])
    out, err, status = run_review(dir, "--exclude-sites", "ハーメルン,カクヨム")
    assert_equal 0, status.exitstatus, err
    assert_equal [["on", "2", "2026-10-18", "なろう・古い"]], lines(out)
  end
end
