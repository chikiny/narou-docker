# narou-docker

[Narou.rb](https://github.com/whiteleaf7/narou) を自宅サーバーの Docker で常駐させ、Cloudflare Tunnel で外出先から WEB UI を開けるようにするための構成です。個人用途向けで、Narou.rb は Fork（[chikiny/narou_rb](https://github.com/chikiny/narou_rb) の `release` ブランチ）を `specific_install` で入れます。

自宅サーバーへの導入手順（初回・運用・再構築）は [docs/self-hosting.md](docs/self-hosting.md) にあります。

## 構成

```
┌──────────────── docker compose ────────────────┐
│ narou        WEB UI :33000 / WebSocket :33001  │── NOVEL_DIR（小説フォルダ）
│              変換した EPUB を /convert_output へ │
│ epub-sorter  /convert_output を監視し           │── CONVERT_OUTPUT_DIR
│              EPUB を作品の状態で振り分け         │     ├─ 04_epub/（連載中）
│ scheduler    毎日 NAROU_UPDATE_TIMES に          │     └─ 05_epub_end/（完結・凍結）
│              WEB UI へ「すべて更新」を依頼        │
│ cloudflared  Cloudflare Tunnel（tunnel プロファイル）│
└────────────────────────────────────────────────┘
```

| サービス | 内容 |
| --- | --- |
| `narou` | `narou web`。起動時に小説フォルダの設定（AozoraEpub3 の場所、`convert.copy-to`）をコンテナ内のパスに合わせる |
| `epub-sorter` | `convert_output` 直下に置かれた EPUB を、連載中かつ未凍結なら `04_epub/`、完結または凍結なら `05_epub_end/` へ移す（下記） |
| `scheduler` | `POST /api/update` で WEB UI のキューに更新を積む（CLI の `narou update` を並行して動かさない） |
| `cloudflared` | `docker compose --profile tunnel up -d` のときだけ起動 |

## イメージの中身

- Ruby 3.4（Debian trixie）
- OpenSSL 3.6.5 をソースビルドし、Ruby の openssl gem をこれにリンク（後述）
- Narou.rb: `gem specific_install -l https://github.com/chikiny/narou_rb -b release`
- [AozoraEpub3](https://github.com/kyukyunyorituryo/AozoraEpub3) 1.1.1b26Q + OpenJDK 21
- [boko](https://github.com/chikiny/boko)（Fork、縦書き KFX 対応のコミットを固定。いまは自動変換には使っていない）

ビルド時の主な引数（`Dockerfile` の `ARG`）:

| 引数 | 既定値 |
| --- | --- |
| `NAROU_REPO` / `NAROU_BRANCH` | `https://github.com/chikiny/narou_rb` / `release` |
| `BOKO_REPO` / `BOKO_REF` | `https://github.com/chikiny/boko.git` / 縦書き KFX 対応のコミット |
| `AOZORAEPUB3_VERSION` | `1.1.1b26Q` |
| `OPENSSL_VERSION` | `3.6.5` |

## EPUB の振り分け（epub-sorter）

narou が変換した EPUB は `convert.copy-to` で `convert_output` 直下にコピーされます。`epub-sorter` はそこを inotify で見張り、書き込みが `EPUB_SETTLE_SECONDS`（既定 15 秒）止まったら 1 冊ずつ振り分けます。取りこぼしに備えて `EPUB_RESCAN_SECONDS`（既定 600 秒）ごとに見直します。

- 作品の特定: 小説フォルダの管理ファイル（`.narou/database.yaml`）の各作品について、narou と同じ方法（`Narou.create_novel_filename`）でファイル名を求め、EPUB の名前と照合します。分割された `書名_2.epub` なども本体と同じ作品として扱います。
- 行き先: 連載中で凍結していない作品は `04_epub/`、完結した作品か凍結した作品は `05_epub_end/`。行き先にある同じ名前の EPUB は上書きし、反対側のフォルダに同じ名前の EPUB があれば消します（完結や凍結で状態が変わると、古いほうは消えます）。
- 作品が特定できない EPUB（一致する作品がない、または 2 つ以上ある）は直下に残し、ログに出します。ファイルが更新されるまで再試行しません。
- EPUB 以外のファイルや、直下のサブフォルダには触りません。
- 小説フォルダは読み取り専用でマウントし、判定（`bin/epub-sorter-classify.rb`）も読むだけです。

テストはイメージの中で動かします（narou gem を使うため）。

```sh
docker build -t narou-docker:test .
docker run --rm --entrypoint ruby -v "$PWD":/src:ro narou-docker:test \
  -e 'Dir.glob("/src/test/*_test.rb").sort.each { |f| require f }'
```

## ハーメルンが Docker から 403 になる件

ハーメルン（syosetu.org）は Cloudflare の配下にあり、本文ページへのアクセスは TLS の ClientHello の特徴（JA3/JA4 指紋）でボット判定されます。同じ IP・同じヘッダでも、Debian 同梱の OpenSSL 3.5 にリンクされた Ruby は `compress_certificate` 拡張や `ec_point_formats` の違いで判定に引っかかり、本文ページの多くが 403 になります。

そこでイメージ内で OpenSSL 3.6.5 をビルドし、Ruby の openssl gem をそれにリンクしています。これで Mac（Homebrew の OpenSSL 3.6.5）の Ruby と同じ指紋になります。ビルド時に `OpenSSL::OPENSSL_LIBRARY_VERSION` が 3.6 系であることを確認し、違えばビルドを失敗させます。

指紋は次のように確認できます（Mac 側と `ja3` が一致すれば OK）。

```sh
docker compose run --rm --no-deps -e NAROU_SKIP_INIT=1 narou \
  ruby -rnet/http -rjson -e 'puts JSON.parse(Net::HTTP.get(URI("https://tls.peet.ws/api/all")))["tls"]["ja3_hash"]'
```

## よく使うコマンド

```sh
docker compose up -d --build                  # LAN 内だけで起動
docker compose --profile tunnel up -d --build # Cloudflare Tunnel も起動
docker compose logs -f narou epub-sorter      # ログ
docker compose exec narou narou list          # narou の CLI（端末から実行。スクリプトから呼ぶときは -T と </dev/null を付ける）
docker compose exec epub-sorter epub-sorter.sh --once                         # 直下の EPUB をいま振り分ける
docker compose exec scheduler narou-scheduler.sh --now                        # 今すぐ更新を依頼
```
