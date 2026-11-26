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
package fountain::f_rule.table

import fountain::f_rule.condition.Truth

/** 单个条件列的求值结果（`doc/07-decision-table.md` §9）。 */
public class ColumnTrace {
    public let column: String
    public let result: Truth

    public init(column: String, result: Truth) {
        this.column = column
        this.result = result
    }

    public func toString(): String {
        "${column}=${result}"
    }
}

/** 一行的条件判定明细：用于回答"为什么这行没命中"。 */
public class RowTrace {
    public let line: Int64
    public let ruleId: String
    public let columns: Array<ColumnTrace>
    public let matched: Bool

    public init(line: Int64, ruleId: String, columns: Array<ColumnTrace>, matched: Bool) {
        this.line = line
        this.ruleId = ruleId
        this.columns = columns
        this.matched = matched
    }

    public func toString(): String {
        "RowTrace(${ruleId}@${line}, matched=${matched})"
    }
}
