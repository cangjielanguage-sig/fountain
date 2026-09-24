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
 * FnDeferredSearchFilter: search() where the SECOND argument is a function
 * expression that resolves to a regex pattern string. Evaluates the
 * regexFilter against children to get the regex pattern, then applies it.
 *
 * Enables nesting like search(@.name, search(@.patternField, 'pat'))
 */
internal class FnDeferredSearchFilter <: DataFilter {
    FnDeferredSearchFilter(private let left: DataPath, private let regexFilter: DataFilter) {}

    init(left: String, regexFilter: DataFilter, solid: String) {
        this(compilePath(left, solid), regexFilter)
    }

    public func check(data: Data): Bool {
        let d = match (left.get(data).next()) {
            case Some(x) => x
            case _ => return false
        }
        let regexVal = filterToFirstValue(regexFilter, data)
        let regexStr = match (regexVal) {
            case s: DataString => s.data
            case _ => return false
        }
        let regex = regexStr.regex()
        match (d) {
            case x: DataString => regex.find(x.data, group: true).isSome()
            case _ => false
        }
    }
}
