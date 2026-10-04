# narou-docker

[Narou.rb](https://github.com/whiteleaf7/narou) を自宅サーバーの Docker で常駐させ、Cloudflare Tunnel で外出先から WEB UI を開けるようにするための構成です。個人用途向けで、Narou.rb は Fork（[chikiny/narou_rb](https://github.com/chikiny/narou_rb) の `release` ブランチ）を `specific_install` で入れます。

自宅サーバーへの導入手順（初回・運用・再構築）は [docs/self-hosting.md](docs/self-hosting.md) にあります。

## 構成

```
┌──────────────── docker compose ────────────────┐
│ narou        WEB UI :33000 / WebSocket :33001  │── NOVEL_DIR（小説フォルダ）
│              変換した EPUB を /convert_output へ │
│ kfx-watcher  /convert_output を監視し           │── CONVERT_OUTPUT_DIR
│              boko で EPUB → KFX                 │     ├─ *.kfx（Mac から Kindle へ転送）
│ scheduler    毎日 NAROU_UPDATE_TIMES に          │     └─ 04_epub/（変換済み EPUB）
│              WEB UI へ「すべて更新」を依頼        │
│ cloudflared  Cloudflare Tunnel（tunnel プロファイル）│
└────────────────────────────────────────────────┘
```

| サービス | 内容 |
| --- | --- |
| `narou` | `narou web`。起動時に小説フォルダの設定（AozoraEpub3 の場所、`convert.copy-to`）をコンテナ内のパスに合わせる |
| `kfx-watcher` | `convert_output` 直下に EPUB が置かれると `boko convert -O` で KFX に変換し、EPUB を `04_epub/` へ移す |
| `scheduler` | `POST /api/update` で WEB UI のキューに更新を積む（CLI の `narou update` を並行して動かさない） |
| `cloudflared` | `docker compose --profile tunnel up -d` のときだけ起動 |

## イメージの中身

- Ruby 3.4（Debian trixie）
- OpenSSL 3.6.5 をソースビルドし、Ruby の openssl gem をこれにリンク（後述）
- Narou.rb: `gem specific_install -l https://github.com/chikiny/narou_rb -b release`
- [AozoraEpub3](https://github.com/kyukyunyorituryo/AozoraEpub3) 1.1.1b26Q + OpenJDK 21
- [boko](https://github.com/chikiny/boko)（Fork、縦書き KFX 対応のコミットを固定）

ビルド時の主な引数（`Dockerfile` の `ARG`）:

| 引数 | 既定値 |
| --- | --- |
| `NAROU_REPO` / `NAROU_BRANCH` | `https://github.com/chikiny/narou_rb` / `release` |
| `BOKO_REPO` / `BOKO_REF` | `https://github.com/chikiny/boko.git` / 縦書き KFX 対応のコミット |
| `AOZORAEPUB3_VERSION` | `1.1.1b26Q` |
| `OPENSSL_VERSION` | `3.6.5` |

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
docker compose logs -f narou kfx-watcher      # ログ
docker compose exec narou narou list          # narou の CLI（端末から実行。スクリプトから呼ぶときは -T と </dev/null を付ける）
docker compose exec kfx-watcher convert_epub_kfx.zsh /convert_output/*.epub   # 手動で KFX 変換
docker compose exec scheduler narou-scheduler.sh --now                        # 今すぐ更新を依頼
```
