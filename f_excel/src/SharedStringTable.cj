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

import std.collection.ArrayList
import std.io.ByteBuffer
import fountain::f_base.StringGenerator
import fountain::f_xml.{XmlAttribute, XmlEvent, XmlPullParser}

/**
 * `xl/sharedStrings.xml` 的字符串表。
 *
 * `<si>` 内可能有多个 `<r><t>`（富文本分段），文本拼接成平坦串；`<rPh>` 里的 `<t>` 是注音，跳过。
 * M2-d 起同时保留每段的 `<rPr>`（粗体/斜体/下划线/字号/颜色/字体名），供 `Worksheet.richText` 使用。
 */
internal class SharedStringTable {
    private let items: ArrayList<String>
    private let runSets: ArrayList<ArrayList<TextRun>>

    init(items: ArrayList<String>, runSets: ArrayList<ArrayList<TextRun>>) {
        this.items = items
        this.runSets = runSets
    }

    static func load(bytes: Array<Byte>): SharedStringTable {
        let items = ArrayList<String>()
        let runSets = ArrayList<ArrayList<TextRun>>()
        let parser = XmlPullParser(ByteBuffer(bytes))
        var inItem = false
        var inText = false
        var phoneticDepth: Int64 = 0
        var current = StringGenerator()
        var currentRuns = ArrayList<TextRun>()
        var inRun = false
        var inRunProps = false
        var runText = StringGenerator()
        var runBold = false
        var runItalic = false
        var runUnderline = false
        var runSize: ?Float64 = None
        var runColor: ?String = None
        var runName: ?String = None
        try {
            while (let Some(event) <- parser.nextEvent()) {
                match (event) {
                    case StartElement(name, attrs, _) =>
                        match (name.local) {
                            case "si" =>
                                inItem = true
                                current = StringGenerator()
                                currentRuns = ArrayList<TextRun>()
                                phoneticDepth = 0
                            case "rPh" => if (inItem) {
                                phoneticDepth++
                            }
                            case "r" => if (inItem && phoneticDepth == 0) {
                                inRun = true
                                runText = StringGenerator()
                                runBold = false
                                runItalic = false
                                runUnderline = false
                                runSize = None<Float64>
                                runColor = None<String>
                                runName = None<String>
                            }
                            case "rPr" => if (inRun) {
                                inRunProps = true
                            }
                            case "b" => if (inRunProps) {
                                runBold = true
                            }
                            case "i" => if (inRunProps) {
                                runItalic = true
                            }
                            case "u" => if (inRunProps) {
                                runUnderline = true
                            }
                            case "sz" => if (inRunProps) {
                                match (attrOf(attrs, "val")) {
                                    case Some(text) => runSize = parseFloatOrNone(text)
                                    case None => ()
                                }
                            }
                            case "color" => if (inRunProps) {
                                match (attrOf(attrs, "rgb")) {
                                    case Some(text) => runColor = Some(text)
                                    case None => ()
                                }
                            }
                            case "rFont" => if (inRunProps) {
                                runName = attrOf(attrs, "val")
                            }
                            case "t" =>
                                if (inItem && phoneticDepth == 0) {
                                    inText = true
                                }
                            case _ => ()
                        }
                    case EndElement(name) =>
                        match (name.local) {
                            case "t" => inText = false
                            case "rPr" => inRunProps = false
                            case "r" => if (inRun) {
                                let styled = runBold || runItalic || runUnderline || runSize.isSome() ||
                                    runColor.isSome() || runName.isSome()
                                let font = if (styled) {
                                    Some(
                                        RunFont(
                                            bold: runBold,
                                            italic: runItalic,
                                            underline: runUnderline,
                                            size: runSize,
                                            color: runColor,
                                            name: runName
                                        )
                                    )
                                } else {
                                    None<RunFont>
                                }
                                currentRuns.add(TextRun(runText.toString(), font: font))
                                inRun = false
                            }
                            case "rPh" => if (phoneticDepth > 0) {
                                phoneticDepth--
                            }
                            case "si" =>
                                if (inItem) {
                                    items.add(current.toString())
                                    runSets.add(currentRuns)
                                    inItem = false
                                }
                            case _ => ()
                        }
                    case Text(value) => if (inText) {
                        current.append<String>(value)
                        if (inRun) {
                            runText.append<String>(value)
                        }
                    }
                    case CData(value) => if (inText) {
                        current.append<String>(value)
                        if (inRun) {
                            runText.append<String>(value)
                        }
                    }
                    case _ => ()
                }
            }
        } finally {
            parser.close()
        }
        SharedStringTable(items, runSets)
    }

    static func empty(): SharedStringTable {
        SharedStringTable(ArrayList<String>(), ArrayList<ArrayList<TextRun>>())
    }

    func get(index: Int64): ?String {
        if (index < 0 || index >= Int64(items.size)) {
            return None<String>
        }
        Some(items[index])
    }

    /** 某个 `<si>` 的富文本分段；不是富文本返回空表。 */
    func runsAt(index: Int64): ArrayList<TextRun> {
        if (index < 0 || index >= Int64(runSets.size)) {
            return ArrayList<TextRun>()
        }
        runSets[index]
    }

    prop size: Int64 {
        get() {
            Int64(items.size)
        }
    }
}

private func attrOf(attrs: Array<XmlAttribute>, local: String): ?String {
    for (attribute in attrs) {
        if (attribute.name.local == local) {
            return Some(attribute.value)
        }
    }
    None<String>
}
