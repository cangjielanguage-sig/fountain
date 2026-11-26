/*
Copyright (c) 2026 WuJingrun（吴京润）

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
package fountain::f_rule.rete

/**
 * 构建期索引覆盖率（`doc/04-rete-network.md` §7.4）。
 *
 * `total` 是参与统计的 alpha 约束与 join 数，`indexed` 是其中可走索引的项数；
 * `total == 0` 时覆盖率按 1.0 处理，避免除零。`suggestions` 是去重后的
 * `(typeTag, field)` 建议索引字段。
 */
public class IndexCoverage {
    public let indexed: Int64
    public let total: Int64
    public let suggestions: Array<(String, String)>

    public init(indexed: Int64, total: Int64, suggestions: Array<(String, String)>) {
        this.indexed = indexed
        this.total = total
        this.suggestions = suggestions
    }

    public prop coverage: Float64 {
        get() {
            if (total == 0) {
                1.0
            } else {
                Float64(indexed) / Float64(total)
            }
        }
    }

    public func toString(): String {
        "IndexCoverage(${indexed}/${total}, coverage=${coverage})"
    }
}
