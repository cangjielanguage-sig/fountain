/*
Copyright (c) 2025 WuJingrun（吴京润）

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
package fountain::f_data.json

import std.collection.concurrent.ConcurrentMap

public interface ToJsonString {
    func toJsonString(): String
}

private let JSON_HEX_DIGITS: Array<Rune> = [r'0', r'1', r'2', r'3', r'4', r'5', r'6', r'7', r'8', r'9', r'a', r'b', r'c', r'd', r'e', r'f']

/**
 * 按 JSON 字符串规则转义：双引号、反斜杠、换行/回车/制表符，以及其余码位 < 0x20 的字符。
 * 修复历史缺陷：`ToJsonString` 这条「Data → JSON 文本」路径此前直接拼引号，
 * 含 `"`/`\`/换行的数据会生成非法 JSON（走 JsonWriter 的 JsonValue.toJsonString 路径不受影响）。
 */
internal func escapeJsonString(s: String): String {
    let builder = StringGenerator()
    for (r in s.runes()) {
        if (r == r'"') {
            builder.append("\\\"")
        } else if (r == r'\\') {
            builder.append("\\\\")
        } else if (r == r'\n') {
            builder.append("\\n")
        } else if (r == r'\r') {
            builder.append("\\r")
        } else if (r == r'\t') {
            builder.append("\\t")
        } else if (r.position() < 0x20) {
            let cp = r.position()
            builder.append('\\u00')
            builder.append(JSON_HEX_DIGITS[cp >> 4])
            builder.append(JSON_HEX_DIGITS[cp & 0xF])
        } else {
            builder.append(r)
        }
    }
    builder.toString()
}

extend DataBool <: ToJsonString {
    public func toJsonString(): String {
        toString()
    }
}

extend DataDateTime <: ToJsonString {
    public func toJsonString(): String {
        '\"${toString()}\"'
    }
}

extend DataDuration <: ToJsonString {
    public func toJsonString(): String {
        '\"${toString()}\"'
    }
}

extend DataNone <: ToJsonString {
    public func toJsonString(): String {
        'null'
    }
}

extend DataString <: ToJsonString {
    public func toJsonString(): String {
        '"${escapeJsonString(toString())}"'
    }
}

extend DataReal <: ToJsonString {
    public func toJsonString(): String {
        toString()
    }
}

extend<T> DataObject<T> <: ToJsonString where T <: ObjectData<T> {
    public func toJsonString(): String {
        let builder = StringGenerator('{')
        for ((name, value) in this) {
            let valStr = match (value) {
                case x: ToJsonString => x.toJsonString()
                case _ => continue
            }
            if (builder.size > 1) {
                builder.append(',')
            }
            builder.append('"${escapeJsonString(name)}"')
            builder.append(':')
            builder.append(valStr)
        }
        builder.append('}')
        builder.toString()
    }
}

extend<C, T> DataCollection<C, T> <: ToJsonString where T <: DataFields<T>, C <: DataFields<C> & Collection<T> {
    public func toJsonString(): String {
        let builder = StringGenerator('[')
        for (d in this) {
            let valStr = match (d) {
                case x: ToJsonString => x.toJsonString()
                case _ => continue
            }
            if (builder.size > 1) {
                builder.append(',')
            }
            builder.append(valStr)
        }
        builder.append(']')
        builder.toString()
    }
}

extend<M, K, V> DataMap<M, K, V> <: ToJsonString where K <: DataFields<K>, V <: DataFields<V>,
    M <: DataFields<M> & Map<K, V> {
    public func toJsonString(): String {
        let builder = StringGenerator('{')
        for ((k, v) in this) {
            let (ks, vs) = match ((k, v)) {
                case (x: ToJsonString, y: ToJsonString) => (x.toJsonString(), y.toJsonString())
                case _ => continue
            }
            if (builder.size > 1) {
                builder.append(',')
            }
            if (ks.startsWith('"') && ks.endsWith('"')) {
                builder.append(ks)
            } else {
                builder.append('"${ks}"')
            }
            builder.append(':')
            builder.append(vs)
        }
        builder.append('}')
        builder.toString()
    }
}

extend<M, K, V> DataConcurrentMap<M, K, V> <: ToJsonString where K <: DataFields<K>, V <: DataFields<V>,
    M <: DataFields<M> & ConcurrentMap<K, V> {
    public func toJsonString(): String {
        let builder = StringGenerator('{')
        for ((k, v) in this) {
            let (ks, vs) = match ((k, v)) {
                case (x: ToJsonString, y: ToJsonString) => (x.toJsonString(), y.toJsonString())
                case _ => continue
            }
            if (builder.size > 1) {
                builder.append(',')
            }
            if (ks.startsWith('"') && ks.endsWith('"')) {
                builder.append(ks)
            } else {
                builder.append('"${ks}"')
            }
            builder.append(':')
            builder.append(vs)
        }
        builder.append('}')
        builder.toString()
    }
}
