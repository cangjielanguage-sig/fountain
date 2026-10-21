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
package fountain::f_jit.base

import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_base.BaseException

/**
 * S1.9 `SourceCompileException` 的失败用例（先写红）。
 *
 * 权威 = design-m1 §2.3.2：`kind`（`DiagKind` 常量，**清单见 §4.3.9**：词法族
 * `IllegalCharacter` / `UnterminatedString` / `BadEscape` / `BadNumber` / `UnterminatedRegex` /
 * `UnterminatedComment` / `MultilineHeadContent` / `UnterminatedMultilineString` /
 * `UnterminatedRawString` + 解析/名字/校验族 `UnregisteredFunction` / `UndefinedIdentifier` /
 * `BadParameterList` / `MissingArrow` / `DuplicateRegistration` / `NotImpl`）、`position`、
 * `line`/`column`（**1 起，列按 Unicode 码点**）、`lineText`（**错误所在源码行原文，不含换行**）、
 * `hint`（修复提示，含已注册函数清单）。
 *
 * 同样继承 `fountain::f_base.BaseException`，且**不占用运行期错误码**（spec「与运行期错误分离」：
 * 编译期错误不写入任何运行期错误码、不涉及错误槽）。
 */
@Test
public class SourceCompileException_test {
    /** 六个字段读回与构造入参一致。 */
    @TestCase
    public func allFieldsRoundTrip(): Unit {
        let e = SourceCompileException('UnregisteredFunction', 27, 3, 5, 'let r = f(1)', '已注册：g, h')
        @Assert(e.kind, 'UnregisteredFunction')
        @Assert(e.position, 27)
        @Assert(e.line, 3)
        @Assert(e.column, 5)
        @Assert(e.lineText, 'let r = f(1)')
        @Assert(e.hint, '已注册：g, h')
    }

    /** 多行源码上触发编译期错误：`line`/`column` 指向出错位置，`lineText` 与该行源码逐字节相同。 */
    @TestCase
    public func lineTextEqualsTheSourceLine(): Unit {
        let lines = ['fn main() => {', '    let b = @', '    b', '}']
        // 第 2 行第 11 列是那个非法字符 `@`
        let e = SourceCompileException('IllegalCharacter', 18, 2, 11, lines[1], '删除非法字符 @')
        @Assert(e.line, 2)
        @Assert(e.column, 11)
        @Assert(e.lineText, lines[e.line - 1])
        @Assert(e.lineText, '    let b = @')
        // lineText 不含换行（§2.3.2「错误所在源码行原文（不含换行）」）
        @Assert(e.lineText.contains('\n'), false)
        // 出错列确实落在出错行内（列按 Unicode 码点，1 起）
        @Assert(e.column >= 1, true)
        @Assert(e.column <= e.lineText.size, true)
    }

    /** 空行 / 空 `lineText` 分支可用（位置可落在空行，hint 可为空）。 */
    @TestCase
    public func emptyLineTextAndHintAreAllowed(): Unit {
        let e = SourceCompileException('UnterminatedString', 0, 1, 1, '', '')
        @Assert(e.lineText, '')
        @Assert(e.hint, '')
        @Assert(e.position, 0)
    }

    /** 与运行期错误分离：它是 `BaseException` 子类，但**不是** `JitException`，不带错误码与 site。 */
    @TestCase
    public func separatedFromRuntimeErrorChannel(): Unit {
        let e = SourceCompileException('MissingArrow', 9, 1, 10, '(a: Int64) a', '缺少 =>')
        @Assert(e is BaseException, true)
        @Assert(e is JitException, false)
        // 编译期错误的报告文本经基类 message 可读
        var text = ''
        try {
            throw e
        } catch (b: BaseException) {
            text = b.message
        }
        @Assert(text.isEmpty(), false)
        @Assert(text.contains('MissingArrow'), true)
        @Assert(text.contains('1'), true)
    }
}
