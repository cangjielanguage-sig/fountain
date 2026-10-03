# -*- coding: utf-8 -*-
"""
把 speech.pptx 按 10–15 分钟口播时长拆成多个独立 pptx。
- 从【已被用户修改过的】speech.pptx 里按 OOXML 层面取页，不重新生成
- 每个包 = 新开头页 + 原页 + 新结尾页，三者都带讲者备注
- 新页样式沿用原稿：深底 #0B1220、主色 #38BDF8、页脚 9.75pt / #64748B / 微软雅黑
"""
import io, os, re, shutil, zipfile
from xml.sax.saxutils import escape

DOCS = r'D:\docs\work\cangjie\projects\fountain\docs'
SRC = os.path.join(DOCS, 'speech.pptx')
TPL = os.path.join(DOCS, 'speech', 'parts_build', 'tpl.pptx')
OUT = os.path.join(DOCS, 'speech', 'parts')

REL_NS = 'http://schemas.openxmlformats.org/package/2006/relationships'
HL = 'http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink'
NOTE_CT = 'application/vnd.openxmlformats-officedocument.presentationml.notesSlide+xml'
SLIDE_CT = 'application/vnd.openxmlformats-officedocument.presentationml.slide+xml'
DEFAULT_FONT = ('<a:latin typeface="微软雅黑" panose="020B0503020204020204" charset="-122"/>'
                '<a:ea typeface="微软雅黑" panose="020B0503020204020204" charset="-122"/>')
FILL = '<a:solidFill><a:srgbClr val="64748B"/></a:solidFill>'
SEP = '\u3000\u00b7\u3000'

from parts_def import PARTS, URL1, URL2


def normalize_font(xml):
    """把 slidep 输出的 Microsoft YaHei 统一成原稿的微软雅黑 + panose"""
    xml = re.sub(r'<a:latin typeface="Microsoft YaHei"/>',
                 '<a:latin typeface="微软雅黑" panose="020B0503020204020204" charset="-122"/>', xml)
    xml = re.sub(r'<a:ea typeface="Microsoft YaHei"/>',
                 '<a:ea typeface="微软雅黑" panose="020B0503020204020204" charset="-122"/>', xml)
    return xml


def fill_tpl(xml, k, body):
    """替换模板占位符，并清掉 slidep 写进 alt text 的源码"""
    for key, val in body.items():
        xml = xml.replace('@@%s@@' % key, escape(str(val)))
    xml = normalize_font(xml)
    xml = re.sub(r' descr="&lt;Slide[^"]*"', '', xml)          # 去掉源码 alt text
    xml = re.sub(r'<p:cNvPr id="(\d+)" name="" descr="[^"]*"/>',
                 r'<p:cNvPr id="\1" name=""/>', xml)
    left = re.findall(r'@@\w+@@', xml)
    if left:
        raise RuntimeError('未替换的占位符: %s' % set(left))
    return xml


def notes_xml(text):
    ps = []
    for line in text.split('\n'):
        line = line.rstrip()
        ps.append('<a:p><a:r><a:rPr lang="zh-CN" dirty="0"/><a:t>%s</a:t></a:r></a:p>' % escape(line)
                  if line else '<a:p><a:endParaRPr lang="zh-CN" dirty="0"/></a:p>')
    return ('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\r\n'
            '<p:notes xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"'
            ' xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"'
            ' xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">'
            '<p:cSld><p:spTree>'
            '<p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr>'
            '<p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/>'
            '<a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr>'
            '<p:sp><p:nvSpPr><p:cNvPr id="2" name="Notes Placeholder 3"/>'
            '<p:cNvSpPr><a:spLocks noGrp="1"/></p:cNvSpPr>'
            '<p:nvPr><p:ph type="body" idx="1"/></p:nvPr></p:nvSpPr>'
            '<p:spPr/><p:txBody><a:bodyPr/><a:lstStyle/>' + ''.join(ps) +
            '</p:txBody></p:sp></p:spTree></p:cSld>'
            '<p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:notes>')


def rels_for(slide_no, note_no, with_links):
    out = ['<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\r\n',
           '<Relationships xmlns="%s">' % REL_NS,
           '<Relationship Id="rIdLayout" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideLayout" Target="../slideLayouts/slideLayout1.xml"/>',
           '<Relationship Id="rIdNotes" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/notesSlide" Target="../notesSlides/notesSlide%d.xml"/>' % note_no]
    if with_links:
        out.append('<Relationship Id="rIdHlink1" Type="%s" Target="%s" TargetMode="External"/>' % (HL, URL1))
        out.append('<Relationship Id="rIdHlink2" Type="%s" Target="%s" TargetMode="External"/>' % (HL, URL2))
    out.append('</Relationships>')
    return ''.join(out)


def add_hlink_to_runs(xml):
    """给新页里的两个 URL run 加上可点击超链接（显式色值 + 去下划线）"""
    if 'xmlns:r=' not in xml.split('>', 2)[1]:
        xml = xml.replace('<p:sld ', '<p:sld xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" ', 1)
    for url, rid in ((URL1, 'rIdHlink1'), (URL2, 'rIdHlink2')):
        pat = r'(<a:rPr [^>]*?)(sz="975")'
        i = xml.find('<a:t>%s</a:t>' % url)
        if i < 0:
            i = xml.find('<a:t xml:space="preserve">%s</a:t>' % url)
        if i < 0:
            raise RuntimeError('URL run not found: ' + url)
        j = xml.rfind('<a:rPr', 0, i)
        seg = xml[j:i]
        if 'hlinkClick' in seg:
            continue
        new = seg.replace('<a:rPr ', '<a:rPr u="none" ', 1).rstrip()
        new = new + '<a:hlinkClick r:id="%s"/>' % rid
        xml = xml[:j] + new + xml[i:]
    return xml


def content_types(n_slides):
    o = ['<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\r\n',
         '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">',
         '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>',
         '<Default Extension="xml" ContentType="application/xml"/>',
         '<Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>',
         '<Override PartName="/ppt/presentation.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml"/>',
         '<Override PartName="/ppt/slideMasters/slideMaster1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slideMaster+xml"/>',
         '<Override PartName="/ppt/slideLayouts/slideLayout1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slideLayout+xml"/>',
         '<Override PartName="/ppt/notesMasters/notesMaster1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.notesMaster+xml"/>',
         '<Override PartName="/ppt/theme/theme1.xml" ContentType="application/vnd.openxmlformats-officedocument.theme+xml"/>',
         '<Override PartName="/ppt/theme/theme2.xml" ContentType="application/vnd.openxmlformats-officedocument.theme+xml"/>',
         '<Override PartName="/ppt/presProps.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.presProps+xml"/>',
         '<Override PartName="/ppt/viewProps.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.viewProps+xml"/>',
         '<Override PartName="/ppt/tableStyles.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.tableStyles+xml"/>']
    for n in range(1, n_slides + 1):
        o.append('<Override PartName="/ppt/slides/slide%d.xml" ContentType="%s"/>' % (n, SLIDE_CT))
        o.append('<Override PartName="/ppt/notesSlides/notesSlide%d.xml" ContentType="%s"/>' % (n, NOTE_CT))
    o.append('</Types>')
    return ''.join(o)


def main():
    src = zipfile.ZipFile(SRC)
    tpl = zipfile.ZipFile(TPL)
    S = {n: src.read(n) for n in src.namelist()}
    t_open = tpl.read('ppt/slides/slide1.xml').decode('utf-8')
    t_end = tpl.read('ppt/slides/slide2.xml').decode('utf-8')

    # 母版 / 版式 / 主题等共用部件
    shared = [n for n in S if n.startswith(('ppt/slideMasters/', 'ppt/slideLayouts/',
                                            'ppt/notesMasters/', 'ppt/theme/'))
              and n.endswith(('.xml', '.rels'))]
    shared += ['ppt/presProps.xml', 'ppt/viewProps.xml', 'ppt/tableStyles.xml']
    pres = S['ppt/presentation.xml'].decode('utf-8')
    pres_rels = S['ppt/_rels/presentation.xml.rels'].decode('utf-8')
    keep_rels = re.findall(r'<Relationship (?![^>]*relationships/slide")[^>]*/>', pres_rels)

    # 每页口播时长：字/240 + 0.1 分钟（指屏与停顿）
    def nchars(i):
        d = S['ppt/notesSlides/notesSlide%d.xml' % i].decode('utf-8')
        return len(''.join(re.findall(r'<a:t>(.*?)</a:t>', d, re.S)))
    T = {i: nchars(i) / 240.0 + 0.10 for i in range(1, 117)}
    print('原稿总时长估算: %.1f 分钟' % sum(T.values()))

    os.makedirs(OUT, exist_ok=True)
    N = len(PARTS)
    manifest = []

    for k, p in enumerate(PARTS, 1):
        src_idx = list(range(p['a'], p['b'] + 1))
        M = len(src_idx) + 2                      # 新页 2 张
        mins = (sum(T[i] for i in src_idx)
                + (len(p['cn']) + len(p['e'])) / 240.0 + 0.20)
        base = 'speech-%02d-%s' % (k, p['title'])
        pptx_path = os.path.join(OUT, base + '.pptx')

        body = dict(NUM='%02d' % k, N=N, KICK='· 课程分册', TITLE=p['title'],
                    L1=p['l1'], L2=p['l2'], L3=p['l3'],
                    META='第 %d 讲 / 共 %d 讲　·　原稿第 %d–%d 页 + 首尾两页　·　约 %.1f 分钟'
                         % (k, N, p['a'], p['b'], mins),
                    NOTES=p['cn'], URL1=URL1, URL2=URL2)
        # 实际分钟数稍后回填
        parts_xml = {}

        cover = fill_tpl(t_open, k, body)
        parts_xml[1] = (add_hlink_to_runs(cover), 'new', p['cn'])

        for pos, si in enumerate(src_idx, start=2):
            parts_xml[pos] = (S['ppt/slides/slide%d.xml' % si].decode('utf-8'), 'src', si)

        ebody = dict(NUM='%02d' % k, N=N, TITLE=p['title'], P1='· ' + p['l1'], P2='· ' + p['l2'],
                     P3='· ' + p['l3'], NEXT=p['nxt'], NOTES=p['e'],
                     URL1=URL1, URL2=URL2)
        endx = fill_tpl(t_end, k, ebody)
        parts_xml[M] = (add_hlink_to_runs(endx), 'new', p['e'])

        # 组装包
        items = {'[Content_Types].xml': content_types(M).encode('utf-8'),
                 '_rels/.rels': S['_rels/.rels'],
                 'docProps/core.xml': S['docProps/core.xml'],
                 'ppt/presentation.xml': None,
                 'ppt/_rels/presentation.xml.rels': None}
        for n in shared:
            items[n] = S[n]

        rel_items = []
        for n in range(1, M + 1):
            rel_items.append('<Relationship Id="rIdSl%d" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide" Target="slides/slide%d.xml"/>' % (n, n))
        items['ppt/_rels/presentation.xml.rels'] = (
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\r\n'
            '<Relationships xmlns="%s">%s%s</Relationships>'
            % (REL_NS, ''.join(keep_rels), ''.join(rel_items))).encode('utf-8')

        sld_ids = ''.join('<p:sldId id="%d" r:id="rIdSl%d"/>' % (256 + n - 1, n) for n in range(1, M + 1))
        npres = re.sub(r'<p:sldIdLst>.*?</p:sldIdLst>', '<p:sldIdLst>%s</p:sldIdLst>' % sld_ids,
                       pres, flags=re.S)
        items['ppt/presentation.xml'] = npres.encode('utf-8')

        for n in range(1, M + 1):
            xml, kind, extra = parts_xml[n]
            items['ppt/slides/slide%d.xml' % n] = xml.encode('utf-8')
            items['ppt/slides/_rels/slide%d.xml.rels' % n] = rels_for(
                n, n, with_links=(kind == 'new')).encode('utf-8')
            txt = extra if kind == 'new' else None
            if kind == 'src':
                items['ppt/notesSlides/notesSlide%d.xml' % n] = \
                    S['ppt/notesSlides/notesSlide%d.xml' % extra]
            else:
                items['ppt/notesSlides/notesSlide%d.xml' % n] = notes_xml(txt).encode('utf-8')
            items['ppt/notesSlides/_rels/notesSlide%d.xml.rels' % n] = (
                '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\r\n'
                '<Relationships xmlns="%s">'
                '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/notesMaster" Target="../notesMasters/notesMaster1.xml"/>'
                '<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide" Target="../slides/slide%d.xml"/>'
                '</Relationships>' % (REL_NS, n)).encode('utf-8')

        with zipfile.ZipFile(pptx_path, 'w', zipfile.ZIP_DEFLATED) as zo:
            for name, data in items.items():
                zo.writestr(name, data)
        manifest.append((base, pptx_path, M))
        print('P%02d  %-40s %2d 页' % (k, base, M))

    print('\n共生成 %d 个文件 → %s' % (len(manifest), OUT))


if __name__ == '__main__':
    main()
