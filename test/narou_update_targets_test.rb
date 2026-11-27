# frozen_string_literal: true

# bin/narou-update-targets.rb のテスト。実行方法は test_helper.rb の冒頭を参照。

require_relative "test_helper"

class NarouUpdateTargetsTest < Minitest::Test
  include EpubSorterTestHelper

  TARGETS = File.join(EpubSorterTestHelper::BIN_DIR, "narou-update-targets.rb")

  NOVELS = [
    { id: 0, author: "A", title: "なろう" },
    { id: 1, author: "B", title: "なろう・凍結中", frozen: true },
    { id: 2, author: "C", title: "ハーメルン", sitename: "ハーメルン" },
    { id: 3, author: "D", title: "ハーメルン・凍結中", sitename: "ハーメルン", frozen: true },
    { id: 10, author: "E", title: "カクヨム", sitename: "カクヨム" },
  ].freeze

  def setup
    @tmp = Dir.mktmpdir("narou-update-targets")
    @novel = make_novel_dir(File.join(@tmp, "novel"), NOVELS)
  end

  def teardown
    make_writable(@tmp)
    FileUtils.rm_rf(@tmp)
  end

  def run_targets(*args)
    Open3.capture3("ruby", TARGETS, "--novel-dir", @novel, *args)
  end

  def test_excludes_sites_and_frozen
    out, err, status = run_targets("--exclude-sites", "ハーメルン")
    assert_equal 0, status.exitstatus, err
    assert_equal %w[0 10], out.split
  end

  def test_include_frozen
    out, err, status = run_targets("--exclude-sites", "ハーメルン", "--include-frozen")
    assert_equal 0, status.exitstatus, err
    assert_equal %w[0 1 10], out.split
  end

  def test_multiple_sites
    out, _err, status = run_targets("--exclude-sites", "ハーメルン,カクヨム", "--include-frozen")
    assert_equal 0, status.exitstatus
    assert_equal %w[0 1], out.split
  end

  def test_nothing_left
    out, _err, status = run_targets("--exclude-sites", "小説家になろう,ハーメルン,カクヨム")
    assert_equal 0, status.exitstatus
    assert_equal "", out
  end

  def test_broken_database_exits_retry
    File.write(File.join(@novel, ".narou", "database.yaml"), "--- {\n  0: [")
    out, _err, status = run_targets("--exclude-sites", "ハーメルン")
    assert_equal 3, status.exitstatus
    assert_equal "", out
  end

  def test_not_narou_dir
    FileUtils.mkdir_p(File.join(@tmp, "empty"))
    _out, _err, status = Open3.capture3("ruby", TARGETS, "--novel-dir", File.join(@tmp, "empty"))
    assert_equal 2, status.exitstatus
  end
end
