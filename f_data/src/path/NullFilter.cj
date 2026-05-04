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
 * NullFilter implements RFC 9535 null literal comparisons.
 * `?(@.name == null)` returns true if the field value is DataNone.
 * `?(@.name != null)` returns true if the field value is NOT DataNone.
 */
internal class NullFilter <: DataFilter {
    NullFilter(private let left: DataPath, private let isNull: Bool) {}
    init(left: String, solid: String, isNullStr: String) {
        this(compilePath(left, solid), isNullStr == "true")
    }
    public func check(data: Data): Bool {
        let d = match (left.get(data).next()) {
            case Some(x) => x
            case _ => return false
        }
        match (d) {
            case _: DataNone => isNull
            case _ => !isNull
        }
    }
}
