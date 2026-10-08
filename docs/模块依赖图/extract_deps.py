#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""抽取 fountain 各模块之间的依赖（数据源：各模块 cjpm.toml 的 [dependencies]）。

用法：
    python3 extract_deps.py            # 打印依赖表
    python3 extract_deps.py --json     # 打印 JSON

被 gen_layered_svg.py / gen_matrix_svg.py 以模块方式导入，所以改依赖判定规则只改这里。
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


def scan(root=ROOT, exclude=EXCLUDE):
    """返回 {模块目录名: {'package': 包名, 'deps': [依赖的模块目录名…]}}。"""
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
        mods[mod] = {'package': name, 'deps': sorted(deps)}
    return {k: v for k, v in mods.items() if k not in exclude}


def graph(mods=None):
    """返回 (节点名列表, {节点: [依赖节点…]})，只保留库模块之间的边。"""
    mods = mods or scan()
    nodes = sorted(mods)
    deps = {n: sorted(d for d in mods[n]['deps'] if d in mods and d != n) for n in nodes}
    return nodes, deps


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument('--json', action='store_true', help='输出 JSON（供其它脚本/工具消费）')
    ap.add_argument('--root', default=ROOT, help='仓库根目录（默认按脚本位置推断）')
    args = ap.parse_args(argv)
    mods = scan(args.root)
    if args.json:
        json.dump(mods, sys.stdout, ensure_ascii=False, indent=1)
        print()
        return 0
    nodes, deps = graph(mods)
    print(f'modules={len(nodes)} edges={sum(len(v) for v in deps.values())}')
    for n in nodes:
        print(f"{n:14s} -> {' '.join(deps[n]) if deps[n] else '-'}")
    return 0


if __name__ == '__main__':
    sys.exit(main())
