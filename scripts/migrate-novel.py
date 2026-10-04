#!/usr/bin/env python3
"""Mac の小説フォルダをサーバーへ移す（Mac で実行する）。

  python3 scripts/migrate-novel.py SRC_DIR HOST DEST_DIR

例:
  python3 scripts/migrate-novel.py /Users/chikiny/convert_mobi/narou/novel ubuntu narou/novel

手順:
  1. rsync -a で転送する
  2. サーバーでファイル名を NFC に揃える（scripts/nfc-filenames.py）
  3. NFD のままだと 255 バイトを超えて rsync が作れなかった名前を、NFC 名で個別に転送する
  4. Mac 側を NFC にした一覧と、サーバー側の一覧（正規化せずそのまま）が一致することを確かめる

DEST_DIR は空であること（NFC に揃えた後の転送先に rsync し直すと NFD 名が重複して作られるため）。
"""
import os
import shlex
import subprocess
import sys
import unicodedata

NAME_MAX = 255


def nfc(s):
    return unicodedata.normalize("NFC", s)


def ssh(host, command, **kwargs):
    return subprocess.run(["ssh", host, command], check=True, **kwargs)


def list_local(root):
    paths = set()
    for dirpath, dirnames, filenames in os.walk(root):
        for name in dirnames + filenames:
            paths.add(nfc(os.path.relpath(os.path.join(dirpath, name), root)))
    return paths


LIST_REMOTE = r"""
import os, sys
root = os.path.expanduser(sys.argv[1])
for dirpath, dirnames, filenames in os.walk(root):
    for name in dirnames + filenames:
        print(os.path.relpath(os.path.join(dirpath, name), root))
"""


def list_remote(host, dest):
    out = ssh(host, f"python3 -c {shlex.quote(LIST_REMOTE)} {shlex.quote(dest)}",
              capture_output=True, text=True).stdout
    return set(out.splitlines())


def main():
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    src, host, dest = sys.argv[1].rstrip("/"), sys.argv[2], sys.argv[3].rstrip("/")
    script_dir = os.path.dirname(os.path.abspath(__file__))

    remote_entries = ssh(host, f"mkdir -p {shlex.quote(dest)} && ls -A {shlex.quote(dest)} | wc -l",
                         capture_output=True, text=True).stdout.strip()
    if remote_entries != "0":
        sys.exit(f"中止: {host}:{dest} が空ではありません")

    print("[1/4] rsync で転送します", flush=True)
    r = subprocess.run(["rsync", "-a", f"{src}/", f"{host}:{dest}/"],
                       stderr=subprocess.DEVNULL)
    # 23 = 一部のファイルを転送できなかった（長すぎる名前）。3 で拾うので続行する
    if r.returncode not in (0, 23):
        sys.exit(f"rsync が失敗しました（終了コード {r.returncode}）")

    print("[2/4] ファイル名を NFC に揃えます", flush=True)
    with open(os.path.join(script_dir, "nfc-filenames.py"), "rb") as f:
        ssh(host, f"python3 - --apply {shlex.quote(dest)}", stdin=f)

    print("[3/4] 名前が長すぎて転送できなかったものを NFC 名で転送します", flush=True)
    for dirpath, dirnames, filenames in os.walk(src):
        rel_dir = os.path.relpath(dirpath, src)
        too_long_dir = any(len(part.encode()) > NAME_MAX for part in rel_dir.split(os.sep))
        for name in dirnames + filenames:
            path = os.path.join(dirpath, name)
            if not (too_long_dir or len(name.encode()) > NAME_MAX):
                continue
            target = f"{dest}/{nfc(os.path.relpath(path, src))}"
            if name in dirnames:
                ssh(host, f"mkdir -p {shlex.quote(target)}")
                continue
            mtime = int(os.path.getmtime(path))
            with open(path, "rb") as f:
                ssh(host, f"mkdir -p {shlex.quote(os.path.dirname(target))} && "
                          f"cat > {shlex.quote(target)} && touch -d @{mtime} {shlex.quote(target)}",
                    stdin=f)
            print(f"  {nfc(name)}", flush=True)

    print("[4/4] ファイル一覧を比べます", flush=True)
    local, remote = list_local(src), list_remote(host, dest)
    missing, extra = sorted(local - remote), sorted(remote - local)
    for p in missing[:20]:
        print(f"  サーバーに無い: {p}")
    for p in extra[:20]:
        print(f"  サーバーにだけある: {p}")
    print(f"Mac: {len(local)} 件 / サーバー: {len(remote)} 件 / 不足 {len(missing)} / 余分 {len(extra)}")
    sys.exit(1 if missing or extra else 0)


if __name__ == "__main__":
    main()
