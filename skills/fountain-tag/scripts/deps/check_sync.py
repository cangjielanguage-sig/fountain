#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""校验技能自带的 deps 脚本与仓库内 docs/模块依赖图/ 的入库版本是否同源。

两处只有「有意差异」，脚本会把技能副本归一化回仓库形态再逐字节比对：
  1. `extract_deps.py`：技能副本按 `_default_root()`（FOUNTAIN_ROOT > git 仓库根 > 当前目录）推断仓库根，
     多一行 `import subprocess`；仓库版按脚本位置推断；
  2. 两个生成器：技能副本用 `extract_deps.ROOT` 拼产物路径，仓库版用脚本相对路径；
  3. 三份都把「用法：」写成「用法（在仓库里执行）：」，docstring 末尾多一行同步提示。

用法（在仓库里执行）：
    python3 check_sync.py                 # 只比源码
    python3 check_sync.py --run           # 再跑一遍技能副本，核对两张 SVG 与仓库版产物 md5 相同
    FOUNTAIN_ROOT=/path/to/fountain python3 check_sync.py
退出码 0 = 同源；1 = 有漂移（把仓库版重新同步到 scripts/deps/ 即可）。
"""
import argparse
import hashlib
import difflib
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
FILES = ['extract_deps.py', 'gen_layered_svg.py', 'gen_matrix_svg.py']
OUTS = ['module-dependencies.svg', 'module-dependency-matrix.svg']


def repo_root():
    env = os.environ.get('FOUNTAIN_ROOT')
    if env:
        return os.path.abspath(env)
    for cmd in (['git', 'rev-parse', '--show-toplevel'],):
        try:
            out = subprocess.run(cmd, capture_output=True, text=True, check=True,
                                 cwd=os.getcwd()).stdout.strip()
            if out:
                return os.path.abspath(out)
        except Exception:
            pass
    return os.path.abspath(os.getcwd())


def to_repo_form(skill_text):
    """把技能副本归一化成仓库版形态（消掉上面列的 3 处有意差异）。"""
    t = skill_text.replace('用法（在仓库里执行）：', '用法：')
    t = re.sub(r'\n\n?注：本文件是技能自带副本.*?两处要同步。\n', '\n', t, flags=re.S)
    t = re.sub(r'\ndef _default_root\(\):.*?\nROOT = _default_root\(\)\n',
               "\nROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)),"
               " '..', '..'))\n", t, flags=re.S)
    t = t.replace('import re\nimport subprocess\nimport sys', 'import re\nimport sys')
    for out in OUTS:
        t = t.replace(
            f"OUT = os.path.abspath(os.path.join(extract_deps.ROOT, '.assets', 'README', '{out}'))\n",
            f"HERE = os.path.dirname(os.path.abspath(__file__))\n"
            f"OUT = os.path.abspath(os.path.join(HERE, '..', '..', '.assets', 'README', '{out}'))\n")
    return t


def md5(path):
    return hashlib.md5(open(path, 'rb').read()).hexdigest()


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument('--run', action='store_true', help='再跑技能副本，核对两张 SVG 与仓库版产物一致')
    ap.add_argument('--root', default=None, help='仓库根（默认 FOUNTAIN_ROOT > git 仓库根 > 当前目录）')
    args = ap.parse_args()
    root = os.path.abspath(args.root) if args.root else repo_root()
    repo_deps = os.path.join(root, 'docs', '模块依赖图')
    print(f'仓库根 = {root}\n仓库版脚本 = {repo_deps}\n技能副本 = {HERE}\n')

    bad = 0
    for name in FILES:
        rp, sp = os.path.join(repo_deps, name), os.path.join(HERE, name)
        if not os.path.exists(rp):
            print(f'{name:22s} ? 仓库版不存在，跳过')
            continue
        repo = open(rp, encoding='utf-8').read()
        norm = to_repo_form(open(sp, encoding='utf-8').read())
        if repo == norm:
            print(f'{name:22s} 同源 OK（{len(repo)} bytes）')
            continue
        bad += 1
        print(f'{name:22s} ✗ 有非预期差异：')
        diff = list(difflib.unified_diff(repo.splitlines(), norm.splitlines(),
                                         'repo', 'skill(normalized)', lineterm='', n=1))
        for line in diff[:20]:
            print('   ', line)

    if args.run:
        py = sys.executable
        print('\n=== 跑技能副本，核对产物 ===')
        before = {o: md5(os.path.join(root, '.assets', 'README', o))
                  for o in OUTS if os.path.exists(os.path.join(root, '.assets', 'README', o))}
        for name in ('gen_layered_svg.py', 'gen_matrix_svg.py'):
            subprocess.run([py, os.path.join(HERE, name)], check=True,
                           stdout=subprocess.DEVNULL, cwd=root)
        for o in OUTS:
            p = os.path.join(root, '.assets', 'README', o)
            now = md5(p)
            same = '与跑之前一致' if before.get(o) == now else '★ 变了（说明技能副本与仓库版不一致）'
            print(f'   {o:34s} md5={now}  {same}')
            if before.get(o) and before[o] != now:
                bad += 1

    print('\n结论：', '同源' if not bad else f'{bad} 处漂移 —— 请把仓库版重新同步到 scripts/deps/')
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main())
