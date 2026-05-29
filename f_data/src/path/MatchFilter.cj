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
 * RFC 9535 match() function extension: full-string regex match.
 * Returns true if the entirety of the input matches the I-Regexp.
 */
internal class MatchFilter <: DataFilter {
    private let left: DataPath
    private let regex: Regex
    init(left: DataPath, regex: String) {
        this.left = left
        this.regex = parseRegex(regex)
    }
    init(left: String, regex: String, solid: String) {
        this(compilePath(left, solid), regex)
    }
    private static func parseRegex(regex: String): Regex {
        regex.regex()
    }
    public func check(data: Data): Bool {
        let d = match (left.get(data).next()) {
            case Some(x) => x
            case _ => return false
        }
        match (d) {
            case x: DataString => regex.matches(x.data)
            case _ => false
        }
    }
}
