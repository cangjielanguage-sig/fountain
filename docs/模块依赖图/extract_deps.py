#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""抽取 fountain 各模块之间的依赖，分两层：

  1. **声明**（declared）：各模块 cjpm.toml 的 [dependencies] 里 `fountain::*` 条目；
  2. **已引用**（used）：该模块 `src/` 下的非测试代码里出现了 `import fountain::<依赖>…`。

仓颉里要用某个模块的 API 必须把它声明成直接依赖（间接依赖的符号不可见），所以
「声明了 + 真的 import 了」才算一条真实依赖；**声明了但源码未引用的边不进图**
（它们只是多余的声明，不代表依赖关系）。两张图（连线图 / 矩阵图）都只画 used 边。

用法：
    python3 extract_deps.py             # 依赖表 + 统计（默认只列已引用的边）
    python3 extract_deps.py --declared  # 连「声明了但未引用」的边一起列（标 UNUSED，便于清理 cjpm.toml）
    python3 extract_deps.py --usage     # 每条边的 API 引用次数（连线图靠它决定颜色深浅）
    python3 extract_deps.py --json      # 输出 JSON（含 declared / used / usage）
    python3 extract_deps.py --usage | head  # 看引用量最大的边

被 gen_layered_svg.py / gen_matrix_svg.py 以模块方式导入：graph() 默认只返回已引用的边。
改「什么算依赖」只改这里。
"""
import argparse
import glob
import json
import os
import re
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..'))
# 示例应用不进图（README 的模块清单里只有库模块与 fleet）
EXCLUDE = {'fdemo', 'fcoder', 'frpcdemo'}
# import 可以带可见性修饰：import / public import / protected import / internal import / private import
IMPORT_FMT = (r'^\s*(?:(?:public|protected|internal|private)\s+)?import\s+'
              r'fountain::{}(?![A-Za-z0-9_])')
ANY_IMPORT = re.compile(r'^\s*(?:(?:public|protected|internal|private)\s+)?import\s')
# 公开符号声明（顶层与成员都算）：用来判断「这个模块对外提供了哪些名字」
PUBLIC_DECL = re.compile(
    r'^\s*public\s+(?:open\s+|sealed\s+|abstract\s+|static\s+|unsafe\s+|redef\s+)*'
    r'(?:class|interface|struct|enum|func|macro|let|var|const|type|prop|operator)\s+([A-Za-z_]\w*)', re.M)
_BLOCK = re.compile(r'/\*.*?\*/', re.S)
_LINE = re.compile(r'//.*$', re.M)
_STR = re.compile(r'"(?:\\.|[^"\\])*"')


def src_files(root, mod, include_tests=False):
    out = []
    for dirpath, _dirs, names in os.walk(os.path.join(root, mod, 'src')):
        for n in names:
            if not n.endswith('.cj'):
                continue
            if n.endswith('_test.cj') and not include_tests:
                continue
            out.append(os.path.join(dirpath, n))
    return sorted(out)


def imports_dep(root, mod, dep):
    """模块 mod 的非测试源码里是否 import 了 fountain::dep（含子包）。"""
    pat = re.compile(IMPORT_FMT.format(re.escape(dep)), re.M)
    for f in src_files(root, mod):
        try:
            if pat.search(open(f, encoding='utf-8', errors='replace').read()):
                return True
        except OSError:
            continue
    return False


def scan(root=ROOT, exclude=EXCLUDE):
    """返回 {模块目录名: {'package': 包名, 'deps': [声明的依赖…], 'used': [已引用的依赖…]}}。"""
    mods = {}
    for path in sorted(glob.glob(os.path.join(root, '*', 'cjpm.toml'))):
        mod = os.path.basename(os.path.dirname(path))
        text = open(path, encoding='utf-8').read()
        name = mod
        pm = re.search(r'^\[package\](.*?)(?=^\[|\Z)', text, re.S | re.M)
        if pm:
            nm = re.search(r'^\s*name\s*=\s*"([^"]+)"', pm.group(1), re.M)
            if nm:
                name = nm.group(1)
        deps = set()
        dm = re.search(r'^\[dependencies\](.*?)(?=^\[|\Z)', text, re.S | re.M)
        if dm:
            for line in dm.group(1).splitlines():
                line = line.strip()
                if not line or line.startswith('#'):
                    continue
                mm = re.match(r'"fountain::([A-Za-z0-9_]+)"', line)
                if mm:
                    deps.add(mm.group(1))
        deps = sorted(deps)
        mods[mod] = {'package': name, 'deps': deps,
                     'used': [d for d in deps if imports_dep(root, mod, d)]}
    return {k: v for k, v in mods.items() if k not in exclude}


def graph(mods=None, root=ROOT, used_only=True):
    """返回 (节点名列表, {节点: [依赖节点…]})。

    used_only=True（默认）：只含「声明并已引用 API」的边——两张图的数据源；
    used_only=False：含全部声明边（对照用）。
    """
    mods = mods or scan(root)
    nodes = sorted(mods)
    key = 'used' if used_only else 'deps'
    deps = {n: sorted(d for d in mods[n][key] if d in mods and d != n) for n in nodes}
    return nodes, deps


def summary(mods=None, root=ROOT):
    """返回 (声明的边数, 已引用的边数, [(模块, 未引用的依赖)…])。"""
    mods = mods or scan(root)
    declared = sum(len(v['deps']) for v in mods.values())
    used = sum(len(v['used']) for v in mods.values())
    unused = [(m, d) for m in sorted(mods) for d in mods[m]['deps'] if d not in mods[m]['used']]
    return declared, used, unused


# ---- API 使用量：边 A → B 的「粗细」依据 ----
_SYM_CACHE = {}
_PAT_CACHE = {}


def _clean(text):
    """去掉块注释 / 行注释 / 字符串字面量，避免把文档和文案里的名字算成 API 引用。"""
    return _STR.sub('""', _LINE.sub('', _BLOCK.sub('', text)))


def symbols(mod, root=ROOT):
    """模块对外公开的符号名集合（顶层与成员都算，取 `public <kind> <name>`）。"""
    key = (os.path.abspath(root), mod)
    if key not in _SYM_CACHE:
        names = set()
        for f in src_files(root, mod):
            try:
                names |= set(PUBLIC_DECL.findall(_clean(open(f, encoding='utf-8', errors='replace').read())))
            except OSError:
                continue
        _SYM_CACHE[key] = names
    return _SYM_CACHE[key]


def api_usage(mods=None, root=ROOT):
    """返回 {(依赖方, 被依赖方): 引用次数}，只对「声明且已引用」的边计数。

    口径：A 的非测试源码里出现 B 的公开符号名的次数。
    - import 行本身不计（只看使用处）；
    - 注释与字符串字面量不计；
    - 同名符号若同时属于 A 依赖的多个模块 → 按候选数均摊（不重复计给每个模块）；
    - A 自己也声明了同名符号 → 归属不明，直接不计。
    值保留一位小数（均摊后可能是 .5）。
    """
    mods = mods or scan(root)
    nodes = sorted(mods)
    deps = {n: sorted(d for d in mods[n]['used'] if d in mods and d != n) for n in nodes}
    syms = {n: symbols(n, root) for n in nodes}
    out = {}
    for a in nodes:
        cand = {}
        for b in deps[a]:
            for nm in syms[b]:
                if nm in syms[a]:
                    continue
                cand.setdefault(nm, []).append(b)
        if not cand:
            continue
        key = tuple(sorted(cand))
        pat = _PAT_CACHE.get(key)
        if pat is None:
            pat = re.compile(r'\b(?:' + '|'.join(re.escape(n) for n in key) + r')\b')
            _PAT_CACHE[key] = pat
        counts = {}
        for f in src_files(root, a):
            try:
                text = _clean(open(f, encoding='utf-8', errors='replace').read())
            except OSError:
                continue
            for line in text.splitlines():
                if ANY_IMPORT.match(line):
                    continue
                for nm in pat.findall(line):
                    counts[nm] = counts.get(nm, 0) + 1
        for nm, k in counts.items():
            owners = cand[nm]
            for b in owners:
                out[(a, b)] = out.get((a, b), 0.0) + k / len(owners)
    return {k: round(v, 1) for k, v in out.items()}


def top_edges(k=3, mods=None, root=ROOT):
    """每个模块 API 引用量前三的依赖：{模块: {依赖, …}}（次数相同时按依赖名定序）。

    两张图用它决定「哪些边画成彩色实线 / 彩色格」——其余依赖退成灰色虚线 / 浅灰格。
    """
    mods = mods or scan(root)
    nodes, deps = graph(mods, root)
    us = api_usage(mods, root)
    return {a: {b for b, _u in sorted(((b, us.get((a, b), 1)) for b in deps[a]),
                                      key=lambda t: (-t[1], t[0]))[:k]} for a in nodes}


# ---- 配色：每个模块一个不重复的色相；深浅（明度）由 API 引用量决定 ----
GOLDEN = 137.508                # 黄金角散布色相，43 个模块互相不撞色


def hues(names):
    """按给定顺序给每个模块分配不重复的色相（度）。"""
    return {n: (i * GOLDEN) % 360 for i, n in enumerate(names)}


def hsl_hex(h, s, l):
    """HSL（h 度，s/l 取 0~1）→ #rrggbb。"""
    c = (1 - abs(2 * l - 1)) * s
    x = c * (1 - abs((h / 60) % 2 - 1))
    m = l - c / 2
    r, g, b = [(c, x, 0), (x, c, 0), (0, c, x), (0, x, c), (x, 0, c), (c, 0, x)][int(h // 60) % 6]
    return '#%02x%02x%02x' % (round((r + m) * 255), round((g + m) * 255), round((b + m) * 255))


def shade_hex(hue, t, s=0.62, dark=0.34, light=0.80):
    """t=1（引用量最大）最深、t=0 最浅。"""
    return hsl_hex(hue, s, light - (light - dark) * max(0.0, min(1.0, t)))


def base_hex(hue, s=0.62, l=0.50):
    """模块本色（节点色条、矩阵图默认格）。"""
    return hsl_hex(hue, s, l)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument('--json', action='store_true', help='输出 JSON（供其它脚本/工具消费）')
    ap.add_argument('--declared', action='store_true',
                    help='连「声明了但源码未引用」的边一起列出（标 UNUSED）')
    ap.add_argument('--usage', action='store_true',
                    help='列出每条边的 API 引用次数（按次数降序；连线图用它决定颜色深浅）')
    ap.add_argument('--root', default=ROOT, help='仓库根目录（默认按脚本位置推断）')
    args = ap.parse_args(argv)
    mods = scan(args.root)
    declared, used, unused = summary(mods, args.root)
    if args.json:
        us = api_usage(mods, args.root)
        json.dump({'modules': mods, 'declared': declared, 'used': used,
                   'unused': [{'mod': m, 'dep': d} for m, d in unused],
                   'usage': {f'{a}|{b}': v for (a, b), v in sorted(us.items())}},
                  sys.stdout, ensure_ascii=False, indent=1)
        print()
        return 0
    nodes, deps = graph(mods)
    if args.usage:
        us = api_usage(mods, args.root)
        print(f'modules={len(nodes)} declared={declared} used={used} unused={len(unused)}')
        for (a, b), v in sorted(us.items(), key=lambda kv: (-kv[1], kv[0])):
            print(f'{v:8.1f}  {a:14s} -> {b}')
        return 0
    print(f'modules={len(nodes)} declared={declared} used={used} unused={len(unused)}')
    for n in nodes:
        line = ' '.join(deps[n]) if deps[n] else '-'
        if args.declared:
            skip = [d for d in mods[n]['deps'] if d not in mods[n]['used'] and d in mods]
            if skip:
                line += '  [UNUSED: ' + ' '.join(skip) + ']'
        print(f'{n:14s} -> {line}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
