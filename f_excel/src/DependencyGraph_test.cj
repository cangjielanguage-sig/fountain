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
package fountain::f_excel

import std.collection.ArrayList
import std.unittest.*
import std.unittest.testmacro.*

private func position(list: ArrayList<String>, value: String): Int64 {
    for (i in 0..list.size) {
        if (list[i] == value) {
            return i
        }
    }
    -1
}

@Test
public class DependencyGraph_test {
    @TestCase
    public func topologicalOrderPutsDependenciesFirst(): Unit {
        let graph = DependencyGraph()
        graph.add("Sheet1", 1, 1, "A2+1")   // A1 依赖 A2
        graph.add("Sheet1", 2, 1, "A3*2")   // A2 依赖 A3
        graph.add("Sheet1", 3, 1, "5")      // A3 是公式（常量也可以登记）
        let order = graph.order()
        @Assert(order.size, 3)
        @Assert(position(order, "Sheet1!A3") < position(order, "Sheet1!A2"), true)
        @Assert(position(order, "Sheet1!A2") < position(order, "Sheet1!A1"), true)
        @Assert(graph.cycles().size, 0)
    }

    @TestCase
    public func cycleIsDetected(): Unit {
        let graph = DependencyGraph()
        graph.add("Sheet1", 1, 1, "B1")
        graph.add("Sheet1", 1, 2, "A1")
        @Assert(graph.cycles().size, 2)
        @Assert(graph.order().size, 0)
    }

    @TestCase
    public func crossSheetDependency(): Unit {
        let graph = DependencyGraph()
        graph.add("Sheet1", 1, 1, "'S2'!A1")
        graph.add("S2", 1, 1, "1")
        let order = graph.order()
        @Assert(position(order, "S2!A1") < position(order, "Sheet1!A1"), true)
    }

    @TestCase
    public func dependenciesOfReturnsDirectRefs(): Unit {
        let graph = DependencyGraph()
        graph.add("Sheet1", 2, 2, "SUM(A1:A3)+$C$1")
        let deps = graph.dependenciesOf("Sheet1", 2, 2)
        @Assert(deps.size, 4)
        @Assert(deps.contains("Sheet1!A1"), true)
        @Assert(deps.contains("Sheet1!C1"), true)
    }

    @TestCase
    public func buildGraphFromDocument(): Unit {
        let doc = ExcelDocument()
        let sheet = doc.sheet("Sheet1").getOrThrow()
        sheet.setCell("A1", CellValue.Formula("B1+C1", None))
        sheet.setCell("B1", CellValue.Number(1.0))
        let graph = CalcEngine(doc).buildGraph()
        @Assert(graph.size(), 1)
        @Assert(graph.dependenciesOf("Sheet1", 1, 1).size, 2)
    }
}
