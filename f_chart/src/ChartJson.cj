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
package fountain::f_chart

import fountain::f_data.json.*

/**
 * 带字段路径的 JSON 读取器。
 *
 * 图表的数据数组随图类型变化，因此这里保留 `JsonValue` 的动态读取；
 * 所有读取失败都转成带路径的 `ChartException`。
 */
internal class ChartJson {
    private let obj: JsonObject
    private let basePath: String

    private init(obj: JsonObject, basePath: String) {
        this.obj = obj
        this.basePath = basePath
    }

    static func of(obj: JsonObject): ChartJson {
        ChartJson(obj, "")
    }

    static func of(obj: JsonObject, path: String): ChartJson {
        ChartJson(obj, path)
    }

    private func pathOf(name: String): String {
        if (this.basePath.isEmpty()) {
            name
        } else if (name.startsWith("[")) {
            "${this.basePath}${name}"
        } else {
            "${this.basePath}.${name}"
        }
    }

    func has(name: String): Bool {
        this.obj.contains(name)
    }

    func value(name: String): ?JsonValue {
        this.obj.get(name)
    }

    func required(name: String): JsonValue {
        match (this.obj.get(name)) {
            case Some(value) => value
            case None => throw chartMissingField(this.pathOf(name))
        }
    }

    func string(name: String): ?String {
        match (this.obj.get(name)) {
            case Some(value) => Some(jsonStringValue(value, this.pathOf(name)))
            case None => None
        }
    }

    func string(name: String, default!: String): String {
        match (this.string(name)) {
            case Some(value) => value
            case None => default
        }
    }

    func requiredString(name: String): String {
        jsonStringValue(this.required(name), this.pathOf(name))
    }

    func number(name: String): ?Float64 {
        match (this.obj.get(name)) {
            case Some(value) =>
                if (value.kind.isNull) {
                    None<Float64>
                } else {
                    Some(jsonNumberValue(value, this.pathOf(name)))
                }
            case None => None
        }
    }

    func number(name: String, default!: Float64): Float64 {
        match (this.number(name)) {
            case Some(value) => value
            case None => default
        }
    }

    func bool(name: String, default!: Bool): Bool {
        match (this.obj.get(name)) {
            case Some(value) =>
                if (!value.kind.isBool) {
                    throw chartInvalidValue(this.pathOf(name), "期望布尔值")
                }
                value.asBool().value
            case None => default
        }
    }

    func int(name: String, default!: Int64): Int64 {
        match (this.obj.get(name)) {
            case Some(value) =>
                if (value.kind.isInt) {
                    value.asInt().toInt64()
                } else if (value.kind.isDecimal) {
                    let number = value.asDecimal().toFloat64()
                    if (number.isNaN() || number.isInf()) {
                        throw chartInvalidValue(this.pathOf(name), "期望有限整数")
                    }
                    Int64(number)
                } else {
                    throw chartInvalidValue(this.pathOf(name), "期望整数")
                }
            case None => default
        }
    }

    func object(name: String): ?ChartJson {
        match (this.obj.get(name)) {
            case Some(value) => Some(ChartJson(jsonObjectValue(value, this.pathOf(name)), this.pathOf(name)))
            case None => None
        }
    }

    func requiredObject(name: String): ChartJson {
        ChartJson(jsonObjectValue(this.required(name), this.pathOf(name)), this.pathOf(name))
    }

    func array(name: String): ?JsonArray {
        match (this.obj.get(name)) {
            case Some(value) => Some(jsonArrayValue(value, this.pathOf(name)))
            case None => None
        }
    }

    func requiredArray(name: String): JsonArray {
        jsonArrayValue(this.required(name), this.pathOf(name))
    }

    func stringArray(name: String, default!: Array<String>): Array<String> {
        match (this.array(name)) {
            case Some(items) =>
                let values = ArrayList<String>()
                var index = 0
                for (item in items.getItems()) {
                    values.add(jsonStringValue(item, "${this.pathOf(name)}[${index}]"))
                    index++
                }
                values.toArray()
            case None => default
        }
    }

    func numberArray(name: String): Array<Float64> {
        match (this.array(name)) {
            case Some(items) =>
                let values = ArrayList<Float64>()
                var index = 0
                for (item in items.getItems()) {
                    values.add(jsonNumberValue(item, "${this.pathOf(name)}[${index}]"))
                    index++
                }
                values.toArray()
            case None => Array<Float64>()
        }
    }

    func numberOrNullArray(name: String): Array<?Float64> {
        match (this.array(name)) {
            case Some(items) =>
                let values = ArrayList<?Float64>()
                var index = 0
                for (item in items.getItems()) {
                    let itemPath = "${this.pathOf(name)}[${index}]"
                    if (item.kind.isNull) {
                        values.add(None<Float64>)
                    } else {
                        values.add(Some(jsonNumberValue(item, itemPath)))
                    }
                    index++
                }
                values.toArray()
            case None => Array<?Float64>()
        }
    }

    func childPath(name: String): String {
        this.pathOf(name)
    }
}

internal func jsonStringValue(value: JsonValue, path: String): String {
    if (!value.kind.isString) {
        throw chartInvalidValue(path, "期望字符串")
    }
    value.asString().value
}

internal func jsonNumberValue(value: JsonValue, path: String): Float64 {
    let number = if (value.kind.isInt) {
        value.asInt().toDecimal().toFloat64()
    } else if (value.kind.isDecimal) {
        value.asDecimal().toFloat64()
    } else {
        throw chartInvalidValue(path, "期望数字")
    }
    if (number.isNaN() || number.isInf()) {
        throw chartInvalidValue(path, "期望有限数字")
    }
    number
}

internal func jsonObjectValue(value: JsonValue, path: String): JsonObject {
    if (!value.kind.isObject) {
        throw chartInvalidValue(path, "期望对象")
    }
    value.asObject()
}

internal func jsonArrayValue(value: JsonValue, path: String): JsonArray {
    if (!value.kind.isArray) {
        throw chartInvalidValue(path, "期望数组")
    }
    value.asArray()
}
