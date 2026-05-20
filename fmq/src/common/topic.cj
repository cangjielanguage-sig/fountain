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
package fountain::fmq.common

/**
 * 校验 topic 路径是否合法。
 * 合法条件：
 * - 以 '/' 开头
 * - 非空
 * - 不含除字母、数字、'_'、'/'、'-'、'.' 之外的字符
 */
public func validateTopic(topic: String): Bool {
    if (topic.isEmpty()) { return false }
    if (!topic.startsWith("/")) { return false }
    for (i in 0..topic.size) {
        let ch = topic[i]
        if (ch >= 0x30u8 && ch <= 0x39u8) { continue }  // 0-9
        if (ch >= 0x41u8 && ch <= 0x5Au8) { continue }  // A-Z
        if (ch >= 0x61u8 && ch <= 0x7Au8) { continue }  // a-z
        if (ch == 0x2Fu8 || ch == 0x5Fu8 || ch == 0x2Du8 || ch == 0x2Eu8) { continue }  // / _ - .
        return false
    }
    true
}

/**
 * 将 topic 路径编码为文件系统安全名称。
 * 使用转义编码避免 _ 歧义：
 *   '/' → '_'（单个下划线）
 *   '_' → '__'（双下划线）
 *
 * 示例：
 *   "/order/create" → "_order_create"
 *   "/a_b"         → "_a__b"
 */
public func encodeTopicToPath(topic: String): String {
    let parts = ArrayList<UInt8>()
    for (b in topic) {
        match (b) {
            case b'/' => parts.add(b'_')         // '/' -> '_'
            case b'_' => parts.add(all: [b'_', b'_']) // '_' -> '__'
            case _ => parts.add(b)
        }
    }
    String.fromUtf8(parts.unsafeData())
}

/**
 * 将编码后的路径名解码为 topic。
 * 解码顺序：先 '__' → '_'，再单 '_' → '/'。
 * 使用 ArrayList<UInt8> 避免 O(n²) 字符串拼接。
 *
 * 示例：
 *   "_order_create" → "/order/create"
 *   "_a__b"        → "/a_b"
 */
public func decodePathToTopic(path: String): String {
    let parts = ArrayList<UInt8>()
    var i = 0
    while (i < path.size) {
        let ch = path[i]
        if (ch == 0x5Fu8) {  // '_'
            if (i + 1 < path.size && path[i + 1] == 0x5Fu8) {
                parts.add(b'_')  // '__' → '_'
                i += 2
            } else {
                parts.add(b'/')  // '_' → '/'
                i += 1
            }
        } else {
            parts.add(ch)
            i += 1
        }
    }
    String.fromUtf8(parts.unsafeData())
}
