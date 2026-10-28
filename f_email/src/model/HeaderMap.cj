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
package fountain::f_email.model

import std.collection.ArrayList

/**
 * 头字段容器：保序、大小写不敏感查找、允许同名重复。
 *
 * 用 `ArrayList<(String, String)>` 而不是 `HashMap`——`Received` 链的顺序是语义的一部分，
 * 打乱顺序等于改写了邮件经过的路径。
 *
 * 值按原样保存（`String` 即 UTF-8 字节），**允许裸 UTF-8**（RFC 6532 的 `UTF8=ACCEPT` /
 * `SMTPUTF8` 场景），只在含 `\r` / `\n` 时拒绝；这两个字符是头注入的唯一入口。
 *
 * 折行展开（`CRLF + WSP` → 单个空格）在解析阶段完成，本类只存展开后的值；
 * 生成侧的 78 octets 折行由 `MimeWriter` 负责。
 */
public class HeaderMap {
    /** 单行硬上限（RFC 5322 §2.1.1）。 */
    public static let MAX_LINE_OCTETS: Int64 = 998

    private let items = ArrayList<(String, String)>()

    public init() {}

    public prop size: Int64 {
        get() {
            items.size
        }
    }

    public func isEmpty(): Bool {
        items.isEmpty()
    }

    /** 取第一个同名项。 */
    public func get(name: String): ?String {
        for ((key, value) in items) {
            if (equalName(key, name)) {
                return Some(value)
            }
        }
        None
    }

    /** 取全部同名项，保持原顺序。 */
    public func getAll(name: String): Array<String> {
        let out = ArrayList<String>()
        for ((key, value) in items) {
            if (equalName(key, name)) {
                out.add(value)
            }
        }
        out.toArray()
    }

    public func contains(name: String): Bool {
        for ((key, _) in items) {
            if (equalName(key, name)) {
                return true
            }
        }
        false
    }

    /**
     * 覆盖第一个同名项并删除其余同名项；不存在则追加。
     *
     * 这是"设置"语义，与 [add] 的"追加"语义分开：`set("Subject", ...)` 之后
     * 不应该还留着三条旧的 `Subject`。
     */
    public func set(name: String, value: String): Unit {
        validateName(name)
        validateValue(value)
        let first = indexOf(name)
        if (first < 0) {
            items.add((name, value))
            return
        }
        var i = items.size - 1
        while (i > first) {
            if (equalName(items[i][0], name)) {
                items.remove(i..(i + 1))
            }
            i -= 1
        }
        items[first] = (items[first][0], value)
    }

    public func add(name: String, value: String): Unit {
        validateName(name)
        validateValue(value)
        items.add((name, value))
    }

    /** 删除全部同名项并返回被删除的值（按原顺序）。 */
    public func remove(name: String): Array<String> {
        let removed = ArrayList<String>()
        var i = items.size - 1
        while (i >= 0) {
            if (equalName(items[i][0], name)) {
                removed.add(items[i][1])
                items.remove(i..(i + 1))
            }
            i -= 1
        }
        // 上面是倒序删除，返回值需要翻回原顺序
        let out = ArrayList<String>()
        var j = removed.size - 1
        while (j >= 0) {
            out.add(removed[j])
            j -= 1
        }
        out.toArray()
    }

    /** 按原始顺序返回 `(名字, 值)`。 */
    public func entries(): Array<(String, String)> {
        items.toArray()
    }

    /** 去重后的名字，按首次出现顺序。 */
    public func names(): Array<String> {
        let out = ArrayList<String>()
        for ((key, _) in items) {
            var seen = false
            for (existing in out) {
                if (equalName(existing, key)) {
                    seen = true
                    break
                }
            }
            if (!seen) {
                out.add(key)
            }
        }
        out.toArray()
    }

    public func clear(): Unit {
        items.clear()
    }

    // ---------- 校验 ----------

    private func indexOf(name: String): Int64 {
        var i = 0
        while (i < items.size) {
            if (equalName(items[i][0], name)) {
                return i
            }
            i += 1
        }
        -1
    }

    private func equalName(a: String, b: String): Bool {
        a.toAsciiUpper() == b.toAsciiUpper()
    }

    /**
     * 字段名只允许 `!`–`~` 中除 `:` 的可见 ASCII。
     *
     * 空名字也拒绝：空名字在解析侧会被当成上一条头的续行，放进来只会制造歧义。
     */
    private func validateName(name: String): Unit {
        let bytes = name.toArray()
        if (bytes.size == 0) {
            throw MailProtocolException("头字段名不能为空")
        }
        for (b in bytes) {
            if (b < 33 || b > 126 || b == b':') {
                throw MailProtocolException("头字段名含非法字符：${name}")
            }
        }
    }

    private func validateValue(value: String): Unit {
        let bytes = value.toArray()
        for (b in bytes) {
            if (b == b'\r' || b == b'\n') {
                throw MailProtocolException("头字段值含 CR/LF，拒绝写入（头注入防线）")
            }
        }
        if (bytes.size > MAX_LINE_OCTETS) {
            throw MailLimitException(LimitKind.Header, MAX_LINE_OCTETS, bytes.size)
        }
    }
}
