import io, os, re, shutil, zipfile
from xml.sax.saxutils import escape

DOCS = r'D:\docs\work\cangjie\projects\fountain\docs'
PPTX = os.path.join(DOCS, 'speech.pptx')
SLIDES_DIR = os.path.join(DOCS, 'speech', 'slides')

def read_notes(path):
    s = io.open(path, encoding='utf-8').read()
    i = s.find('notes={')
    if i < 0:
        return ''
    j = s.find('`', i)
    if j < 0:
        return ''
    k = s.find('`', j + 1)
    if k < 0:
        return ''
    return s[j + 1:k].strip()

def notes_slide_xml(text):
    paras = []
    for line in text.split('\n'):
        line = line.rstrip()
        if line == '':
            paras.append('<a:p><a:endParaRPr lang="zh-CN" dirty="0"/></a:p>')
        else:
            paras.append(
                '<a:p><a:r><a:rPr lang="zh-CN" dirty="0"/>'
                '<a:t>%s</a:t></a:r></a:p>' % escape(line)
            )
    if not paras:
        paras.append('<a:p><a:endParaRPr lang="zh-CN" dirty="0"/></a:p>')
    return (
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\r\n'
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
        '<p:spPr/><p:txBody><a:bodyPr/><a:lstStyle/>'
        + ''.join(paras) +
        '</p:txBody></p:sp>'
        '</p:spTree></p:cSld>'
        '<p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:notes>'
    )

def notes_rels_xml(idx):
    return (
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\r\n'
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
        '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/notesMaster" Target="../notesMasters/notesMaster1.xml"/>'
        '<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide" Target="../slides/slide%d.xml"/>'
        '</Relationships>' % idx
    )

REL_NS = 'http://schemas.openxmlformats.org/package/2006/relationships'
NOTE_TYPE = 'http://schemas.openxmlformats.org/officeDocument/2006/relationships/notesSlide'
NOTE_CT = 'application/vnd.openxmlformats-officedocument.presentationml.notesSlide+xml'

def main():
    zin = zipfile.ZipFile(PPTX, 'r')
    items = {n: zin.read(n) for n in zin.namelist()}
    zin.close()

    slide_ns = sorted(
        int(re.search(r'slide(\d+)\.xml$', n).group(1))
        for n in items if re.match(r'ppt/slides/slide\d+\.xml$', n)
    )
    print('slides in package:', len(slide_ns))

    total_notes = 0
    for idx in slide_ns:
        src = os.path.join(SLIDES_DIR, '%02d.slide' % idx)
        if not os.path.exists(src):
            continue
        text = read_notes(src)
        if not text:
            continue
        total_notes += 1
        items['ppt/notesSlides/notesSlide%d.xml' % idx] = notes_slide_xml(text).encode('utf-8')
        items['ppt/notesSlides/_rels/notesSlide%d.xml.rels' % idx] = notes_rels_xml(idx).encode('utf-8')

        rels_name = 'ppt/slides/_rels/slide%d.xml.rels' % idx
        rel = items.get(rels_name)
        if rel is None:
            rel = ('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\r\n'
                   '<Relationships xmlns="%s"></Relationships>' % REL_NS).encode('utf-8')
        rel_s = rel.decode('utf-8')
        if 'notesSlide' not in rel_s:
            new_rel = ('<Relationship Id="rIdNotes%d" Type="%s" Target="../notesSlides/notesSlide%d.xml"/>'
                       % (idx, NOTE_TYPE, idx))
            rel_s = rel_s.replace('</Relationships>', new_rel + '</Relationships>')
        items[rels_name] = rel_s.encode('utf-8')

        ct_name = '[Content_Types].xml'
        ct = items[ct_name].decode('utf-8')
        part = '/ppt/notesSlides/notesSlide%d.xml' % idx
        if part not in ct:
            ct = ct.replace('</Types>',
                            '<Override PartName="%s" ContentType="%s"/></Types>' % (part, NOTE_CT))
        items[ct_name] = ct.encode('utf-8')

    print('notes injected:', total_notes)

    tmp = PPTX + '.tmp'
    zout = zipfile.ZipFile(tmp, 'w', zipfile.ZIP_DEFLATED)
    for name, data in items.items():
        zout.writestr(name, data)
    zout.close()
    shutil.move(tmp, PPTX)

if __name__ == '__main__':
    main()
