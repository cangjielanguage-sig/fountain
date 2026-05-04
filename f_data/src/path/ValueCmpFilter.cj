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
 * RFC 9535 value() function comparison in filter expressions.
 * value(@.name) == "Alice" — extracts first node's value and compares.
 */
internal class ValueCmpFilter <: DataFilter {
    ValueCmpFilter(private let left: DataPath, private let rightLiteral: String) {}
    init(left: String, rightLiteral: String, solid: String) {
        this(compilePath(left, solid), rightLiteral)
    }
    public func check(data: Data): Bool {
        let d = match (left.get(data).next()) {
            case Some(x) => x
            case _ => return false
        }
        d.toString() == rightLiteral
    }
}
