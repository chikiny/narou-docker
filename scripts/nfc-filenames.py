#!/usr/bin/env python3
"""Mac から持ってきたフォルダのファイル名を Unicode NFC に揃える。

macOS で作られたファイル名には濁点などが分解された NFD 形式のものが混ざる
（例: 「小説データ」）。macOS は正規化の違いを無視して開けるが、Linux はバイト列で
比較するため、narou の管理データ（NFC）からファイルを見つけられなくなる。

使い方:
  python3 scripts/nfc-filenames.py DIR            # 変更内容を表示するだけ
  python3 scripts/nfc-filenames.py --apply DIR    # 実際に名前を変える

NFC 名と NFD 名のファイルが同じフォルダに両方ある場合は、上書きせずに中止する。
"""
import os
import sys
import unicodedata


def plan(root):
    renames = []
    # 子から先に処理するので、親の改名で子のパスが変わらない
    for dirpath, dirnames, filenames in os.walk(root, topdown=False):
        names = set(dirnames) | set(filenames)
        for name in dirnames + filenames:
            nfc = unicodedata.normalize("NFC", name)
            if nfc == name:
                continue
            if nfc in names:
                sys.exit(f"中止: NFC 名が既に存在します: {os.path.join(dirpath, nfc)}")
            renames.append((os.path.join(dirpath, name), os.path.join(dirpath, nfc)))
    return renames


def main():
    args = sys.argv[1:]
    apply = "--apply" in args
    args = [a for a in args if a != "--apply"]
    if len(args) != 1 or not os.path.isdir(args[0]):
        sys.exit(__doc__)
    renames = plan(args[0])
    for src, dst in renames:
        if apply:
            os.rename(src, dst)
        else:
            print(f"{src!r} -> {os.path.basename(dst)}")
    print(f"{'改名しました' if apply else '改名対象'}: {len(renames)} 件", file=sys.stderr)


if __name__ == "__main__":
    main()
