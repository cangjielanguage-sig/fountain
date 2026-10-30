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
import fountain::f_xml.{XmlEvent, XmlPullParser}

/**
 * `xl/sharedStrings.xml` 的字符串表。
 *
 * `<si>` 内可能有多个 `<r><t>`（富文本分段），必须拼接；`<rPh>` 里的 `<t>` 是注音，跳过。
 * M1 不解析 `<rPr>`（字体留给 M2）。
 */
internal class SharedStringTable {
    private let items: ArrayList<String>

    init(items: ArrayList<String>) {
        this.items = items
    }

    static func load(bytes: Array<Byte>): SharedStringTable {
        let items = ArrayList<String>()
        let parser = XmlPullParser(ByteBuffer(bytes))
        var inItem = false
        var inText = false
        var phoneticDepth: Int64 = 0
        var current = StringGenerator()
        try {
            while (let Some(event) <- parser.nextEvent()) {
                match (event) {
                    case StartElement(name, _, _) =>
                        match (name.local) {
                            case "si" =>
                                inItem = true
                                current = StringGenerator()
                                phoneticDepth = 0
                            case "rPh" => if (inItem) {
                                phoneticDepth++
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
                            case "rPh" => if (phoneticDepth > 0) {
                                phoneticDepth--
                            }
                            case "si" =>
                                if (inItem) {
                                    items.add(current.toString())
                                    inItem = false
                                }
                            case _ => ()
                        }
                    case Text(value) => if (inText) {
                        current.append<String>(value)
                    }
                    case CData(value) => if (inText) {
                        current.append<String>(value)
                    }
                    case _ => ()
                }
            }
        } finally {
            parser.close()
        }
        SharedStringTable(items)
    }

    static func empty(): SharedStringTable {
        SharedStringTable(ArrayList<String>())
    }

    func get(index: Int64): ?String {
        if (index < 0 || index >= Int64(items.size)) {
            return None<String>
        }
        Some(items[index])
    }

    prop size: Int64 {
        get() {
            Int64(items.size)
        }
    }
}
