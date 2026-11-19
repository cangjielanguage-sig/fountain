/*
Copyright (c) 2026 WuJingrun（吴京润）

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/
package fountain::f_excel

import std.collection.{ArrayList, HashMap}
import std.io.ByteBuffer
import fountain::f_xml.{QName, XmlAttribute, XmlWriter}

/**
 * 写侧样式池：按值深比较去重，返回 `cellXfs` 索引。
 *
 * `s = 0` 恒为默认样式；自定义 `numFmt` 从 164 起分配（与 Excel 一致）。
 */
internal class StylePool {
    private let styles = ArrayList<CellStyle>()
    private let keys = ArrayList<String>()
    private let resolved = ArrayList<Int64>()
    private let customs = ArrayList<(Int64, String)>()
    private let dxfList = ArrayList<CfFormat>()
    private let dxfKeys = ArrayList<String>()
    private var nextCustomId: Int64 = 164

    init() {
        addDefault()
    }

    private func addDefault(): Unit {
        styles.add(CellStyle())
        keys.add(styleKey(CellStyle()))
        resolved.add(0)
    }

    prop size: Int64 {
        get() {
            Int64(styles.size)
        }
    }

    /** 差分样式（条件格式用）按值去重，返回索引。 */
    func getOrAddDxf(format: CfFormat): Int64 {
        let key = "${format.fill ?? ""}|${format.fontColor ?? ""}|${format.bold}|${format.icon ?? ""}"
        for (i in 0..this.dxfKeys.size) {
            if (this.dxfKeys[i] == key) {
                return i
            }
        }
        this.dxfKeys.add(key)
        this.dxfList.add(format)
        Int64(this.dxfKeys.size) - 1
    }

    func dxfs(): ArrayList<CfFormat> {
        this.dxfList
    }

    func entries(): ArrayList<CellStyle> {
        styles
    }

    func formatIdAt(index: Int64): Int64 {
        if (index < 0 || index >= Int64(resolved.size)) {
            return 0
        }
        resolved[index]
    }

    func customFormats(): ArrayList<(Int64, String)> {
        customs
    }

    private func resolveFormat(format: NumberFormat): Int64 {
        match (format) {
            case General => 0
            case Builtin(id) => id
            case Custom(code) =>
                for (item in customs) {
                    if (item[1] == code) {
                        return item[0]
                    }
                }
                let id = nextCustomId
                nextCustomId++
                customs.add((id, code))
                id
        }
    }

    /** 返回 `s` 索引；超限抛 `ExcelException`（设计 6.8）。 */
    func getOrAdd(style: CellStyle, maxCellStyles: Int64): Int64 {
        let key = styleKey(style)
        for (i in 0..keys.size) {
            if (keys[i] == key) {
                return i
            }
        }
        if (Int64(styles.size) >= maxCellStyles) {
            throw ExcelException(
                "样式种类超过 ${maxCellStyles}（当前 ${styles.size} 种）。" +
                    "可提高 SheetWriteOptions.maxCellStyles，或合并相同样式；" +
                    "Linux 上限 64000，其他平台 8192"
            )
        }
        styles.add(style)
        keys.add(key)
        resolved.add(resolveFormat(style.numberFormat))
        Int64(styles.size - 1)
    }
}

/** 生成 `xl/styles.xml`（最小完整结构 + 用户样式）。 */
internal class StylesWriter {
    static func write(pool: StylePool): Array<Byte> {
        let buffer = ByteBuffer(256 * 1024)
        let xml = XmlWriter(buffer)
        xml.writeDeclaration(encoding: "UTF-8", standalone: Some(true))
        xml.startElement(styleEl("styleSheet"))

        let dxfs = pool.dxfs()
        if (dxfs.size > 0) {
            xml.startElement(styleEl("dxfs"), attributes: [XmlAttribute(QName("count"), dxfs.size.toString())])
            for (format in dxfs) {
                xml.startElement(styleEl("dxf"))
                if (format.bold || format.fontColor.isSome()) {
                    xml.startElement(styleEl("font"))
                    if (format.bold) {
                        xml.emptyElement(styleEl("b"))
                    }
                    match (format.fontColor) {
                        case Some(color) =>
                            xml.emptyElement(styleEl("color"), attributes: [XmlAttribute(QName("rgb"), color)])
                        case None => ()
                    }
                    xml.endElement(styleEl("font"))
                }
                match (format.fill) {
                    case Some(color) =>
                        xml.startElement(styleEl("fill"))
                        xml.startElement(styleEl("patternFill"))
                        xml.emptyElement(styleEl("bgColor"), attributes: [XmlAttribute(QName("rgb"), color)])
                        xml.endElement(styleEl("patternFill"))
                        xml.endElement(styleEl("fill"))
                    case None => ()
                }
                xml.endElement(styleEl("dxf"))
            }
            xml.endElement(styleEl("dxfs"))
        }
        let formats = pool.customFormats()
        if (formats.size > 0) {
            xml.startElement(styleEl("numFmts"), attributes: [XmlAttribute(QName("count"), formats.size.toString())])
            for (item in formats) {
                xml.emptyElement(
                    styleEl("numFmt"),
                    attributes: [
                        XmlAttribute(QName("numFmtId"), item[0].toString()),
                        XmlAttribute(QName("formatCode"), item[1])
                    ]
                )
            }
            xml.endElement(styleEl("numFmts"))
        }

        let fonts = ArrayList<Font>()
        let fontKeys = ArrayList<String>()
        let fills = ArrayList<Fill>()
        let fillKeys = ArrayList<String>()
        let borders = ArrayList<Border>()
        let borderKeys = ArrayList<String>()
        fills.add(Fill.none())
        fillKeys.add(Fill.none().toString())
        fills.add(Fill(patternType: PatternType.Gray125))
        fillKeys.add(Fill(patternType: PatternType.Gray125).toString())
        for (style in pool.entries()) {
            addUniqueFont(fonts, fontKeys, style.font)
            addUniqueFill(fills, fillKeys, style.fill)
            addUniqueBorder(borders, borderKeys, style.border)
        }
        if (fonts.size == 0) {
            fonts.add(Font.default())
            fontKeys.add(Font.default().toString())
        }
        if (borders.size == 0) {
            borders.add(Border.none())
            borderKeys.add(Border.none().toString())
        }

        writeFonts(xml, fonts)
        writeFills(xml, fills)
        writeBorders(xml, borders)

        xml.startElement(styleEl("cellStyleXfs"), attributes: [XmlAttribute(QName("count"), "1")])
        xml.emptyElement(
            styleEl("xf"),
            attributes: [
                XmlAttribute(QName("numFmtId"), "0"),
                XmlAttribute(QName("fontId"), "0"),
                XmlAttribute(QName("fillId"), "0"),
                XmlAttribute(QName("borderId"), "0")
            ]
        )
        xml.endElement(styleEl("cellStyleXfs"))

        xml.startElement(styleEl("cellXfs"), attributes: [XmlAttribute(QName("count"), pool.size.toString())])
        for (i in 0..pool.entries().size) {
            let style = pool.entries()[i]
            let attrs = ArrayList<XmlAttribute>()
            attrs.add(XmlAttribute(QName("numFmtId"), pool.formatIdAt(i).toString()))
            attrs.add(XmlAttribute(QName("fontId"), indexOf(fontKeys, style.font.toString()).toString()))
            attrs.add(XmlAttribute(QName("fillId"), indexOf(fillKeys, style.fill.toString()).toString()))
            attrs.add(XmlAttribute(QName("borderId"), indexOf(borderKeys, style.border.toString()).toString()))
            attrs.add(XmlAttribute(QName("xfId"), "0"))
            if (pool.formatIdAt(i) != 0) {
                attrs.add(XmlAttribute(QName("applyNumberFormat"), "1"))
            }
            if (style.fill.patternType.toString() != "none" || style.fill.gradient.isSome()) {
                attrs.add(XmlAttribute(QName("applyFill"), "1"))
            }
            if (style.font.bold || style.font.italic || style.font.underline.toString() != "none" ||
                style.font.strike || style.font.color.isSome() || style.font.name.isSome() ||
                style.font.size != 11.0) {
                attrs.add(XmlAttribute(QName("applyFont"), "1"))
            }
            if (style.border.left.style.toString() != "none" || style.border.right.style.toString() != "none" ||
                style.border.top.style.toString() != "none" || style.border.bottom.style.toString() != "none") {
                attrs.add(XmlAttribute(QName("applyBorder"), "1"))
            }
            let hasAlignment = style.alignment.horizontal.toString() != "general" ||
                style.alignment.vertical.toString() != "bottom" || style.alignment.wrapText ||
                style.alignment.textRotation != 0 || style.alignment.indent != 0 || style.alignment.shrinkToFit
            if (hasAlignment) {
                attrs.add(XmlAttribute(QName("applyAlignment"), "1"))
            }
            if (!style.protection.locked || style.protection.hidden) {
                attrs.add(XmlAttribute(QName("applyProtection"), "1"))
            }
            if (hasAlignment || !style.protection.locked || style.protection.hidden) {
                xml.startElement(styleEl("xf"), attributes: attrs.toArray())
                if (hasAlignment) {
                    let alignmentAttrs = ArrayList<XmlAttribute>()
                    if (style.alignment.horizontal.toString() != "general") {
                        alignmentAttrs.add(XmlAttribute(QName("horizontal"), style.alignment.horizontal.toString()))
                    }
                    if (style.alignment.vertical.toString() != "bottom") {
                        alignmentAttrs.add(XmlAttribute(QName("vertical"), style.alignment.vertical.toString()))
                    }
                    if (style.alignment.wrapText) {
                        alignmentAttrs.add(XmlAttribute(QName("wrapText"), "1"))
                    }
                    if (style.alignment.textRotation != 0) {
                        alignmentAttrs.add(XmlAttribute(QName("textRotation"), style.alignment.textRotation.toString()))
                    }
                    if (style.alignment.indent != 0) {
                        alignmentAttrs.add(XmlAttribute(QName("indent"), style.alignment.indent.toString()))
                    }
                    if (style.alignment.shrinkToFit) {
                        alignmentAttrs.add(XmlAttribute(QName("shrinkToFit"), "1"))
                    }
                    xml.emptyElement(styleEl("alignment"), attributes: alignmentAttrs.toArray())
                }
                if (!style.protection.locked || style.protection.hidden) {
                    let protectionAttrs = ArrayList<XmlAttribute>()
                    if (!style.protection.locked) {
                        protectionAttrs.add(XmlAttribute(QName("locked"), "0"))
                    }
                    if (style.protection.hidden) {
                        protectionAttrs.add(XmlAttribute(QName("hidden"), "1"))
                    }
                    xml.emptyElement(styleEl("protection"), attributes: protectionAttrs.toArray())
                }
                xml.endElement(styleEl("xf"))
            } else {
                xml.emptyElement(styleEl("xf"), attributes: attrs.toArray())
            }
        }
        xml.endElement(styleEl("cellXfs"))

        xml.startElement(styleEl("cellStyles"), attributes: [XmlAttribute(QName("count"), "1")])
        xml.emptyElement(
            styleEl("cellStyle"),
            attributes: [
                XmlAttribute(QName("name"), "Normal"),
                XmlAttribute(QName("xfId"), "0"),
                XmlAttribute(QName("builtinId"), "0")
            ]
        )
        xml.endElement(styleEl("cellStyles"))
        xml.endElement(styleEl("styleSheet"))
        xml.flush()
        buffer.bytes()
    }

    private static func indexOf(keys: ArrayList<String>, key: String): Int64 {
        for (i in 0..keys.size) {
            if (keys[i] == key) {
                return i
            }
        }
        0
    }

    private static func addUniqueFont(items: ArrayList<Font>, keys: ArrayList<String>, value: Font): Unit {
        let key = value.toString()
        for (item in keys) {
            if (item == key) {
                return
            }
        }
        items.add(value)
        keys.add(key)
    }

    private static func addUniqueFill(items: ArrayList<Fill>, keys: ArrayList<String>, value: Fill): Unit {
        let key = value.toString()
        for (item in keys) {
            if (item == key) {
                return
            }
        }
        items.add(value)
        keys.add(key)
    }

    private static func addUniqueBorder(items: ArrayList<Border>, keys: ArrayList<String>, value: Border): Unit {
        let key = value.toString()
        for (item in keys) {
            if (item == key) {
                return
            }
        }
        items.add(value)
        keys.add(key)
    }

    private static func writeFonts(xml: XmlWriter, fonts: ArrayList<Font>): Unit {
        xml.startElement(styleEl("fonts"), attributes: [XmlAttribute(QName("count"), fonts.size.toString())])
        for (font in fonts) {
            xml.startElement(styleEl("font"))
            match (font.name) {
                case Some(name) => xml.emptyElement(styleEl("name"), attributes: [XmlAttribute(QName("val"), name)])
                case None => ()
            }
            if (font.bold) {
                xml.emptyElement(styleEl("b"))
            }
            if (font.italic) {
                xml.emptyElement(styleEl("i"))
            }
            if (font.underline.toString() != "none") {
                xml.emptyElement(styleEl("u"), attributes: [XmlAttribute(QName("val"), font.underline.toString())])
            }
            if (font.strike) {
                xml.emptyElement(styleEl("strike"))
            }
            writeColor(xml, "color", font.color)
            xml.emptyElement(styleEl("sz"), attributes: [XmlAttribute(QName("val"), formatNumber(font.size))])
            if (font.family != 0) {
                xml.emptyElement(styleEl("family"), attributes: [XmlAttribute(QName("val"), font.family.toString())])
            }
            if (font.charset != 0) {
                xml.emptyElement(styleEl("charset"), attributes: [XmlAttribute(QName("val"), font.charset.toString())])
            }
            match (font.scheme) {
                case Some(scheme) => xml.emptyElement(styleEl("scheme"), attributes: [XmlAttribute(QName("val"), scheme)])
                case None => ()
            }
            xml.endElement(styleEl("font"))
        }
        xml.endElement(styleEl("fonts"))
    }

    private static func writeColor(xml: XmlWriter, tag: String, color: ?Color): Unit {
        match (color) {
            case Some(value) =>
                let attrs = ArrayList<XmlAttribute>()
                match (value) {
                    case Rgb(rgb) => attrs.add(XmlAttribute(QName("rgb"), rgb))
                    case Theme(theme, tint) =>
                        attrs.add(XmlAttribute(QName("theme"), theme.toString()))
                        if (tint != 0.0) {
                            attrs.add(XmlAttribute(QName("tint"), formatNumber(tint)))
                        }
                    case Indexed(index) => attrs.add(XmlAttribute(QName("indexed"), index.toString()))
                }
                xml.emptyElement(styleEl(tag), attributes: attrs.toArray())
            case None => ()
        }
    }

    private static func writeFills(xml: XmlWriter, fills: ArrayList<Fill>): Unit {
        xml.startElement(styleEl("fills"), attributes: [XmlAttribute(QName("count"), fills.size.toString())])
        for (fill in fills) {
            xml.startElement(styleEl("fill"))
            match (fill.gradient) {
                case Some(gradient) =>
                    let attrs = ArrayList<XmlAttribute>()
                    attrs.add(XmlAttribute(QName("type"), gradient.kind))
                    if (gradient.degree != 0.0) {
                        attrs.add(XmlAttribute(QName("degree"), formatNumber(gradient.degree)))
                    }
                    xml.startElement(styleEl("gradientFill"), attributes: attrs.toArray())
                    for (stop in gradient.stops) {
                        xml.startElement(styleEl("stop"), attributes: [XmlAttribute(QName("position"), formatNumber(stop.position))])
                        writeColor(xml, "color", Some(stop.color))
                        xml.endElement(styleEl("stop"))
                    }
                    xml.endElement(styleEl("gradientFill"))
                case None =>
                    xml.startElement(styleEl("patternFill"), attributes: [XmlAttribute(QName("patternType"), fill.patternType.toString())])
                    writeColor(xml, "fgColor", fill.fgColor)
                    writeColor(xml, "bgColor", fill.bgColor)
                    xml.endElement(styleEl("patternFill"))
            }
            xml.endElement(styleEl("fill"))
        }
        xml.endElement(styleEl("fills"))
    }

    private static func writeBorders(xml: XmlWriter, borders: ArrayList<Border>): Unit {
        xml.startElement(styleEl("borders"), attributes: [XmlAttribute(QName("count"), borders.size.toString())])
        for (border in borders) {
            xml.startElement(styleEl("border"))
            writeBorderSide(xml, "left", border.left)
            writeBorderSide(xml, "right", border.right)
            writeBorderSide(xml, "top", border.top)
            writeBorderSide(xml, "bottom", border.bottom)
            writeBorderSide(xml, "diagonal", border.diagonal)
            xml.endElement(styleEl("border"))
        }
        xml.endElement(styleEl("borders"))
    }

    private static func writeBorderSide(xml: XmlWriter, tag: String, side: BorderSide): Unit {
        if (side.style.toString() == "none" && side.color.isNone()) {
            xml.emptyElement(styleEl(tag))
            return
        }
        let attrs = ArrayList<XmlAttribute>()
        if (side.style.toString() != "none") {
            attrs.add(XmlAttribute(QName("style"), side.style.toString()))
        }
        xml.startElement(styleEl(tag), attributes: attrs.toArray())
        writeColor(xml, "color", side.color)
        xml.endElement(styleEl(tag))
    }
}

private func styleEl(local: String): QName {
    QName(local, uri: Some(NS_MAIN))
}
