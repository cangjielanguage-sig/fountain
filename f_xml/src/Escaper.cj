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
package fountain::f_xml

import fountain::f_base.StringGenerator

/**
 * 文本 / 属性值转义与非法字符检查。
 *
 * `\r` 必须转成 `&#13;`：否则写出再读回会被行尾归一转成 `\n`，往返不一致。
 * 非法控制字符（`0x00`–`0x08`、`0x0B`、`0x0C`、`0x0E`–`0x1F`）一律报错，**不静默剔除**。
 */
internal class Escaper {
    static func escapeText(text: String, elementName: String, out: StringGenerator): Unit {
        for (r in text.runes()) {
            let cp = r.position()
            if (!XmlChars.isXmlChar(cp)) {
                throw XmlException(
                    "元素「${elementName}」的文本里出现 XML 1.0 不允许的字符 U+${XmlChars.hex(cp)}"
                )
            }
            match (r) {
                case r'&' => out.append<String>("&amp;")
                case r'<' => out.append<String>("&lt;")
                case r'>' => out.append<String>("&gt;")
                case r'\r' => out.append<String>("&#13;")
                case _ => out.append(r)
            }
        }
    }

    static func escapeAttribute(value: String, attrName: String, out: StringGenerator): Unit {
        for (r in value.runes()) {
            let cp = r.position()
            if (!XmlChars.isXmlChar(cp)) {
                throw XmlException(
                    "属性「${attrName}」的值里出现 XML 1.0 不允许的字符 U+${XmlChars.hex(cp)}"
                )
            }
            match (r) {
                case r'&' => out.append<String>("&amp;")
                case r'<' => out.append<String>("&lt;")
                case r'>' => out.append<String>("&gt;")
                case r'"' => out.append<String>("&quot;")
                case r'\r' => out.append<String>("&#13;")
                case _ => out.append(r)
            }
        }
    }

    /** CDATA 模式：`]]>` 拆成 `]]]]><![CDATA[>`，语义不变。 */
    static func writeCData(text: String, elementName: String, out: StringGenerator): Unit {
        for (r in text.runes()) {
            if (!XmlChars.isXmlChar(r.position())) {
                throw XmlException(
                    "元素「${elementName}」的文本里出现 XML 1.0 不允许的字符 U+${XmlChars.hex(r.position())}"
                )
            }
        }
        out.append<String>("<![CDATA[")
        var i: Int64 = 0
        let runes = runesOf(text)
        while (i < runes.size) {
            if (runes[i] == r']' && i + 2 < runes.size && runes[i + 1] == r']' && runes[i + 2] == r'>') {
                out.append<String>("]]]]><![CDATA[>")
                i += 3
            } else {
                out.append(runes[i])
                i++
            }
        }
        out.append<String>("]]>")
    }
}
