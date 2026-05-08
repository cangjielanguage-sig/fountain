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
    if (topic[0] != r'/') { return false }
    for (ch in topic.toRuneArray()) {
        if (ch == r'/' || ch == r'_' || ch == r'-' || ch == r'.') { continue }
        if ((ch >= r'0' && ch <= r'9') || (ch >= r'a' && ch <= r'z') || (ch >= r'A' && ch <= r'Z')) { continue }
        return false
    }
    true
}

/**
 * 将 topic 路径编码为文件系统安全名称。
 * '/' → '_'，其余字符不变。
 * 如 "/order/create" → "_order_create"
 */
public func encodeTopicToPath(topic: String): String {
    topic.replace("/", "_")
}

/**
 * 将编码后的路径名解码为 topic。
 * '_' → '/'，其余字符不变。
 */
public func decodePathToTopic(path: String): String {
    path.replace("_", "/")
}
