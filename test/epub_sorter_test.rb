# frozen_string_literal: true

# bin/epub-sorter.sh の 1 回分の処理（--once）のテスト。判定には本物の epub-sorter-classify.rb を使う。
# 実行方法は test_helper.rb の冒頭を参照。

require_relative "test_helper"

class EpubSorterTest < Minitest::Test
  include EpubSorterTestHelper

  NOVELS = [
    { id: 0, author: "作者A", title: "連載中の作品" },
    { id: 1, author: "作者B", title: "完結した作品", end: true },
    { id: 2, author: "作者C", title: "凍結した作品", frozen: true },
  ].freeze

  def setup
    @tmp = Dir.mktmpdir("epub-sorter")
    @novel = make_novel_dir(File.join(@tmp, "novel"), NOVELS)
    @out = File.join(@tmp, "convert_output")
    FileUtils.mkdir_p(@out)
  end

  def teardown
    make_writable(@tmp)
    FileUtils.rm_rf(@tmp)
  end

  def run_once
    env = {
      "CONVERT_OUTPUT_DIR" => @out,
      "EPUB_SORTER_NOVEL_DIR" => @novel,
    }
    stdout, stderr, status = Open3.capture3(env, "bash", SORTER, "--once")
    assert status.success?, "exit=#{status.exitstatus}\n#{stdout}\n#{stderr}"
    stdout + stderr
  end

  def files(dir = @out)
    Dir.glob("**/*", base: dir).select { |rel| File.file?(File.join(dir, rel)) }.sort
  end

  def test_moves_by_status
    touch_epub(@out, "[作者A] 連載中の作品.epub")
    touch_epub(@out, "[作者A] 連載中の作品_2.epub")
    touch_epub(@out, "[作者B] 完結した作品.epub")
    touch_epub(@out, "[作者C] 凍結した作品.epub")
    log = run_once
    assert_equal [
      "04_epub/[作者A] 連載中の作品.epub",
      "04_epub/[作者A] 連載中の作品_2.epub",
      "05_epub_end/[作者B] 完結した作品.epub",
      "05_epub_end/[作者C] 凍結した作品.epub",
    ], files
    assert_includes log, "[epub-sorter] 振り分け: [作者A] 連載中の作品.epub -> 04_epub（連載中）"
    assert_includes log, "[epub-sorter] 振り分け: [作者B] 完結した作品.epub -> 05_epub_end（完結）"
    assert_includes log, "[epub-sorter] 振り分け: [作者C] 凍結した作品.epub -> 05_epub_end（凍結）"
  end

  def test_overwrites_destination_and_removes_the_other_side
    touch_epub(File.join(@out, "04_epub"), "[作者A] 連載中の作品.epub", "old")
    # 完結した作品の古い EPUB が連載中側に残っている
    touch_epub(File.join(@out, "04_epub"), "[作者B] 完結した作品.epub", "old")
    # 連載中の作品の古い EPUB が完結側に残っている（凍結を解除した場合など）
    touch_epub(File.join(@out, "05_epub_end"), "[作者A] 連載中の作品.epub", "old")
    touch_epub(@out, "[作者A] 連載中の作品.epub", "new")
    touch_epub(@out, "[作者B] 完結した作品.epub", "new")
    run_once
    assert_equal [
      "04_epub/[作者A] 連載中の作品.epub",
      "05_epub_end/[作者B] 完結した作品.epub",
    ], files
    assert_equal "new", File.read(File.join(@out, "04_epub", "[作者A] 連載中の作品.epub"))
    assert_equal "new", File.read(File.join(@out, "05_epub_end", "[作者B] 完結した作品.epub"))
  end

  def test_unknown_stays_in_place
    touch_epub(@out, "[誰か] 知らない作品.epub")
    touch_epub(@out, "syosetu_org_427026.epub")
    log = run_once
    assert_equal ["[誰か] 知らない作品.epub", "syosetu_org_427026.epub"], files
    assert_match(/\[epub-sorter\] 振り分けできません.*\[誰か\] 知らない作品\.epub/, log)
  end

  def test_leaves_other_files_and_subfolders_alone
    touch_epub(@out, "[作者A] 連載中の作品.kfx", "kfx")
    touch_epub(File.join(@out, "06_webnobel"), "[作者A] 連載中の作品.epub", "sub")
    touch_epub(@out, "[作者B] 完結した作品.epub")
    run_once
    assert_equal [
      "05_epub_end/[作者B] 完結した作品.epub",
      "06_webnobel/[作者A] 連載中の作品.epub",
      "[作者A] 連載中の作品.kfx",
    ], files
  end

  def test_removes_all_parts_from_the_other_side
    # 連載中に戻った作品（凍結の解除など）。完結側の本体と分割ファイルを全部消す
    old_side = File.join(@out, "05_epub_end")
    %w[.epub _2.epub _3.epub].each { |s| touch_epub(old_side, "[作者A] 連載中の作品#{s}", "old") }
    # 別の名前（narou の分割ファイルの名前ではない）は消さない
    touch_epub(old_side, "[作者A] 連載中の作品_1.epub", "keep")
    touch_epub(old_side, "[作者A] 連載中の作品 外伝.epub", "keep")
    touch_epub(@out, "[作者A] 連載中の作品.epub", "new")
    log = run_once
    assert_equal [
      "04_epub/[作者A] 連載中の作品.epub",
      "05_epub_end/[作者A] 連載中の作品 外伝.epub",
      "05_epub_end/[作者A] 連載中の作品_1.epub",
    ], files
    assert_includes log, "古い EPUB を消しました: 05_epub_end/[作者A] 連載中の作品_3.epub"
  end

  def test_removes_other_side_when_a_split_part_moves
    touch_epub(File.join(@out, "04_epub"), "[作者B] 完結した作品.epub", "old")
    touch_epub(File.join(@out, "04_epub"), "[作者B] 完結した作品_2.epub", "old")
    touch_epub(@out, "[作者B] 完結した作品_2.epub", "new")
    run_once
    assert_equal ["05_epub_end/[作者B] 完結した作品_2.epub"], files
  end

  def test_skips_names_with_control_characters
    touch_epub(@out, "改行\nのある名前.epub")
    touch_epub(@out, "タブ\tのある名前.epub")
    touch_epub(@out, "[作者A] 連載中の作品.epub")
    log = run_once
    assert_equal [
      "04_epub/[作者A] 連載中の作品.epub",
      "タブ\tのある名前.epub",
      "改行\nのある名前.epub",
    ], files
    assert_equal 2, log.scan("ファイル名に制御文字が含まれるため振り分けません").size, log
  end

  # 監視ループで、判定スクリプトを何回呼ぶかを数える（偽の判定スクリプトを使う）
  def count_classify_calls(status)
    stub = File.join(@tmp, "stub-classify.rb")
    counter = File.join(@tmp, "calls")
    File.write(stub, <<~RUBY)
      File.write(#{counter.inspect}, "x", mode: "a")
      paths = ARGV.drop_while { |a| a != "--novel-dir" }.drop(2)
      paths.each { |p| puts [p, #{status.inspect}, "テスト", ""].join("\t") }
    RUBY
    touch_epub(@out, "どれでもない.epub")
    env = {
      "CONVERT_OUTPUT_DIR" => @out, "EPUB_SORTER_NOVEL_DIR" => @novel, "EPUB_SORTER_CLASSIFY" => stub,
      "EPUB_SETTLE_SECONDS" => "1", "EPUB_RESCAN_SECONDS" => "1",
    }
    log = +""
    Open3.popen2e(env, "bash", SORTER, pgroup: true) do |_in, out, wait|
      sleep 4.5
      Process.kill("TERM", -wait.pid)
      log << out.read
    end
    assert File.exist?(File.join(@out, "どれでもない.epub")), "直下に残る"
    [File.exist?(counter) ? File.read(counter).size : 0, log]
  end

  def test_unknown_is_not_retried_in_the_loop
    calls, log = count_classify_calls("unknown")
    assert_equal 1, calls, log
  end

  def test_error_is_retried_in_the_loop
    calls, log = count_classify_calls("error")
    assert_operator calls, :>=, 2, log
    assert_match(/判定できませんでした（次の回にやり直します）: どれでもない\.epub/, log)
  end

  def test_does_nothing_without_epubs
    log = run_once
    assert_equal [], files
    refute_match(/振り分け/, log)
  end

  def test_novel_dir_read_only
    before = snapshot(@novel)
    make_read_only(@novel)
    touch_epub(@out, "[作者A] 連載中の作品.epub")
    run_once
    assert_equal ["04_epub/[作者A] 連載中の作品.epub"], files
    make_writable(@novel)
    assert_equal before, snapshot(@novel)
  end
end
