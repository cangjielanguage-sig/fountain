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

import std.collection.{ArrayList, HashMap}
import std.math.numeric.{BigInt, Decimal}
import fountain::f_regex.*

/**
 * 一条校验失败。`path` 是 JSON Pointer（'' 为根，'/limit' 为成员，'/tags/0' 为数组元素），
 * `keyword` 是触发失败的关键字，`message` 是给人看的说明（不保证可解析）。
 */
public struct ValidationError {
    public const ValidationError(public let path: String, public let keyword: String, public let message: String) {}
}

/** 校验结果。`skipped` 记录 lenient 模式下被跳过的关键字（带路径），供事后审计。 */
public struct ValidationResult {
    public const ValidationResult(public let errors!: Array<ValidationError> = Array<ValidationError>(),
        public let skipped!: Array<String> = Array<String>()) {}

    public prop isValid: Bool {
        get() {
            errors.size == 0
        }
    }

    /** 直接塞进 JSON-RPC 的 error.data，客户端可按 path 定位字段。 */
    public func toJson(): JsonArray {
        let list = ArrayList<JsonValue>()
        for (e in errors) {
            let obj = JsonObject()
            obj.add('path', e.path)
            obj.add('keyword', e.keyword)
            obj.add('message', e.message)
            list.add(obj)
        }
        JsonArray(list: list)
    }
}

public enum UnknownKeyword {
    | Reject
    | Skip
}

public struct ValidationOptions {
    public const ValidationOptions(public let maxErrors!: Int64 = 32, public let maxDepth!: Int64 = 64,
        public let unknownKeyword!: UnknownKeyword = UnknownKeyword.Reject) {}
}

// format 的固定模式：编译期常量，走 solid: true 的进程级表；
// schema 文档里的 pattern 是外部输入，走 solid: false 的 HeapCache（有上限）。
private let EMAIL_RE = Regex.EMAIL
private let DATE_RE = #"^\d{4}-\d{2}-\d{2}$"#.regex(solid: true)
private let DATETIME_RE = #"^\d{4}-\d{2}-\d{2}[Tt ]\d{2}:\d{2}:\d{2}(\.\d+)?([Zz]|[+-]\d{2}:?\d{2})?$"#.regex(
    solid: true)
private let UUID_RE = #"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"#.regex(
    solid: true)

class ValidationCtx {
    let options: ValidationOptions
    let errors = ArrayList<ValidationError>()
    let skipped = ArrayList<String>()
    private let patterns: ?HashMap<String, Regex>
    private var stopped = false

    init(options: ValidationOptions, patterns!: ?HashMap<String, Regex> = None) {
        this.options = options
        this.patterns = patterns
    }

    /** 取预编译的正则；没有预编译表时按需编译（与旧行为一致）。 */
    func regexFor(pattern: String): Regex {
        match (patterns) {
            case Some(table) =>
                match (table.get(pattern)) {
                    case Some(re) => re
                    case _ =>
                        let re = pattern.regex(solid: false)
                        table.add(pattern, re)
                        re
                }
            case _ => pattern.regex(solid: false)
        }
    }

    prop aborted: Bool {
        get() {
            stopped
        }
    }

    func add(path: String, keyword: String, message: String): Unit {
        if (stopped) {
            return
        }
        errors.add(ValidationError(path, keyword, message))
        if (errors.size >= options.maxErrors) {
            stopped = true
        }
    }

    func skip(path: String, keyword: String): Unit {
        skipped.add(if (path.isEmpty()) {
            keyword
        } else {
            '${path}/${keyword}'
        })
    }

    func result(): ValidationResult {
        ValidationResult(errors: errors.toArray(), skipped: skipped.toArray())
    }
}

/**
 * JSON Schema 运行时校验器。
 *
 * 两个入口：
 * - `JsonSchemaValidator.validate(schema, value)`：按 schema 文档校验（对象成员靠它）
 * - `JsonSchema.validate(value)`：按注解实例校验（单标量 / 数组）
 *
 * 语言限制：仓颉不允许静态方法与实例方法同名重载，所以文档版没有做成
 * `JsonSchema.validate(schema, value)`（见设计 4.7.1 的退化方案）。
 */
public class JsonSchemaValidator {
    public static func validate(schema: JsonObject, value: JsonValue, options!: ValidationOptions = ValidationOptions()): ValidationResult {
        let ctx = ValidationCtx(options)
        validateDoc(schema, value, '', ctx, 0)
        ctx.result()
    }

    /** 复用已预编译的 `pattern` 表（`CompiledSchema` 的入口）。 */
    static func validateWithPatterns(schema: JsonObject, value: JsonValue, patterns: HashMap<String, Regex>,
        options: ValidationOptions): ValidationResult {
        let ctx = ValidationCtx(options, patterns: patterns)
        validateDoc(schema, value, '', ctx, 0)
        ctx.result()
    }

    static func validateInstance(schema: JsonSchema, value: JsonValue, options: ValidationOptions): ValidationResult {
        let ctx = ValidationCtx(options)
        validateInstanceAt(schema, value, '', ctx, 0)
        ctx.result()
    }

    // —— 文档校验 ——

    private static func validateDoc(schema: JsonValue, value: JsonValue, path: String, ctx: ValidationCtx, depth: Int64): Unit {
        if (ctx.aborted) {
            return
        }
        if (depth > ctx.options.maxDepth) {
            ctx.add(path, '$schema', 'schema depth exceeds ${ctx.options.maxDepth}')
            return
        }
        if (!(schema is JsonObject)) {
            ctx.add(path, '$schema', 'schema must be an object')
            return
        }
        let obj = schema.asObject()

        var nullable = false
        if (let Some(n) <- obj.get('nullable')) {
            if (n is JsonBool) {
                nullable = n.asBool().value
            } else {
                ctx.add(path, '$schema', 'nullable must be a boolean')
                return
            }
        }
        if (nullable && value is JsonNull) {
            return
        }

        if (let Some(t) <- obj.get('type')) {
            match (typeNames(t)) {
                case Some(names) =>
                    var ok = false
                    for (n in names) {
                        if (matchesType(value, n)) {
                            ok = true
                            break
                        }
                    }
                    if (!ok) {
                        ctx.add(path, 'type', "expected type ${names.toString()}, got ${typeName(value)}")
                        return
                    }
                case _ =>
                    ctx.add(path, '$schema', 'type must be a string or an array of strings')
                    return
            }
        }

        if (let Some(e) <- obj.get('enum')) {
            match (asEnumValues(e)) {
                case Some(values) =>
                    var found = false
                    for (item in values) {
                        if (jsonEquals(item, value)) {
                            found = true
                            break
                        }
                    }
                    if (!found) {
                        ctx.add(path, 'enum', 'value is not one of the enumerated values')
                    }
                case _ => ctx.add(path, '$schema', 'enum must be an array')
            }
        }

        if (let s: JsonString <- value) {
            validateStringDoc(obj, s.value, path, ctx)
        }
        if (value is JsonInt || value is JsonDecimal) {
            validateNumberDoc(obj, value, path, ctx)
        }
        if (let a: JsonArray <- value) {
            validateArrayDoc(obj, a, path, ctx, depth)
        }
        if (let o: JsonObject <- value) {
            validateObjectDoc(obj, o, path, ctx, depth)
        }
        checkUnknownKeywords(obj, path, ctx)
    }

    private static func validateStringDoc(obj: JsonObject, s: String, path: String, ctx: ValidationCtx): Unit {
        let length = s.toRuneArray().size
        if (let Some(n) <- intKeyword(obj, 'minLength', path, ctx) && length < n) {
            ctx.add(path, 'minLength', 'string length ${length} is less than ${n}')
        }
        if (let Some(n) <- intKeyword(obj, 'maxLength', path, ctx) && length > n) {
            ctx.add(path, 'maxLength', 'string length ${length} is greater than ${n}')
        }
        if (let Some(p) <- stringKeyword(obj, 'pattern', path, ctx)) {
            try {
                if (!ctx.regexFor(p).matches(s)) {
                    ctx.add(path, 'pattern', "string does not match pattern '${p}'")
                }
            } catch (_: Exception) {
                ctx.add(path, '$schema', "invalid pattern '${p}'")
            }
        }
        if (let Some(f) <- stringKeyword(obj, 'format', path, ctx)) {
            checkFormat(f, s, path, ctx)
        }
    }

    private static func checkFormat(format: String, s: String, path: String, ctx: ValidationCtx): Unit {
        var ok = true
        match (format) {
            case 'email' => ok = EMAIL_RE.matches(s)
            case 'date' => ok = DATE_RE.matches(s)
            case 'date-time' => ok = DATETIME_RE.matches(s)
            case 'uuid' => ok = UUID_RE.matches(s)
            case _ =>
                unknownKeyword("format:${format}", path, ctx)
                return
        }
        if (!ok) {
            ctx.add(path, 'format', "string does not match format '${format}'")
        }
    }

    private static func validateNumberDoc(obj: JsonObject, value: JsonValue, path: String, ctx: ValidationCtx): Unit {
        let d = asDecimal(value)
        if (let Some(n) <- numberKeyword(obj, 'minimum', path, ctx) && d < n) {
            ctx.add(path, 'minimum', 'value is less than ${n}')
        }
        if (let Some(n) <- numberKeyword(obj, 'maximum', path, ctx) && d > n) {
            ctx.add(path, 'maximum', 'value is greater than ${n}')
        }
        if (let Some(n) <- numberKeyword(obj, 'exclusiveMinimum', path, ctx) && d <= n) {
            ctx.add(path, 'exclusiveMinimum', 'value must be greater than ${n}')
        }
        if (let Some(n) <- numberKeyword(obj, 'exclusiveMaximum', path, ctx) && d >= n) {
            ctx.add(path, 'exclusiveMaximum', 'value must be less than ${n}')
        }
        if (let Some(n) <- numberKeyword(obj, 'multipleOf', path, ctx)) {
            if (n <= Decimal(0)) {
                ctx.add(path, '$schema', 'multipleOf must be greater than zero')
            } else {
                let (_, remainder) = d.divAndMod(n)
                if (remainder != Decimal(0)) {
                    ctx.add(path, 'multipleOf', 'value is not a multiple of ${n}')
                }
            }
        }
    }

    private static func validateArrayDoc(obj: JsonObject, value: JsonArray, path: String, ctx: ValidationCtx,
        depth: Int64): Unit {
        if (let Some(n) <- intKeyword(obj, 'minItems', path, ctx) && value.size < n) {
            ctx.add(path, 'minItems', 'array has ${value.size} items, less than ${n}')
        }
        if (let Some(n) <- intKeyword(obj, 'maxItems', path, ctx) && value.size > n) {
            ctx.add(path, 'maxItems', 'array has ${value.size} items, greater than ${n}')
        }
        if (let Some(u) <- boolKeyword(obj, 'uniqueItems', path, ctx) && u) {
            if (value.size > 1000) {
                ctx.skip(path, 'uniqueItems')
            } else if (hasDuplicates(value)) {
                ctx.add(path, 'uniqueItems', 'array items must be unique')
            }
        }
        if (let Some(items) <- obj.get('items')) {
            var index = 0
            for (item in value) {
                validateDoc(items, item, joinPath(path, index.toString()), ctx, depth + 1)
                index++
            }
        }
    }

    private static func validateObjectDoc(obj: JsonObject, value: JsonObject, path: String, ctx: ValidationCtx,
        depth: Int64): Unit {
        var properties = None<JsonObject>
        if (let Some(p) <- obj.get('properties')) {
            if (p is JsonObject) {
                properties = Some(p.asObject())
            } else {
                ctx.add(path, '$schema', 'properties must be an object')
                return
            }
        }
        if (let Some(r) <- obj.get('required')) {
            match (stringArray(r)) {
                case Some(names) => for (name in names) {
                    if (!value.contains(name)) {
                        ctx.add(path, 'required', "required member '${name}' is missing")
                    }
                }
                case _ => ctx.add(path, '$schema', 'required must be an array of strings')
            }
        }
        if (let Some(props) <- properties) {
            for ((name, sub) in props) {
                if (let Some(v) <- value.get(name)) {
                    validateDoc(sub, v, joinPath(path, name), ctx, depth + 1)
                }
            }
        }
        if (let Some(ap) <- obj.get('additionalProperties')) {
            if (ap is JsonBool) {
                if (!ap.asBool().value) {
                    for ((name, _) in value) {
                        let declared = match (properties) {
                            case Some(props) => props.contains(name)
                            case _ => false
                        }
                        if (!declared) {
                            ctx.add(joinPath(path, name), 'additionalProperties', "member '${name}' is not allowed")
                        }
                    }
                }
            } else {
                ctx.add(path, '$schema', 'additionalProperties must be a boolean')
            }
        }
    }

    private static func checkUnknownKeywords(obj: JsonObject, path: String, ctx: ValidationCtx): Unit {
        for ((key, _) in obj) {
            match (key) {
                case 'type' | 'nullable' | 'enum' | 'title' | 'description' | 'default' | '$schema' | 'minLength'
                    | 'maxLength' | 'pattern' | 'format' | 'minimum' | 'maximum' | 'exclusiveMinimum'
                    | 'exclusiveMaximum' | 'multipleOf' | 'minItems' | 'maxItems' | 'uniqueItems' | 'items'
                    | 'properties' | 'required' | 'additionalProperties' => ()
                case _ => unknownKeyword(key, path, ctx)
            }
        }
    }

    private static func unknownKeyword(keyword: String, path: String, ctx: ValidationCtx): Unit {
        match (ctx.options.unknownKeyword) {
            case UnknownKeyword.Reject => ctx.add(path, '$schema', "unsupported keyword '${keyword}'")
            case UnknownKeyword.Skip => ctx.skip(path, keyword)
        }
    }

    // —— 实例校验 ——

    private static func validateInstanceAt(schema: JsonSchema, value: JsonValue, path: String, ctx: ValidationCtx,
        depth: Int64): Unit {
        if (ctx.aborted) {
            return
        }
        if (depth > ctx.options.maxDepth) {
            ctx.add(path, '$schema', 'schema depth exceeds ${ctx.options.maxDepth}')
            return
        }
        match (schema) {
            case s: JsonBoolSchema => requireType(value, 'boolean', path, ctx)
            case s: JsonIntSchema =>
                if (requireType(value, 'integer', path, ctx)) {
                    let v = value.asInt().value
                    validateBigIntKeywords(s, v, path, ctx)
                }
            case s: JsonFloatSchema =>
                if (requireType(value, 'number', path, ctx)) {
                    validateDecimalKeywords(s, asDecimal(value), path, ctx)
                }
            case s: JsonStringSchema =>
                if (requireType(value, 'string', path, ctx)) {
                    validateStringInstance(s, value.asString().value, path, ctx)
                }
            case s: JsonArraySchema =>
                if (requireType(value, 'array', path, ctx)) {
                    validateArrayInstance(s, value.asArray(), path, ctx, depth)
                }
            case s: JsonObjectSchema =>
                if (requireType(value, 'object', path, ctx)) {
                    validateObjectInstance(s, value.asObject(), path, ctx)
                }
        }
    }

    private static func validateStringInstance(s: JsonStringSchema, text: String, path: String, ctx: ValidationCtx): Unit {
        let length = text.toRuneArray().size
        if (let Some(n) <- s.minLength && length < n) {
            ctx.add(path, 'minLength', 'string length ${length} is less than ${n}')
        }
        if (let Some(n) <- s.maxLength && length > n) {
            ctx.add(path, 'maxLength', 'string length ${length} is greater than ${n}')
        }
        if (let Some(p) <- s.pattern) {
            try {
                if (!p.regex(solid: false).matches(text)) {
                    ctx.add(path, 'pattern', "string does not match pattern '${p}'")
                }
            } catch (_: Exception) {
                ctx.add(path, '$schema', "invalid pattern '${p}'")
            }
        }
        if (let Some(f) <- s.format) {
            checkFormat(f, text, path, ctx)
        }
        if (let Some(e) <- s.enumeration) {
            checkEnumText(e, JsonString(text), path, ctx)
        }
    }

    private static func validateBigIntKeywords(s: JsonIntSchema, v: BigInt, path: String, ctx: ValidationCtx): Unit {
        if (let Some(n) <- s.minimum) {
            if (v < BigInt(n)) {
                ctx.add(path, 'minimum', 'value is less than ${n}')
            }
        }
        if (let Some(n) <- s.maximum) {
            if (v > BigInt(n)) {
                ctx.add(path, 'maximum', 'value is greater than ${n}')
            }
        }
        if (let Some(n) <- s.multipleOf) {
            if (n <= 0) {
                ctx.add(path, '$schema', 'multipleOf must be greater than zero')
            } else if (v % BigInt(n) != BigInt(0)) {
                ctx.add(path, 'multipleOf', 'value is not a multiple of ${n}')
            }
        }
        if (let Some(e) <- s.enumeration) {
            checkEnumText(e, JsonInt(v), path, ctx)
        }
    }

    private static func validateDecimalKeywords(s: JsonFloatSchema, v: Decimal, path: String, ctx: ValidationCtx): Unit {
        if (let Some(n) <- s.minimum) {
            let d = Decimal(n)
            let bad = if (s.exclusiveMinimum) {
                v <= d
            } else {
                v < d
            }
            if (bad) {
                ctx.add(path, if (s.exclusiveMinimum) {
                    'exclusiveMinimum'
                } else {
                    'minimum'
                }, 'value is out of range (${n})')
            }
        }
        if (let Some(n) <- s.maximum) {
            let d = Decimal(n)
            let bad = if (s.exclusiveMaximum) {
                v >= d
            } else {
                v > d
            }
            if (bad) {
                ctx.add(path, if (s.exclusiveMaximum) {
                    'exclusiveMaximum'
                } else {
                    'maximum'
                }, 'value is out of range (${n})')
            }
        }
        if (let Some(n) <- s.multipleOf) {
            let d = Decimal(n)
            if (d <= Decimal(0)) {
                ctx.add(path, '$schema', 'multipleOf must be greater than zero')
            } else {
                let (_, remainder) = v.divAndMod(d)
                if (remainder != Decimal(0)) {
                    ctx.add(path, 'multipleOf', 'value is not a multiple of ${n}')
                }
            }
        }
        if (let Some(e) <- s.enumeration) {
            checkEnumText(e, JsonDecimal(v), path, ctx)
        }
    }

    private static func validateArrayInstance(s: JsonArraySchema, value: JsonArray, path: String, ctx: ValidationCtx,
        depth: Int64): Unit {
        if (let Some(n) <- s.minItems && value.size < n) {
            ctx.add(path, 'minItems', 'array has ${value.size} items, less than ${n}')
        }
        if (let Some(n) <- s.maxItems && value.size > n) {
            ctx.add(path, 'maxItems', 'array has ${value.size} items, greater than ${n}')
        }
        if (let Some(u) <- s.uniqueItems && u) {
            if (value.size > 1000) {
                ctx.skip(path, 'uniqueItems')
            } else if (hasDuplicates(value)) {
                ctx.add(path, 'uniqueItems', 'array items must be unique')
            }
        }
        if (let Some(items) <- s.items) {
            var index = 0
            for (item in value) {
                validateInstanceAt(items, item, joinPath(path, index.toString()), ctx, depth + 1)
                index++
            }
        }
    }

    private static func validateObjectInstance(s: JsonObjectSchema, value: JsonObject, path: String, ctx: ValidationCtx): Unit {
        if (let Some(r) <- s.required) {
            match (stringArray(JsonValue.fromStr(r))) {
                case Some(names) => for (name in names) {
                    if (!value.contains(name)) {
                        ctx.add(path, 'required', "required member '${name}' is missing")
                    }
                }
                case _ => ctx.add(path, '$schema', 'required must be an array of strings')
            }
        }
        // 实例模式没有 properties，无从判断哪些是"额外"的：additionalProperties 必须跳过（设计 4.7.2）。
    }

    // —— 关键字读取 ——

    private static func intKeyword(obj: JsonObject, key: String, path: String, ctx: ValidationCtx): Option<Int64> {
        match (obj.get(key)) {
            case Some(v) =>
                if (v is JsonInt) {
                    Some(v.asInt().toInt64())
                } else {
                    ctx.add(path, '$schema', '${key} must be an integer')
                    None
                }
            case _ => None
        }
    }

    private static func boolKeyword(obj: JsonObject, key: String, path: String, ctx: ValidationCtx): Option<Bool> {
        match (obj.get(key)) {
            case Some(v) =>
                if (v is JsonBool) {
                    Some(v.asBool().value)
                } else {
                    ctx.add(path, '$schema', '${key} must be a boolean')
                    None
                }
            case _ => None
        }
    }

    private static func stringKeyword(obj: JsonObject, key: String, path: String, ctx: ValidationCtx): Option<String> {
        match (obj.get(key)) {
            case Some(v) =>
                if (v is JsonString) {
                    Some(v.asString().value)
                } else {
                    ctx.add(path, '$schema', '${key} must be a string')
                    None
                }
            case _ => None
        }
    }

    private static func numberKeyword(obj: JsonObject, key: String, path: String, ctx: ValidationCtx): Option<Decimal> {
        match (obj.get(key)) {
            case Some(v) =>
                if (v is JsonInt || v is JsonDecimal) {
                    Some(asDecimal(v))
                } else {
                    ctx.add(path, '$schema', '${key} must be a number')
                    None
                }
            case _ => None
        }
    }

    private static func typeNames(value: JsonValue): Option<ArrayList<String>> {
        match (value) {
            case s: JsonString =>
                let names = ArrayList<String>()
                names.add(s.value)
                Some(names)
            case a: JsonArray =>
                let names = ArrayList<String>()
                for (item in a) {
                    if (item is JsonString) {
                        names.add(item.asString().value)
                    } else {
                        return None<ArrayList<String>>
                    }
                }
                Some(names)
            case _ => None<ArrayList<String>>
        }
    }

    private static func stringArray(value: JsonValue): Option<ArrayList<String>> {
        match (value) {
            case a: JsonArray =>
                let names = ArrayList<String>()
                for (item in a) {
                    if (item is JsonString) {
                        names.add(item.asString().value)
                    } else {
                        return None<ArrayList<String>>
                    }
                }
                Some(names)
            case _ => None<ArrayList<String>>
        }
    }

    private static func asEnumValues(value: JsonValue): Option<Array<JsonValue>> {
        match (value) {
            case a: JsonArray => Some(a.toArray())
            case _ => None<Array<JsonValue>>
        }
    }

    private static func checkEnumText(text: String, value: JsonValue, path: String, ctx: ValidationCtx): Unit {
        let parsed = try {
            JsonValue.fromStr(text)
        } catch (_: Exception) {
            ctx.add(path, '$schema', 'enum must be a JSON array')
            return
        }
        match (asEnumValues(parsed)) {
            case Some(values) =>
                var found = false
                for (item in values) {
                    if (jsonEquals(item, value)) {
                        found = true
                        break
                    }
                }
                if (!found) {
                    ctx.add(path, 'enum', 'value is not one of the enumerated values')
                }
            case _ => ctx.add(path, '$schema', 'enum must be a JSON array')
        }
    }

    // —— 基础工具 ——

    private static func requireType(value: JsonValue, expected: String, path: String, ctx: ValidationCtx): Bool {
        if (matchesType(value, expected)) {
            true
        } else {
            ctx.add(path, 'type', "expected ${expected}, got ${typeName(value)}")
            false
        }
    }

    private static func typeName(value: JsonValue): String {
        match (value) {
            case _: JsonNull => 'null'
            case _: JsonBool => 'boolean'
            case _: JsonInt => 'integer'
            case _: JsonDecimal => 'number'
            case _: JsonString => 'string'
            case _: JsonArray => 'array'
            case _: JsonObject => 'object'
            case _ => 'unknown'
        }
    }

    private static func matchesType(value: JsonValue, expected: String): Bool {
        match (expected) {
            case 'null' => value is JsonNull
            case 'boolean' => value is JsonBool
            case 'integer' => value is JsonInt
            case 'number' => value is JsonInt || value is JsonDecimal
            case 'string' => value is JsonString
            case 'array' => value is JsonArray
            case 'object' => value is JsonObject
            case _ => false
        }
    }

    private static func asDecimal(value: JsonValue): Decimal {
        match (value) {
            case x: JsonInt => x.toDecimal()
            case x: JsonDecimal => x.value
            case _ => Decimal(0)
        }
    }

    private static func hasDuplicates(value: JsonArray): Bool {
        let items = value.toArray()
        for (i in 0..items.size) {
            for (j in (i + 1)..items.size) {
                if (jsonEquals(items[i], items[j])) {
                    return true
                }
            }
        }
        false
    }

    static func jsonEquals(a: JsonValue, b: JsonValue): Bool {
        match ((a, b)) {
            case (x: JsonNull, y: JsonNull) => true
            case (x: JsonBool, y: JsonBool) => x.value == y.value
            case (x: JsonString, y: JsonString) => x.value == y.value
            case (x: JsonInt, y: JsonInt) => x.value == y.value
            case (x: JsonDecimal, y: JsonDecimal) => x.value == y.value
            case (x: JsonInt, y: JsonDecimal) => x.toDecimal() == y.value
            case (x: JsonDecimal, y: JsonInt) => x.value == y.toDecimal()
            case (x: JsonArray, y: JsonArray) =>
                if (x.size != y.size) {
                    return false
                }
                let left = x.toArray()
                let right = y.toArray()
                for (i in 0..left.size) {
                    if (!jsonEquals(left[i], right[i])) {
                        return false
                    }
                }
                true
            case (x: JsonObject, y: JsonObject) =>
                if (x.size != y.size) {
                    return false
                }
                for ((key, v) in x) {
                    match (y.get(key)) {
                        case Some(other) =>
                            if (!jsonEquals(v, other)) {
                                return false
                            }
                        case _ => return false
                    }
                }
                true
            case _ => false
        }
    }

    private static func joinPath(path: String, segment: String): String {
        '${path}/${segment.replace('~', '~0').replace('/', '~1')}'
    }
}
