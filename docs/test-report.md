# 動作確認の記録

2026-10-04、Mac（Apple Silicon）の Docker Desktop で `linux/amd64` イメージをビルドして確認しました。
同日、サーバー（`ssh ubuntu`、x86_64 Ubuntu 24.04、Docker Compose v5.5.1）でも `docker compose build` し、一時フォルダ（Mac の設定ファイルだけを複製した小説フォルダ）で下記「サーバーでの確認」を行いました。

## イメージ

| 項目 | 結果 |
| --- | --- |
| `docker build`（本番の `Dockerfile`、GitHub の `chikiny/narou_rb` `release` から `specific_install`） | 成功 |
| `narou version` | 3.9.4 |
| `boko --version` | boko 0.5.1（chikiny/boko `4f646eea`） |
| Java | OpenJDK 21.0.12.1 |
| Ruby / openssl gem のリンク先 | Ruby 3.4.11 / OpenSSL 3.6.5 |
| AozoraEpub3 | 1.1.1b26Q、`narou init` によるカスタム注記・`vertical_font.css` の埋め込みあり |
| 実行ユーザー | uid 1000 / gid 1000 |

## ハーメルン（Cloudflare）

| 項目 | 結果 |
| --- | --- |
| TLS 指紋（`tls.peet.ws`） | JA3 `83702d7e8b362fbe2cf0059c4e12521a`、JA4 `t13d3012_1d37bd780c83_89ab6efea773`。Mac の Ruby と一致 |
| 参考: Debian 同梱 OpenSSL の Ruby で本文ページ 10 回取得 | 200 が 1〜2 回、残りは 403 |
| 参考: OpenSSL 3.6.5 にリンクした Ruby で本文ページ 10 回取得 | 10 回とも 200 |
| `narou download https://syosetu.org/novel/405165/` | 全 10 話を取得し、EPUB に変換して `/convert_output` にコピー。作者名も取得できた |

## 自動処理

| 項目 | 結果 |
| --- | --- |
| 起動時の設定書き換え（Mac の `global_setting.yaml` / `local_setting.yaml` を複製して確認） | `aozoraepub3dir` と `convert.copy-to` だけが書き換わり、他の値は元のまま |
| kfx-watcher | narou が置いた EPUB を検知して KFX を作成し、EPUB を `04_epub/` に移動 |
| KFX の中身 | 同じ EPUB から Mac の boko で作った KFX と SHA-1 が一致 |
| scheduler（`narou-scheduler.sh --now`） | `POST /api/update` が HTTP 200。データベースの `last_check_date` が依頼の 2 秒後に更新された |

## WEB UI

| 項目 | 結果 |
| --- | --- |
| `GET /`（33000） | 200 |
| WebSocket（33001、パス `/` と `/ws/`、`Origin` 付き） | 101 Switching Protocols |
| 配信される `narou.library.js` | ポート指定なしのとき `wss://<ホスト>/ws/` に接続するコードになっている |
| WebSocket 接続中のエラーログ | 出ない（Linux で EPUB 端末のときの取り外し可否チェックのエラーを Fork 側で修正済み） |

## サーバーでの確認

| 項目 | 結果 |
| --- | --- |
| `docker compose build` | 成功（openssl gem は OpenSSL 3.6.5、Narou.rb は GitHub の release から 3.9.4） |
| TLS 指紋 | JA3 `83702d7e8b362fbe2cf0059c4e12521a`（Mac と一致） |
| 起動時の設定書き換え | `aozoraepub3dir` と `convert.copy-to` だけ |
| `GET /` / WebSocket `/ws/` | 200 / 101 |
| ハーメルン `novel/405165` の取得（自宅回線の IP から） | 全 10 話取得、EPUB 化、`/convert_output` へコピー |
| kfx-watcher | KFX を作成し EPUB を `04_epub/` へ移動。ファイルの所有者は `chikiny` |
| scheduler `--now` | HTTP 200、`last_check_date` が 2 秒後に更新 |
| narou コンテナのエラーログ | 0 件 |

## 気づいたこと

- `docker compose exec -T narou narou ...` のように標準入力が端末でないと、narou は標準入力から対象を読もうとして止まります。スクリプトから呼ぶときは `</dev/null` を付けてください。

## 未確認

- 実際の小説フォルダ（約 10 GB）での動作
- Cloudflare Tunnel の接続、`/ws` の振り分け、Access のログイン
