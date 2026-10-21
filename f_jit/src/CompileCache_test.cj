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

import std.sync.*
import std.collection.ArrayList
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_jit.base.LocalType
import fountain::f_jit.test.TCase

/** S6.7：编译缓存状态机与同键并发去重。 */
@Test
public class CompileCache_test {
    @TestCase
    public func claimIsExclusive(): Unit {
        CompileCache.reset()
        let key = 'S6.7/claim'
        @Assert(TCase.hit('T16/claim-exclusive', CompileCache.claim(key)), true)
        @Assert(TCase.hit('T16/claim-twice-blocked', !CompileCache.claim(key)), true)
        CompileCache.finish(key, CompileCache_test.fn())
        @Assert(CompileCache.claim(key), false)
        CompileCache.remove(key)
        @Assert(CompileCache.claim(key), true)
        CompileCache.remove(key)
    }

    @TestCase
    public func concurrentPipelineRunsOnce(): Unit {
        CompileCache.reset()
        let key = 'S6.7/concurrent'
        let results = ArrayList<JitFunction>()
        let rmtx = Mutex()
        let futures = ArrayList<Future<Unit>>()
        var t = 0
        while (t < 4) {
            futures.add(spawn {
                if (CompileCache.claim(key)) {
                    // 模拟管线：只应有一个线程进来
                    let f = CompileCache_test.fn()
                    CompileCache.finish(key, f)
                } else {
                    match (CompileCache.awaitReady(key)) {
                        case Some(f) =>
                            synchronized(rmtx) {
                                results.add(f)
                            }
                        case None => @Fail('等待者未拿到结果')
                    }
                }
            })
            t = t + 1
        }
        for (f in futures) {
            f.get()
        }
        @Assert(TCase.hit('T17/pipeline-once', CompileCache.runs() == 1), true)
        @Assert(TCase.hit('T17/waiters-get-result', results.size == 3), true)
        CompileCache.remove(key)
    }

    @TestCase
    public func failureIsShared(): Unit {
        CompileCache.reset()
        let key = 'S6.7/fail'
        @Assert(CompileCache.claim(key), true)
        CompileCache.fail(key, 'boom')
        @Assert(CompileCache.awaitReady(key).isNone(), true)
        match (CompileCache.failureOf(key)) {
            case Some(msg) => @Assert(msg, 'boom')
            case None => @Fail('失败文本未共享')
        }
        @Assert(CompileCache.claim(key), false)
        CompileCache.remove(key)
        @Assert(CompileCache.failureOf(key).isNone(), true)
    }

    @TestCase
    public func lookupHitsReady(): Unit {
        CompileCache.reset()
        let key = 'S6.7/hit'
        let f = CompileCache_test.fn()
        CompileCache.finish(key, f)
        @Assert(CompileCache.lookup(key).isSome(), true)
        let unused = f
        CompileCache.remove(key)
    }

    private static func fn(): JitFunction {
        JitFunction(0, LocalType.I64, Array<UInt16>(),
            { _, _ => 1 }, { _, _ => 1 }, '')
    }
}
