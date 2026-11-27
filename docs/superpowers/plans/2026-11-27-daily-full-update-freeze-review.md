# 毎日の全件更新と凍結の見直し Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** scheduler が 1 日 1 回、凍結済みも含めて全件更新し、その後サイトの最終投稿日で凍結を付け外しする。

**Architecture:** 判定は `bin/narou-freeze-review.rb`（小説フォルダを読むだけ）に分け、`bin/narou-scheduler.sh` が WEB UI の API（`/api/update` force=true、`/api/get_queue_size`、`/api/freeze_on`・`/api/freeze_off`）を順に呼ぶ。CLI は動かさない（WEB UI と管理ファイルを取り合うため）。

**Tech Stack:** bash + curl、Ruby（narou gem 同梱のイメージ）、minitest。

**Spec:** チャットで合意した内容（2026-11-27）。要点は下の Global Constraints。

## Global Constraints

- 「更新があった」= database.yaml の `general_lastup`（サイト上の最終投稿日）。
- `general_lastup` が `NAROU_FREEZE_AFTER_DAYS`（既定 30）日以内 → 凍結中なら解除。より前 → 未凍結なら凍結。完結フラグは見ない。
- `general_lastup` が無い作品は触らない。
- 全件更新の時刻は `NAROU_FULL_UPDATE_TIME`（既定 `03:30`）。空なら無効。
- 全件更新の前後でキューが空になるまで待つ。全件更新中に来た毎時の更新は飛ばし、ログに出す。
- 手動実行: `narou-scheduler.sh --daily-now`。
- 小説フォルダは scheduler に読み取り専用でマウントする。

## Review Focus

- database.yaml が保存途中で読めない → 判定を出さず終了コード 3、scheduler は少し待って数回やり直す。
- キューがいつまでも空にならない → 待ち時間の上限（既定 6 時間）で見直しを諦めてログに出す。
- 対象 0 件 → API を呼ばない。
- `general_lastup` がちょうど境界（30 日前）→ 「より前」でないので凍結しない（テストで固定）。
- WEB UI が落ちている（curl 失敗）→ ログを出して次の予定に進む（scheduler は落ちない）。

---

### Task 1: 凍結の判定スクリプト

**Files:**
- Create: `bin/narou-freeze-review.rb`
- Test: `test/narou_freeze_review_test.rb`（`test_helper.rb` の `make_novel_dir` に `general_lastup:` を足す）

**Interfaces:**
- Produces: `narou-freeze-review.rb [--novel-dir DIR] [--days N] [--now EPOCH]`
  - 標準出力: 1 行 1 件、タブ区切り `<on|off>\t<id>\t<general_lastup の YYYY-MM-DD>\t<title>`（on = 凍結する、off = 解除する）。id 昇順。
  - 終了コード: 0 = 出力どおり、2 = 小説フォルダではない、3 = 管理ファイルが読めない（あとでやり直す）。

- [ ] テスト: 30 日以内で凍結中 → off、31 日前で未凍結 → on、ちょうど 30 日前 → 出力なし、general_lastup 無し → 出力なし、凍結中で古い・未凍結で新しい → 出力なし、`--days 7` が効く、壊れた database.yaml → 終了コード 3、`.narou` 無し → 2、小説フォルダに書き込まない。
- [ ] 失敗を確認 → 実装 → 通ることを確認（README の docker run コマンド）。
- [ ] Commit。

### Task 2: scheduler に毎日の処理を足す

**Files:**
- Modify: `bin/narou-scheduler.sh`、`docker-compose.yml`（scheduler に `NOVEL_DIR:/novel:ro`、`NAROU_FULL_UPDATE_TIME`、`NAROU_FREEZE_AFTER_DAYS`）、`.env.example`、`docs/self-hosting.md`（自動更新の節）

- [ ] `wait_queue_empty`（`/api/get_queue_size` の両方が 0 になるまで 30 秒ごと、上限 `NAROU_QUEUE_WAIT_MAX`=21600 秒）、`daily_job`（待つ → force 更新 → 待つ → 判定 → freeze_on / freeze_off をまとめて POST）、`--daily-now`。
- [ ] メインループ: 次の予定が毎時か毎日かを選び、毎日の処理の最中に過ぎた毎時の予定は飛ばしてログに出す。
- [ ] `bash -n` と、イメージで `--daily-now` を実行して確認。
- [ ] Commit、PR。
