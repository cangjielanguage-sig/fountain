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

import std.time.DateTime
import std.unittest.*
import std.unittest.testmacro.*

/**
 * S1.6 `CallContext` 的失败用例（先写红）。
 *
 * 权威 = design-m1 §2.3.4：`var args: Array<Int64>`（入参 cell 数组，Marshal 结果）、
 * `var literalCopy: Bool = false`（M2 字面量深拷贝开关）、`var strictFp: Bool = false`
 * （bit0 → ctx.flags，`FDIV_CHK` 语义）、`var deadline: ?DateTime`（配合 `interrupt_poll`，
 * 到期 → -2）；默认值契约亦见 spec「公共值类型 / 默认值契约」场景。
 *
 * `strictFp = true` 真正写入 ctx.flags 的验证在 S4.1 / S6.4 联测（plan-m1 S1.6 明写
 * 「后置步骤联测」），本步只钉住**默认值与可写性**。
 */
@Test
public class CallContext_test {
    /** 默认构造：`literalCopy=false`、`strictFp=false`、`deadline=None`（spec 默认值契约）。 */
    @TestCase
    public func defaultsFollowSpec(): Unit {
        var ctx = CallContext()
        @Assert(ctx.literalCopy, false)
        @Assert(ctx.strictFp, false)
        @Assert(ctx.deadline.isNone(), true)
        @Assert(ctx.args.size, 0)
    }

    /** 三个开关可写，且互不干扰（改一个不动另外两个）。 */
    @TestCase
    public func flagsAreIndependentlyWritable(): Unit {
        var ctx = CallContext()
        ctx.literalCopy = true
        @Assert(ctx.literalCopy, true)
        @Assert(ctx.strictFp, false)
        @Assert(ctx.deadline.isNone(), true)

        ctx.strictFp = true
        @Assert(ctx.strictFp, true)
        @Assert(ctx.literalCopy, true)
        @Assert(ctx.deadline.isNone(), true)
    }

    /** `deadline` 可设为具体时刻并原样读回（配合 `interrupt_poll` 的 -2 路径）。 */
    @TestCase
    public func deadlineRoundTrips(): Unit {
        var ctx = CallContext()
        ctx.deadline = DateTime.UnixEpoch
        @Assert(ctx.deadline.isSome(), true)
        match (ctx.deadline) {
            case Some(v) => @Assert(v, DateTime.UnixEpoch)
            case None => @Fail('deadline 已被赋值，不应为 None')
        }
        // 回置 None 亦生效
        ctx.deadline = None
        @Assert(ctx.deadline.isNone(), true)
    }

    /** `args` 是 Marshal 结果的入参 cell 数组：按构造值原样读回，顺序不变。 */
    @TestCase
    public func argsRoundTrip(): Unit {
        let ctx = CallContext([7, -1, 42])
        @Assert(ctx.args.size, 3)
        @Assert(ctx.args[0], 7)
        @Assert(ctx.args[1], -1)
        @Assert(ctx.args[2], 42)
        @Assert(ctx.literalCopy, false)
        @Assert(ctx.strictFp, false)
        @Assert(ctx.deadline.isNone(), true)
    }
}
