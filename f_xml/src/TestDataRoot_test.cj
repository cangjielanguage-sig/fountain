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

import std.collection.{ArrayList, HashMap}
import std.env
import std.fs.{File, OpenMode, Path, exists}
import fountain::f_base.StringGenerator

/**
 * xmlconf 缓存目录解析。
 *
 * 顺序固定：
 * 1. 环境变量 `F_XML_XMLCONF_CACHE`；
 * 2. `<module>/.cache/xmlconf/`（`cjpm test` 的工作目录就是模块根，R6 实测）。
 *
 * 两者都不存在时**直接 fail**（不 skip）：跳过会让「没跑」看起来像「跑过了」。
 */
internal class TestDataRoot {
    static let MISSING_MESSAGE: String =
        "xmlconf 缓存缺失：请先运行 python3 f_xml/tools/xmlconf_gen.py" +
        "（离线环境请把已生成的缓存放到 F_XML_XMLCONF_CACHE）"

    /** 返回缓存目录；不存在返回 `None`。 */
    static func cacheDir(): ?Path {
        match (env.getVariable("F_XML_XMLCONF_CACHE")) {
            case Some(value) => if (!value.isEmpty()) {
                let path = Path(value)
                if (exists(path.join("cases.json"))) {
                    return Some(path)
                }
            }
            case None => ()
        }
        let local = env.getWorkingDirectory().join(".cache").join("xmlconf")
        if (exists(local.join("cases.json"))) {
            return Some(local)
        }
        None
    }

    static func requireCacheDir(): Path {
        match (cacheDir()) {
            case Some(path) => path
            case None => throw XmlException(MISSING_MESSAGE)
        }
    }
}

/** 一个扁平 JSON 对象（只用于读脚本生成的固定格式清单）。 */
internal class JsonRecord {
    let fields: HashMap<String, String>

    init(fields: HashMap<String, String>) {
        this.fields = fields
    }

    func get(key: String): String {
        match (this.fields.get(key)) {
            case Some(value) => value
            case None => ""
        }
    }

    func isNull(key: String): Bool {
        this.get(key) == "null"
    }
}

/** 极简 JSON 数组解析：只认 `[{...}, ...]` 与字符串 / null 值。 */
internal class FlatJson {
    static func parseArray(text: String): ArrayList<JsonRecord> {
        let records = ArrayList<JsonRecord>()
        let runes = runesOf(text)
        var i: Int64 = 0
        while (i < runes.size) {
            if (runes[i] == r'{') {
                let start = i
                var depth: Int64 = 0
                var inString = false
                var escaped = false
                while (i < runes.size) {
                    let r = runes[i]
                    if (inString) {
                        if (escaped) {
                            escaped = false
                        } else if (r == r'\\') {
                            escaped = true
                        } else if (r == r'"') {
                            inString = false
                        }
                    } else if (r == r'"') {
                        inString = true
                    } else if (r == r'{') {
                        depth++
                    } else if (r == r'}') {
                        depth--
                        if (depth == 0) {
                            break
                        }
                    }
                    i++
                }
                if (i >= runes.size) {
                    break
                }
                records.add(parseObject(runes[start + 1..i]))
                i++
            } else {
                i++
            }
        }
        records
    }

    private static func parseObject(body: Array<Rune>): JsonRecord {
        let fields = HashMap<String, String>()
        var i: Int64 = 0
        while (i < body.size) {
            while (i < body.size && (body[i] == r' ' || body[i] == r'\n' || body[i] == r',' || body[i] == r'\r' ||
                body[i] == r'\t')) {
                i++
            }
            if (i >= body.size) {
                break
            }
            if (body[i] != r'"') {
                i++
                continue
            }
            let (key, next) = readString(body, i)
            i = next
            while (i < body.size && body[i] != r':') {
                i++
            }
            i++
            while (i < body.size && (body[i] == r' ' || body[i] == r'\n' || body[i] == r'\r' || body[i] == r'\t')) {
                i++
            }
            if (i >= body.size) {
                break
            }
            if (body[i] == r'"') {
                let (value, nextValue) = readString(body, i)
                fields[key] = value
                i = nextValue
            } else {
                let start = i
                while (i < body.size && body[i] != r',' && body[i] != r'}') {
                    i++
                }
                let gen = StringGenerator()
                for (k in start..i) {
                    gen.append(body[k])
                }
                fields[key] = gen.toString().trimAscii()
            }
        }
        JsonRecord(fields)
    }

    private static func readString(body: Array<Rune>, from: Int64): (String, Int64) {
        let gen = StringGenerator()
        var i = from + 1
        while (i < body.size) {
            let r = body[i]
            if (r == r'"') {
                return (gen.toString(), i + 1)
            }
            if (r == r'\\' && i + 1 < body.size) {
                i++
                match (body[i]) {
                    case r'n' => gen.append<String>("\n")
                    case r't' => gen.append<String>("\t")
                    case r'r' => gen.append<String>("\r")
                    case r'"' => gen.append<String>("\"")
                    case r'\\' => gen.append<String>("\\")
                    case _ => gen.append(body[i])
                }
            } else {
                gen.append(r)
            }
            i++
        }
        (gen.toString(), i)
    }

    static func readFile(path: Path): String {
        let file = File(path.toString(), OpenMode.Read)
        try {
            let bytes = ArrayList<Byte>()
            let buffer = Array<Byte>(8192, repeat: 0)
            var reading = true
            while (reading) {
                let n = file.read(buffer)
                if (n <= 0) {
                    reading = false
                } else {
                    for (i in 0..n) {
                        bytes.add(buffer[i])
                    }
                }
            }
            String.fromUtf8(bytes.toArray())
        } finally {
            file.close()
        }
    }
}
