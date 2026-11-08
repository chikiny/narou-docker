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

  # 終了コードを確かめずに実行する
  def run_classify(*names, novel_dir: @novel, env: {})
    paths = names.map { |name| touch_epub(@out, name) }
    stdout, stderr, status = Open3.capture3(env, "ruby", CLASSIFY, "--novel-dir", novel_dir, *paths)
    [paths, stdout, stderr, status]
  end

  # 1 行を [path, dest, reason, base] に分ける
  def classify_rows(*names, **kw)
    paths, stdout, stderr, status = run_classify(*names, **kw)
    assert status.success?, "exit=#{status.exitstatus}\n#{stderr}"
    rows = stdout.b.lines.map { |line| line.chomp.split("\t".b, -1).map { |c| c.force_encoding(Encoding::UTF_8) } }
    assert rows.all? { |r| r.size == 4 }, "4 列で出力する\n#{stdout}"
    assert_equal paths.map(&:b), rows.map { |r| r.first.b }, "入力の順に 1 行ずつ出力する\n#{stdout}"
    rows
  end

  def classify(*names, **kw)
    classify_rows(*names, **kw).to_h { |path, dest, reason, _base| [File.basename(path), [dest, reason]] }
  end

  def assert_retry_without_output(paths_stdout_stderr_status)
    _paths, stdout, stderr, status = paths_stdout_stderr_status
    assert_equal 3, status.exitstatus, "全体をやり直す終了コード\n#{stderr}"
    assert_equal "", stdout, "途中の結果を出力しない"
    stderr
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

  def test_missing_novel_folder_fails_whole_batch_without_writing
    # 保存フォルダが無い作品があると、narou は database から消して保存しようとする。保存させず、全体をやり直す
    novel = make_novel_dir(File.join(@tmp, "novel2"), [
      { id: 0, author: "作者A", title: "連載中の作品" },
      { id: 1, author: "作者X", title: "フォルダが無い作品", folder: false },
    ])
    before = snapshot(novel)
    stderr = assert_retry_without_output(run_classify("[作者A] 連載中の作品.epub", novel_dir: novel))
    assert_match(/作品 ID 1.*ファイル名を求められません/, stderr)
    assert_equal before, snapshot(novel)
    # 読み取り専用でも同じ
    make_read_only(novel)
    assert_retry_without_output(run_classify("[作者A] 連載中の作品.epub", novel_dir: novel))
    make_writable(novel)
    assert_equal before, snapshot(novel)
  end

  def test_record_without_end_fails_whole_batch
    # 保存途中の database.yaml（"end" の前で切れている）を読んだ場合。連載中と誤判定しない
    path = File.join(@novel, ".narou", "database.yaml")
    db = YAML.unsafe_load_file(path)
    db[1].delete("end")
    File.write(path, YAML.dump(db))
    stderr = assert_retry_without_output(run_classify("[作者B] 完結した作品.epub", "[作者A] 連載中の作品.epub"))
    assert_match(/"end" がありません/, stderr)
  end

  def test_truncated_database_fails_whole_batch_and_is_not_restored
    path = File.join(@novel, ".narou", "database.yaml")
    full = File.read(path)
    File.write("#{path}.backup", full)
    File.write(path, full[0, full.index("作者B")] + "\"broken: [")
    before = snapshot(@novel)
    assert_retry_without_output(run_classify("[作者A] 連載中の作品.epub"))
    assert_equal before, snapshot(@novel), "narou の .backup からの書き戻しをさせない"
  end

  def test_freeze_not_a_hash_fails_whole_batch
    File.write(File.join(@novel, ".narou", "freeze.yaml"), "--- [2]\n")
    stderr = assert_retry_without_output(run_classify("[作者C] 凍結した作品.epub"))
    assert_match(/freeze\.yaml/, stderr)
  end

  def test_settings_changed_during_run_fails_whole_batch
    %w[database.yaml freeze.yaml local_setting.yaml].each do |name|
      path = touch_epub(@out, "[作者A] 連載中の作品.epub")
      env = { "EPUB_SORTER_TEST_DELAY" => "3" }
      Open3.popen3(env, "ruby", CLASSIFY, "--novel-dir", @novel, path) do |stdin, stdout, stderr, wait|
        stdin.close
        sleep 1.5
        File.write(File.join(@novel, ".narou", name), "\n# narou が保存中\n", mode: "a")
        status = wait.value
        assert_equal 3, status.exitstatus, "#{name}: #{stderr.read}"
        assert_equal "", stdout.read, name
      end
    end
  end

  def test_per_file_exception_is_error_not_unknown
    # 不正な UTF-8 のファイル名は照合中に例外になる。その冊だけ error（やり直し可）にし、ほかは判定する
    bad = "壊れた\xFF名前.epub".b
    rows = classify_rows(bad, "[作者A] 連載中の作品.epub")
    assert_equal "error", rows[0][1]
    assert_match(/判定に失敗しました/, rows[0][2])
    assert_equal "04_epub", rows[1][1]
  end

  def test_outputs_matched_narou_name
    rows = classify_rows("[作者A] 連載中の作品_2.epub", "[作者B] 完結した作品.EPUB", "[誰か] 知らない作品.epub")
    assert_equal ["[作者A] 連載中の作品", "[作者B] 完結した作品", ""], rows.map(&:last)
  end

  def test_split_suffix_starts_at_2
    assert_equal "unknown", dest_of("[作者A] 連載中の作品_1.epub")
    assert_equal "unknown", dest_of("[作者A] 連載中の作品_0.epub")
    assert_equal "unknown", dest_of("[作者A] 連載中の作品_02.epub")
    assert_equal "04_epub", dest_of("[作者A] 連載中の作品_10.epub")
  end

  def test_fails_when_novel_dir_is_not_narou_root
    path = touch_epub(@out, "[作者A] 連載中の作品.epub")
    _stdout, stderr, status = Open3.capture3("ruby", CLASSIFY, "--novel-dir", @out, path)
    refute status.success?
    assert_match(/\.narou/, stderr)
  end
end
