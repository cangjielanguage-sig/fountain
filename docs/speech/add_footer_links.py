# -*- coding: utf-8 -*-
"""
在 speech.pptx 每一页的页脚行末尾追加两个链接。
- 追加到已有的页脚文本框段落里（同一行），沿用完全相同的字号(sz=975)、颜色(64748B)、字体(微软雅黑)
- 没有页脚的 6 页（封面 / 4 个分节页 / 结束页）补一个同样式的页脚文本框
- 只做追加，不改动已有 run 的任何内容与属性
"""
import io, os, re, shutil, sys, zipfile, datetime
from xml.sax.saxutils import escape

DOCS = r'D:\docs\work\cangjie\projects\fountain\docs'
PPTX = os.path.join(DOCS, 'speech.pptx')
BACKUP_DIR = os.path.join(DOCS, 'speech', 'backup')

URL1 = 'https://pkg.cangjie-lang.cn/org/fountain'
URL2 = 'https://gitcode.com/Cangjie-SIG/fountain'

SEP = '\u3000\u00b7\u3000'          # 全角空格 · 全角空格
SZ = '975'
FILL = '<a:solidFill><a:srgbClr val="64748B"/></a:solidFill>'
FONT = ('<a:latin typeface="微软雅黑" panose="020B0503020204020204" charset="-122"/>'
        '<a:ea typeface="微软雅黑" panose="020B0503020204020204" charset="-122"/>')
HLINK_TYPE = 'http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink'
REL_NS = 'http://schemas.openxmlformats.org/package/2006/relationships'


def rpr(lang, hlink_id=None):
    u = ' u="none"' if hlink_id else ''
    hl = '<a:hlinkClick r:id="%s"/>' % hlink_id if hlink_id else ''
    return '<a:rPr lang="%s" sz="%s"%s>%s%s%s</a:rPr>' % (lang, SZ, u, FILL, FONT, hl)


def run(text, lang, hlink_id=None):
    return '<a:r>%s<a:t>%s</a:t></a:r>' % (rpr(lang, hlink_id), escape(text))


def free_ids(rels_xml):
    used = set(re.findall(r'Id="([^"]+)"', rels_xml))
    n, out = 1, []
    while len(out) < 2:
        cid = 'rIdHlink%d' % n
        if cid not in used:
            out.append(cid)
        n += 1
    return out


def add_hyperlink_rels(rels_xml, ids):
    extra = ''.join(
        '<Relationship Id="%s" Type="%s" Target="%s" TargetMode="External"/>' % (i, HLINK_TYPE, u)
        for i, u in zip(ids, (URL1, URL2))
    )
    return rels_xml.replace('</Relationships>', extra + '</Relationships>')


def build_link_runs(id1, id2):
    return (run(SEP, 'zh-CN') + run(URL1, 'en-US', id1)
            + run(SEP, 'zh-CN') + run(URL2, 'en-US', id2))


BOX_TMPL = (
    '<p:sp><p:nvSpPr><p:cNvPr id="{sid}" name="文本框 {sid}"'
    ' descr="{{&quot;isTemplate&quot;:true,&quot;type&quot;:&quot;text&quot;}}"/>'
    '<p:cNvSpPr txBox="1"/><p:nvPr/></p:nvSpPr>'
    '<p:spPr><a:xfrm><a:off x="609600" y="6410325"/><a:ext cx="2219325" cy="152400"/></a:xfrm>'
    '<a:prstGeom prst="rect"><a:avLst/></a:prstGeom></p:spPr>'
    '<p:txBody><a:bodyPr wrap="none" lIns="0" tIns="0" rIns="0" bIns="0"/>'
    '<a:p><a:pPr><a:lnSpc><a:spcPct val="100000"/></a:lnSpc></a:pPr>'
    '<a:r>{r1}<a:t>fountain · </a:t></a:r>'
    '<a:r>{r2}<a:t>一站式服务器应用开发工具库</a:t></a:r>'
    '{links}'
    '<a:endParaRPr lang="zh-CN" sz="975">{fill}{font}</a:endParaRPr>'
    '</a:p></p:txBody></p:sp>'
)


def main():
    apply = '--apply' in sys.argv

    zin = zipfile.ZipFile(PPTX, 'r')
    items = {n: zin.read(n) for n in zin.namelist()}
    zin.close()

    if apply:
        os.makedirs(BACKUP_DIR, exist_ok=True)
        ts = datetime.datetime.now().strftime('%Y%m%d-%H%M%S')
        bak = os.path.join(BACKUP_DIR, 'speech-before-links-%s.pptx' % ts)
        shutil.copy2(PPTX, bak)
        print('backup ->', bak)

    changed = 0
    added_box = []
    for i in range(1, 117):
        sname = 'ppt/slides/slide%d.xml' % i
        rname = 'ppt/slides/_rels/slide%d.xml.rels' % i
        if sname not in items:
            continue
        doc = items[sname].decode('utf-8')
        rels = items.get(rname)
        rels_s = rels.decode('utf-8') if rels else (
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\r\n'
            '<Relationships xmlns="%s"></Relationships>' % REL_NS)

        # 已经处理过就跳过（幂等）
        if URL1 in doc:
            continue

        id1, id2 = free_ids(rels_s)
        links = build_link_runs(id1, id2)

        # 以页脚第一个 run「fountain · 」精确定位页脚段落
        # （不能只匹配「一站式服务器应用开发工具库」——封面上它是副标题）
        m = re.search(r'<a:t>fountain ·\s*</a:t>', doc)
        if m:
            # 找到该 run 所属段落的 </a:p>，把新 run 插到 endParaRPr 之前
            p_end = doc.index('</a:p>', m.end())
            epr = doc.rfind('<a:endParaRPr', m.end(), p_end)
            at = epr if epr != -1 else p_end
            doc = doc[:at] + links + doc[at:]
        else:
            # 无页脚：补一个同款式样式的页脚文本框
            used = set(int(x) for x in re.findall(r'<p:cNvPr id="(\d+)"', doc))
            sid = 9001
            while sid in used:
                sid += 1
            box = BOX_TMPL.format(
                sid=sid, links=links,
                r1=rpr('en-US'), r2=rpr('zh-CN'), fill=FILL, font=FONT)
            doc = doc.replace('</p:spTree>', box + '</p:spTree>')
            added_box.append(i)

        rels_s = add_hyperlink_rels(rels_s, (id1, id2))
        items[sname] = doc.encode('utf-8')
        items[rname] = rels_s.encode('utf-8')
        changed += 1

    print('slides updated :', changed)
    print('footer added to:', added_box)

    if not apply:
        print('(dry run — 加 --apply 才写入)')
        return

    tmp = PPTX + '.tmp'
    zout = zipfile.ZipFile(tmp, 'w', zipfile.ZIP_DEFLATED)
    for name, data in items.items():
        zout.writestr(name, data)
    zout.close()
    shutil.move(tmp, PPTX)
    print('written:', PPTX)


if __name__ == '__main__':
    main()
