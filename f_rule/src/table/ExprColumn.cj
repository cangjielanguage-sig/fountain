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

import fountain::f_jit.Compiler
import fountain::f_rule.condition.JitExpression

/**
 * `expr` 列单元格编译（`doc/07-decision-table.md` §4.3）。
 *
 * 单元格是裸布尔表达式，按事实类型与绑定名包装成 lambda 后交给
 * [JitExpression.ofExpression]；宿主类型名来自 `FactSpace` 的类型描述，
 * 空串表示动态事实（整体走内置解释器）。
 */
public class ExprColumn {
    private init() {}

    /** 空单元格与 `-` 返回 `None`；语法错误由 `JitExpression` 抛 `SCRIPT_COMPILE`。 */
    public static func compile(cell: ?String, binding: String, hostType: String,
        compiler: Compiler): ?JitExpression {
        let source = match (cell) {
            case Some(text) => text.trimAscii()
            case None => return None
        }
        if (source == "" || source == "-") {
            return None
        }
        Some(JitExpression.ofExpression(source, [(binding, hostType)], compiler))
    }
}
