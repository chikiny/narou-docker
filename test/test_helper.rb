# frozen_string_literal: true

# epub-sorter のテスト共通部分。
# 一時ディレクトリに narou の小説フォルダ（名前付けに読む最小限）を作る。
#
# 実行はイメージの中で（narou gem が要る）:
#   docker build -t narou-docker:test .
#   docker run --rm --entrypoint ruby -v "$PWD":/src:ro narou-docker:test \
#     -e 'Dir.glob("/src/test/*_test.rb").sort.each { |f| require f }'

require "minitest/autorun"
require "fileutils"
require "open3"
require "tmpdir"
require "yaml"

module EpubSorterTestHelper
  BIN_DIR = File.expand_path("../bin", __dir__)
  CLASSIFY = File.join(BIN_DIR, "epub-sorter-classify.rb")
  SORTER = File.join(BIN_DIR, "epub-sorter.sh")

  # novels: [{ id:, author:, title:, sitename:, end:, frozen:, toc_url:, folder: }]
  # folder: false にすると小説の保存フォルダを作らない
  def make_novel_dir(root, novels, local_setting: { "convert.filename-to-ncode" => false })
    FileUtils.mkdir_p(File.join(root, ".narou"))
    FileUtils.mkdir_p(File.join(root, ".narousetting"))
    database = {}
    freeze = {}
    novels.each do |n|
      file_title = n[:file_title] || "#{n[:ncode] || "n#{n[:id]}"} #{n[:title]}"
      database[n[:id]] = {
        "id" => n[:id],
        "author" => n[:author],
        "title" => n[:title],
        "file_title" => file_title,
        "toc_url" => n[:toc_url] || "https://ncode.syosetu.com/n#{n[:id]}aa/",
        "sitename" => n[:sitename] || "小説家になろう",
        "novel_type" => 1,
        "end" => n.fetch(:end, false),
        "last_update" => Time.at(0),
        "use_subdirectory" => false,
      }
      freeze[n[:id]] = true if n[:frozen]
      next if n[:folder] == false
      FileUtils.mkdir_p(File.join(root, "小説データ", database[n[:id]]["sitename"], file_title))
    end
    File.write(File.join(root, ".narou", "database.yaml"), YAML.dump(database))
    File.write(File.join(root, ".narou", "freeze.yaml"), YAML.dump(freeze))
    File.write(File.join(root, ".narou", "local_setting.yaml"), YAML.dump(local_setting))
    File.write(File.join(root, ".narousetting", "global_setting.yaml"), YAML.dump({}))
    root
  end

  def touch_epub(dir, name, body = "epub")
    FileUtils.mkdir_p(dir)
    path = File.join(dir, name)
    File.write(path, body)
    path
  end

  # ディレクトリ以下のファイルの一覧と更新時刻・中身（書き込まれていないことの確認用）
  def snapshot(root)
    Dir.glob("**/*", File::FNM_DOTMATCH, base: root).sort.to_h do |rel|
      path = File.join(root, rel)
      [rel, File.file?(path) ? [File.mtime(path).to_f, File.binread(path)] : :dir]
    end
  end

  def make_read_only(root)
    Dir.glob("**/*", File::FNM_DOTMATCH, base: root).each do |rel|
      File.chmod(File.directory?(File.join(root, rel)) ? 0o555 : 0o444, File.join(root, rel))
    end
    File.chmod(0o555, root)
  end

  def make_writable(root)
    File.chmod(0o755, root)
    Dir.glob("**/*", File::FNM_DOTMATCH, base: root).each do |rel|
      File.chmod(File.directory?(File.join(root, rel)) ? 0o755 : 0o644, File.join(root, rel))
    end
  end
end
