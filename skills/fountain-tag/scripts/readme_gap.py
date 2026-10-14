#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""fountain-tag Step 1.2 工具：各模块「public 声明 vs README 提及」差集报告。

统计口径：
  - 只看受版本控制的模块（顶层带 cjpm.toml，排除示例应用 fdemo / fcoder / frpcdemo）；
  - 跳过 *_test.cj；宿主类型不是 public 的成员不算对外 API；
  - 「README 提过」只在代码上下文里认：行内 `code span`，或围栏代码块里像声明/调用的行。

默认排除（不进 README 的声明，详见技能 Step 1.2）：
  bench / 极简迭代器 / FFI / 类型转换族（to* tryTo* from* as*、f_data 的 Data* 与 *Data 类型）/
  配置类（含 Config）/ 仅给宏调用的声明 / f_orm 的 *SqlArg / f_uring 的非核心 API / f_store 的辅助项 /
  冻结模块 f_llm f_log f_mvc f_ticktock f_rpc（用 --base 传入基线时，区间内有代码改动的模块自动解冻）。

用法：
    python3 readme_gap.py --base release-1.3.13.alpha        # 全量报告（推荐）
    python3 readme_gap.py f_base f_util                      # 只看指定模块
    python3 readme_gap.py --root /path/to/fountain           # 显式指定仓库根
    python3 readme_gap.py --all                              # 连排除项一起列出（排查用）
"""
import argparse
import glob
import os
import re
import subprocess
import sys

SKIP = {'fdemo', 'fcoder', 'frpcdemo'}
FREEZE = {'f_llm', 'f_log', 'f_mvc', 'f_ticktock', 'f_rpc'}
FFI_ONLY_CORE = {'f_uring'}          # 只保留核心 API（其余一律排除）
CONV_RE = re.compile(r'^(?:try)?[Tt]o[A-Z]|^(?:try)?[Ff]rom[A-Z]|^as[A-Z]')
MACRO_ONLY_NAMES = {'dataFields', 'classTypeInfo', 'fieldTypeInfo',
                    'tryFindAnnotation', 'tryGetAnnotation'}
MACRO_ONLY_MODULES = {'f_macros'}
MACRO_MODULE_FUNC = re.compile(r'^f_[a-z]+_[a-z]')
STORE_AUX_MODULES = {'f_store'}       # 只写核心 API：ByteArray 上的工具成员不进 README

TYPES = re.compile(r'^\s*public\s+(?:open\s+|sealed\s+|abstract\s+)*'
                   r'(class|struct|enum|interface)\s+([A-Za-z_]\w*)', re.M)
DECL = re.compile(r'^\s*public\s+(?:open\s+|sealed\s+|abstract\s+|const\s+|static\s+)*'
                  r'(class|struct|enum|interface|func|macro|let|var|type|prop)\s+([A-Za-z_]\w*)', re.M)
PUBLIC_MEMBER = re.compile(r'^\s*public\s+(?:static\s+|const\s+|mut\s+|override\s+|open\s+|sealed\s+|abstract\s+)*'
                           r'(func|init|let|var|prop|macro|type)\s+([A-Za-z_]\w*)', re.M)
NONPUB_TYPES = re.compile(r'^\s*(?:open\s+|sealed\s+|abstract\s+)*'
                          r'(class|struct|enum|interface)\s+([A-Za-z_]\w*)', re.M)
EXTEND = re.compile(r'^\s*(?:public\s+)?extend\s+([A-Za-z_][A-Za-z0-9_]*)', re.M)
FENCE = re.compile(r'~~~.*?~~~|```.*?```', re.S)
SPAN = re.compile(r'`[^`\n]*`')


def repo_root(explicit=None):
    if explicit:
        return os.path.abspath(explicit)
    try:
        out = subprocess.run(['git', 'rev-parse', '--show-toplevel'],
                             capture_output=True, text=True, check=True).stdout.strip()
        return out
    except Exception:
        return os.path.abspath('.')


def strip_code(text):
    """注释与字符串字面量替换为空格（保留换行），便于括号配对与行首锚定。"""
    out = []
    i, n = 0, len(text)
    while i < n:
        c = text[i]
        if c == '/' and i + 1 < n and text[i + 1] == '/':
            j = text.find('\n', i)
            j = n if j < 0 else j
            out.append(' ' * (j - i))
            i = j
        elif c == '/' and i + 1 < n and text[i + 1] == '*':
            j = text.find('*/', i + 2)
            j = n if j < 0 else j + 2
            out.append(''.join('\n' if ch == '\n' else ' ' for ch in text[i:j]))
            i = j
        elif c in ('"', "'"):
            j = i + 1
            while j < n:
                if text[j] == '\\':
                    j += 2
                    continue
                if text[j] == c or text[j] == '\n':
                    break
                j += 1
            out.append(''.join('\n' if ch == '\n' else ' ' for ch in text[i:min(j + 1, n)]))
            i = j + 1
        else:
            out.append(c)
            i += 1
    return ''.join(out)


def match_brace(text, start):
    depth = 0
    for i in range(start, len(text)):
        if text[i] == '{':
            depth += 1
        elif text[i] == '}':
            depth -= 1
            if depth == 0:
                return i
    return len(text)


def span_of(clean, m, tname, is_public, members=None):
    b = clean.find('{', m.end())
    if b < 0:
        return None
    e = match_brace(clean, b)
    body = clean[b + 1:e]
    pub = [n for _, n in PUBLIC_MEMBER.findall(body)]
    if re.search(r'^\s*public\s+' + re.escape(tname) + r'\s*\(', body, re.M):
        pub.append('init')       # 主构造函数
    return (m.start(), e, tname, pub, is_public)


def doc_above(raw_lines, idx):
    """取声明上方紧邻的注释块（/** … */ 或 // 行），最多 8 行。"""
    out = []
    i = idx - 1
    while i >= 0 and len(out) < 8:
        line = raw_lines[i].strip()
        if line.endswith('*/') or line.startswith('*') or line.startswith('/**') or line.startswith('//'):
            out.append(line)
            i -= 1
        else:
            break
    return list(reversed(out))


def scan_file(path, root):
    raw = open(path, encoding='utf-8').read()
    raw_lines = raw.splitlines()
    clean = strip_code(raw)
    spans = [s for s in (span_of(clean, m, m.group(2), True) for m in TYPES.finditer(clean)) if s]
    spans += [s for s in (span_of(clean, m, m.group(2), False) for m in NONPUB_TYPES.finditer(clean)) if s]
    spans += [s for s in (span_of(clean, m, m.group(1), True) for m in EXTEND.finditer(clean)) if s]
    types = [s[:4] for s in spans if s[4]]
    decls = []
    for m in DECL.finditer(clean):
        owner, owner_pub, best = None, True, -1
        for s, e, nm, _, is_pub in spans:      # 取最内层宿主
            if s < m.start() <= e and s > best:
                owner, owner_pub, best = nm, is_pub, s
        idx = clean.count('\n', 0, m.start())
        clean_lines = clean.splitlines()
        sig = clean_lines[idx].strip().rstrip(',').rstrip() if idx < len(clean_lines) else ''
        decls.append((m.group(1), m.group(2), owner, owner_pub,
                      f'{os.path.relpath(path, root)}:{idx + 1}',
                      sig,
                      doc_above(raw_lines, idx)))
    return types, decls


def word_in(name, chunk):
    return re.search(r'(?<![A-Za-z0-9_])' + re.escape(name) + r'(?![A-Za-z0-9_])', chunk) is not None


def mentioned(name, text):
    """README 是否「提」了该符号：行内 code span 命中，或围栏里出现像声明/调用的行。"""
    if any(word_in(name, span) for span in SPAN.findall(text)):
        return True
    pat = re.compile(
        r'(?<![A-Za-z0-9_])(?:func|let|var|const|static|prop|class|struct|enum|interface|type|macro|public|private|open)\s+'
        + re.escape(name) + r'\b'
        + r'|(?<![A-Za-z0-9_.])' + re.escape(name) + r'\s*[(<:=\[]'
        + r'|\.\s*' + re.escape(name) + r'\b')
    for fence in FENCE.findall(text):
        for line in fence.splitlines():
            if pat.search(line):
                return True
    return False


def data_type(mod, name):
    """f_data 里 Data 开头 / Data 结尾的类型（含其成员）属于类型转换用途。"""
    return mod == 'f_data' and (name.startswith('Data') or name.endswith('Data'))


def analyze(root, mod):
    types_all, decls = [], []
    for f in glob.glob(os.path.join(root, mod, 'src', '**', '*.cj'), recursive=True):
        if f.endswith('_test.cj'):
            continue
        t, d = scan_file(f, root)
        types_all += t
        decls += d
    trivial = {nm for _, _, nm, mem in types_all
               if 'iterator' in nm.lower() and mem and set(mem) <= {'init', 'next'} and 'next' in mem}
    readme = {}
    for lang, fn in (('zh', 'README.md'), ('en', 'README_en.md')):
        path = os.path.join(root, mod, fn)
        readme[lang] = open(path, encoding='utf-8', errors='replace').read() if os.path.exists(path) else ''
    rows = {}
    for kind, name, owner, owner_pub, where, sig, doc in decls:
        key = f'{owner}.{name}' if owner else name
        if not owner_pub:
            continue                     # 宿主类型非 public：模块外不可达
        low = (name + ' ' + (owner or '')).lower()
        if 'bench' in low:
            why = 'bench'
        elif owner in trivial or ('iterator' in name.lower() and name in trivial):
            why = 'iter'
        elif mod in FREEZE:
            why = 'freeze'
        elif mod in FFI_ONLY_CORE:
            why = 'ffi'
        elif mod in STORE_AUX_MODULES and owner == 'ByteArray':
            why = 'store-aux'        # f_store 只写核心 API：ByteArray 的工具成员不进 README
        elif 'Config' in name or 'Config' in (owner or ''):
            why = 'config'
        elif data_type(mod, name) or (owner and data_type(mod, owner)):
            why = 'conv'
        elif CONV_RE.match(name):
            why = 'conv'
        elif (mod in MACRO_ONLY_MODULES or name in MACRO_ONLY_NAMES
              or (owner is None and MACRO_MODULE_FUNC.match(name))):
            why = 'macro'
        elif name.endswith('SqlArg'):
            why = 'sqlarg'
        else:
            why = ''
        miss_zh = not mentioned(name, readme['zh'])
        miss_en = not mentioned(name, readme['en'])
        if not (miss_zh or miss_en):
            continue
        old = rows.get(key)
        if old is None:
            rows[key] = {'kind': kind, 'name': name, 'owner': owner, 'key': key, 'why': why,
                         'zh': miss_zh, 'en': miss_en, 'where': where, 'sig': sig, 'doc': doc}
        else:
            old['zh'] = old['zh'] or miss_zh
            old['en'] = old['en'] or miss_en
            if not old['why']:
                old['why'] = why
    return list(rows.values())


def module_dirs(root):
    return sorted(os.path.basename(os.path.dirname(p))
                  for p in glob.glob(os.path.join(root, '*', 'cjpm.toml'))
                  if os.path.basename(os.path.dirname(p)) not in SKIP)


def changed_since(root, base):
    """区间 base..HEAD 里**有代码改动**的模块目录名（用于给冻结模块解冻）。

    只认代码路径（`<模块>/src/…`）：只改 README、或只动 cjpm.toml（版本号）都不算代码改动，
    否则「冻结模块除非本轮有代码改动」这条规则会被文档提交 / 升版提交误触发。
    """
    try:
        out = subprocess.run(['git', '-C', root, 'diff', '--name-only', f'{base}..HEAD'],
                             capture_output=True, text=True, check=True).stdout
    except Exception:
        return set()
    mods = set()
    for ln in out.splitlines():
        parts = ln.split('/')
        if len(parts) < 2 or parts[0] in SKIP:
            continue
        if '/src/' in ln:
            mods.add(parts[0])
    return mods


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument('modules', nargs='*', help='只查这些模块（默认全部）')
    ap.add_argument('--root', default=None, help='仓库根（默认取当前 git 仓库根）')
    ap.add_argument('--base', default=None, help='基线 rev；区间内有代码改动的冻结模块自动解冻')
    ap.add_argument('--all', action='store_true', help='连排除项一起列出（排查用）')
    ap.add_argument('--details', action='store_true',
                    help='每条待新增声明附上源码位置、签名行与上方注释（写文档时用）')
    args = ap.parse_args(argv)
    root = repo_root(args.root)
    mods = args.modules or module_dirs(root)
    thawed = changed_since(root, args.base) if args.base else set()
    keeps, sync_zh, sync_en, excl_sync, excl_count = [], [], [], [], {}
    for mod in mods:
        frozen = mod in FREEZE and mod not in thawed
        for r in analyze(root, mod):
            r['mod'] = mod
            why = r['why']
            if why == 'freeze' and not frozen:
                why = ''                 # 冻结模块本轮有代码改动：按普通模块处理
            r['why'] = why
            if why and not args.all:
                excl_count[why] = excl_count.get(why, 0) + 1
                if r['zh'] != r['en']:
                    excl_sync.append(r)
            elif why:
                excl_count[why] = excl_count.get(why, 0) + 1
                keeps.append(r)
            elif r['zh'] and r['en']:
                keeps.append(r)
            elif r['zh']:
                sync_zh.append(r)
            else:
                sync_en.append(r)
    print(f'repo={root}')
    if args.base:
        print(f'基线 {args.base} 以来有代码改动的模块：' +
              (', '.join(sorted(thawed)) if thawed else '（无）'))
    print('排除明细：' + '  '.join(f'{k}={v}' for k, v in sorted(excl_count.items(), key=lambda kv: -kv[1])))
    print(f'一、待新增（中英都没提）：{len(keeps)}    '
          f'二、补中文（英文有、中文漏）：{len(sync_zh)}    '
          f'三、补英文（中文有、英文漏）：{len(sync_en)}    '
          f'四、排除类里两侧不一致：{len(excl_sync)}')
    print()
    print('=== 一、待新增（中英都没提）===')
    by_mod = {}
    for r in keeps:
        by_mod.setdefault(r['mod'], []).append(r)
    for mod in sorted(by_mod):
        rs = by_mod[mod]
        print(f'### {mod}（{len(rs)}）')
        top = sorted((r for r in rs if not r['owner']), key=lambda r: r['key'])
        members = {}
        for r in rs:
            if r['owner']:
                members.setdefault(r['owner'], []).append(r)
        if top:
            print('  模块级：' + ', '.join(f"[{r['kind']}] {r['key']}" for r in top))
        for owner in sorted(members):
            items = []
            for r in sorted(members[owner], key=lambda r: r['name']):
                items.append((f"[{r['kind']}] " if r['kind'] != 'func' else '') + r['name'])
            print(f'  {owner}：{", ".join(items)}')
        if args.details:
            for r in sorted(rs, key=lambda r: (r['owner'] or '', r['name'])):
                print(f"    · {r['key']}  [{r['where']}]")
                print(f"        {r['sig']}")
                for line in r['doc']:
                    print(f"        {line}")
        print()
    print('=== 二、补中文（英文 README 已提、中文 README 漏）===')
    for r in sorted(sync_zh, key=lambda r: (r['mod'], r['key'])):
        print(f"  {r['mod']}: {r['key']}")
    if not sync_zh:
        print('  （无）')
    print()
    print('=== 三、补英文（中文 README 已提、英文 README 漏）===')
    if not sync_en:
        print('  （无）')
    for r in sorted(sync_en, key=lambda r: (r['mod'], r['key'])):
        print(f"  {r['mod']}: {r['key']}")
    print()
    print('=== 四、排除类里两侧不一致（按规则本不该进 README，另一侧可能是多余提及）===')
    if not excl_sync:
        print('  （无）')
    for r in sorted(excl_sync, key=lambda r: (r['mod'], r['key'])):
        side = '中文有、英文无' if r['en'] else '英文有、中文无'
        print(f"  {r['mod']}: {r['key']}  [{r['why']}]（{side}）")
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
