#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""fountain-tag Step 1.2 批量补齐：给模块 README 追加「其他公开 API」小节（中英同构）。

做的事：复用同目录 readme_gap.py 的口径（排除 bench / FFI / 类型转换 / 配置类 / 宏专用 /
极简迭代器 / 冻结模块等），把「中英两边都没提」的公开声明渲染成签名清单，追加到该模块的
README.md 与 README_en.md 末尾；两边的条目相同（签名是代码），标题与引导语各自语言。
不改写已有内容，文件里已有该小节就跳过（幂等）。

用法（在仓库里执行）：
    python3 append_api_section.py --base BASE f_bean f_cache …      # --base 用于给冻结模块解冻
    python3 append_api_section.py --base BASE --dry-run f_bean      # 只打印，不写文件
    python3 append_api_section.py --base BASE --root /path/to/fountain f_bean

补完务必用 readme_gap.py 复核：同一模块的「待新增」应清零。
"""
import argparse
import importlib.util
import os
import sys

SKILL_SCRIPTS = os.path.dirname(os.path.abspath(__file__))     # readme_gap.py 与本脚本同目录
MARK = '## 其他公开 API'
MARK_EN = '## Other public API'

spec = importlib.util.spec_from_file_location('readme_gap', os.path.join(SKILL_SCRIPTS, 'readme_gap.py'))
gap = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gap)


def clean_sig(sig, member):
    s = (sig or '').strip()
    if s.endswith('{'):
        s = s[:-1].rstrip()
    if member and s.startswith('public '):
        s = s[len('public '):]
    return s


def item(r, member, lang):
    sig = clean_sig(r.get('sig'), member)
    if sig:
        return f'`{sig}`'
    if lang == 'zh':
        return f"`{r['name']}`（{r['kind']}）"
    return f"`{r['name']}` ({r['kind']})"


def render(rows, lang):
    """把 kept rows 渲染成小节文本（中英同构：标题与引导语各自语言，条目是签名）。"""
    title = MARK if lang == 'zh' else MARK_EN
    intro = ('以下声明未在上文展开，按「模块级 / 类型」分组列出（`extend` 里的成员归到被扩展的类型）；完整语义见 `src/` 下对应文件。'
             if lang == 'zh' else
             'The declarations below are not expanded above; they are grouped by module level and by type '
             '(members declared in `extend` blocks are listed under the extended type). '
             'See the corresponding files under `src/` for the full semantics.')
    sep = '、' if lang == 'zh' else ', '
    colon = '：' if lang == 'zh' else ': '
    top = sorted((r for r in rows if not r['owner']), key=lambda r: r['key'])
    owners = {}
    for r in rows:
        if r['owner']:
            owners.setdefault(r['owner'], []).append(r)
    lines = ['', '---', '', f'{title}', '', intro, '']
    if top:
        pref = '模块级' if lang == 'zh' else 'Module level'
        lines.append(f"- {pref}{colon}{sep.join(item(r, False, lang) for r in top)}")
    for owner in sorted(owners):
        items = [item(r, True, lang) for r in sorted(owners[owner], key=lambda r: r['name'])]
        lines.append(f"- `{owner}`{colon}{sep.join(items)}")
    lines.append('')
    return '\n'.join(lines)


def ensure_trailing_newline(path):
    with open(path, 'rb') as fh:
        data = fh.read()
    if data and not data.endswith(b'\n'):
        with open(path, 'ab') as fh:
            fh.write(b'\n')


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument('modules', nargs='+')
    ap.add_argument('--root', default=None)
    ap.add_argument('--base', default=None)
    ap.add_argument('--dry-run', action='store_true')
    args = ap.parse_args(argv)
    root = gap.repo_root(args.root)
    thawed = gap.changed_since(root, args.base) if args.base else set()
    for mod in args.modules:
        frozen = mod in gap.FREEZE and mod not in thawed
        rows = []
        for r in gap.analyze(root, mod):
            why = r['why']
            if why == 'freeze' and not frozen:
                why = ''
            if not why and r['zh'] and r['en']:
                rows.append(r)
        if not rows:
            print(f'{mod}: 无需补充')
            continue
        for lang, fn, mark in (('zh', 'README.md', MARK), ('en', 'README_en.md', MARK_EN)):
            path = os.path.join(root, mod, fn)
            if not os.path.exists(path):
                print(f'{mod}: {fn} 不存在，跳过')
                continue
            text = open(path, encoding='utf-8').read()
            if mark in text:
                print(f'{mod}: {fn} 已含「{mark}」，跳过')
                continue
            section = render(rows, lang)
            if args.dry_run:
                print(f'--- {mod}/{fn} ---{section}')
                continue
            ensure_trailing_newline(path)
            with open(path, 'a', encoding='utf-8') as fh:
                fh.write(section)
            print(f'{mod}: 追加到 {fn}（{len(rows)} 条）')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
