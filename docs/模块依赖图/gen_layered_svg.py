#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""生成 fountain 模块依赖关系（分层连线）SVG。

可读性设计：
- 分层布局（level = 到汇点的最长路径）+ 行内重心法排序降交叉，节点间距放大；
- 依赖分两类：结构性依赖（无法由其它依赖间接到达）画实线并按来源模块配色，
  冗余直达（可由其它依赖间接到达，但 cjpm.toml 仍声明了）画淡虚线退到背景；
- 出/入边锚点沿节点边分散，避免「一点引出一束线」；
- 每条边带 <title>，节点悬停时高亮它的直连（CSS，被剥离也不影响静态观感）。

用法：python3 gen_layered_svg.py [输出路径]
"""
import os
import sys
import xml.etree.ElementTree as ET

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import extract_deps                                   # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.abspath(os.path.join(HERE, '..', '..', '.assets', 'README', 'module-dependencies.svg'))

HUB = 10                                               # 入度达到该值 → 高亮
NW, NH = 132, 34                                       # 节点尺寸
HGAP, VGAP = 36, 102                                   # 行内间隙 / 层间距
MARGIN_X, HEAD = 30, 158
PALETTE = ['#2563eb', '#db2777', '#ea580c', '#059669', '#7c3aed', '#0891b2',
           '#ca8a04', '#dc2626', '#4f46e5', '#16a34a', '#c026d3', '#0d9488']

nodes, deps = extract_deps.graph()
edges = sum(len(v) for v in deps.values())

# ---- 分层 ----
level = {}


def lvl(n):
    if n not in level:
        level[n] = 0 if not deps[n] else 1 + max(lvl(d) for d in deps[n])
    return level[n]


for n in nodes:
    lvl(n)
maxl = max(level.values())
rows = [[n for n in nodes if level[n] == L] for L in range(maxl + 1)]

indeg = {n: 0 for n in nodes}
for n in nodes:
    for d in deps[n]:
        indeg[d] += 1

# ---- 传递可达 → 结构性依赖（传递归约）----
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

# ---- 行内排序：重心法多轮扫 ----
pos = {}
for row in rows:
    for i, n in enumerate(row):
        pos[n] = i


def reorder(row, ref_key):
    keyed = []
    for n in row:
        refs = [pos[m] for m in ref_key(n) if m in pos]
        keyed.append((sum(refs) / len(refs) if refs else pos[n], pos[n], n))
    keyed.sort()
    return [n for _, _, n in keyed]


for _ in range(8):
    for L in range(1, maxl + 1):
        rows[L] = reorder(rows[L], lambda n: deps[n])
        for i, n in enumerate(rows[L]):
            pos[n] = i
    for L in range(maxl - 1, -1, -1):
        rows[L] = reorder(rows[L], lambda n: [m for m in nodes if n in deps[m]])
        for i, n in enumerate(rows[L]):
            pos[n] = i

# ---- 坐标 ----
row_w = [len(r) * NW + (len(r) - 1) * HGAP for r in rows]
W = max(row_w) + MARGIN_X * 2
H = HEAD + (maxl + 1) * NH + maxl * (VGAP - NH) + 30
xy = {}
for L, row in enumerate(rows):
    offset = (W - row_w[L]) / 2
    y = HEAD + (maxl - L) * VGAP
    for i, n in enumerate(row):
        xy[n] = (offset + i * (NW + HGAP), y)

# ---- 配色：与矩阵图同一条规则（按 (层级, 名字) 排序后轮流取色）----
color = {}
for i, n in enumerate(sorted(nodes, key=lambda x: (level[x], x))):
    color[n] = PALETTE[i % len(PALETTE)]
cidx = {c: i for i, c in enumerate(PALETTE)}

# ---- 边锚点：沿节点底边/顶边均匀分散 ----
out_order = {n: sorted(deps[n], key=lambda d: xy[d][0]) for n in nodes}
in_order = {n: sorted([m for m in nodes if n in deps[m]], key=lambda m: xy[m][0]) for n in nodes}


def anchors(n, lst, bottom):
    k = len(lst)
    span = NW - 26
    base_y = xy[n][1] + (NH if bottom else 0)
    return [(other, xy[n][0] + 13 + span * (i + 0.5) / k, base_y) for i, other in enumerate(lst)]


src_anchor = {n: anchors(n, out_order[n], True) for n in nodes if out_order[n]}
dst_anchor = {n: anchors(n, in_order[n], False) for n in nodes if in_order[n]}
dst_index = {n: {o: i for i, (o, _, _) in enumerate(dst_anchor[n])} for n in dst_anchor}


def crossings(row_above, row_below):
    segs = [(pos[a], pos[d]) for a in row_above for d in deps[a] if d in row_below]
    return sum(1 for i in range(len(segs)) for j in range(i + 1, len(segs))
               if (segs[i][0] - segs[j][0]) * (segs[i][1] - segs[j][1]) < 0)


cross = sum(crossings(rows[L + 1], rows[L]) for L in range(maxl))

# ---- SVG ----
F = "font-family=\"'Segoe UI', Roboto, 'Helvetica Neue', Arial, sans-serif\""
o = [f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W:.0f} {H:.0f}" width="100%" '
     'role="img" aria-label="fountain module dependencies">',
     '<title>fountain 模块依赖关系 / module dependencies</title>',
     '<defs>' + ''.join(
         f'<marker id="a{i}" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="3.8" markerHeight="3.8" '
         f'orient="auto"><path d="M0,0 L10,5 L0,10 z" fill="{c}"/></marker>'
         for i, c in enumerate(PALETTE)) + '</defs>',
     '<style>',
     'text{user-select:none}',
     'g.n:hover>rect{stroke-width:2.6}',
     'svg:has(g.n:hover) g.e>path{stroke-opacity:.05}',
     'svg:has(g.n:hover) g.e[data-struct="1"]>path{stroke-opacity:.95;stroke-width:2.6}']
for n in nodes:
    o.append(f'svg:has(#nd-{n}:hover) g.e[data-src="{n}"][data-struct="1"]>path,'
             f'svg:has(#nd-{n}:hover) g.e[data-dst="{n}"][data-struct="1"]>path'
             '{stroke-opacity:.95;stroke-width:2.6}')
    o.append(f'svg:has(#nd-{n}:hover) g.e[data-src="{n}"][data-struct="0"]>path,'
             f'svg:has(#nd-{n}:hover) g.e[data-dst="{n}"][data-struct="0"]>path'
             '{stroke-opacity:.55;stroke-width:1.4}')
o.append('</style>')

o.append(f'<rect x="0" y="0" width="{W:.0f}" height="{H:.0f}" fill="#ffffff"/>')
o.append(f'<text x="{MARGIN_X}" y="32" {F} font-size="18" font-weight="600" fill="#0f172a">'
         'fountain 模块依赖关系 / module dependencies</text>')
o.append(f'<text x="{MARGIN_X}" y="56" {F} font-size="12.5" fill="#64748b">'
         f'箭头 A → B：A 依赖 B（A depends on B）｜{len(nodes)} 个模块 / {edges} 条直连'
         f'（结构性 {len(structural)} 条、冗余直达 {redundant} 条）｜不含 fdemo、fcoder、frpcdemo 等示例应用</text>')
o.append(f'<text x="{MARGIN_X}" y="76" {F} font-size="12.5" fill="#64748b">'
         '实线＝结构性依赖（无法由其它依赖间接到达），按来源模块配色：同色 = 同一模块的依赖</text>')
o.append(f'<text x="{MARGIN_X}" y="96" {F} font-size="12.5" fill="#64748b">'
         '虚线＝冗余直达（可由其它依赖间接到达，cjpm.toml 仍声明了它）；悬停节点可高亮它的全部直连</text>')

legend = [('#dbeafe', '#60a5fa', '被依赖 ≥ 10 次 (hub)'), ('#dcfce7', '#86efac', '基础层：无依赖 (foundation)'),
          ('#f8fafc', '#cbd5e1', '其它模块 (others)')]


def tw(s):
    return sum(13 if ord(c) > 0x2E80 else 6.8 for c in s)


lx = MARGIN_X
for fill, stroke, label in legend:
    o.append(f'<rect x="{lx:.0f}" y="112" width="13" height="13" rx="3" fill="{fill}" stroke="{stroke}"/>')
    o.append(f'<text x="{lx + 19:.0f}" y="123" {F} font-size="12.5" fill="#475569">{label}</text>')
    lx += 19 + tw(label) + 28
o.append(f'<path d="M{MARGIN_X},{136} h34" stroke="#2563eb" stroke-width="1.7" fill="none" '
         'marker-end="url(#a0)"/>')
o.append(f'<text x="{MARGIN_X + 42}" y="140" {F} font-size="12.5" fill="#475569">'
         f'结构性依赖 {len(structural)} 条</text>')
o.append(f'<path d="M{MARGIN_X + 152},{136} h34" stroke="#94a3b8" stroke-width="1" fill="none" '
         'stroke-dasharray="2 3" stroke-opacity="0.5"/>')
o.append(f'<text x="{MARGIN_X + 194}" y="140" {F} font-size="12.5" fill="#475569">'
         f'冗余直达 {redundant} 条</text>')

# 边：先画冗余直达（背景），再画结构性依赖（前景）
for kind in (0, 1):
    for n in sorted(nodes, key=lambda x: -level[x]):
        for (d, sx, sy) in src_anchor.get(n, []):
            if ((n, d) in structural) != (kind == 1):
                continue
            tx, ty = dst_anchor[d][dst_index[d][n]][1], dst_anchor[d][dst_index[d][n]][2]
            if abs(sx - tx) < 1:
                path = f'M{sx:.1f},{sy:.1f} L{tx:.1f},{ty:.1f}'
            else:
                my = (sy + ty) / 2
                path = f'M{sx:.1f},{sy:.1f} C{sx:.1f},{my:.1f} {tx:.1f},{my:.1f} {tx:.1f},{ty:.1f}'
            title = (f'<title>{n} → {d}（{n} 依赖 {d} / {n} depends on {d}）'
                     + ('' if (n, d) in structural else '；冗余直达：也可由其它依赖间接到达') + '</title>')
            if (n, d) in structural:
                span = level[n] - level[d]
                op = 0.8 if span <= 3 else (0.55 if span <= 6 else 0.35)
                o.append(f'<g class="e" data-struct="1" data-src="{n}" data-dst="{d}">{title}'
                         f'<path d="{path}" fill="none" stroke="{color[n]}" stroke-width="1.7" '
                         f'stroke-opacity="{op}" marker-end="url(#a{cidx[color[n]]})"/></g>')
            else:
                o.append(f'<g class="e" data-struct="0" data-src="{n}" data-dst="{d}">{title}'
                         f'<path d="{path}" fill="none" stroke="#94a3b8" stroke-width="1" '
                         'stroke-opacity="0.2" stroke-dasharray="2 3"/></g>')

# 节点
for n in nodes:
    x, y = xy[n]
    if indeg[n] >= HUB:
        fill, stroke, tcolor, weight = '#dbeafe', '#60a5fa', '#1d4ed8', '600'
    elif not deps[n]:
        fill, stroke, tcolor, weight = '#dcfce7', '#86efac', '#166534', '600'
    else:
        fill, stroke, tcolor, weight = '#f8fafc', '#cbd5e1', '#334155', '500'
    n_struct = sum(1 for d in deps[n] if (n, d) in structural)
    o.append(f'<g class="n" id="nd-{n}"><title>{n}：被 {indeg[n]} 个模块依赖；自身直连 {len(deps[n])} 个'
             f'（结构性 {n_struct} 个、冗余 {len(deps[n]) - n_struct} 个）</title>'
             f'<rect x="{x:.1f}" y="{y:.1f}" width="{NW}" height="{NH}" rx="8" fill="{fill}" '
             f'stroke="{stroke}" stroke-width="1.3"/>'
             f'<rect x="{x + 6:.1f}" y="{y + NH - 5:.1f}" width="{NW - 12}" height="4" rx="2" '
             f'fill="{color[n]}" stroke="none" opacity="0.9"/>'
             f'<text x="{x + NW / 2:.1f}" y="{y + NH / 2 + 3.5:.1f}" {F} font-size="13" '
             f'font-weight="{weight}" fill="{tcolor}" text-anchor="middle">{n}</text></g>')

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

print(f'layered: nodes={len(nodes)} direct={edges} structural={len(structural)} redundant={redundant} '
      f'levels={maxl + 1} canvas={W:.0f}x{H:.0f} crossings={cross} size={os.path.getsize(OUT)} out={OUT}')
print('header overflow:', over if over else 'none')
dup = [(a, b) for a in nodes for b in nodes if a < b
       if abs(xy[a][0] - xy[b][0]) < NW and abs(xy[a][1] - xy[b][1]) < NH]
print('overlaps:', dup if dup else 'none')
