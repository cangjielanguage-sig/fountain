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
 * S1.8 `JitException` 的失败用例（先写红）。
 *
 * 权威 = design-m1 §2.3.1 与规格 §2「错误码 → 桥侧异常类型映射」：`JitException` 是
 * **运行期错误载体**（错误码 + site + fnId + 源位置 + 报告文本 + cause），由桥在报告组装完成后
 * 构造；六个字段 `code` / `site` / `fnId` / `sourcePos` / `message` / `cause`。
 *
 * `site = -1` 表示未知（§2.3.1）；`cause` 在 `code = 99` 时是 helper 原始描述（M2 起 21 含完整
 * 仓颉栈）。继承 `fountain::f_base.BaseException`（design D15）⇒ 宿主可 `catch (e: BaseException)`
 * 与其它 fountain 模块统一处理，报告文本经 `super(message)` 成为基类 `message` 语义。
 */
@Test
public class JitException_test {
    /** 六个字段读回与构造入参一致（含 `sourcePos`/`cause` 都有值的分支）。 */
    @TestCase
    public func allSixFieldsRoundTrip(): Unit {
        let pos = SourcePos(12, 5)
        let e = JitException(ErrCode.ARG_MISMATCH, 42, 3, Some(pos), '报告文本', '原始 cause')
        @Assert(e.code, ErrCode.ARG_MISMATCH)
        @Assert(e.site, 42)
        @Assert(e.fnId, 3)
        @Assert(e.sourcePos.isSome(), true)
        match (e.sourcePos) {
            case Some(v) =>
                @Assert(v.line, 12)
                @Assert(v.column, 5)
            case None => @Fail('sourcePos 已被赋值，不应为 None')
        }
        @Assert(e.message, '报告文本')
        @Assert(e.cause.isSome(), true)
        match (e.cause) {
            case Some(v) => @Assert(v, '原始 cause')
            case None => @Fail('cause 已被赋值，不应为 None')
        }
    }

    /** `sourcePos = None` 与 `cause` 取默认值（`None`）两个分支都可用。 */
    @TestCase
    public func optionalFieldsMayBeNone(): Unit {
        let e = JitException(ErrCode.CALL_CONTRACT, -1, 0, None, '契约错误')
        @Assert(e.code, ErrCode.CALL_CONTRACT)
        @Assert(e.site, -1) // 契约类错误的 site 恒为 -1（§2 行 19）
        @Assert(e.fnId, 0)
        @Assert(e.sourcePos.isNone(), true)
        @Assert(e.cause.isNone(), true)
        @Assert(e.message, '契约错误')
    }

    /** 可 `catch (e: JitException)` 并读回全部字段（抛出路径与直接构造一致）。 */
    @TestCase
    public func catchableAsJitException(): Unit {
        var got = 0
        var site = 0
        try {
            throw JitException(ErrCode.NULL_HANDLE, 7, 1, Some(SourcePos(2, 3)), 'null 句柄')
        } catch (e: JitException) {
            got = e.code
            site = e.site
            @Assert(e.fnId, 1)
            @Assert(e.message, 'null 句柄')
            @Assert(e.cause.isNone(), true)
        }
        @Assert(got, ErrCode.NULL_HANDLE)
        @Assert(site, 7)
    }

    /** `is BaseException` 成立，且宿主可 `catch (e: BaseException)` 读到报告文本（design D15）。 */
    @TestCase
    public func catchableAsBaseException(): Unit {
        let e = JitException(ErrCode.HELPER_PANIC, 9, 2, None, 'internal helper failure: boom', 'boom')
        @Assert(e is BaseException, true)
        var text = ''
        try {
            throw e
        } catch (b: BaseException) {
            text = b.message
        }
        @Assert(text, 'internal helper failure: boom')
        // 99 的 msg 前缀按 §2 表固定为 `internal helper failure`
        @Assert(text.startsWith('internal helper failure'), true)
    }
}
