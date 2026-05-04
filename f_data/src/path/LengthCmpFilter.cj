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

/**
 * RFC 9535 length() function comparison in filter expressions.
 * length(@.name) > 5 — computes length and compares to a numeric value.
 */
internal class LengthCmpFilter <: DataFilter {
    LengthCmpFilter(private let left: DataPath, private let right: Int64, private let ordering: Ordering, private let eq: Bool) {}
    init(left: String, right: String, orderingStr: String, eqStr: String, solid: String) {
        this(compilePath(left, solid), Int64.parse(right),
            match (orderingStr) {
                case "LT" => Ordering.LT
                case "GT" => Ordering.GT
                case "EQ" => Ordering.EQ
                case _ => throw DataException('illegal Ordering string')
            }, eqStr == "true")
    }
    private static func computeLen(data: Data): Int64 {
        match (data) {
            case x: Collection<Data> => x.size
            case x: Collection<(String, Data)> => x.size
            case x: Collection<(Data, Data)> => x.size
            case x: DataString =>
                var len = 0
                for (_ in x.data.runes()) { len++ }
                len
            case _ => -1  // unsupported type
        }
    }
    public func check(data: Data): Bool {
        let d = match (left.get(data).next()) {
            case Some(x) => x
            case _ => return false
        }
        let len = computeLen(d)
        if (len < 0) { return false }
        let cmp = if (len < right) { Ordering.LT } else if (len > right) { Ordering.GT } else { Ordering.EQ }
        cmp == ordering || (eq && cmp == Ordering.EQ)
    }
}
