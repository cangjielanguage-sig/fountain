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
import std.collection.HashMap

/**
 * Structural equality filter for object literal comparison.
 * @.obj == {"name": "Alice", "age": 30} — compares the resolved path result
 * against a parsed object literal.
 */
internal class ObjectEqFilter <: DataFilter {
    ObjectEqFilter(private let left: DataPath, private let right: HashMap<String, Data>, private let isEq: Bool) {}
    init(left: String, rightStr: String, solid: String) {
        this(compilePath(left, solid), ObjectEqFilter.parseRaw(rightStr), true)
    }
    init(left: String, rightStr: String, solid: String, isEqStr: String) {
        this(compilePath(left, solid), ObjectEqFilter.parseRaw(rightStr), isEqStr == "true")
    }

    private static func parseRaw(value: String): HashMap<String, Data> {
        let map = HashMap<String, Data>()
        // Strip outer braces
        let inner = if (value.startsWith("{") && value.endsWith("}")) {
            value[1..value.size - 1]
        } else { value }
        let parts = splitByComma(inner)
        for (p in parts) {
            if (p.size == 0) { continue }
            let colonIdx = findColon(p)
            if (colonIdx < 0) { continue }
            let keyStr = p[0..colonIdx].trimAscii()
            let valStr = p[colonIdx + 1..p.size].trimAscii()
            // Strip quotes from key
            let key = if (keyStr.size >= 2 && (keyStr[0] == 0x22u8 || keyStr[0] == 0x27u8)) {
                keyStr[1..keyStr.size - 1]
            } else { keyStr }
            map.add(key, parseValue(valStr))
        }
        map
    }

    // Find first colon at depth 0 (not inside nested brackets/braces)
    private static func findColon(s: String): Int64 {
        var depth = 0
        for (i in 0..s.size) {
            let ch = s[i]
            if (ch == 0x7Bu8 || ch == 0x5Bu8) { depth++ }     // { or [
            else if (ch == 0x7Du8 || ch == 0x5Du8) { depth-- }  // } or ]
            else if (ch == 0x3Au8 && depth == 0) { return i }   // : at depth 0
        }
        -1
    }

    // Parse a single value from string into Data
    // Note: STRING_LITERAL.value from cangjieLex does NOT include surrounding quotes.
    private static func parseValue(s: String): Data {
        let val = s.trimAscii()
        if (val.toAsciiLower() == "null") {
            return DataNone.INSTANCE
        }
        if (val == "true") { return DataBool.TRUE }
        if (val == "false") { return DataBool.FALSE }
        // Nested object
        if (val.startsWith("{") && val.endsWith("}")) {
            let subMap = parseRaw(val)
            let dict = DataDict()
            for ((k, v) in subMap) {
                dict.add(k, v)
            }
            return dict
        }
        // Nested array
        if (val.startsWith("[") && val.endsWith("]")) {
            let arr = parseArrayLiteral(val)
            let list = DataList()
            for (d in arr) {
                list.add(d)
            }
            return list
        }
        // Number: starts with digit, -, or +
        if (val.size > 0 && ((val[0] >= 0x30u8 && val[0] <= 0x39u8) || val[0] == 0x2Du8 || val[0] == 0x2Bu8)) {
            if (val.contains(".") || val.contains("e") || val.contains("E")) {
                return DataReal(Float64.parse(val))
            }
            return DataReal(Int64.parse(val))
        }
        // Default: string value
        DataString(val)
    }

    // Parse array literal from string into ArrayList<Data>
    private static func parseArrayLiteral(val: String): ArrayList<Data> {
        let list = ArrayList<Data>()
        let inner = if (val.startsWith("[") && val.endsWith("]")) {
            val[1..val.size - 1]
        } else { val }
        let parts = splitByComma(inner)
        for (p in parts) {
            if (p.size == 0) { continue }
            list.add(parseValue(p))
        }
        list
    }

    // Depth-aware comma splitting (handles nested [] and {})
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
        let results = ArrayList<Data>()
        for (d in left.get(data)) {
            results.add(d)
        }
        // Single result expected for object comparison
        if (results.size != 1) {
            return if (isEq) { false } else { true }
        }
        let eq = if (let dict: DataDict <- results[0]) {
            dictEquals(dict, right)
        } else { false }
        if (isEq) { eq } else { !eq }
    }

    // Compare DataDict against HashMap<String, Data>
    private static func dictEquals(a: DataDict, b: HashMap<String, Data>): Bool {
        if (a.size != b.size) { return false }
        for ((key, value) in a) {
            if (let Some(bVal) <- b.get(key)) {
                if (!dataEquals(value, bVal)) { return false }
            } else { return false }
        }
        true
    }

    // Recursive Data equality check
    private static func dataEquals(a: Data, b: Data): Bool {
        match ((a, b)) {
            case (x: DataReal, y: DataReal) => x.data == y.data
            case (x: DataString, y: DataString) => x.data == y.data
            case (x: DataBool, y: DataBool) => x.data == y.data
            case (_: DataNone, _: DataNone) => true
            case (x: DataDict, y: DataDict) => dictEq(x, y)
            case (x: DataList, y: DataList) => listEq(x, y)
            case _ => false
        }
    }

    private static func dictEq(a: DataDict, b: DataDict): Bool {
        if (a.size != b.size) { return false }
        for ((key, value) in a) {
            var found = false
            for ((bk, bv) in b) {
                if (key == bk) {
                    if (!dataEquals(value, bv)) { return false }
                    found = true
                    break
                }
            }
            if (!found) { return false }
        }
        true
    }

    private static func listEq(a: DataList, b: DataList): Bool {
        if (a.size != b.size) { return false }
        let iterA = a.iterator()
        let iterB = b.iterator()
        for (_ in 0..a.size) {
            if (let Some(valA) <- iterA.next()) {
                if (let Some(valB) <- iterB.next()) {
                    if (!dataEquals(valA, valB)) { return false }
                } else { return false }
            } else { return false }
        }
        true
    }
}
