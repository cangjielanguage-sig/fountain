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
package fountain::f_jit

import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_jit.base.DummyDiagnosticsSink
import fountain::f_jit.base.LocalType
import fountain::f_jit.base.PredefinedFunction
import fountain::f_jit.runtime.HelperId
import fountain::f_jit.runtime.UserHelperEntry
import fountain::f_jit.runtime.UserHelperTable

/**
 * helper 活动表的**作用域语义**护栏（`optimize-helper-table`）。
 *
 * 本次把「每调用重建整张表」改成「建一次、压引用」，语义必须逐条不变：
 * 栈顶优先、pop 恢复外层、调用结束不留残余。这些用例只用**改造前就存在**的 API，
 * 因此在旧实现上先跑一遍全绿，才说明它们描述的是既有行为。
 */
@Test
public class HelperTableScope_test {
    private static func entry(marker: Int64): UserHelperEntry {
        UserHelperEntry(params: [LocalType.I64], ret: LocalType.I64, impl: { _ => marker })
    }

    private static func markerAt(hid: Int64): Int64 {
        match (UserHelperTable.find(hid)) {
            case Some(e) =>
                match (e.impl([])) {
                    case v: Int64 => v
                    case _ => -1
                }
            case None => -2
        }
    }

    /** 同 hid 的两张表：内层遮蔽外层，pop 后恢复。 */
    @TestCase
    public func nestedTablesShadowAndRestore(): Unit {
        let hid = Int64(HelperId.USER_BASE)
        UserHelperTable.push(0u16, [HelperTableScope_test.entry(1)])
        UserHelperTable.push(0u16, [HelperTableScope_test.entry(2)])
        @Assert(HelperTableScope_test.markerAt(hid), 2)
        UserHelperTable.pop()
        @Assert(HelperTableScope_test.markerAt(hid), 1)
        UserHelperTable.pop()
        @Assert(HelperTableScope_test.markerAt(hid), -2)
    }

    /** 多次真实调用后栈必须清空（push/pop 配对、异常路径也不残留）。 */
    @TestCase
    public func callLeavesNoResidue(): Unit {
        CompileCache.reset()
        let c = Compiler(CompileOptions(DummyDiagnosticsSink()))
        c.registerFunction(PredefinedFunction('h0', [LocalType.I64], LocalType.I64, { _ => Int64(7) }))
        let f = c.compile('{ => h0(1) }')
        let hid = Int64(HelperId.USER_BASE)
        // 调用期间可见（说明表确实被压入）
        var i = 0
        while (i < 100) {
            @Assert(f.call<Int64>([]), 7)
            i = i + 1
        }
        @Assert(UserHelperTable.find(hid).isNone(), true)
    }

    /** hid 依次为 `USER_BASE + i`，顺序不得错位。 */
    @TestCase
    public func hidOrderIsPreserved(): Unit {
        UserHelperTable.push(0u16, [
            HelperTableScope_test.entry(10),
            HelperTableScope_test.entry(11),
            HelperTableScope_test.entry(12)
        ])
        @Assert(HelperTableScope_test.markerAt(Int64(HelperId.USER_BASE)), 10)
        @Assert(HelperTableScope_test.markerAt(Int64(HelperId.USER_BASE) + 1), 11)
        @Assert(HelperTableScope_test.markerAt(Int64(HelperId.USER_BASE) + 2), 12)
        UserHelperTable.pop()
    }
}
