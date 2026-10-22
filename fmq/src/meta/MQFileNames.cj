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
package fountain::fmq.meta

import std.collection.ArrayList

/**
 * 主题 / 订阅组名到文件名的百分号编码。
 *
 * 只保留 `[A-Za-z0-9._-]`，其余字节写成 `%XX`；空串编码为 `%00`。
 * 编码可逆、无碰撞（`/a_b` → `%2Fa_b`，`/a/b` → `%2Fa%2Fb`）。
 */
protected class MQFileNames {
    private static func isPlain(b: Byte): Bool {
        (b >= b'a' && b <= b'z') || (b >= b'A' && b <= b'Z') || (b >= b'0' && b <= b'9') ||
            b == b'.' || b == b'_' || b == b'-'
    }

    private static func hexOf(value: Int64): Byte {
        if (value < 10) {
            UInt8(Int64(b'0') + value)
        } else {
            UInt8(Int64(b'A') + value - 10)
        }
    }

    private static func valueOf(c: Byte): Int64 {
        if (c >= b'0' && c <= b'9') {
            Int64(c - b'0')
        } else if (c >= b'a' && c <= b'f') {
            Int64(c - b'a') + 10
        } else if (c >= b'A' && c <= b'F') {
            Int64(c - b'A') + 10
        } else {
            -1
        }
    }

    protected static func escape(name: String): String {
        if (name.isEmpty()) {
            return "%00"
        }
        let out = ArrayList<Byte>()
        for (b in name.toArray()) {
            if (isPlain(b)) {
                out.add(b)
            } else {
                out.add(b'%')
                out.add(hexOf(Int64(b) / 16))
                out.add(hexOf(Int64(b) % 16))
            }
        }
        String.fromUtf8(out.toArray())
    }

    protected static func unescape(name: String): String {
        if (name == "%00") {
            return ""
        }
        let raw = name.toArray()
        let out = ArrayList<Byte>()
        var i = 0i64
        while (i < raw.size) {
            if (raw[i] == b'%' && i + 2 < raw.size) {
                let hi = valueOf(raw[i + 1])
                let lo = valueOf(raw[i + 2])
                if (hi >= 0 && lo >= 0) {
                    out.add(UInt8(hi * 16 + lo))
                    i += 3
                    continue
                }
            }
            out.add(raw[i])
            i++
        }
        String.fromUtf8(out.toArray())
    }

    /** `metas/topics/<topicEsc>.meta` */
    protected static func topicFile(topic: String): String {
        "topics/${escape(topic)}.meta"
    }

    /** `metas/groups/<topicEsc>/<groupEsc>.meta` */
    protected static func groupFile(topic: String, group: String): String {
        "groups/${escape(topic)}/${escape(group)}.meta"
    }

    /** `metas/offsets/<topicEsc>/<queueIndex>/<groupEsc>.cursor` */
    protected static func cursorFile(topic: String, queueIndex: Int64, group: String): String {
        "offsets/${escape(topic)}/${queueIndex}/${escape(group)}.cursor"
    }

    /** 段日志目录：`<logRoot>/<topicEsc>/<queueIndex>` */
    protected static func queueDir(logRoot: String, topic: String, queueIndex: Int64): String {
        "${logRoot}/${escape(topic)}/${queueIndex}"
    }
}
