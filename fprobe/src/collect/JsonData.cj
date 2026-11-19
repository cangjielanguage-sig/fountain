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
package fountain::fprobe.collect

import std.collection.*
import fountain::f_data.*

/**
 * 把 JSON 文本适配成支持 `NamedData` 的 `Data` 树。
 *
 * `JsonValue.toData()` 产生的对象只能按集合遍历，`DataPath` 的成员访问依赖
 * `NamedData`。这里在外层包一层，路径求值、聚合与告警规则即可共用同一套
 * `f_data.path.DataPath` 语义。
 */
public func jsonToData(text: String): ?Data {
    try {
        Some(adapt(JsonValue.fromStr(text)))
    } catch (_: Exception) {
        None<Data>
    }
}

private func adapt(value: JsonValue): Data {
    match (value) {
        case object: JsonObject => JsonObjectData(object)
        case array: JsonArray => JsonArrayData(array)
        case _ => value.toData()
    }
}

private class JsonObjectData <: Data & NamedData {
    private let object: JsonObject

    init(object: JsonObject) {
        this.object = object
    }

    public func get(name: String): ?Data {
        match (object.get(name)) {
            case Some(value) => Some(adapt(value))
            case None => None<Data>
        }
    }

    public operator func [](name: String): Data {
        get(name).getOrThrow {DataException('${name} is not found in JSON object')}
    }

    public func toString(): String {
        object.toString()
    }

    public static func tryParse(text: String): ?Data {
        jsonToData(text)
    }

    public static func parse(text: String): Data {
        tryParse(text).getOrThrow {DataException('${text} cannot be parsed as JSON object')}
    }
}

private class JsonArrayData <: Data & Collection<Data> {
    private let array: JsonArray

    init(array: JsonArray) {
        this.array = array
    }

    public prop size: Int64 {
        get() {
            array.size
        }
    }

    public func isEmpty(): Bool {
        size == 0
    }

    public func iterator(): Iterator<Data> {
        JsonArrayDataIterator(array.getItems().iterator())
    }

    public func toString(): String {
        array.toString()
    }

    public static func tryParse(text: String): ?Data {
        jsonToData(text)
    }

    public static func parse(text: String): Data {
        tryParse(text).getOrThrow {DataException('${text} cannot be parsed as JSON array')}
    }
}

private class JsonArrayDataIterator <: Iterator<Data> {
    private let source: Iterator<JsonValue>

    init(source: Iterator<JsonValue>) {
        this.source = source
    }

    public func next(): ?Data {
        match (source.next()) {
            case Some(value) => adapt(value)
            case None => None<Data>
        }
    }
}
