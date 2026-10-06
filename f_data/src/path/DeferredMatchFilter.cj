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
 * DeferredMatchFilter: like MatchFilter, but the regex is sourced from a
 * DataPath evaluated at runtime. Supports match(@.name, @.regexField).
 *
 * The second argument is a path expression that resolves to a string value
 * containing the regex pattern. The regex is compiled dynamically on each
 * check() call, so the pattern can differ per data item.
 */
internal class DeferredMatchFilter <: DataFilter {
    private let left: DataPath
    private let regexSource: DataPath

    init(left: DataPath, regexSource: DataPath) {
        this.left = left
        this.regexSource = regexSource
    }
    init(left: String, regexSource: String, solid: String) {
        this(compilePath(left, solid), compilePath(regexSource, solid))
    }

    public func check(data: Data): Bool {
        let d = match (left.get(data).next()) {
            case Some(x) => x
            case _ => return false
        }
        let regexStr = match (regexSource.get(data).next()) {
            case Some(x: DataString) => x.data
            case _ => return false
        }
        let regex = regexStr.regex()
        match (d) {
            case x: DataString => regex.matches(x.data)
            case _ => false
        }
    }
}
