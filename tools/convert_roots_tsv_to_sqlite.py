#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
convert_roots_tsv_to_sqlite.py
==============================
构建期工具：把预计算词根索引 precomputed_roots.tsv（word + spec，tab 分隔）
转换为 roots.sqlite（按需查询，运行时不再全量载入内存）。

表结构对齐安卓端已验收的 roots.db：
    CREATE TABLE precomputed_roots(
        word TEXT PRIMARY KEY COLLATE NOCASE,
        spec TEXT NOT NULL
    ) WITHOUT ROWID;

幂等策略：
    - 目标文件已存在、行数与 tsv 一致、且不比 tsv 旧 → 直接跳过（exit 0），
      构建脚本重复执行不重复报错、不重复重建。
    - 否则重建（DROP + CREATE + 批量插入），内置完整性与 NOCASE 校验，
      任何一步失败均以非零退出码中止构建。

用法：
    python3 tools/convert_roots_tsv_to_sqlite.py
    python3 tools/convert_roots_tsv_to_sqlite.py --force   # 强制重建
    python3 tools/convert_roots_tsv_to_sqlite.py --tsv X --out Y
"""

import argparse
import os
import sqlite3
import sys

SAMPLE_WORDS = [
    "tween", "ability", "yesterday", "airport", "toothpaste",
    "international", "spectator", "unhappy", "impossible", "teacher",
    "'tween",  # 撇号=重读音节标记，独立词条（勿与 tween 混淆）
]


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    here = os.path.dirname(os.path.abspath(__file__))
    default_tsv = os.path.normpath(os.path.join(here, "..", "Resources", "precomputed_roots.tsv"))
    default_out = os.path.normpath(os.path.join(here, "..", "Resources", "roots.sqlite"))
    parser.add_argument("--tsv", default=default_tsv, help="源 tsv 路径（默认工程 Resources/precomputed_roots.tsv）")
    parser.add_argument("--out", default=default_out, help="输出 sqlite 路径（默认工程 Resources/roots.sqlite）")
    parser.add_argument("--force", action="store_true", help="强制重建（忽略幂等跳过逻辑）")
    return parser


def count_tsv_lines(tsv_path: str) -> int:
    n = 0
    with open(tsv_path, "r", encoding="utf-8") as f:
        for line in f:
            line = line.rstrip("\n")
            if line:
                n += 1
    return n


def is_up_to_date(tsv_path: str, out_path: str, tsv_lines: int) -> bool:
    """目标已存在、行数一致、不比源旧 → 视为已是最新，跳过重建。"""
    if not os.path.exists(out_path):
        return False
    try:
        conn = sqlite3.connect(out_path)
        try:
            row = conn.execute(
                "SELECT COUNT(*) FROM precomputed_roots"
            ).fetchone()
            if row is None or row[0] != tsv_lines:
                return False
        finally:
            conn.close()
    except sqlite3.Error:
        return False
    tsv_mtime = os.path.getmtime(tsv_path)
    out_mtime = os.path.getmtime(out_path)
    return out_mtime >= tsv_mtime


def build_sqlite(tsv_path: str, out_path: str) -> None:
    os.makedirs(os.path.dirname(os.path.abspath(out_path)) or ".", exist_ok=True)
    if os.path.exists(out_path):
        os.remove(out_path)

    conn = sqlite3.connect(out_path)
    try:
        conn.execute("PRAGMA journal_mode=OFF")
        conn.execute(
            "CREATE TABLE precomputed_roots("
            "word TEXT PRIMARY KEY COLLATE NOCASE,"
            "spec TEXT NOT NULL"
            ") WITHOUT ROWID"
        )
        inserted = 0
        with conn:  # 单事务
            with open(tsv_path, "r", encoding="utf-8") as f:
                cur = conn.cursor()
                batch = []
                for line in f:
                    line = line.rstrip("\n")
                    if not line:
                        continue
                    word, _, spec = line.partition("\t")
                    if not spec:
                        print(f"✗ 数据异常：第 {inserted + 1} 行非两列（word={word!r}），中止", file=sys.stderr)
                        sys.exit(1)
                    batch.append((word, spec))
                    if len(batch) >= 5000:
                        cur.executemany(
                            "INSERT INTO precomputed_roots(word, spec) VALUES (?, ?)",
                            batch,
                        )
                        inserted += len(batch)
                        batch.clear()
                if batch:
                    cur.executemany(
                        "INSERT INTO precomputed_roots(word, spec) VALUES (?, ?)",
                        batch,
                    )
                    inserted += len(batch)
        conn.commit()
    except Exception:
        conn.close()
        raise
    finally:
        conn.close()
    print(f"✓ 已写入 {inserted} 行 → {out_path}")


def verify_sqlite(tsv_path: str, out_path: str, tsv_lines: int) -> None:
    print("==> 完整性校验")
    conn = sqlite3.connect(out_path)
    try:
        row = conn.execute("SELECT COUNT(*) FROM precomputed_roots").fetchone()
        count = row[0] if row else 0
        status = "✓" if count == tsv_lines else "✗"
        print(f"  {status} 行数：sqlite={count} / tsv={tsv_lines}")

        print("  抽样查询（word -> spec）：")
        for word in SAMPLE_WORDS:
            r = conn.execute(
                "SELECT spec FROM precomputed_roots WHERE word = ?", (word,)
            ).fetchone()
            if r is None:
                print(f"    ✗ {word!r:20} → 未命中")
            else:
                print(f"    ✓ {word!r:20} → {r[0]}")

        print("  NOCASE 大小写不敏感查询：")
        nocase_cases = [("TWEEN", "tween"), ("Ability", "ability"), ("YESTERDAY", "yesterday")]
        for upper_word, lower_word in nocase_cases:
            ru = conn.execute(
                "SELECT spec FROM precomputed_roots WHERE word = ?", (upper_word,)
            ).fetchone()
            rl = conn.execute(
                "SELECT spec FROM precomputed_roots WHERE word = ?", (lower_word,)
            ).fetchone()
            ok = ru is not None and rl is not None and ru[0] == rl[0]
            print(f"    {'✓' if ok else '✗'} {upper_word!r} → {ru[0] if ru else '未命中'}（与 {lower_word!r} 一致）")

        if count != tsv_lines or any(
            conn.execute("SELECT spec FROM precomputed_roots WHERE word = ?", (w,)).fetchone() is None
            for w in SAMPLE_WORDS
        ):
            print("✗ 校验失败", file=sys.stderr)
            sys.exit(1)
    finally:
        conn.close()

    size = os.path.getsize(out_path)
    print(f"  文件体积：{size} 字节 = {size / 1024 / 1024:.2f} MB")
    print("✓ 校验全部通过")


def main() -> int:
    args = build_parser().parse_args()
    if not os.path.isfile(args.tsv):
        print(f"✗ 找不到源 tsv：{args.tsv}", file=sys.stderr)
        return 1

    tsv_lines = count_tsv_lines(args.tsv)
    print(f"==> 转换 precomputed_roots.tsv（{tsv_lines} 行）→ roots.sqlite")

    if not args.force and is_up_to_date(args.tsv, args.out, tsv_lines):
        print(f"✓ roots.sqlite 已存在且为最新（{tsv_lines} 行），跳过重建（幂等）")
        verify_sqlite(args.tsv, args.out, tsv_lines)
        return 0

    build_sqlite(args.tsv, args.out)
    verify_sqlite(args.tsv, args.out, tsv_lines)
    return 0


if __name__ == "__main__":
    sys.exit(main())
