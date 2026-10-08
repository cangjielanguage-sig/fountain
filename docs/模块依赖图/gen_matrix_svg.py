#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""生成 fountain 模块依赖矩阵 SVG（行 = 依赖方，列 = 被依赖方）。

两轴按同一顺序（依赖层级从基础到上层）排列 ⇒ 依赖只出现在对角线右上侧；
格子 = 「cjpm.toml 声明了、且 src/ 里 import 了对方 API」的直接依赖（口径见 extract_deps.py），
声明了但源码未引用对方 API 的、以及间接可达关系都不画。
每行里 API 引用量**前三**的依赖画彩色格（色相 = 依赖方、深浅 = 引用量），其余画浅灰格 ——
与连线图的「彩色实线 / 灰色虚线」同一规则（见 extract_deps.top_edges）。
查询场景用它更快："某模块依赖了谁"看一行，"谁依赖了某模块"看一列。

用法：python3 gen_matrix_svg.py [输出路径]
"""
import math
import os
import sys
import xml.etree.ElementTree as ET

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import extract_deps                                   # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.abspath(os.path.join(HERE, '..', '..', '.assets', 'README', 'module-dependency-matrix.svg'))

CELL, PITCH = 16, 18                                   # 格子尺寸 / 格距
LEFT, TOP = 116, 132                                   # 行标签宽 / 列标签高
HEAD = 168                                             # 页眉高（标题 + 3 组双语说明）
MARGIN = 26
LEVELS = 6                                             # API 引用量的深浅档数（与连线图一致）

nodes, deps = extract_deps.graph()
edges = sum(len(v) for v in deps.values())

# 分层（同 gen_layered_svg.py）：level = 到汇点的最长路径
level = {}


def lvl(n):
    if n not in level:
        level[n] = 0 if not deps[n] else 1 + max(lvl(d) for d in deps[n])
    return level[n]


for n in nodes:
    lvl(n)

# 声明 / 已引用统计（格子已在 extract_deps.graph() 里按「声明且引用 API」过滤）
declared, used, unused_edges = extract_deps.summary()

# ---- API 引用量（决定格子深浅）与模块色相（每个模块一个，不重复；与连线图同序同色）----
usage = extract_deps.api_usage()
UMIN = min(usage.values()) if usage else 1
UMAX = max(usage.values()) if usage else 1


def u_of(pair):
    return usage.get(pair, 1)


def shade_of(u):
    t = math.log1p(u) / math.log1p(UMAX) if UMAX > 1 else 1.0
    return min(LEVELS - 1, int(t * LEVELS))


def pair_hex(a, pair):
    return extract_deps.shade_hex(hue[a], (shade_of(u_of(pair)) + 0.5) / LEVELS)


TOPK = 3
MAIN = extract_deps.top_edges(TOPK)                  # 每行 API 引用量前三的依赖（彩色格），其余浅灰
main_edges = sum(len(v) for v in MAIN.values())
PALE = '#e2e8f0'

# 两轴同一顺序：层级升序（基础层在上/左）⇒ 依赖落在右上三角
order = sorted(nodes, key=lambda n: (level[n], n))
idx = {n: i for i, n in enumerate(order)}
indeg = {n: sum(1 for m in nodes if n in deps[m]) for n in nodes}
hue = extract_deps.hues(order)                         # 与连线图同一套色（同序 ⇒ 同色）

GW = GH = len(order) * PITCH
W = MARGIN + LEFT + GW + MARGIN
H = HEAD + TOP + GH + MARGIN + 8

F = "font-family=\"'Segoe UI', Roboto, 'Helvetica Neue', Arial, sans-serif\""
o = [f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W:.0f} {H:.0f}" width="100%" '
     'role="img" aria-label="fountain module dependency matrix">',
     '<title>fountain 模块依赖矩阵 / Module dependency matrix</title>',
     '<style>',
     'text{user-select:none}',
     'rect.c:hover{stroke:#0f172a;stroke-width:1.6}',
     '</style>',
     f'<rect x="0" y="0" width="{W:.0f}" height="{H:.0f}" fill="#ffffff"/>',
     f'<text x="{MARGIN}" y="32" {F} font-size="18" font-weight="600" fill="#0f172a">'
     'fountain 模块依赖矩阵 / Module dependency matrix</text>']


def note(y, zh, en):
    """一组双语说明：中文一行（深）、英文一行（浅），返回下一组的 y。"""
    o.append(f'<text x="{MARGIN}" y="{y}" {F} font-size="12.5" fill="#475569">{zh}</text>')
    o.append(f'<text x="{MARGIN}" y="{y + 16}" {F} font-size="11.5" fill="#94a3b8">{en}</text>')
    return y + 38


yy = note(56,
          '行 = 依赖方，列 = 被依赖方；两轴同一顺序（按依赖层级：基础层在左上）⇒ 依赖只落在对角线右上侧',
          'Rows are dependents, columns are dependencies; both axes share one order (foundation top-left) '
          '⇒ all cells sit above the diagonal')
yy = note(yy,
          f'{len(nodes)} 个模块 / {edges} 条依赖（都是「已声明且源码里 import 了对方 API」）；'
          f'声明了但未引用对方 API 的 {len(unused_edges)} 条、间接可达关系都不画；不含示例应用',
          f'{len(nodes)} modules / {edges} dependencies (each imports the required API); '
          f'{len(unused_edges)} declared-but-unused edges are not drawn; demo apps excluded')
yy = note(yy,
          f'彩色格 = 该行 API 引用量前三的依赖（{main_edges} 格；色相 = 依赖方、深浅 = 引用量）；'
          f'浅灰格 = 其余依赖（{edges - main_edges} 格）；底行数字 = 被依赖次数',
          f'Colored cells = the 3 most-called deps of that row ({main_edges}); pale = the rest '
          f'({edges - main_edges}); bottom numbers = in-degree')

# 左下三角（结构上不可能有依赖）铺一层浅底
gx0, gy0 = MARGIN + LEFT, HEAD + TOP
o.append(f'<path d="M{gx0},{gy0 + GH} L{gx0 + GW},{gy0 + GH} L{gx0 + GW},{gy0} Z" '
         'fill="#f1f5f9" stroke="none"/>')

# 网格（每 5 格加深）
for i in range(len(order) + 1):
    w = 1.2 if i % 5 == 0 else 0.6
    c = '#cbd5e1' if i % 5 == 0 else '#e2e8f0'
    o.append(f'<path d="M{gx0 + i * PITCH},{gy0} v{GH}" stroke="{c}" stroke-width="{w}"/>')
    o.append(f'<path d="M{gx0},{gy0 + i * PITCH} h{GW}" stroke="{c}" stroke-width="{w}"/>')

# 格子：「声明且引用对方 API」的直接依赖；引用量前三 → 依赖方色相（深浅 = 引用量），其余 → 浅灰
for n in order:
    for d in deps[n]:
        r, c = idx[n], idx[d]
        x = gx0 + c * PITCH + 1
        y = gy0 + r * PITCH + 1
        cnt = u_of((n, d))
        if d in MAIN[n]:
            fill, note_zh, note_en = (pair_hex(n, (n, d)), f'引用 {cnt:g} 次（前三）',
                                      f'{cnt:g} API references (top {TOPK})')
        else:
            fill, note_zh, note_en = (PALE, f'引用 {cnt:g} 次（未进前三）',
                                      f'{cnt:g} API references (not in top {TOPK})')
        o.append(f'<rect class="c" x="{x}" y="{y}" width="{CELL}" height="{CELL}" rx="3" '
                 f'fill="{fill}" stroke="#ffffff" stroke-width="0.5">'
                 f'<title>{n} 依赖 {d}（直接依赖，源码里已引用对方 API，{note_zh}）\n'
                 f'{n} depends on {d} (direct dependency, {note_en})</title></rect>')

# 行标签（左）+ 列标签（上，竖排）
for n in order:
    bold = ' font-weight="700"' if indeg[n] >= 10 else ''
    o.append(f'<text x="{gx0 - 8}" y="{gy0 + idx[n] * PITCH + CELL / 2 + 4:.1f}" {F} font-size="11.5" '
             f'fill="#334155" text-anchor="end"{bold}>{n}</text>')
    o.append(f'<text x="{gx0 + idx[n] * PITCH + CELL / 2 + 4:.1f}" y="{gy0 - 10}" {F} font-size="11.5" '
             f'fill="#334155" text-anchor="start" transform="rotate(-90 {gx0 + idx[n] * PITCH + CELL / 2 + 4:.1f} '
             f'{gy0 - 10})"{bold}>{n}</text>')
    o.append(f'<text x="{gx0 + idx[n] * PITCH + CELL / 2:.1f}" y="{gy0 + GH + 16}" {F} font-size="10" '
             f'fill="#94a3b8" text-anchor="middle">{indeg[n]}</text>')

o.append('</svg>')
open(OUT, 'w', encoding='utf-8').write('\n'.join(o) + '\n')
root = ET.parse(OUT).getroot()
NS = '{http://www.w3.org/2000/svg}'
over = []
for t in root.iter(NS + 'text'):
    if not t.text:
        continue
    ty, tx = float(t.get('y', '0')), float(t.get('x', '0'))
    fs = float(t.get('font-size', '12.5'))
    if ty <= HEAD:                                   # 页眉里的文字：横向不能超出画布、纵向不能压进标签区
        w = sum(fs * (1.04 if ord(c) > 0x2E80 else 0.55) for c in t.text)
        if tx + w > W - 8:
            over.append(('宽 ' + t.text[:30], round(tx + w)))
        if ty > HEAD - 12:
            over.append(('低 ' + t.text[:30], round(ty)))

print(f'matrix: {len(order)}x{len(order)} edges={edges} declared={declared} used={used} '
      f'unused={len(unused_edges)} main={main_edges} usage={UMIN:g}..{UMAX:g} shades={LEVELS} '
      f'canvas={W:.0f}x{H:.0f} size={os.path.getsize(OUT)} out={OUT}')
print('header overflow:', over if over else 'none')
clash = [(a, b) for a in order for b in order if a < b and round(hue[a], 3) == round(hue[b], 3)]
print(f'colors unique: {"yes" if not clash else clash}（{len(set(hue.values()))} 个色相 / {len(nodes)} 个模块）')
