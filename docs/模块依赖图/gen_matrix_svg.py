#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""生成 fountain 模块依赖矩阵 SVG（行 = 依赖方，列 = 被依赖方）。

两轴按同一顺序（依赖层级从基础到上层）排列 ⇒ 依赖只出现在对角线右上侧；
实心格 = 结构性依赖（无法由其它依赖间接到达），浅色格 = 冗余直达。
查询场景用它更快："某模块依赖了谁"看一行，"谁依赖了某模块"看一列。

用法：python3 gen_matrix_svg.py [输出路径]
"""
import os
import sys
import xml.etree.ElementTree as ET

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import extract_deps                                   # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.abspath(os.path.join(HERE, '..', '..', '.assets', 'README', 'module-dependency-matrix.svg'))

CELL, PITCH = 16, 18                                   # 格子尺寸 / 格距
LEFT, TOP = 116, 132                                   # 行标签宽 / 列标签高
HEAD = 122                                             # 页眉高
MARGIN = 26
PALETTE = ['#2563eb', '#db2777', '#ea580c', '#059669', '#7c3aed', '#0891b2',
           '#ca8a04', '#dc2626', '#4f46e5', '#16a34a', '#c026d3', '#0d9488']

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

# 传递可达 → 结构性依赖
reach = {}


def rch(n):
    if n not in reach:
        r = set()
        for d in deps[n]:
            r.add(d)
            r |= rch(d)
        reach[n] = r
    return reach[n]


for n in nodes:
    rch(n)
structural = {(n, d) for n in nodes for d in deps[n]
              if not any(d in reach[o] for o in deps[n] if o != d)}
redundant = edges - len(structural)

# 两轴同一顺序：层级升序（基础层在上/左）⇒ 依赖落在右上三角
order = sorted(nodes, key=lambda n: (level[n], n))
idx = {n: i for i, n in enumerate(order)}
indeg = {n: sum(1 for m in nodes if n in deps[m]) for n in nodes}
color = {n: PALETTE[i % len(PALETTE)] for i, n in enumerate(order)}

GW = GH = len(order) * PITCH
W = MARGIN + LEFT + GW + MARGIN
H = HEAD + TOP + GH + MARGIN + 8

F = "font-family=\"'Segoe UI', Roboto, 'Helvetica Neue', Arial, sans-serif\""
o = [f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W:.0f} {H:.0f}" width="100%" '
     'role="img" aria-label="fountain module dependency matrix">',
     '<title>fountain 模块依赖矩阵 / module dependency matrix</title>',
     '<style>',
     'text{user-select:none}',
     'rect.c:hover{stroke:#0f172a;stroke-width:1.6}',
     '</style>',
     f'<rect x="0" y="0" width="{W:.0f}" height="{H:.0f}" fill="#ffffff"/>',
     f'<text x="{MARGIN}" y="32" {F} font-size="18" font-weight="600" fill="#0f172a">'
     'fountain 模块依赖矩阵 / module dependency matrix</text>',
     f'<text x="{MARGIN}" y="56" {F} font-size="12.5" fill="#64748b">'
     f'行 = 依赖方（行依赖列），列 = 被依赖方；两轴同一顺序：按依赖层级从基础（左上）到上层（右下）。'
     f'依赖只出现在对角线右上侧</text>',
     f'<text x="{MARGIN}" y="76" {F} font-size="12.5" fill="#64748b">'
     f'{len(nodes)} 个模块 / {edges} 条直连（结构性 {len(structural)}、冗余直达 {redundant}）；'
     '格子的颜色 = 依赖方的颜色，与连线图一致</text>',
     f'<text x="{MARGIN}" y="96" {F} font-size="12.5" fill="#64748b">'
     '实心格 = 结构性依赖；浅色格 = 冗余直达（可由其它依赖间接到达，cjpm.toml 仍声明了它）；'
     '不含 fdemo、fcoder、frpcdemo 等示例应用</text>',
     f'<text x="{MARGIN}" y="116" {F} font-size="12.5" fill="#64748b">'
     '底行数字 = 被依赖次数；加粗标签 = 被依赖 ≥ 10 次；悬停格子显示「依赖方 → 被依赖方」</text>']

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

# 格子：先冗余（浅）后结构性（实心）
for kind in (0, 1):
    for n in order:
        for d in deps[n]:
            if ((n, d) in structural) != (kind == 1):
                continue
            r, c = idx[n], idx[d]
            x = gx0 + c * PITCH + 1
            y = gy0 + r * PITCH + 1
            is_s = (n, d) in structural
            op = '0.95' if is_s else '0.22'
            o.append(f'<rect class="c" x="{x}" y="{y}" width="{CELL}" height="{CELL}" rx="3" '
                     f'fill="{color[n]}" fill-opacity="{op}" stroke="#ffffff" stroke-width="0.5">'
                     f'<title>{n} 依赖 {d}（{d} 是 {n} 的'
                     f'{"结构性依赖" if is_s else "冗余直达：可由其它依赖间接到达"}）</title></rect>')

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
    if not t.text or float(t.get('y', '0')) > HEAD:
        continue
    fs = float(t.get('font-size', '12.5'))
    w = sum(fs * (1.04 if ord(c) > 0x2E80 else 0.55) for c in t.text)
    if float(t.get('x', '0')) + w > W - 8:
        over.append((t.text[:36], round(float(t.get('x', '0')) + w)))

print(f'matrix: {len(order)}x{len(order)} direct={edges} structural={len(structural)} '
      f'redundant={redundant} canvas={W:.0f}x{H:.0f} size={os.path.getsize(OUT)} out={OUT}')
print('header overflow:', over if over else 'none')
