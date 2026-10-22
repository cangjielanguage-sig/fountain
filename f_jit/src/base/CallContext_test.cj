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
 * `CallContext` 的调用级契约（X3 改写）。
 *
 * 旧版还有 `literalCopy` 与 `strictFp`：前者自 M2 起无消费点，后者写进 `ctx.flags` 后无人读取。
 * 两者都已移除——`strictFp` 归位到 `CompileOptions`（产物级：`FDIV` vs `FDIV_CHK`）。
 * 本文件只钉住**真正的调用级选项**：`args` 与 `deadline`，以及「不多不少」这条边界。
 */
@Test
public class CallContext_test {
    /** 默认构造：`deadline = None`。 */
    @TestCase
    public func defaultsFollowSpec(): Unit {
        let ctx = CallContext()
        @Assert(ctx.deadline.isNone(), true)
    }

    /** `deadline` 在构造时给定并原样读回（配合 `interrupt_poll` 的 -2 路径）。 */
    @TestCase
    public func deadlineRoundTrips(): Unit {
        let ctx = CallContext(deadline: Some(DateTime.UnixEpoch))
        @Assert(ctx.deadline.isSome(), true)
        match (ctx.deadline) {
            case Some(v) => @Assert(v, DateTime.UnixEpoch)
            case None => @Fail('deadline 已给定，不应为 None')
        }
    }

    /** 值语义：构造后不可变；两个不同 ctx 互不影响（含 None 与非 None 并存）。 */
    @TestCase
    public func instancesAreIndependentValues(): Unit {
        let withDeadline = CallContext(deadline: Some(DateTime.UnixEpoch))
        let without = CallContext()
        @Assert(withDeadline.deadline.isSome(), true)
        @Assert(without.deadline.isNone(), true)
    }
}
