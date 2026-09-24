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

import std.collection.ArrayList

/**
 * Structural equality filter for array/object comparison.
 * @.items == [1, 2, 3] — compares the resolved path result against a parsed array.
 */
internal class StructEqFilter <: DataFilter {
    StructEqFilter(private let left: DataPath, private let right: ArrayList<Data>, private let isEq: Bool) {}
    init(left: String, rightStr: String, solid: String) {
        this(compilePath(left, solid), StructEqFilter.parseRaw(rightStr), true)
    }
    init(left: String, rightStr: String, solid: String, isEqStr: String) {
        this(compilePath(left, solid), StructEqFilter.parseRaw(rightStr), isEqStr == "true")
    }
    private static func parseRaw(value: String): ArrayList<Data> {
        let list = ArrayList<Data>()
        // Remove brackets if present
        let inner = if (value.startsWith("[") && value.endsWith("]")) {
            value[1..value.size - 1]
        } else { value }
        let parts = splitByComma(inner)
        for (p in parts) {
            if (p.size == 0) { continue }
            // Check for null
            if (p.toAsciiLower() == "null") {
                list.add(DataNone.INSTANCE)
            // Check for string (starts with ' or ")
            } else if (p.size >= 2 && (p[0] == 0x27u8 || p[0] == 0x22u8)) {
                list.add(DataString(p[1..p.size - 1]))
            // Check for bool
            } else if (p == "true") {
                list.add(DataBool.TRUE)
            } else if (p == "false") {
                list.add(DataBool.FALSE)
            // Check for number (integer or float)
            } else if (p.contains(".") || p.contains("e") || p.contains("E")) {
                list.add(DataReal(Float64.parse(p)))
            } else {
                list.add(DataReal(Int64.parse(p)))
            }
        }
        list
    }
    private static func splitByComma(s: String): ArrayList<String> {
        let parts = ArrayList<String>()
        var current = StringGenerator()
        var depth = 0
        for (ch in s.runes()) {
            if (ch == r'[' || ch == r'{') { depth++; current.append(ch) }
            else if (ch == r']' || ch == r'}') { depth--; current.append(ch) }
            else if (ch == r',' && depth == 0) { parts.add(current.toString()); current.reset() }
            else { current.append(ch) }
        }
        if (current.size > 0) { parts.add(current.toString()) }
        parts
    }
    public func check(data: Data): Bool {
        // Collect all results from left path, compare as a list against right array
        let results = ArrayList<Data>()
        for (d in left.get(data)) {
            results.add(d)
        }
        var allMatch = true
        if (results.size != right.size) { allMatch = false }
        else {
            for (i in 0..results.size) {
                if (!dataEquals(results[i], right[i])) { allMatch = false; break }
            }
        }
        if (isEq) { allMatch } else { !allMatch }
    }
    private static func dataEquals(a: Data, b: Data): Bool {
        match ((a, b)) {
            case (x: DataReal, y: DataReal) => x.data == y.data
            case (x: DataString, y: DataString) => x.data == y.data
            case (x: DataBool, y: DataBool) => x.data == y.data
            case (_: DataNone, _: DataNone) => true
            case _ => false
        }
    }
}
