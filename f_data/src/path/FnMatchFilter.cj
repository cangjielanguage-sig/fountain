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
 * FnMatchFilter: match() where the first argument is a function expression.
 * Iterates over children of the input data, finds the first child where
 * the inner filter returns true, then applies the regex to that child's
 * string value (via DataString or toString()).
 *
 * Enables nesting like match(match(@.name, 'Alice'), 'Alice')
 */
internal class FnMatchFilter <: DataFilter {
    FnMatchFilter(private let inner: DataFilter, private let regex: Regex) {}

    init(inner: DataFilter, regex: String, solid: String) {
        this(inner, regex.regex())
    }

    public func check(data: Data): Bool {
        match (data) {
            case x: Iterable<Data> =>
                for (d in x) {
                    if (inner.check(d)) {
                        return match (d) {
                            case s: DataString => regex.matches(s.data)
                            case _ => regex.matches(d.toString())
                        }
                    }
                }
                false
            case x: Iterable<(String, Data)> =>
                for ((_, d) in x) {
                    if (inner.check(d)) {
                        return match (d) {
                            case s: DataString => regex.matches(s.data)
                            case _ => regex.matches(d.toString())
                        }
                    }
                }
                false
            case x: Iterable<(Data, Data)> =>
                for ((_, d) in x) {
                    if (inner.check(d)) {
                        return match (d) {
                            case s: DataString => regex.matches(s.data)
                            case _ => regex.matches(d.toString())
                        }
                    }
                }
                false
            case _ =>
                if (inner.check(data)) {
                    match (data) {
                        case s: DataString => regex.matches(s.data)
                        case _ => regex.matches(data.toString())
                    }
                } else { false }
        }
    }
}
