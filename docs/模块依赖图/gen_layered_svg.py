#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""生成 fountain 模块依赖关系（分层连线）SVG。

可读性设计（都是为了「疏朗、少交叉」）：
- 分层布局（level = 到汇点的最长路径）；节点宽度按最长模块名自适应（NW），
  节点高 / 字号 / 行内间隙 HGAP / 层间距 VGAP 都在顶部常量里，线宽 1.2（细线才不糊）；
- 行内布局：节点少的行把省下的横向空间摊到间距里（上限 MAX_HGAP），并叠加「行级横向错位」
  （optimize_shifts 逐行试几个偏移量取交叉数最小者，把竖向走廊错开；错位量夹在画布内）；
- 行内排序 = 多起点「重心法 + 相邻交换」局部搜索，目标函数 = 交叉数：沿与最终 SVG 完全相同的
  路径按 band 像素取 x，统计相邻取样间顺序翻转的对数（路径 y 单调 ⇒ 翻转一次 = 相交一次）；
  固定随机种子，重跑产物一致；
- **跨层长边避让路由**：span > 1 的边在中间每一层都要落在「该层节点之间的空隙」或行两端外侧
  （channel_x 挑通道，尽量贴着它本来的走向，同一空隙内多条边按横向均匀铺开），于是线不会压到
  任何节点框（斜向交叉可以接受）；通道内是竖直段（L），行间过渡用控制点在竖直中点的贝塞尔（C）；
  自检 `node crossings` 会逐条采样复核，必须为 none；
- 边 = 「cjpm.toml 声明了、且 src/ 里 import 了对方 API」的直接依赖（口径见 extract_deps.py），
  一律画实线；声明了但源码未引用对方 API 的、以及间接可达关系都不画；
- 配色：每个模块一个不重复的色相（黄金角散布，43 个模块互不撞色），边的深浅 = 该模块对
  该依赖的 API 引用量（越多越深，log 归一后分 6 档；引用量口径见 extract_deps.api_usage）；
- 边的两种画法：该模块 API 调用次数**前三**的依赖 → 彩色实线；其余依赖 → 灰色虚线（照旧参与
  避让路由与交叉统计，只是退成背景；次数相同时按模块名定序，保证产物可复现）；
- 出/入边锚点沿节点边分散，避免「一点引出一束线」；
- 每条边带 <title>，节点悬停时高亮它的直连（CSS，被剥离也不影响静态观感）。

用法：python3 gen_layered_svg.py [输出路径]
"""
import math
import os
import random
import sys
import xml.etree.ElementTree as ET

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import extract_deps                                   # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.abspath(os.path.join(HERE, '..', '..', '.assets', 'README', 'module-dependencies.svg'))

HUB = 10                                               # 入度达到该值 → 高亮
NH, NODE_FONT = 30, 13                                 # 节点高 / 节点里模块名的字号
HGAP, MAX_HGAP, VGAP = 96, 210, 150                    # 行内间隙（下限/上限）/ 层间距；节点少的行摊得更开
MARGIN_X = 30
NOTE_TOP, NOTE_STEP, N_NOTES = 58, 38, 5            # 页眉：双语说明的起始 y、每组占高、组数
HEAD = NOTE_TOP + N_NOTES * NOTE_STEP + 72          # 页眉总高：标题 + N 组说明 + 图例行
LEVELS = 6                                          # API 引用量的深浅档数（1 档最浅、6 档最深）

nodes, deps = extract_deps.graph()
edges = sum(len(v) for v in deps.values())

# 节点宽度按最长模块名自适应（左右各留 14px 内边距，取偶）——比固定 132 省掉大片空白，
# 省下来的横向空间让连线更舒展。
NW = max(96, 2 * round((max(sum(NODE_FONT * (1.04 if ord(c) > 0x2E80 else 0.55)
                              for c in n) for n in nodes) + 28) / 2))

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

# ---- 声明 / 已引用统计（边集已在 extract_deps.graph() 里按「声明且引用 API」过滤）----
declared, used, unused_edges = extract_deps.summary()

# ---- API 引用量（决定边的深浅）与模块色相（每个模块一个，不重复）----
usage = extract_deps.api_usage()
UMIN = min(usage.values()) if usage else 1
UMAX = max(usage.values()) if usage else 1
hue = extract_deps.hues(sorted(nodes, key=lambda x: (level[x], x)))
color = {n: extract_deps.base_hex(hue[n]) for n in nodes}

# 每个模块「API 调用次数前三」的依赖 → 彩色实线；其余依赖 → 灰色虚线（规则见 extract_deps.top_edges）
TOPK = 3
MAIN = extract_deps.top_edges(TOPK)
main_edges = sum(len(v) for v in MAIN.values())


def u_of(pair):
    return usage.get(pair, 1)


def shade_of(u):
    """引用量 → 深浅档位：log 归一后分 LEVELS 档，0 最浅、LEVELS-1 最深。"""
    t = math.log1p(u) / math.log1p(UMAX) if UMAX > 1 else 1.0
    return min(LEVELS - 1, int(t * LEVELS))


def pair_hex(a, pair):
    return extract_deps.shade_hex(hue[a], (shade_of(u_of(pair)) + 0.5) / LEVELS)


# ---- 边锚点（沿节点上/下边均匀分散）与规范曲线（用于交叉数）----
def anchors_at(x, y, lst, bottom):
    """节点 (x, y) 处的一排锚点：出边沿底边、入边沿顶边均匀分散。"""
    k = len(lst)
    span = NW - 20
    base_y = y + (NH if bottom else 0)
    return [(other, x + 13 + span * (i + 0.5) / k, base_y) for i, other in enumerate(lst)]


# ---- 行内布局：每行按画布宽度摊开（行越窄、间距越大，上限 MAX_HGAP）+ 行级横向错位 ----
ROW_SHIFT = {}                      # 行级错位量（optimize_shifts 填）：把竖向走廊错开用


def row_layout(rows_):
    """返回 (每行左边距 offs, 每行间距 pitch, 画布宽 W_)。

    画布宽由最宽的一行（基础间距 HGAP）决定；节点少的行把省下的空间摊到间距里，
    再叠加行级错位 ROW_SHIFT，避免所有长边在正中间挤成一条竖直走廊。
    """
    counts = [len(r) for r in rows_]
    W_ = max(c * NW + max(0, c - 1) * HGAP for c in counts) + MARGIN_X * 2
    span = W_ - 2 * MARGIN_X
    offs, pitch = [], []
    for L, c in enumerate(counts):
        if c <= 1:
            row_w = NW
            gap = 0
        else:
            gap = min(MAX_HGAP, max(HGAP, (span - c * NW) / (c - 1)))
            row_w = c * NW + (c - 1) * gap
        base = (W_ - row_w) / 2
        shift = max(-(base - MARGIN_X / 2), min(W_ - MARGIN_X / 2 - row_w - base, ROW_SHIFT.get(L, 0)))
        offs.append(base + shift)                    # 错位量夹在画布内，别把节点挤出边界
        pitch.append(NW + gap)
    return offs, pitch, W_


def positions(rows_):
    p = {}
    for row in rows_:
        for i, n in enumerate(row):
            p[n] = i
    return p


def reorder(row, p, ref_key):
    keyed = []
    for n in row:
        refs = [p[m] for m in ref_key(n) if m in p]
        keyed.append((sum(refs) / len(refs) if refs else p[n], p[n], n))
    keyed.sort()
    return [n for _, _, n in keyed]


def barycenter(rows_, rounds=10):
    """重心法上下多轮扫：先按依赖（下层）位置排，再按被依赖（上层）位置排。"""
    rows_ = [list(r) for r in rows_]
    for _ in range(rounds):
        p = positions(rows_)
        for L in range(1, len(rows_)):
            rows_[L] = reorder(rows_[L], p, lambda n: deps[n])
            p = positions(rows_)
        for L in range(len(rows_) - 2, -1, -1):
            rows_[L] = reorder(rows_[L], p, lambda n: [m for m in nodes if n in deps[m]])
            p = positions(rows_)
    return rows_


CLR = 7                                              # 绕行时与节点框保持的横向净距


def row_boxes(rows_, offs, pitch):
    """每行节点的横向占位区间（按 x 排序）。"""
    return [sorted((offs[L] + i * pitch[L], offs[L] + i * pitch[L] + NW) for i in range(len(row)))
            for L, row in enumerate(rows_)]


def free_slots(boxes, L, W_):
    """行 L 上「不压节点」的自由横向区间：节点之间 + 行两端外侧（已扣净距）。"""
    bs = boxes[L]
    out = []
    if bs:
        out.append((MARGIN_X / 2, bs[0][0] - CLR))
        for (_l1, r1), (l2, _r2) in zip(bs, bs[1:]):
            out.append((r1 + CLR, l2 - CLR))
        out.append((bs[-1][1] + CLR, W_ - MARGIN_X / 2))
    else:
        out.append((MARGIN_X / 2, W_ - MARGIN_X / 2))
    return [(lo, hi) for lo, hi in out if hi - lo > 0.5]


def centers(rows_, offs, pitch):
    """{模块: (节点左边界 x, 该行 y)}。"""
    XY = {}
    for L, row in enumerate(rows_):
        for i, n in enumerate(row):
            XY[n] = (offs[L] + i * pitch[L] if len(row) > 1 else offs[L], HEAD + (maxl - L) * VGAP)
    return XY


def channel_x(rows_, offs, pitch, W_, XY):
    """给每条跨层长边在中间各层挑一条通道 x。

    通道只能落在该层的自由区间（节点间隙 / 行两端外侧）里，所以线不会压到节点框；
    每条边尽量贴着它本来的走向（自然 x 插值）选区间，同一区间内的多条边按自然 x 均匀铺开。
    """
    boxes = row_boxes(rows_, offs, pitch)
    slots = [free_slots(boxes, L, W_) for L in range(len(rows_))]
    want = {}
    for a in nodes:
        for b in deps[a]:
            la, lb = level[a], level[b]
            for L in range(lb + 1, la):
                tx = XY[a][0] + (XY[b][0] - XY[a][0]) * (la - L) / (la - lb)
                want.setdefault(L, []).append((tx, (a, b)))
    chan = {}
    for L, items in want.items():
        sl = slots[L]
        if not sl:
            continue
        buckets = [[] for _ in sl]
        for tx, key in items:
            k = min(range(len(sl)), key=lambda i: 0.0 if sl[i][0] <= tx <= sl[i][1]
                    else min(abs(tx - sl[i][0]), abs(tx - sl[i][1])))
            buckets[k].append((tx, key))
        for (lo, hi), bucket in zip(sl, buckets):
            bucket.sort()
            for j, (_tx, key) in enumerate(bucket):
                chan.setdefault(key, {})[L] = lo + (hi - lo) * (j + 0.5) / len(bucket)
    return chan


def route_points(a, b, XY, chan, p0=None, p1=None):
    """一条边的折线：源底边 → 中间各层通道（进/出各一个点，其间竖直穿过该层）→ 目标顶边。"""
    la, lb = level[a], level[b]
    pts = [p0 if p0 else (XY[a][0] + NW / 2, XY[a][1] + NH)]
    for L in range(la - 1, lb, -1):
        gx = chan.get((a, b), {}).get(L)
        if gx is None:
            continue
        y = HEAD + (maxl - L) * VGAP
        pts.append((gx, y))
        pts.append((gx, y + NH))
    pts.append(p1 if p1 else (XY[b][0] + NW / 2, XY[b][1]))
    return pts


def routes(rows_):
    """{边: 折线}，与最终 SVG 同一条路径（只差两端锚点在节点内的小偏移）。"""
    offs, pitch, W_ = row_layout(rows_)
    XY = centers(rows_, offs, pitch)
    chan = channel_x(rows_, offs, pitch, W_, XY)
    return {k: route_points(k[0], k[1], XY, chan)
            for k in [(a, b) for a in nodes for b in deps[a]]}


def path_d(pts):
    """折线 → SVG path：竖直段用 L，其余用控制点在竖直中点的三次贝塞尔（曲线不会超出两端 x 范围）。"""
    d = [f'M{pts[0][0]:.1f},{pts[0][1]:.1f}']
    for (x0, y0), (x1, y1) in zip(pts, pts[1:]):
        if abs(x1 - x0) < 1:
            d.append(f'L{x1:.1f},{y1:.1f}')
        else:
            my = (y0 + y1) / 2
            d.append(f'C{x0:.1f},{my:.1f} {x1:.1f},{my:.1f} {x1:.1f},{y1:.1f}')
    return ' '.join(d)


def crossings(rows_, band=32):
    """交叉数：沿边的避让折线每隔 band 像素取一次 x，统计相邻两次之间顺序翻转的对数。

    折线 y 单调，两条线顺序翻转一次 = 相交一次（斜向交叉就是这样数出来的）。
    """
    ps = routes(rows_)
    top = min(p[0][1] for p in ps.values())
    bot = max(p[-1][1] for p in ps.values())
    total = 0
    prev = {}
    y = top + band / 2
    while y < bot:
        cur = {}
        for k, pts in ps.items():
            if pts[0][1] <= y <= pts[-1][1]:
                for i in range(len(pts) - 1):
                    if pts[i][1] <= y <= pts[i + 1][1]:
                        dy = pts[i + 1][1] - pts[i][1]
                        cur[k] = pts[i][0] if dy <= 0 else (
                            pts[i][0] + (pts[i + 1][0] - pts[i][0]) * (y - pts[i][1]) / dy)
                        break
        common = [k for k in cur if k in prev]
        if len(common) > 1:
            rank = {k: i for i, k in enumerate(sorted(common, key=lambda k: prev[k]))}
            seq = [rank[k] for k in sorted(common, key=lambda k: cur[k])]
            m = len(common)
            tree = [0] * (m + 1)
            for k, v in enumerate(seq):                 # 逆序对数 = 本段翻转的对数
                i = v + 1
                s = 0
                j = i
                while j > 0:
                    s += tree[j]
                    j -= j & -j
                total += k - s
                j = i
                while j <= m:
                    tree[j] += 1
                    j += j & -j
        prev = cur
        y += band
    return total


def transpose(rows_, best, budget=150):
    """相邻交换局部搜索：同层内交换相邻两节点，几何交叉数下降才保留。"""
    rows_ = [list(r) for r in rows_]
    tries = 0
    improved = True
    while improved and tries < budget:
        improved = False
        for L in range(len(rows_)):
            for i in range(len(rows_[L]) - 1):
                rows_[L][i], rows_[L][i + 1] = rows_[L][i + 1], rows_[L][i]
                cur = crossings(rows_)
                tries += 1
                if cur < best:
                    best, improved = cur, True
                else:
                    rows_[L][i], rows_[L][i + 1] = rows_[L][i + 1], rows_[L][i]
                if tries >= budget:
                    break
            if tries >= budget:
                break
    return rows_, best, tries


seeds = [('原始顺序', [list(r) for r in rows]),
         ('入度降序', [sorted(r, key=lambda n: (-indeg[n], n)) for r in rows]),
         ('出度降序', [sorted(r, key=lambda n: (-len(deps[n]), n)) for r in rows])]
rnd = random.Random(20261008)                        # 固定种子 ⇒ 重跑产物一致
for _ in range(12):
    rs = [list(r) for r in rows]
    for r in rs:
        rnd.shuffle(r)
    seeds.append(('随机起点', rs))

cands = []
for tag, seed in seeds:
    cand = barycenter(seed)
    cands.append((crossings(cand), tag, cand))
cands.sort(key=lambda t: t[0])
best_rows, best_cross, best_tag, best_tries = None, None, '', 0
for c, tag, cand in cands[:3]:                       # 只对最好的 3 个起点做相邻交换
    cand2, c2, tries = transpose(cand, c)
    if best_cross is None or c2 < best_cross:
        best_rows, best_cross, best_tag, best_tries = cand2, c2, tag, tries
rows = best_rows


def optimize_shifts(rows_, best, ratios=(-0.34, -0.26, -0.18, -0.1, 0.0, 0.1, 0.18, 0.26, 0.34), rounds=3):
    """行级横向错位：逐行试几个偏移量，取交叉数最小的（错开竖向走廊，观感更疏朗）。"""
    global ROW_SHIFT
    span = (row_layout(rows_)[2] - 2 * MARGIN_X) / 2
    tried = 0
    for _ in range(rounds):
        improved = False
        for L in range(len(rows_)):
            best_val, best_off = None, ROW_SHIFT.get(L, 0)
            for ratio in ratios:
                ROW_SHIFT[L] = ratio * span
                v = crossings(rows_)
                tried += 1
                if best_val is None or v < best_val:
                    best_val, best_off = v, ratio * span
            ROW_SHIFT[L] = best_off
            if best_val < best:
                best, improved = best_val, True
        if not improved:
            break
    return best, tried


shift_best, shift_tries = optimize_shifts(rows, best_cross)
best_cross = shift_best
pos = positions(rows)

# ---- 坐标 ----
offs, pitch, W = row_layout(rows)
H = HEAD + (maxl + 1) * NH + maxl * (VGAP - NH) + 30
xy = {}
for L, row in enumerate(rows):
    y = HEAD + (maxl - L) * VGAP
    for i, n in enumerate(row):
        xy[n] = (offs[L] + i * pitch[L] if len(row) > 1 else offs[L], y)

# ---- 配色：色相在 extract_deps.hues() 里按 (层级, 名字) 顺序分配，每个模块一个不重复的值；
#      矩阵图调用同一个函数 ⇒ 两张图同色。边的深浅由 API 引用量（shade_of）决定 ----
combo = {}                                          # (来源模块, 深浅档) → 彩色箭头 marker 编号
for a in nodes:
    for b in deps[a]:
        if b in MAIN[a]:
            combo.setdefault((a, shade_of(u_of((a, b)))), None)
for i, k in enumerate(sorted(combo)):
    combo[k] = i
GRAY = '#94a3b8'                                    # 非前三名依赖：灰色虚线

# ---- 边锚点：沿节点底边/顶边均匀分散；跨层边在中间各层走「节点间隙通道」----
out_order = {n: sorted(deps[n], key=lambda d: xy[d][0]) for n in nodes}
in_order = {n: sorted([m for m in nodes if n in deps[m]], key=lambda m: xy[m][0]) for n in nodes}
src_anchor = {n: anchors_at(xy[n][0], xy[n][1], out_order[n], True) for n in nodes if out_order[n]}
dst_anchor = {n: anchors_at(xy[n][0], xy[n][1], in_order[n], False) for n in nodes if in_order[n]}
CHAN = channel_x(rows, offs, pitch, W, xy)


def anchors_of(n):
    """模块 n 的出/入边锚点表：{对端: (x, y)}。"""
    out = {}
    for (d, ax, ay) in src_anchor.get(n, []):
        out[('out', d)] = (ax, ay)
    for (m, ax, ay) in dst_anchor.get(n, []):
        out[('in', m)] = (ax, ay)
    return out


ANCH = {n: anchors_of(n) for n in nodes}
draw_routes = {k: route_points(k[0], k[1], xy, CHAN,
                               p0=ANCH[k[0]][('out', k[1])], p1=ANCH[k[1]][('in', k[0])])
               for k in [(a, b) for a in nodes for b in deps[a]]}


def path_samples(pts, n=24):
    """按 SVG 里的画法（竖直段直线、其余三次贝塞尔）采样路径点。"""
    out = []
    for (x0, y0), (x1, y1) in zip(pts, pts[1:]):
        if abs(x1 - x0) < 1:
            out += [(x0, y0 + (y1 - y0) * i / n) for i in range(n + 1)]
        else:
            my = (y0 + y1) / 2
            for i in range(n + 1):
                t = i / n
                mt = 1 - t
                out.append((mt ** 3 * x0 + 3 * mt * mt * t * x0 + 3 * mt * t * t * x1 + t ** 3 * x1,
                            mt ** 3 * y0 + 3 * mt * mt * t * my + 3 * mt * t * t * my + t ** 3 * y1))
    return out


# 自检：任何一条线都不得穿过（或压到）节点框
intrude = []
for (a, b), pts in draw_routes.items():
    for (px, py) in path_samples(pts):
        L = maxl - int((py - HEAD) // VGAP)
        if not 0 <= L <= maxl:
            continue
        for m in rows[L]:
            mx, my = xy[m]
            if mx + 1 < px < mx + NW - 1 and my + 1 < py < my + NH - 1:
                intrude.append((f'{a}->{b}', m))
                break
        if intrude and intrude[-1][0] == f'{a}->{b}':
            break

cross = crossings(rows)                              # 最终交叉数（与搜索同口径）

# ---- SVG ----
F = "font-family=\"'Segoe UI', Roboto, 'Helvetica Neue', Arial, sans-serif\""
o = [f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W:.0f} {H:.0f}" width="100%" '
     'role="img" aria-label="fountain module dependencies">',
     '<title>fountain 模块依赖关系 / Module dependencies</title>',
     '<defs>' + ''.join(
         f'<marker id="a{i}" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="3.8" markerHeight="3.8" '
         f'orient="auto"><path d="M0,0 L10,5 L0,10 z" '
         f'fill="{extract_deps.shade_hex(hue[a], (lv + 0.5) / LEVELS)}"/></marker>'
         for (a, lv), i in sorted(combo.items(), key=lambda kv: kv[1]))
     + f'<marker id="ag" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="3.2" markerHeight="3.2" '
       f'orient="auto"><path d="M0,0 L10,5 L0,10 z" fill="{GRAY}"/></marker></defs>',
     '<style>',
     'text{user-select:none}',
     'g.n:hover>rect{stroke-width:2.6}',
     'svg:has(g.n:hover) g.e>path{stroke-opacity:.08}']
for n in nodes:
    o.append(f'svg:has(#nd-{n}:hover) g.e[data-src="{n}"]>path,'
             f'svg:has(#nd-{n}:hover) g.e[data-dst="{n}"]>path'
             '{stroke-opacity:.95;stroke-width:2.6}')
o.append('</style>')

o.append(f'<rect x="0" y="0" width="{W:.0f}" height="{H:.0f}" fill="#ffffff"/>')
o.append(f'<text x="{MARGIN_X}" y="32" {F} font-size="18" font-weight="600" fill="#0f172a">'
         'fountain 模块依赖关系 / Module dependencies</text>')


def note(y, zh, en):
    """一组双语说明：中文一行（深）、英文一行（浅），返回下一组的 y。"""
    o.append(f'<text x="{MARGIN_X}" y="{y}" {F} font-size="12.5" fill="#475569">{zh}</text>')
    o.append(f'<text x="{MARGIN_X}" y="{y + 16}" {F} font-size="11.5" fill="#94a3b8">{en}</text>')
    return y + 38


yy = note(NOTE_TOP,
          f'箭头 A → B：A 依赖 B｜{len(nodes)} 个模块 / {edges} 条依赖（都是「已声明且源码里 import 了对方 API」）',
          f'Arrow A → B: A depends on B | {len(nodes)} modules / {edges} dependencies '
          f'(each declared in cjpm.toml and imported in source)')
yy = note(yy,
          f'彩色实线 = 该模块 API 调用次数前三的依赖；灰色虚线 = 其余依赖（{main_edges} 条 / '
          f'{edges - main_edges} 条）；悬停节点高亮它的直连，悬停边看引用次数',
          f'Solid = the 3 most-called dependencies of that module; dashed = the rest '
          f'({main_edges} / {edges - main_edges}); hover a node to highlight its edges')
yy = note(yy,
          f'彩色实线的色相 = 来源模块（{len(nodes)} 个模块各一色，不重复）；深浅 = 该模块对该依赖的 API 引用量'
          f'（越多越深，分 {LEVELS} 档）',
          f'Hue of a solid line = its source module (all {len(nodes)} distinct); shade = how much of that '
          f'dependency\'s API the module calls (darker = more, {LEVELS} levels)')
yy = note(yy,
          f'声明了但没有引用对方 API 的 {len(unused_edges)} 条、以及间接可达关系都不画（口径见 extract_deps.py）',
          f'{len(unused_edges)} declared-but-unused edges and indirect reachability are not drawn '
          f'(see extract_deps.py)')
yy = note(yy, '不含 fdemo、fcoder、frpcdemo 等示例应用',
          'Demo applications (fdemo, fcoder, frpcdemo) are not included')
LEGEND_Y = yy + 4

legend = [('#dbeafe', '#60a5fa', '被依赖 ≥ 10 次 (hub)'), ('#dcfce7', '#86efac', '基础层：无依赖 (foundation)'),
          ('#f8fafc', '#cbd5e1', '其它模块 (others)')]


def tw(s):
    return sum(13 if ord(c) > 0x2E80 else 6.8 for c in s)


lx = MARGIN_X
for fill, stroke, label in legend:
    o.append(f'<rect x="{lx:.0f}" y="{LEGEND_Y}" width="13" height="13" rx="3" fill="{fill}" '
             f'stroke="{stroke}"/>')
    o.append(f'<text x="{lx + 19:.0f}" y="{LEGEND_Y + 11}" {F} font-size="12.5" fill="#475569">{label}</text>')
    lx += 19 + tw(label) + 28
LY = LEGEND_Y + 24
t1 = f'彩色实线＝引用最多的 3 个依赖（{main_edges} 条；越深引用越多，{UMIN:g}→{UMAX:g}）'
t2 = f'灰色虚线＝其余依赖（{edges - main_edges} 条）'
o.append(f'<path d="M{MARGIN_X},{LY} h28" stroke="#2563eb" stroke-width="1.3" fill="none" '
         'marker-end="url(#a0)"/>')
x1 = MARGIN_X + 36
o.append(f'<text x="{x1}" y="{LY + 4}" {F} font-size="12.5" fill="#475569">{t1}</text>')
x2 = x1 + tw(t1) + 40
o.append(f'<path d="M{x2:.0f},{LY} h28" stroke="{GRAY}" stroke-width="1" fill="none" '
         'stroke-dasharray="3 3" marker-end="url(#ag)"/>')
o.append(f'<text x="{x2 + 36:.0f}" y="{LY + 4}" {F} font-size="12.5" fill="#475569">{t2}</text>')
o.append(f'<text x="{MARGIN_X}" y="{LY + 22}" {F} font-size="11.5" fill="#94a3b8">'
         f'Solid = the 3 most-called dependencies of each module ({main_edges} edges, darker = more API '
         f'references); dashed = the rest ({edges - main_edges})</text>')

# 边：该模块 API 调用次数前三的依赖 → 彩色实线（色相 = 来源模块、深浅 = 引用量）；
#     其余依赖 → 灰色虚线（淡出为背景，形状与走向照旧，照样不压节点）
for n in sorted(nodes, key=lambda x: -level[x]):
    for (d, sx, sy) in src_anchor.get(n, []):
        path = path_d(draw_routes[(n, d)])
        cnt = u_of((n, d))
        if d in MAIN[n]:
            title = (f'<title>{n} → {d}｜{n} 依赖 {d}，API 引用 {cnt:g} 次（前三）/ '
                     f'{n} depends on {d} — {cnt:g} API references (top 3)</title>')
            o.append(f'<g class="e" data-kind="main" data-src="{n}" data-dst="{d}">{title}'
                     f'<path d="{path}" fill="none" stroke="{pair_hex(n, (n, d))}" stroke-width="1.3" '
                     f'marker-end="url(#a{combo[(n, shade_of(cnt))]})"/></g>')
        else:
            title = (f'<title>{n} → {d}｜{n} 依赖 {d}，API 引用 {cnt:g} 次（未进前三）/ '
                     f'{n} depends on {d} — {cnt:g} API references (not in top 3)</title>')
            o.append(f'<g class="e" data-kind="minor" data-src="{n}" data-dst="{d}">{title}'
                     f'<path d="{path}" fill="none" stroke="{GRAY}" stroke-width="1" '
                     f'stroke-opacity="0.75" stroke-dasharray="3 3" '
                     'marker-end="url(#ag)"/></g>')

# 节点
for n in nodes:
    x, y = xy[n]
    if indeg[n] >= HUB:
        fill, stroke, tcolor, weight = '#dbeafe', '#60a5fa', '#1d4ed8', '600'
    elif not deps[n]:
        fill, stroke, tcolor, weight = '#dcfce7', '#86efac', '#166534', '600'
    else:
        fill, stroke, tcolor, weight = '#f8fafc', '#cbd5e1', '#334155', '500'
    out_use = sum(u_of((n, d)) for d in deps[n])
    o.append(f'<g class="n" id="nd-{n}"><title>{n}｜被 {indeg[n]} 个模块依赖；自身依赖 {len(deps[n])} 个模块'
             f'（引用对方 API 合计 {out_use:g} 次）\n'
             f'{n} — depended on by {indeg[n]}; depends on {len(deps[n])} modules '
             f'({out_use:g} API references in total)</title>'
             f'<rect x="{x:.1f}" y="{y:.1f}" width="{NW}" height="{NH}" rx="8" fill="{fill}" '
             f'stroke="{stroke}" stroke-width="1.3"/>'
             f'<rect x="{x + 6:.1f}" y="{y + NH - 5:.1f}" width="{NW - 12}" height="4" rx="2" '
             f'fill="{color[n]}" stroke="none" opacity="0.9"/>'
             f'<text x="{x + NW / 2:.1f}" y="{y + NH / 2 + 3.5:.1f}" {F} font-size="{NODE_FONT}" '
             f'font-weight="{weight}" fill="{tcolor}" text-anchor="middle">{n}</text></g>')

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
    if ty <= HEAD:                                   # 页眉里的文字：横向不能超出画布、纵向不能压进节点区
        w = sum(fs * (1.04 if ord(c) > 0x2E80 else 0.55) for c in t.text)
        if tx + w > W - 8:
            over.append(('宽 ' + t.text[:30], round(tx + w)))
        if ty > HEAD - 12:
            over.append(('低 ' + t.text[:30], round(ty)))

print(f'layered: nodes={len(nodes)} edges={edges} declared={declared} used={used} unused={len(unused_edges)} '
      f'usage={UMIN:g}..{UMAX:g} shades={LEVELS} hues={len(set(hue.values()))} levels={maxl + 1} '
      f'node={NW}x{NH} gaps={HGAP}..{MAX_HGAP}/{VGAP} canvas={W:.0f}x{H:.0f} '
      f'main={main_edges}/{edges} crossings={cross} '
      f'ordering={best_tag} evals={best_tries + shift_tries} size={os.path.getsize(OUT)} out={OUT}')
print('header overflow:', over if over else 'none')
print('node crossings:', f'{len(intrude)} 处 {intrude[:3]}' if intrude else 'none（没有线压到节点框）')
dup = [(a, b) for a in nodes for b in nodes if a < b
       if abs(xy[a][0] - xy[b][0]) < NW and abs(xy[a][1] - xy[b][1]) < NH]
print('overlaps:', dup if dup else 'none')

# 自检：每个模块的颜色（色相）互不重复
seen = {}
clash = []
for n in nodes:
    h = round(hue[n], 3)
    if h in seen:
        clash.append((seen[h], n, h))
    seen[h] = n
print(f'colors unique: {"yes" if not clash else clash}（{len(seen)} 个模块 / {len(nodes)} 个色相）')
