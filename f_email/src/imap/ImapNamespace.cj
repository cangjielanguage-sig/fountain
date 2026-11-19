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
import fountain::f_email.model.MailProtocolException

/** 命名空间的一段：`(prefix delimiter)`。 */
public struct NamespaceEntry {
    public let prefix: String
    public let delimiter: ?String

    public init(prefix: String, delimiter!: ?String = None) {
        this.prefix = prefix
        this.delimiter = delimiter
    }
}

/** `NAMESPACE` 的三段：个人 / 其他用户 / 共享。 */
public struct NamespaceInfo {
    public let personal: Array<NamespaceEntry>
    public let otherUsers: Array<NamespaceEntry>
    public let shared: Array<NamespaceEntry>

    public init(
        personal!: Array<NamespaceEntry> = [],
        otherUsers!: Array<NamespaceEntry> = [],
        shared!: Array<NamespaceEntry> = []
    ) {
        this.personal = personal
        this.otherUsers = otherUsers
        this.shared = shared
    }

    /** 个人命名空间的第一个前缀与分隔符（最常见的用法）。 */
    public func primaryPrefix(): String {
        if (personal.size == 0) {
            return ""
        }
        personal[0].prefix
    }

    public func primaryDelimiter(): ?String {
        if (personal.size == 0) {
            return None
        }
        personal[0].delimiter
    }
}

/**
 * `NAMESPACE`（RFC 2342）。
 *
 * `* NAMESPACE (("" "/")) NIL NIL` 表示：个人命名空间从根开始、分隔符 `/`，
 * 没有其他用户与共享命名空间。拼接必须走 [joinPath]——直接 `prefix + "/" + name`
 * 在 prefix 以分隔符结尾时会拼出 `INBOX//Sent`。
 */
public class ImapNamespace {
    private let client: ImapClient

    public init(client: ImapClient) {
        this.client = client
    }

    public func fetch(): NamespaceInfo {
        client.requireCapability("NAMESPACE")
        let result = client.execute("NAMESPACE")
        for (untagged in result.untagged) {
            if ((untagged.name ?? "") == "NAMESPACE") {
                return parse(untagged)
            }
        }
        if (!result.isOk()) {
            throw MailProtocolException("NAMESPACE 失败：${result.response.raw}")
        }
        NamespaceInfo()
    }

    /** 解析三段；`NIL` 段解析为空列表。 */
    public static func parse(response: ImapResponse): NamespaceInfo {
        let values = response.values
        NamespaceInfo(
            personal: parseSegment(values, 0),
            otherUsers: parseSegment(values, 1),
            shared: parseSegment(values, 2)
        )
    }

    static func parseSegment(values: Array<ImapValue>, index: Int64): Array<NamespaceEntry> {
        if (index >= values.size) {
            return []
        }
        let out = ArrayList<NamespaceEntry>()
        match (values[index]) {
            case List(entries) =>
                for (entry in entries) {
                    match (entry) {
                        case List(pair) =>
                            if (pair.size >= 1) {
                                let prefix = pair[0].text()
                                let delimiter = if (pair.size > 1) {
                                    stringOrNone(pair[1])
                                } else {
                                    None<String>
                                }
                                out.add(NamespaceEntry(prefix, delimiter: delimiter))
                            }
                        case _ => ()
                    }
                }
            case _ => ()
        }
        out.toArray()
    }

    /** 按分隔符拼接，且不会产生重复分隔符。 */
    public static func joinPath(prefix: String, delimiter: ?String, name: String): String {
        let sep = match (delimiter) {
            case Some(value) => value
            case None => ""
        }
        if (prefix.size == 0) {
            return name
        }
        if (sep.size == 0) {
            return prefix + name
        }
        if (prefix[(prefix.size - sep.size)..] == sep) {
            return prefix + name
        }
        if (name.size > 0 && name[0..sep.size] == sep) {
            return prefix + name
        }
        prefix + sep + name
    }
}
