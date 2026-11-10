#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
离线预解析脚本：复刻 RootParser.swift 的 S2-S7 词根拆解逻辑，
对 ecdict_light.tsv（约 77 万词条）预解析，生成 Resources/precomputed_roots.tsv。

产物格式：每行 `word<TAB>spec`
  - word：小写归一后的单词（与 RootParser.parse 内部 normalize 一致）
  - spec：`|` 连接的片段文本（un-|happy），可直接喂给 RootParser.parseExplicit 重建
  - 只保留成功拆解出 >=2 片段（即 RootParser.parse 非"未收录"）的词条，控制体积
"""

import argparse
import json
import sys
import time


def load_root_library(path):
    with open(path, 'r', encoding='utf-8') as f:
        data = json.load(f)
    entries = []
    for item in data:
        entries.append({
            'id': item.get('id', ''),
            'type': item.get('type', ''),
            'form': item.get('form', ''),
            'normalized': item.get('normalized', ''),
            'meaning': item.get('meaning', ''),
        })
    return entries


def build_indexes(entries):
    prefix_index = {}
    suffix_index = {}
    root_index = {}
    for e in entries:
        if e['type'] == 'prefix':
            prefix_index.setdefault(e['normalized'], e)
        elif e['type'] == 'suffix':
            suffix_index.setdefault(e['normalized'], e)
        elif e['type'] == 'root':
            root_index.setdefault(e['normalized'], e)
    # 子串匹配用：仅 root，长度 >=4，按长度降序（最长优先）
    root_list_by_length = sorted(
        [e for e in entries if e['type'] == 'root' and len(e['normalized']) >= 4],
        key=lambda e: len(e['normalized']), reverse=True)
    return prefix_index, suffix_index, root_index, root_list_by_length


ASSIMILATION = {
    'im': 'in', 'il': 'in', 'ir': 'in',
    'con': 'com', 'col': 'com', 'cor': 'com',
}


def edit_distance(lhs, rhs):
    a, b = lhs, rhs
    if not a:
        return len(b)
    if not b:
        return len(a)
    if abs(len(a) - len(b)) > 1:
        return 2
    prev = list(range(len(b) + 1))
    cur = [0] * (len(b) + 1)
    for i in range(1, len(a) + 1):
        cur[0] = i
        for j in range(1, len(b) + 1):
            cost = 0 if a[i - 1] == b[j - 1] else 1
            cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
        prev, cur = cur, prev
    return prev[len(b)]


class RootParserClone:
    def __init__(self, entries):
        self.prefix_index, self.suffix_index, self.root_index, self.root_list = build_indexes(entries)

    def match_root(self, stem):
        if not stem:
            return None
        if stem in self.root_index:
            return self.root_index[stem]
        if len(stem) >= 4:
            for e in self.root_list:
                if stem.find(e['normalized']) != -1:
                    return e
        if len(stem) >= 4:
            for e in self.root_list:
                if abs(len(e['normalized']) - len(stem)) <= 1:
                    if edit_distance(stem, e['normalized']) <= 1:
                        return e
        return None

    def match_prefix(self, word):
        if len(word) <= 3:
            return None
        max_len = min(5, len(word) - 3)
        if max_len < 2:
            return None
        for length in range(max_len, 1, -1):
            form = word[:length]
            remainder = word[length:]
            # 剩余部分至少 4 个字母，或是词根库可信词根（与 Swift matchPrefix 一致）
            if len(remainder) < 4 and self.match_root(remainder) is None:
                continue
            entry = self.prefix_index.get(form)
            if entry is None and form in ASSIMILATION:
                entry = self.prefix_index.get(ASSIMILATION[form])
            if entry is None:
                continue
            is_literal = (form == entry['normalized'])
            if not is_literal:
                trustworthy = self.match_root(remainder) is not None or len(remainder) >= 5
                if not trustworthy:
                    continue
            return (form, entry)
        return None

    def match_suffix(self, body):
        if len(body) <= 3:
            return None
        max_len = min(7, len(body) - 3)
        if max_len < 2:
            return None
        for length in range(max_len, 1, -1):
            form = body[-length:]
            entry = self.suffix_index.get(form)
            if entry is None:
                continue
            stem = body[:-length]
            if len(stem) < 3:
                continue
            return (form, entry)
        return None

    def parse(self, raw):
        word = raw.strip().lower()
        if not word:
            return None
        if not self.is_matchable(word):
            return None

        prefix_segment = None
        body = word
        m = self.match_prefix(word)
        if m is not None:
            form, entry = m
            prefix_segment = {'text': form + '-', 'type': 'prefix', 'meaning': entry['meaning'], 'rootID': entry['id']}
            body = word[len(form):]

        suffix_segment = None
        stem = body
        m = self.match_suffix(body)
        if m is not None:
            form, entry = m
            suffix_segment = {'text': '-' + form, 'type': 'suffix', 'meaning': entry['meaning'], 'rootID': entry['id']}
            stem = body[:-len(form)]

        stem_segment = None
        if stem:
            root = self.match_root(stem)
            if root is not None:
                stem_segment = {'text': root['normalized'], 'type': 'root', 'meaning': root['meaning'], 'rootID': root['id']}
            elif prefix_segment is not None or suffix_segment is not None:
                stem_segment = {'text': stem, 'type': 'other', 'meaning': ''}

        segments = []
        if prefix_segment is not None:
            segments.append(prefix_segment)
        if stem_segment is not None:
            segments.append(stem_segment)
        if suffix_segment is not None:
            segments.append(suffix_segment)
        if prefix_segment is None and suffix_segment is None:
            # S5B 组合词拆分（与 Swift matchCompound 一致）：airport = air + port
            # 无前后缀即优先尝试组合，避免整词子串命中单个词根（如 airport 含 port）阻断组合
            compound = self.match_compound(word)
            if compound is not None:
                return compound
            if stem_segment is None:
                return None

        if len(segments) < 2:
            return None
        return [s['text'] for s in segments]

    def match_compound(self, word):
        """组合词拆分：左右两段均为可信词根（airport = air + port）"""
        n = len(word)
        if n < 6:
            return None
        for left_len in range(n - 3, 2, -1):
            left = word[:left_len]
            right = word[left_len:]
            if len(left) < 3 or len(right) < 3:
                continue
            left_entry = self.match_root(left)
            right_entry = self.match_root(right)
            if left_entry is None or right_entry is None:
                continue
            return [left_entry['normalized'], right_entry['normalized']]
        return None

    @staticmethod
    def is_matchable(word):
        for ch in word:
            o = ord(ch)
            if not (ch.isascii() and ch.isalpha() or ch in "-'"):
                return False
        return True


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--tsv', required=True, help='ecdict_light.tsv 路径')
    ap.add_argument('--roots', required=True, help='RootLibrary.json 路径')
    ap.add_argument('--output', required=True, help='输出 precomputed_roots.tsv 路径')
    ap.add_argument('--limit', type=int, default=0, help='仅处理前 N 行（测试用，0=全量）')
    args = ap.parse_args()

    entries = load_root_library(args.roots)
    parser = RootParserClone(entries)
    print('[info] 词根库: {} 条 (prefix/root/suffix)'.format(len(entries)), flush=True)

    hits = 0
    total = 0
    start = time.time()
    t0 = start
    out_lines = []

    with open(args.tsv, 'r', encoding='utf-8') as f:
        for lineno, line in enumerate(f, 1):
            if args.limit and lineno > args.limit:
                break
            total += 1
            line = line.rstrip('\n').rstrip('\r')
            if not line:
                continue
            word = line.split('\t', 1)[0].strip()
            if not word:
                continue
            segs = parser.parse(word)
            if segs is not None:
                hits += 1
                out_lines.append(word + '\t' + '|'.join(segs))
            if total % 100000 == 0:
                elapsed = time.time() - t0
                print('[progress] {} 行, 命中 {} , 用时 {:.1f}s'.format(total, hits, elapsed), flush=True)

    with open(args.output, 'w', encoding='utf-8') as f:
        f.write('\n'.join(out_lines))
        f.write('\n')

    elapsed = time.time() - start
    import os
    size = os.path.getsize(args.output)
    print('[done] 处理 {} 行, 命中 {} 词 (命中率 {:.2f}%), 输出 {:.2f} MB, 用时 {:.1f}s'.format(
        total, hits, hits * 100.0 / max(total, 1), size / 1048576.0, elapsed), flush=True)


if __name__ == '__main__':
    main()
