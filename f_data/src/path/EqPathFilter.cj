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
 * EqPathFilter: compares the result of two path expressions for equality.
 * Supports @.x == @.y and @.x == $.y syntax — both paths are evaluated
 * at check() time and the results are compared structurally.
 */
internal class EqPathFilter <: DataFilter {
    EqPathFilter(private let left: DataPath, private let right: DataPath, private let isEq: Bool) {}
    init(left: String, right: String, solid: String) {
        this(compilePath(left, solid), compilePath(right, solid), true)
    }
    init(left: String, right: String, solid: String, isEqStr: String) {
        this(compilePath(left, solid), compilePath(right, solid), isEqStr == "true")
    }

    public func check(data: Data): Bool {
        let leftVals = ArrayList<Data>()
        for (d in left.get(data)) { leftVals.add(d) }
        let rightVals = ArrayList<Data>()
        for (d in right.get(data)) { rightVals.add(d) }
        let eq = if (leftVals.size != rightVals.size) { false }
        else {
            var allMatch = true
            for (i in 0..leftVals.size) {
                if (!dataEquals(leftVals[i], rightVals[i])) { allMatch = false; break }
            }
            allMatch
        }
        if (isEq) { eq } else { !eq }
    }

    private static func dataEquals(a: Data, b: Data): Bool {
        match ((a, b)) {
            case (x: DataReal, y: DataReal) => x.data == y.data
            case (x: DataString, y: DataString) => x.data == y.data
            case (x: DataBool, y: DataBool) => x.data == y.data
            case (_: DataNone, _: DataNone) => true
            case (x: DataList, y: DataList) => listEq(x, y)
            case (x: DataDict, y: DataDict) => dictEq(x, y)
            case _ => false
        }
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
}
