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
import fountain::f_xml.{XmlElement, XmlParser}

/** `cellXfs` 的一条完整记录。 */
internal class XfRecord {
    var numFmtId: Int64 = 0
    var fontId: Int64 = 0
    var fillId: Int64 = 0
    var borderId: Int64 = 0
    var xfId: Int64 = 0
    var alignment: Alignment = Alignment.default()
    var protection: Protection = Protection.default()
    var namedStyle: ?String = None
}

/**
 * `styles.xml` 的读取：`numFmt` / `fonts` / `fills` / `borders` / `cellXfs` / `cellStyles`。
 *
 * 写侧不经过本类（由 [StylePool] 生成），这里只服务读取与日期识别。
 */
internal class StylesLite {
    private let xfFmtIds: ArrayList<Int64>
    private let customCodes: HashMap<Int64, String>
    private let fonts: ArrayList<Font>
    private let fills: ArrayList<Fill>
    private let borders: ArrayList<Border>
    private let xfs: ArrayList<XfRecord>

    private init(
        xfFmtIds: ArrayList<Int64>,
        customCodes: HashMap<Int64, String>,
        fonts: ArrayList<Font>,
        fills: ArrayList<Fill>,
        borders: ArrayList<Border>,
        xfs: ArrayList<XfRecord>
    ) {
        this.xfFmtIds = xfFmtIds
        this.customCodes = customCodes
        this.fonts = fonts
        this.fills = fills
        this.borders = borders
        this.xfs = xfs
    }

    static func empty(): StylesLite {
        let ids = ArrayList<Int64>()
        ids.add(0)
        let fonts = ArrayList<Font>()
        fonts.add(Font.default())
        let fills = ArrayList<Fill>()
        fills.add(Fill.none())
        let borders = ArrayList<Border>()
        borders.add(Border.none())
        let xfs = ArrayList<XfRecord>()
        xfs.add(XfRecord())
        StylesLite(ids, HashMap<Int64, String>(), fonts, fills, borders, xfs)
    }

    static func load(bytes: Array<Byte>): StylesLite {
        let ids = ArrayList<Int64>()
        let codes = HashMap<Int64, String>()
        let fonts = ArrayList<Font>()
        let fills = ArrayList<Fill>()
        let borders = ArrayList<Border>()
        let xfs = ArrayList<XfRecord>()
        let named = HashMap<Int64, String>()
        let doc = try {
            XmlParser.parse(bytes)
        } catch (e: Exception) {
            throw ExcelException("styles.xml 解析失败", e)
        }
        let root = match (doc.root) {
            case Some(r) => r
            case None => return empty()
        }
        match (root.child("numFmts")) {
            case Some(numFmts) =>
                for (item in numFmts.childrenOf("numFmt")) {
                    let id = match (item.attr("numFmtId")) {
                        case Some(v) => parseIntOrNone(v) ?? -1
                        case None => -1
                    }
                    let code = item.attr("formatCode") ?? ""
                    if (id >= 0) {
                        codes.add(id, code)
                    }
                }
            case None => ()
        }
        match (root.child("fonts")) {
            case Some(container) =>
                for (item in container.childrenOf("font")) {
                    fonts.add(parseFont(item))
                }
            case None => ()
        }
        match (root.child("fills")) {
            case Some(container) =>
                for (item in container.childrenOf("fill")) {
                    fills.add(parseFill(item))
                }
            case None => ()
        }
        match (root.child("borders")) {
            case Some(container) =>
                for (item in container.childrenOf("border")) {
                    borders.add(parseBorder(item))
                }
            case None => ()
        }
        match (root.child("cellStyles")) {
            case Some(container) =>
                for (item in container.childrenOf("cellStyle")) {
                    let xfId = match (item.attr("xfId")) {
                        case Some(v) => parseIntOrNone(v) ?? -1
                        case None => -1
                    }
                    if (xfId >= 0) {
                        named.add(xfId, item.attr("name") ?? "")
                    }
                }
            case None => ()
        }
        match (root.child("cellXfs")) {
            case Some(container) =>
                for (item in container.childrenOf("xf")) {
                    let record = XfRecord()
                    record.numFmtId = parseIntOrNone(item.attr("numFmtId") ?? "0") ?? 0
                    record.fontId = parseIntOrNone(item.attr("fontId") ?? "0") ?? 0
                    record.fillId = parseIntOrNone(item.attr("fillId") ?? "0") ?? 0
                    record.borderId = parseIntOrNone(item.attr("borderId") ?? "0") ?? 0
                    record.xfId = parseIntOrNone(item.attr("xfId") ?? "0") ?? 0
                    match (item.child("alignment")) {
                        case Some(node) =>
                            record.alignment = Alignment(
                                horizontal: Horizontal.parse(node.attr("horizontal") ?? "general"),
                                vertical: Vertical.parse(node.attr("vertical") ?? "bottom"),
                                wrapText: node.attr("wrapText") == Some("1") || node.attr("wrapText") == Some("true"),
                                textRotation: parseIntOrNone(node.attr("textRotation") ?? "0") ?? 0,
                                indent: parseIntOrNone(node.attr("indent") ?? "0") ?? 0,
                                shrinkToFit: node.attr("shrinkToFit") == Some("1")
                            )
                        case None => ()
                    }
                    match (item.child("protection")) {
                        case Some(node) =>
                            record.protection = Protection(
                                locked: node.attr("locked") != Some("0"),
                                hidden: node.attr("hidden") == Some("1")
                            )
                        case None => ()
                    }
                    ids.add(record.numFmtId)
                    xfs.add(record)
                }
            case None => ()
        }
        if (ids.size == 0) {
            ids.add(0)
            xfs.add(XfRecord())
        }
        for (xfId in 0..xfs.size) {
            if (let Some(name) <- named.get(Int64(xfId))) {
                xfs[xfId].namedStyle = Some(name)
            }
        }
        if (fonts.size == 0) {
            fonts.add(Font.default())
        }
        if (fills.size == 0) {
            fills.add(Fill.none())
        }
        if (borders.size == 0) {
            borders.add(Border.none())
        }
        StylesLite(ids, codes, fonts, fills, borders, xfs)
    }

    private static func parseIntAttr(item: XmlElement, name: String, fallback: Int64): Int64 {
        match (item.attr(name)) {
            case Some(value) => parseIntOrNone(value) ?? fallback
            case None => fallback
        }
    }

    private static func parseColor(node: XmlElement): ?Color {
        match (node.attr("rgb")) {
            case Some(value) => return Some(Color.Rgb(value))
            case None => ()
        }
        match (node.attr("theme")) {
            case Some(value) =>
                let theme = parseIntOrNone(value) ?? 0
                let tint = match (node.attr("tint")) {
                    case Some(text) => parseFloatOrNone(text) ?? 0.0
                    case None => 0.0
                }
                return Some(Color.Theme(theme, tint))
            case None => ()
        }
        match (node.attr("indexed")) {
            case Some(value) => Some(Color.Indexed(parseIntOrNone(value) ?? 0))
            case None => None<Color>
        }
    }

    private static func parseFont(item: XmlElement): Font {
        let name = match (item.child("name")) {
            case Some(node) => node.attr("val")
            case None => None<String>
        }
        let size = match (item.child("sz")) {
            case Some(node) => parseFloatOrNone(node.attr("val") ?? "11") ?? 11.0
            case None => 11.0
        }
        let underline = match (item.child("u")) {
            case Some(node) => match (node.attr("val")) {
                case Some("double") => Underline.Double
                case Some("singleAccounting") => Underline.SingleAccounting
                case Some("doubleAccounting") => Underline.DoubleAccounting
                case Some("none") => Underline.Off
                case _ => Underline.Single
            }
            case None => Underline.Off
        }
        let color = match (item.child("color")) {
            case Some(node) => parseColor(node)
            case None => None<Color>
        }
        Font(
            name: name,
            size: size,
            bold: item.child("b").isSome(),
            italic: item.child("i").isSome(),
            underline: underline,
            strike: item.child("strike").isSome(),
            color: color,
            family: parseIntAttr(item, "family", 2),
            charset: parseIntAttr(item, "charset", 0),
            scheme: match (item.child("scheme")) {
                case Some(node) => node.attr("val")
                case None => None<String>
            }
        )
    }

    private static func parseFill(item: XmlElement): Fill {
        match (item.child("gradientFill")) {
            case Some(node) =>
                let stops = ArrayList<GradientStop>()
                for (stop in node.childrenOf("stop")) {
                    let color = match (stop.child("color")) {
                        case Some(c) => parseColor(c) ?? Color.Rgb("FF000000")
                        case None => Color.Rgb("FF000000")
                    }
                    stops.add(GradientStop(parseFloatOrNone(stop.attr("position") ?? "0") ?? 0.0, color))
                }
                return Fill(
                    gradient: Some(Gradient(
                        kind: node.attr("type") ?? "linear",
                        degree: parseFloatOrNone(node.attr("degree") ?? "0") ?? 0.0,
                        stops: stops
                    ))
                )
            case None => ()
        }
        match (item.child("patternFill")) {
            case Some(node) =>
                let fg = match (node.child("fgColor")) {
                    case Some(c) => parseColor(c)
                    case None => None<Color>
                }
                let bg = match (node.child("bgColor")) {
                    case Some(c) => parseColor(c)
                    case None => None<Color>
                }
                Fill(patternType: PatternType.parse(node.attr("patternType") ?? "none"), fgColor: fg, bgColor: bg)
            case None => Fill.none()
        }
    }

    private static func parseBorderSide(item: XmlElement, name: String): BorderSide {
        match (item.child(name)) {
            case Some(node) =>
                let style = BorderStyle.parse(node.attr("style") ?? "none")
                let color = match (node.child("color")) {
                    case Some(c) => parseColor(c)
                    case None => None<Color>
                }
                BorderSide(style: style, color: color)
            case None => BorderSide.none()
        }
    }

    private static func parseBorder(item: XmlElement): Border {
        Border(
            left: parseBorderSide(item, "left"),
            right: parseBorderSide(item, "right"),
            top: parseBorderSide(item, "top"),
            bottom: parseBorderSide(item, "bottom"),
            diagonal: parseBorderSide(item, "diagonal")
        )
    }

    func formatId(styleIndex: Int64): Int64 {
        if (styleIndex < 0 || styleIndex >= Int64(xfFmtIds.size)) {
            return 0
        }
        xfFmtIds[styleIndex]
    }

    func codeOf(numFmtId: Int64): ?String {
        customCodes.get(numFmtId)
    }

    /** 该样式索引是否是日期格式。 */
    func isDateFormat(styleIndex: Int64): Bool {
        let id = formatId(styleIndex)
        if (isBuiltinDateFormat(id)) {
            return true
        }
        match (customCodes.get(id)) {
            case Some(code) => isDateFormatCode(code)
            case None => false
        }
    }

    /** 该样式是否用了 `[h]` / `[m]` / `[s]` 时长格式。 */
    func isElapsedFormat(styleIndex: Int64): Bool {
        let id = formatId(styleIndex)
        match (customCodes.get(id)) {
            case Some(code) => hasElapsedMarker(code)
            case None => id == 46 || id == 47
        }
    }

    /** 完整样式（M2-a）。越界返回默认样式。 */
    func styleAt(styleIndex: Int64): CellStyle {
        if (styleIndex < 0 || styleIndex >= Int64(xfs.size)) {
            return CellStyle()
        }
        let xf = xfs[styleIndex]
        let font = if (xf.fontId >= 0 && xf.fontId < Int64(fonts.size)) {
            fonts[xf.fontId]
        } else {
            Font.default()
        }
        let fill = if (xf.fillId >= 0 && xf.fillId < Int64(fills.size)) {
            fills[xf.fillId]
        } else {
            Fill.none()
        }
        let border = if (xf.borderId >= 0 && xf.borderId < Int64(borders.size)) {
            borders[xf.borderId]
        } else {
            Border.none()
        }
        let format = match (customCodes.get(xf.numFmtId)) {
            case Some(code) => NumberFormat.Custom(code)
            case None => NumberFormat.Builtin(xf.numFmtId)
        }
        CellStyle(
            numberFormat: format,
            font: font,
            fill: fill,
            border: border,
            alignment: xf.alignment,
            protection: xf.protection,
            namedStyle: xf.namedStyle
        )
    }
}
