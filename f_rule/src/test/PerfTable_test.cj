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
package fountain::f_rule.test

import std.collection.ArrayList
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_jit.Compiler
import fountain::f_rule.fact.{FactSpaceRegistry, FieldType}
import fountain::f_rule.table.{CsvTableParser, TableCompiler}

/**
 * 决策表编译门禁（`doc/09-testing.md` §5 B-07）。
 *
 * 口径：1000 行 CSV 文本的**解析 + 编译**整体计时，编译产物行数必须等于 1000，
 * 防止"少编译几行"式作弊。
 */
@Tag[perf]
@Test
class PerfTable_test {
    private let rowCount: Int64 = 1000
    private var lastRows_: Int64 = 0

    private func csv(): String {
        let lines = ArrayList<String>()
        lines.add("# f_rule decision table v1")
        lines.add("# id: perf-table")
        lines.add("# name: performance table")
        lines.add("# version: v1")
        lines.add("# factSpace: orders")
        lines.add("# hitPolicy: First")
        lines.add("id,name,when.order.amount,then.discount")
        var i: Int64 = 0
        while (i < rowCount) {
            lines.add("R${i},row ${i},>${i % 500},0.${i % 10}")
            i += 1
        }
        var out = ""
        for (line in lines) {
            out = out + line + "\n"
        }
        out
    }

    private func registry(): FactSpaceRegistry {
        let registry = FactSpaceRegistry()
        let space = registry.declare("orders")
        let _ = space.registerDynamic("Order", [("amount", FieldType.`Any`)])
        registry
    }

    /** B-07：1000 行决策表解析 + 编译 < 300ms。 */
    @Tag[perf, b07]
    @TestCase
    public func b07ParsesAndCompilesThousandRowsWithinGate(): Unit {
        let text = csv()
        let spaces = registry()
        let compiler = Compiler()
        let stats = PerfSupport.measure(1, 5) {
            let table = CsvTableParser.parse(text)
            let compiled = TableCompiler(table, spaces, compiler).compile()
            lastRows_ = Int64(compiled.rows.size)
        }
        PerfSupport.report("B-07 1000 行解析+编译", stats, detail: "rows=${lastRows_}")
        @Expect(lastRows_, rowCount)
        PerfSupport.requireAtMost("B-07 解析+编译", stats.p95(), PerfGate.B07_TABLE_NANOS)
    }
}
