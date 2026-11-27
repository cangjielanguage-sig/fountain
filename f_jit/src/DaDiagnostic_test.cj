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
import fountain::f_jit.base.SourceCompileException

/**
 * 前端诊断的分类正确性（`fix-da-diagnostic-classification`）。
 *
 * 明确赋值分析（§7 校验 10）只校验**已声明的非参数局部**。名字根本不存在时，
 * 应由名字解析给出 `UndefinedIdentifier` / `UnregisteredFunction`，而不是
 * 「局部变量「x」在读取路径上未必已被赋值」——后者会误导用户去补一个赋值。
 *
 * 四条直接断言 + 一条闭包对照，钉住分类边界。
 */
@Test
public class DaDiagnostic_test {
    private static func kindOf(src: String): String {
        let c = Compiler(CompileOptions(DummyDiagnosticsSink()))
        try {
            let _ = c.compile(src)
            'OK'
        } catch (e: SourceCompileException) {
            e.kind
        } catch (e: Exception) {
            'OTHER:' + e.message
        }
    }

    /** 值位置读到从未声明的名字 → `UndefinedIdentifier`。 */
    @TestCase
    public func undefinedValueIsNotReportedAsUnassigned(): Unit {
        @Assert(DaDiagnostic_test.kindOf('{ => y }'), 'UndefinedIdentifier')
    }

    /** 调用未注册的预定义函数 → `UnregisteredFunction`（不是「局部未赋值」）。 */
    @TestCase
    public func unregisteredCalleeIsNotReportedAsUnassigned(): Unit {
        @Assert(DaDiagnostic_test.kindOf('{ x: Int64 => unknownFn(x) }'), 'UnregisteredFunction')
    }

    /** 已声明但未赋值的局部 → 仍然是 `NotAssigned`（明确赋值的主场）。 */
    @TestCase
    public func declaredUnassignedLocalStaysNotAssigned(): Unit {
        @Assert(DaDiagnostic_test.kindOf('{ => var x: Int64\nx }'), 'NotAssigned')
        // 循环出口不视为已赋值（回边不动点）
        @Assert(DaDiagnostic_test.kindOf('{ c: Bool => var x: Int64\nwhile (c) { x = 1 }\nx }'),
            'NotAssigned')
    }

    /** 闭包捕获创建点未赋值的变量 → 仍是 `NotAssigned`（§8.5 捕获语义）。 */
    @TestCase
    public func capturingUnassignedLocalStaysNotAssigned(): Unit {
        @Assert(DaDiagnostic_test.kindOf('{ => var a: Int64\nlet f = { => a }\n1 }'), 'NotAssigned')
    }
}
