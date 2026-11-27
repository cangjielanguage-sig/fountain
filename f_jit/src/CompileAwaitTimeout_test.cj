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

import std.time.MonoTime
import std.unittest.*
import std.unittest.testmacro.*

/**
 * 编译等待超时的语义（H6）。
 *
 * 旧实现把「等待超时」与「首编失败」都塞进 `CompileFailed`，调用方无法区分。
 * 现在：
 * - `awaitReady` 的超时值可配（默认 30 s），测试可用 1 ms 直接打超时路径；
 * - `CompilePipeline.missingResult` 三态判定：失败文本 / 仍在编译（超时）/ 其它。
 */
@Test
public class CompileAwaitTimeout_test {
    /** 1 ms 超时：`awaitReady` 返回 None，且该键仍标记为「编译中」。 */
    @TestCase
    public func awaitTimeoutReturnsNoneAndKeepsCompilingFlag(): Unit {
        CompileCache.reset()
        let saved = CompileCache.awaitTimeoutNs
        let key = 'S6.7/timeout'
        @Assert(CompileCache.claim(key), true)
        CompileCache.awaitTimeoutNs = 1000000 // 1 ms
        let t0 = MonoTime.now()
        let r = CompileCache.awaitReady(key)
        let elapsed = (MonoTime.now() - t0).toNanoseconds()
        CompileCache.awaitTimeoutNs = saved
        @Assert(r.isNone(), true)
        @Assert(CompileCache.isCompiling(key), true)
        // 超时确实发生了（而不是瞬间返回）：至少 1 ms、远小于默认 30 s。
        @Assert(elapsed >= 1000000, true)
        @Assert(elapsed < 30000000000, true)
        CompileCache.remove(key)
        @Assert(CompileCache.isCompiling(key), false)
        CompileCache.reset()
    }

    /** 三态判定：失败文本 / 仍在编译 / 无状态。 */
    @TestCase
    public func missingResultDistinguishesTimeoutFromFailure(): Unit {
        CompileCache.reset()
        // 1) 首编失败：复述失败文本
        @Assert(CompileCache.claim('k/fail'), true)
        CompileCache.fail('k/fail', 'boom')
        let (kind1, msg1) = CompilePipeline.missingResult('k/fail', '编译失败')
        @Assert(kind1, 'CompileFailed')
        @Assert(msg1, 'boom')
        // 2) 仍在编译：判为超时，消息含「编译等待超时」与秒数
        @Assert(CompileCache.claim('k/hang'), true)
        let (kind2, msg2) = CompilePipeline.missingResult('k/hang', '编译失败')
        @Assert(kind2, 'CompileTimeout')
        @Assert(msg2.contains('编译等待超时'), true)
        @Assert(msg2.contains('30 s'), true)
        CompileCache.remove('k/hang')
        // 3) 无状态：回落到调用方给的默认文案
        let (kind3, msg3) = CompilePipeline.missingResult('k/none', '装载失败')
        @Assert(kind3, 'CompileFailed')
        @Assert(msg3, '装载失败')
        CompileCache.reset()
    }
}
