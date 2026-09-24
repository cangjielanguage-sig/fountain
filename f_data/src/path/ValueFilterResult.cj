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
 * ValueFilterResult: evaluates an inner DataFilter and returns the first
 * matching element's string value, then compares it against a literal.
 *
 * Enables nested function expressions like value(search(@.name, 'lice')) == 'Alice'
 * where the inner filter is evaluated first to find the matching element.
 */
internal class ValueFilterResult <: DataFilter {
    ValueFilterResult(private let inner: DataFilter, private let literal: String, private let isEq: Bool) {}

    init(inner: DataFilter, literal: String, isEqStr: String) {
        this(inner, literal, isEqStr == "true")
    }

    public func check(data: Data): Bool {
        // Evaluate inner filter on all children, find first match
        match (data) {
            case x: Iterable<Data> =>
                for (d in x) {
                    if (inner.check(d)) {
                        return match (d) {
                            case s: DataString => if (isEq) { s.data == literal } else { s.data != literal }
                            case _ => !isEq
                        }
                    }
                }
                !isEq  // no match found
            case x: Iterable<(String, Data)> =>
                for ((_, d) in x) {
                    if (inner.check(d)) {
                        return match (d) {
                            case s: DataString => if (isEq) { s.data == literal } else { s.data != literal }
                            case _ => !isEq
                        }
                    }
                }
                !isEq
            case _ =>
                if (inner.check(data)) {
                    match (data) {
                        case s: DataString => if (isEq) { s.data == literal } else { s.data != literal }
                        case _ => !isEq
                    }
                } else { !isEq }
        }
    }
}
