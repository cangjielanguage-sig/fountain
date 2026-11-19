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
package fountain::f_data.json

import std.collection.HashMap
import fountain::f_regex.*

/**
 * 注册期编译过的 JSON Schema。
 *
 * 只做两件在请求路径上值钱的事：
 * 1. 结构校验 —— 关键字取值类型不对（`pattern: 1`、`required: "x"`）在注册期就报错，
 *    而不是等到第一个请求才暴露；
 * 2. `pattern` 预编译 —— 请求期直接查表，不再每请求走一次全局正则缓存。
 *
 * 校验语义完全复用 [JsonSchemaValidator]（同一个遍历器），不存在第二套实现。
 */
public class CompiledSchema {
    private let schemaDoc: JsonObject
    private let patterns: HashMap<String, Regex>

    private CompiledSchema(schema: JsonObject, patterns: HashMap<String, Regex>) {
        this.schemaDoc = schema
        this.patterns = patterns
    }

    /** 遍历一次 schema 文档：校验关键字类型并预编译所有 `pattern`。 */
    public static func compile(schema: JsonObject): CompiledSchema {
        let patterns = HashMap<String, Regex>()
        checkDoc(schema, '', patterns)
        CompiledSchema(schema, patterns)
    }

    public prop schema: JsonObject {
        get() {
            schemaDoc
        }
    }

    /** 预编译的正则条数（同一 pattern 只编译一次）。 */
    public prop patternCount: Int64 {
        get() {
            patterns.size
        }
    }

    public func validate(value: JsonValue, options!: ValidationOptions = ValidationOptions()): ValidationResult {
        JsonSchemaValidator.validateWithPatterns(schemaDoc, value, patterns, options)
    }

    private static func checkDoc(value: JsonValue, path: String, patterns: HashMap<String, Regex>): Unit {
        match (value) {
            case obj: JsonObject =>
                checkObject(obj, path, patterns)
                for ((key, child) in obj) {
                    checkDoc(child, '${path}/${key}', patterns)
                }
            case array: JsonArray =>
                var index = 0
                for (child in array) {
                    checkDoc(child, '${path}/${index}', patterns)
                    index++
                }
            case _ => ()
        }
    }

    private static func checkObject(obj: JsonObject, path: String, patterns: HashMap<String, Regex>): Unit {
        if (let Some(value) <- obj.get('pattern')) {
            let pattern = match (value) {
                case text: JsonString => text.value
                case _ => throw invalid(path, 'pattern', 'must be a string')
            }
            try {
                let regex = pattern.regex(solid: false)
                patterns.add(pattern, regex)
            } catch (_: Exception) {
                throw invalid(path, 'pattern', "invalid regular expression '${pattern}'")
            }
        }
        if (let Some(value) <- obj.get('required')) {
            match (value) {
                case array: JsonArray =>
                    for (item in array) {
                        if (!(item is JsonString)) {
                            throw invalid(path, 'required', 'must be an array of strings')
                        }
                    }
                case _ => throw invalid(path, 'required', 'must be an array of strings')
            }
        }
        if (let Some(value) <- obj.get('type')) {
            match (value) {
                case text: JsonString => ()
                case array: JsonArray =>
                    for (item in array) {
                        if (!(item is JsonString)) {
                            throw invalid(path, 'type', 'must be a string or an array of strings')
                        }
                    }
                case _ => throw invalid(path, 'type', 'must be a string or an array of strings')
            }
        }
        if (let Some(value) <- obj.get('enum')) {
            if (!(value is JsonArray)) {
                throw invalid(path, 'enum', 'must be an array')
            }
        }
        for (keyword in ['minLength', 'maxLength', 'minItems', 'maxItems', 'minProperties', 'maxProperties']) {
            if (let Some(value) <- obj.get(keyword)) {
                if (!(value is JsonInt) && !(value is JsonDecimal)) {
                    throw invalid(path, keyword, 'must be a number')
                }
            }
        }
        for (keyword in ['minimum', 'maximum', 'exclusiveMinimum', 'exclusiveMaximum', 'multipleOf']) {
            if (let Some(value) <- obj.get(keyword)) {
                if (!(value is JsonInt) && !(value is JsonDecimal)) {
                    throw invalid(path, keyword, 'must be a number')
                }
            }
        }
        if (let Some(value) <- obj.get('nullable')) {
            if (!(value is JsonBool)) {
                throw invalid(path, 'nullable', 'must be a boolean')
            }
        }
    }

    private static func invalid(path: String, keyword: String, detail: String): IllegalArgumentException {
        IllegalArgumentException("invalid json schema at '${path}': keyword '${keyword}' ${detail}")
    }
}
