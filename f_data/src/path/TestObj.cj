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
package fountain::f_data.path

import std.collection.HashMap
import fountain::f_data.base.*
import fountain::f_data.exception.DataException

/**
 * A simple NamedData implementation for testing subpath access.
 * Avoids cyclic dependency with @DataAssist in f_data.macros.
 */
internal class TestObj <: Data & NamedData {
    private let map = HashMap<String, Data>()

    public func set(name: String, value: Data) {
        map[name] = value
    }
    public func get(name: String): ?Data {
        map.get(name)
    }
    public operator func [](name: String): Data {
        map.get(name).getOrThrow {DataException("field ${name} not found")}
    }
    public func toString(): String {
        let s = StringGenerator('{')
        var first = true
        for ((k, v) in map) {
            if (!first) {
                s.append(',')
            }
            first = false
            s.append('\"').append(k).append("\":").append(v.toString())
        }
        s.append('}').toString()
    }
    public static func fromData(data: Data, flag: DataConversionFlag): Any {
        throw DataException('TestObj.fromData not supported')
    }
    public static func tryFromData(data: Data, flag: DataConversionFlag): Any {
        throw DataException('TestObj.tryFromData not supported')
    }
    public static func parse(s: String): Data {
        throw DataException('TestObj.parse not supported')
    }
    public static func tryParse(s: String): ?Data {
        None<Data>
    }
}
