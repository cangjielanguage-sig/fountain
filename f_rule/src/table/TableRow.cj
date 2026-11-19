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

/**
 * 决策表数据行（`doc/07-decision-table.md` §1）。
 *
 * 一行对应一条规则。[line] 是物理行号（表头为 1），报错定位与 [RowTrace] 使用；
 * [values] 与 `DecisionTable.columns` 等长，`None` 表示该单元格为空。
 */
public class TableRow {
    public let line: Int64
    public let values: Array<?String>
    public let ruleId: String

    init(line: Int64, values: Array<?String>, ruleId: String) {
        this.line = line
        this.values = values
        this.ruleId = ruleId
    }

    public func toString(): String {
        "TableRow(${ruleId}@${line})"
    }
}
