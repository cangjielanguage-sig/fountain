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
package fountain::f_email.imap

import std.collection.ArrayList

/**
 * `CAPABILITY` 的结果。
 *
 * 这一层只回答"服务器**能**做什么"。[ImapClient] 另外维护"**已经**生效什么"
 * （`ENABLE` 的 `* ENABLED` 回显），两者不能混用：广告了 `UTF8=ACCEPT` 不等于已经启用。
 *
 * 未识别的能力保留在 [raw] 里，不报错——服务器自定义能力是常态。
 */
public struct ImapCapabilities {
    public let raw: Array<String>

    public init(raw!: Array<String> = []) {
        this.raw = raw
    }

    public static func fromValues(values: Array<ImapValue>): ImapCapabilities {
        let out = ArrayList<String>()
        for (value in values) {
            let text = value.text()
            if (text.size > 0) {
                out.add(text.toAsciiUpper())
            }
        }
        ImapCapabilities(raw: out.toArray())
    }

    public static func fromLine(line: String): ImapCapabilities {
        fromValues(ImapParser.parse(line))
    }

    public func supports(name: String): Bool {
        let wanted = name.toAsciiUpper()
        for (entry in raw) {
            if (entry == wanted) {
                return true
            }
        }
        false
    }

    public func hasPrefix(prefix: String): Bool {
        let wanted = prefix.toAsciiUpper()
        for (entry in raw) {
            if (entry.size > wanted.size && entry[0..wanted.size] == wanted) {
                return true
            }
        }
        false
    }

    public prop size: Int64 {
        get() {
            raw.size
        }
    }

    public prop isEmpty: Bool {
        get() {
            raw.size == 0
        }
    }

    public prop supportsStartTls: Bool {
        get() {
            supports("STARTTLS")
        }
    }

    public prop supportsIdle: Bool {
        get() {
            supports("IDLE")
        }
    }

    public prop supportsMove: Bool {
        get() {
            supports("MOVE")
        }
    }

    public prop supportsSpecialUse: Bool {
        get() {
            supports("SPECIAL-USE")
        }
    }

    public prop supportsNamespace: Bool {
        get() {
            supports("NAMESPACE")
        }
    }

    public prop supportsEnable: Bool {
        get() {
            supports("ENABLE")
        }
    }

    /** `UTF8=ACCEPT`：注意这只是能力位，真正生效要看 `ENABLE` 的回显。 */
    public prop supportsUtf8Accept: Bool {
        get() {
            supports("UTF8=ACCEPT")
        }
    }

    public prop supportsCondStore: Bool {
        get() {
            supports("CONDSTORE")
        }
    }

    public prop supportsQResync: Bool {
        get() {
            supports("QRESYNC")
        }
    }

    /** `SORT=DISPLAY` 是 `SORT` 的扩展，广告了前者就一定能用 `SORT`。 */
    public prop supportsSort: Bool {
        get() {
            supports("SORT") || supports("SORT=DISPLAY")
        }
    }

    public prop supportsSortDisplay: Bool {
        get() {
            supports("SORT=DISPLAY")
        }
    }

    public prop supportsThreadOrderedSubject: Bool {
        get() {
            supports("THREAD=ORDEREDSUBJECT")
        }
    }

    public prop supportsThreadReferences: Bool {
        get() {
            supports("THREAD=REFERENCES")
        }
    }

    public prop supportsUidPlus: Bool {
        get() {
            supports("UIDPLUS")
        }
    }

    public prop supportsLiteralPlus: Bool {
        get() {
            supports("LITERAL+")
        }
    }

    public prop supportsSaslIr: Bool {
        get() {
            supports("SASL-IR")
        }
    }

    public prop supportsId: Bool {
        get() {
            supports("ID")
        }
    }

    public prop supportsUnselect: Bool {
        get() {
            supports("UNSELECT")
        }
    }

    public prop supportsListExtended: Bool {
        get() {
            supports("LIST-EXTENDED")
        }
    }

    public prop supportsLoginDisabled: Bool {
        get() {
            supports("LOGINDISABLED")
        }
    }

    /** `AUTH=...` 里声明的 SASL 机制。 */
    public prop authMechanisms: Array<String> {
        get() {
            let out = ArrayList<String>()
            for (entry in raw) {
                if (entry.size > 5 && entry[0..5] == "AUTH=") {
                    out.add(entry[5..])
                }
            }
            out.toArray()
        }
    }

    public func toString(): String {
        var out = ""
        var first = true
        for (entry in raw) {
            if (!first) {
                out = out + " "
            }
            out = out + entry
            first = false
        }
        out
    }
}
