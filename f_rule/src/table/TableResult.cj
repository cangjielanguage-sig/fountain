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

import std.collection.HashMap

/**
 * 决策表执行结果（`doc/07-decision-table.md` §9）。
 *
 * `hits` 是命中策略处理后的行；`outputs` 与 `hits` 一一对应（`Collect` 类策略多条，
 * 单值策略至多一条）；`trace` 仅在显式开启 tracing 时非空。
 */
public class TableResult {
    public let hits: Array<TableRow>
    public let outputs: Array<HashMap<String, Any>>
    public let trace: Array<RowTrace>

    public init(hits: Array<TableRow>, outputs: Array<HashMap<String, Any>>,
        trace: Array<RowTrace>) {
        this.hits = hits
        this.outputs = outputs
        this.trace = trace
    }

    public func toString(): String {
        "TableResult(${hits.size} hits)"
    }
}
