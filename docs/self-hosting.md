# 自宅サーバーへの導入手順書（Cloudflare Tunnel）

自宅の Ubuntu サーバー（`ssh ubuntu`）で Narou.rb を動かし、Cloudflare で取得したドメインから WEB UI を開けるようにする手順です。

- [1. 初回手順](#1-初回手順): はじめて導入するときに上から順に行います。
- [2. ふだんの運用](#2-ふだんの運用): 更新・ログ・KFX の受け取り。
- [3. 再構築手順](#3-再構築手順): サーバーの入れ直しや買い替えで、環境を立ち上げ直すときに行います。

ドメインは `y2privateserver.link`、このアプリの公開 URL は `https://novelmanager.y2privateserver.link/` とします（サブドメインは好みで変えてかまいません）。

## 0. 全体像

```
ブラウザ ──HTTPS──> Cloudflare ──(トンネル)──> 自宅サーバー
                                                ├─ cloudflared コンテナ
                                                ├─ narou コンテナ（WEB UI :33000 / WebSocket :33001）
                                                ├─ kfx-watcher コンテナ（EPUB → KFX）
                                                └─ scheduler コンテナ（毎日の自動更新）

~/narou_rb/
├── narou-docker/     このリポジトリ（.env もここ）
├── novel/            小説フォルダ（Mac の /Users/chikiny/convert_mobi/narou/novel を移したもの）
└── convert_output/   変換した EPUB の置き場 → KFX に変換、EPUB は 04_epub/ へ
```

- 事実: Cloudflare Tunnel は、サーバー側の `cloudflared` が Cloudflare へ外向きに接続する仕組みなので、ルーターのポート開放や固定 IP は要りません（[Cloudflare Tunnel](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/)）。
- 事実: `cloudflared` は `docker-compose.yml` の `cloudflared` サービスとして動かし、`tunnel` プロファイルを付けたときだけ起動します。
- 事実: Narou.rb の WEB UI は画面（33000）とは別に、進捗表示用の WebSocket（33001）を使います。トンネル経由（https・ポート指定なし）で開いたときは、Fork 版の Narou.rb が `wss://<ホスト>/ws/` に接続するので、トンネル側で `/ws` を 33001 に振り分けます（[1-7](#1-7-ドメインをアプリにつなぐpublished-application)）。
- 事実: 小説データはホストの `~/narou_rb/novel` に直接置かれます（Docker ボリュームではありません）。サーバーの `/home/chikiny` は既存の Samba で共有されているので、Mac から `~/narou_rb/convert_output` の KFX を取り出せます。

## 1. 初回手順

### 1-1. 前提の確認

サーバーには Docker と Docker Compose が入っている前提です（`solt_calculation` の [1-2](https://github.com/chikiny/solt_calculation/blob/master/docs/self-hosting.md) で導入済み）。

```sh
ssh ubuntu
docker compose version
id    # uid=1000(chikiny) gid=1000(chikiny) であることを確認（違えば .env の PUID / PGID を合わせる）
```

### 1-2. リポジトリを取ってくる

```sh
ssh ubuntu
mkdir -p ~/narou_rb/novel ~/narou_rb/convert_output
git clone https://github.com/chikiny/narou-docker.git ~/narou_rb/narou-docker
cd ~/narou_rb/narou-docker
cp .env.example .env
chmod 600 .env
nano .env    # NOVEL_DIR / CONVERT_OUTPUT_DIR を確認（既定は ~/narou_rb/novel と ~/narou_rb/convert_output）
```

### 1-3. Mac から小説フォルダを移す

二重に更新しないよう、Mac 側の narou（WEB UI や定期実行）を止めてから行います。

```sh
# Mac で実行
# Mac で、このリポジトリを clone した場所から実行する（転送先は空であること）
python3 scripts/migrate-novel.py /Users/chikiny/convert_mobi/narou/novel ubuntu narou_rb/novel
```

- 事実: `migrate-novel.py` は、rsync での転送 → サーバーでファイル名を NFC に揃える（`scripts/nfc-filenames.py`）→ 名前が長すぎて rsync が作れなかったファイルを NFC 名で個別に転送 → 両側のファイル一覧の照合、を順に行います。最後に `不足 0 / 余分 0` と出れば完了です。

- 事実: Mac で作られたファイル名には、濁点などが分解された NFD 形式のものが混ざっています（2026-10-05 時点で約 13.6 万件中 約 3.5 万件。「小説データ」フォルダ自体も NFD）。macOS は正規化の違いを無視して開けますが、Linux はバイト列で比べるので、narou の管理データ（NFC）からフォルダを見つけられず、別のフォルダを作ってしまいます。転送後に必ず NFC に揃えてください。
- 事実: NFD は濁点 1 文字ぶん長くなるため、長い作品名では Linux（ext4）のファイル名の上限 255 バイトを超え、rsync では作れないものがあります（2026-10-05 時点で 5 件）。NFC にすると収まります。
- 事実: 揃えた後の転送先に rsync し直すと NFD 名のファイルが別に作られてしまうので、やり直すときは転送先を空にしてから `migrate-novel.py` を実行してください。

- 事実: 小説フォルダは約 10 GB あります（2026-10-04 時点）。
- 事実: `narou` コンテナは起動時に、小説フォルダの設定のうち環境に依存する値だけを書き換えます。
  - `.narousetting/global_setting.yaml`: `aozoraepub3dir` → `/aozoraepub3`（`server-port: 33000`、`server-bind: 0.0.0.0` も保証）
  - `.narou/local_setting.yaml`: `convert.copy-to` → `/convert_output`
  
  書き換えたときはログに `[init] ...` と出ます。Mac 側の元フォルダは変更されません。
- 推測: 小説フォルダの `webnovel/syosetu.org.yaml`（ハーメルンの作者名の上書き）は、Fork 版 3.9.4 に同じ内容を取り込んだので不要です。残しておいても同じ値で上書きされるだけなので害はありません。

### 1-4. LAN 内で動かして確認する

```sh
ssh ubuntu
cd ~/narou_rb/narou-docker
docker compose up -d --build     # 初回は OpenSSL・boko・gem のビルドで時間がかかります
docker compose ps
docker compose logs narou --tail 30
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:33000/   # 200 なら OK
```

Mac のブラウザから確認したいときは、`.env` の `NAROU_BIND_ADDR` をサーバーの LAN IP（例: `192.168.0.36`）にして `docker compose up -d` し直し、`http://192.168.0.36:33000/` を開きます。

### 1-5. WEB UI にパスワードを設定する

トンネルで公開する前に、WEB UI の **環境設定 > 詳細設定 > サーバ** で Digest 認証（`server-digest-auth.*`）を設定します。

- 事実: 設定したら `.env` の `NAROU_WEB_USER` / `NAROU_WEB_PASSWORD` にも同じものを入れ、`docker compose up -d` で `scheduler` に反映させてください（自動更新の依頼に使います）。
- 事実: Narou.rb の Digest 認証がかかるのは画面（33000）だけで、WebSocket（33001）にはかかりません。外部公開するときは [1-8](#1-8推奨自分だけが開けるようにするcloudflare-access) の Cloudflare Access でホスト全体を守ってください。

### 1-6. トンネルを作り、トークンを控える

出典: [Create a tunnel (dashboard)](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/get-started/create-remote-tunnel/)

1. Cloudflare ダッシュボードで **Networking** > **Tunnels** を開き、**Create a tunnel** を押す。
2. トンネル名（例: `home-narou`）を入れて **Create Tunnel**。
3. 接続方法で **Docker** を選び、表示されたコマンドの `--token` の後ろ（`eyJ` で始まる文字列）だけをコピーする。**表示されたコマンドは実行しない**。
4. サーバーの `~/narou_rb/narou-docker/.env` の `TUNNEL_TOKEN=` に貼り付けて保存する。
5. 起動する。

   ```sh
   cd ~/narou_rb/narou-docker
   docker compose --profile tunnel up -d
   docker compose --profile tunnel logs cloudflared --tail 20   # "Registered tunnel connection" が出れば接続済み
   ```

- 事実: リポジトリは公開されているので、`.env` は絶対にコミットしないでください（`.gitignore` で除外済み）。
- 推測: `solt_calculation` とは別のトンネルにしておくと、片方を止めたりトークンを作り直したりしても、もう片方に影響しません。

### 1-7. ドメインをアプリにつなぐ（Published application）

**Networking** > **Tunnels** で作ったトンネルを選び、**Routes** タブの **Add route** > **Published application** で次の 2 つを追加します。**`/ws` の行が上**（先に評価される）になるようにしてください。

| 順 | Subdomain | Domain | Path | Service URL |
| --- | --- | --- | --- | --- |
| 1 | `novelmanager` | `y2privateserver.link` | `^/ws` | `http://narou:33001` |
| 2 | `novelmanager` | `y2privateserver.link` | （空欄） | `http://narou:33000` |

- 事実: Service URL は `cloudflared` コンテナから見た場所なので、サービス名 `narou` で指定します。
- 事実: Cloudflare Tunnel は WebSocket をそのまま中継します。
- 未確認: ダッシュボードでのルートの並び順の変え方。並び順が逆だと `/ws` も 33000 に行き、WEB UI のコンソール（進捗表示）が動きません。

### 1-8.（推奨）自分だけが開けるようにする（Cloudflare Access）

出典: [Self-hosted public application](https://developers.cloudflare.com/cloudflare-one/access-controls/applications/http-apps/self-hosted-public-app/)

`solt_calculation` の [1-7](https://github.com/chikiny/solt_calculation/blob/master/docs/self-hosting.md) と同じ手順で、`novelmanager.y2privateserver.link` に Access のアプリケーションを作り、Include の **Emails** に自分のメールアドレスだけを入れます。One-time PIN の設定は済んでいるので追加不要です。

### 1-9. 外から確認する

1. 外出先（またはモバイル回線）のブラウザで `https://novelmanager.y2privateserver.link/` を開く。
2. 小説の一覧が出て、画面下のコンソールに「更新」などの進捗が流れることを確認する（WebSocket が通っている確認）。

## 2. ふだんの運用

### KFX を受け取る

- `kfx-watcher` は `~/narou_rb/convert_output` 直下の EPUB を見張り、書き込みが 15 秒（`KFX_SETTLE_SECONDS`）止まったら `boko convert -O` で KFX を作り、EPUB を `04_epub/` へ移します。
- Mac からは Samba 共有の `narou_rb/convert_output` に KFX が見えます。Kindle への転送は従来どおり Mac の `kindle-kfx-transfer.zsh` で行います。
- 変換に失敗した EPUB は `convert_output` に残り、ファイルが更新されるまで再試行しません。原因は `docker compose logs kfx-watcher` で確認し、手で再実行するときは次のようにします。

  ```sh
  docker compose exec kfx-watcher convert_epub_kfx.zsh /convert_output/書名.epub
  ```

### 自動更新

- `scheduler` が毎日 `NAROU_UPDATE_TIMES`（既定 `05:00`）に WEB UI へ「すべて更新」を依頼します。進捗は WEB UI のコンソールに出ます。
- 今すぐ依頼する: `docker compose exec scheduler narou-scheduler.sh --now`

### アプリを新しい版に更新する

```sh
ssh ubuntu
cd ~/narou_rb/narou-docker
git pull
docker compose --profile tunnel build --no-cache narou   # Fork の release ブランチを取り直す
docker compose --profile tunnel up -d
```

- 事実: `--no-cache` を付けないと、Docker のキャッシュにより Fork の新しいコミットが入りません。

### 状態とログを見る

```sh
docker compose --profile tunnel ps
docker compose --profile tunnel logs --tail 50
docker compose exec narou narou list     # narou の CLI も使えます
```

## 3. 再構築手順

Cloudflare 側（ドメイン・トンネル・公開ルート・Access）は残っているので、作り直すのはサーバー側だけです。

1. 古いサーバーが動くなら、小説フォルダをサーバーの外へ退避する（例: Mac で `rsync -a ubuntu:narou_rb/novel/ ./novel-backup/`）。
2. 新しいサーバーに Docker を入れる。
3. [1-2](#1-2-リポジトリを取ってくる) を行い、`.env` に `TUNNEL_TOKEN` を入れる（トークンは Tunnels の **Overview** > **Add a replica** で再表示できる）。
4. 退避した小説フォルダを `~/narou_rb/novel` に戻す。
5. `docker compose --profile tunnel up -d --build`。
6. [1-9](#1-9-外から確認する) で確認する。古いサーバーの `cloudflared` は止めてから手放す。

## 確認済みのこと・未確認のこと

- 確認済み（Mac の Docker Desktop、linux/amd64 イメージで実施）: [test-report.md](test-report.md) を参照。
- 未確認: 実際の Cloudflare アカウントでのトンネル接続、公開ルート（`/ws` の振り分け）、Access のログイン。
