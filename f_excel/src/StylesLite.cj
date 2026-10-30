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
import fountain::f_xml.XmlParser

/**
 * `styles.xml` 的最小读取：`cellXfs[i].numFmtId` 与自定义 `numFmt.code`。
 *
 * M1 只关心"是否日期"；字体/填充/边框留给 M2-a。
 */
internal class StylesLite {
    private let xfFmtIds: ArrayList<Int64>
    private let customCodes: HashMap<Int64, String>

    private init(xfFmtIds: ArrayList<Int64>, customCodes: HashMap<Int64, String>) {
        this.xfFmtIds = xfFmtIds
        this.customCodes = customCodes
    }

    static func empty(): StylesLite {
        let ids = ArrayList<Int64>()
        ids.add(0)
        StylesLite(ids, HashMap<Int64, String>())
    }

    static func load(bytes: Array<Byte>): StylesLite {
        let ids = ArrayList<Int64>()
        let codes = HashMap<Int64, String>()
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
        match (root.child("cellXfs")) {
            case Some(cellXfs) =>
                for (item in cellXfs.childrenOf("xf")) {
                    let id = match (item.attr("numFmtId")) {
                        case Some(v) => parseIntOrNone(v) ?? 0
                        case None => 0
                    }
                    ids.add(id)
                }
            case None => ()
        }
        if (ids.size == 0) {
            ids.add(0)
        }
        StylesLite(ids, codes)
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

    /** 该样式是否用了 `[h]` / `[m]` / `[s]` 时长格式（M1 按日期处理并告警）。 */
    func isElapsedFormat(styleIndex: Int64): Bool {
        let id = formatId(styleIndex)
        match (customCodes.get(id)) {
            case Some(code) => hasElapsedMarker(code)
            case None => id == 46 || id == 47
        }
    }
}
