# frozen_string_literal: true

# bin/epub-sorter-classify.rb のテスト。実行方法は test_helper.rb の冒頭を参照。

require_relative "test_helper"

class EpubSorterClassifyTest < Minitest::Test
  include EpubSorterTestHelper

  NOVELS = [
    { id: 0, author: "作者A", title: "連載中の作品" },
    { id: 1, author: "作者B", title: "完結した作品", end: true },
    { id: 2, author: "作者C", title: "凍結した作品", frozen: true },
    { id: 3, author: "作者D", title: "完結して凍結した作品", end: true, frozen: true },
    # 同じ作者・題名の作品が 2 つ（別サイト）
    { id: 4, author: "作者E", title: "同名の作品" },
    { id: 5, author: "作者E", title: "同名の作品", sitename: "カクヨム",
      toc_url: "https://kakuyomu.jp/works/1/" },
    # ハーメルン（filename-to-ncode: false なら ID 形式の名前にはならない）
    { id: 6, author: "作者F", title: "ハーメルンの作品", sitename: "ハーメルン",
      toc_url: "https://syosetu.org/novel/427026/", ncode: "427026" },
    # 題名が「_数字」で終わる作品と、それを外した題名の作品
    { id: 7, author: "作者G", title: "続き物", end: true },
    { id: 8, author: "作者G", title: "続き物_2" },
    # 特殊文字を含む題名（narou がファイル名用に置き換える）
    { id: 9, author: "作者H", title: "題名/記号:あり?", end: true },
  ].freeze

  def setup
    @tmp = Dir.mktmpdir("epub-sorter-classify")
    @novel = make_novel_dir(File.join(@tmp, "novel"), NOVELS)
    @out = File.join(@tmp, "convert_output")
  end

  def teardown
    make_writable(@tmp)
    FileUtils.rm_rf(@tmp)
  end

  def classify(*names, novel_dir: @novel)
    paths = names.map { |name| touch_epub(@out, name) }
    stdout, stderr, status = Open3.capture3("ruby", CLASSIFY, "--novel-dir", novel_dir, *paths)
    assert status.success?, "exit=#{status.exitstatus}\n#{stderr}"
    rows = stdout.lines.map { |line| line.chomp.split("\t", 3) }
    assert_equal paths, rows.map(&:first), "入力の順に 1 行ずつ出力する\n#{stdout}"
    rows.to_h { |path, dest, reason| [File.basename(path), [dest, reason]] }
  end

  def dest_of(name, **kw)
    classify(name, **kw).fetch(name).first
  end

  def test_ongoing_goes_to_04_epub
    assert_equal ["04_epub", "連載中"], classify("[作者A] 連載中の作品.epub")["[作者A] 連載中の作品.epub"]
  end

  def test_completed_goes_to_05_epub_end
    assert_equal ["05_epub_end", "完結"], classify("[作者B] 完結した作品.epub")["[作者B] 完結した作品.epub"]
  end

  def test_frozen_goes_to_05_epub_end
    assert_equal ["05_epub_end", "凍結"], classify("[作者C] 凍結した作品.epub")["[作者C] 凍結した作品.epub"]
  end

  def test_completed_and_frozen_goes_to_05_epub_end
    assert_equal "05_epub_end", dest_of("[作者D] 完結して凍結した作品.epub")
  end

  def test_split_files_follow_the_main_file
    result = classify("[作者A] 連載中の作品_2.epub", "[作者B] 完結した作品_3.epub")
    assert_equal "04_epub", result["[作者A] 連載中の作品_2.epub"].first
    assert_equal "05_epub_end", result["[作者B] 完結した作品_3.epub"].first
  end

  def test_exact_name_wins_over_split_suffix
    # 「続き物_2」という作品がある（連載中）。「続き物」（完結）の分割ファイルとは見なさない
    assert_equal "04_epub", dest_of("[作者G] 続き物_2.epub")
    # 「続き物_3」という作品はないので「続き物」の分割ファイル
    assert_equal "05_epub_end", dest_of("[作者G] 続き物_3.epub")
  end

  def test_uppercase_extension
    assert_equal "04_epub", dest_of("[作者A] 連載中の作品.EPUB")
  end

  def test_special_characters_are_named_like_narou
    assert_equal "05_epub_end", dest_of("[作者H] 題名／記号：あり？.epub")
  end

  def test_no_match_is_unknown
    dest, reason = classify("[誰か] 知らない作品.epub")["[誰か] 知らない作品.epub"]
    assert_equal "unknown", dest
    assert_match(/一致する作品がありません/, reason)
  end

  def test_two_matches_is_unknown
    dest, reason = classify("[作者E] 同名の作品.epub")["[作者E] 同名の作品.epub"]
    assert_equal "unknown", dest
    assert_match(/2 件/, reason)
  end

  def test_id_style_name_does_not_match_without_filename_to_ncode
    assert_equal "unknown", dest_of("syosetu_org_427026.epub")
    assert_equal "04_epub", dest_of("[作者F] ハーメルンの作品.epub")
  end

  def test_mixed_input_keeps_order
    result = classify("[誰か] 知らない作品.epub", "[作者A] 連載中の作品.epub", "[作者B] 完結した作品.epub")
    assert_equal %w[unknown 04_epub 05_epub_end], result.values.map(&:first)
  end

  def test_does_not_write_to_novel_dir
    before = snapshot(@novel)
    make_read_only(@novel)
    result = classify("[作者A] 連載中の作品.epub", "[作者C] 凍結した作品.epub", "[誰か] 知らない作品.epub")
    assert_equal %w[04_epub 05_epub_end unknown], result.values.map(&:first)
    make_writable(@novel)
    assert_equal before, snapshot(@novel)
  end

  def test_missing_novel_folder_is_skipped_without_writing_database
    # 保存フォルダが無い作品があると、narou は database から消して保存しようとする。読むだけなので保存させない
    novel = make_novel_dir(File.join(@tmp, "novel2"), [
      { id: 0, author: "作者A", title: "連載中の作品" },
      { id: 1, author: "作者X", title: "フォルダが無い作品", folder: false },
    ])
    before = snapshot(novel)
    make_read_only(novel)
    result = classify("[作者A] 連載中の作品.epub", "[作者X] フォルダが無い作品.epub", novel_dir: novel)
    assert_equal %w[04_epub unknown], result.values.map(&:first)
    make_writable(novel)
    assert_equal before, snapshot(novel)
  end

  def test_missing_novel_folder_does_not_save_database_even_if_writable
    # 書き込めるフォルダでも保存しない（ro マウントに頼らない）
    novel = make_novel_dir(File.join(@tmp, "novel3"), [
      { id: 0, author: "作者A", title: "連載中の作品" },
      { id: 1, author: "作者X", title: "フォルダが無い作品", folder: false },
    ])
    before = snapshot(novel)
    result = classify("[作者A] 連載中の作品.epub", novel_dir: novel)
    assert_equal %w[04_epub], result.values.map(&:first)
    assert_equal before, snapshot(novel)
  end

  def test_fails_when_novel_dir_is_not_narou_root
    path = touch_epub(@out, "[作者A] 連載中の作品.epub")
    _stdout, stderr, status = Open3.capture3("ruby", CLASSIFY, "--novel-dir", @out, path)
    refute status.success?
    assert_match(/\.narou/, stderr)
  end
end
