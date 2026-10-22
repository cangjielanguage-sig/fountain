#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把仓库内 docs/模块依赖图/ 的入库版本同步到技能自带的 scripts/deps/。

改完仓库版（生成逻辑、依赖判定、布局、配色、自检）后跑这一个命令即可，脚本会补上三处「有意差异」：
  1. `extract_deps.py` 的仓库根改按 `_default_root()`（FOUNTAIN_ROOT > git 仓库根 > 当前目录）推断，
     并补 `import subprocess`（`_default_root` 块从技能副本原样保留）；
  2. 两个生成器的产物路径改用 `extract_deps.ROOT` 拼；
  3. docstring 里「用法：」写成「用法（在仓库里执行）：」，并在末尾加一行「技能副本、两处要同步」的提示。

用法（在仓库里执行）：
    python3 sync_from_repo.py             # 同步三份脚本
    python3 sync_from_repo.py --check     # 只检查是否需要同步（等价于 check_sync.py）
    FOUNTAIN_ROOT=/path/to/fountain python3 sync_from_repo.py
"""
import argparse
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
FILES = ['extract_deps.py', 'gen_layered_svg.py', 'gen_matrix_svg.py']
OUTS = ['module-dependencies.svg', 'module-dependency-matrix.svg']
NOTE = ('注：本文件是技能自带副本，与仓库内 `docs/模块依赖图/{name}` 同源'
        '（副本按 FOUNTAIN_ROOT > git 仓库根 > 当前目录推断仓库根，仓库版按脚本位置推断）。'
        '改依赖判定 / 生成逻辑时两处要同步。')


def repo_root():
    env = os.environ.get('FOUNTAIN_ROOT')
    if env:
        return os.path.abspath(env)
    try:
        out = subprocess.run(['git', 'rev-parse', '--show-toplevel'], capture_output=True,
                             text=True, check=True, cwd=os.getcwd()).stdout.strip()
        if out:
            return os.path.abspath(out)
    except Exception:
        pass
    return os.path.abspath(os.getcwd())


def to_skill_form(repo_text, name, root_block):
    """仓库版 → 技能副本（补上有意差异）。"""
    t = repo_text
    if name == 'extract_deps.py':
        t = t.replace(
            "ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..'))\n",
            root_block)
        t = t.replace('import re\nimport sys', 'import re\nimport subprocess\nimport sys')
    for out in OUTS:
        t = t.replace(
            f"HERE = os.path.dirname(os.path.abspath(__file__))\n"
            f"OUT = os.path.abspath(os.path.join(HERE, '..', '..', '.assets', 'README', '{out}'))\n",
            f"OUT = os.path.abspath(os.path.join(extract_deps.ROOT, '.assets', 'README', '{out}'))\n")
    t = t.replace('用法：python3 ', '用法（在仓库里执行）：python3 ')
    t = t.replace('用法：\n    python3 extract_deps.py', '用法（在仓库里执行）：\n    python3 extract_deps.py')
    t = t.replace('\n"""\n', '\n\n' + NOTE.format(name=name) + '\n"""\n', 1)
    return t


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument('--check', action='store_true', help='只检查是否同源，不写文件')
    ap.add_argument('--root', default=None, help='仓库根（默认 FOUNTAIN_ROOT > git 仓库根 > 当前目录）')
    args = ap.parse_args()
    root = os.path.abspath(args.root) if args.root else repo_root()
    repo_deps = os.path.join(root, 'docs', '模块依赖图')
    print(f'仓库根 = {root}\n仓库版 = {repo_deps}\n技能副本 = {HERE}\n')

    # 技能副本里已有的 _default_root 块要原样保留（仓库版没有这段）
    skill_extract = os.path.join(HERE, 'extract_deps.py')
    m = re.search(r'\ndef _default_root\(\):.*?\nROOT = _default_root\(\)\n',
                  open(skill_extract, encoding='utf-8').read(), re.S) if os.path.exists(skill_extract) else None
    if not m:
        print('✗ 技能副本里没有 _default_root 块，无法安全同步 —— 手工处理一下')
        return 1
    root_block = m.group(0).lstrip('\n')

    changed = []
    for name in FILES:
        rp, sp = os.path.join(repo_deps, name), os.path.join(HERE, name)
        if not os.path.exists(rp):
            print(f'{name:22s} ? 仓库版不存在，跳过')
            continue
        want = to_skill_form(open(rp, encoding='utf-8').read(), name, root_block)
        old = open(sp, encoding='utf-8').read() if os.path.exists(sp) else ''
        if want == old:
            print(f'{name:22s} 已是最新')
            continue
        changed.append(name)
        if args.check:
            print(f'{name:22s} ✗ 需要同步')
            continue
        open(sp, 'w', encoding='utf-8', newline='\n').write(want)
        print(f'{name:22s} 已同步（{len(want)} bytes）')

    if changed and not args.check:
        print('\n下一步：跑 check_sync.py --run 核对源码同源且两张 SVG 与仓库版产物一致。')
    return 1 if (changed and args.check) else 0


if __name__ == '__main__':
    sys.exit(main())
