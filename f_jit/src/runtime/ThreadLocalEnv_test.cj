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
package fountain::f_jit.runtime

import std.sync.*
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_jit.base.LocalType

/**
 * 调用级环境三项的**线程私有**验收（`feat-f-jit-parallel-call` P2.2）。
 *
 * 旧实现三项都是进程级静态量：A 线程设置 deadline / 函数表基址 / helper 栈，会直接改写
 * B 线程看到的同一份值。这三条用例在旧实现上必红（见变更 verify.md 的变异验证）。
 */
@Test
public class ThreadLocalEnv_test {

    /** A 线程的 deadline 不影响新线程；新线程自己的 deadline 也不回写 A。 */
    @TestCase
    public func deadlineIsThreadLocal(): Unit {
        RuntimeEnv.clearDeadline()
        RuntimeEnv.setDeadline(RuntimeEnv.nowNanos() - 1)
        @Assert(RuntimeEnv.deadlineExpired(), true)
        let f = spawn {
            // 新线程：无期限（旧实现会读到 A 的过期时刻 ⇒ 这里为 true）
            let sawExpired = RuntimeEnv.deadlineExpired()
            RuntimeEnv.setDeadline(RuntimeEnv.nowNanos() + 3600000000000)
            var bad = 0
            if (sawExpired) {
                bad = bad + 1
            }
            // 子线程自己的远期 deadline 生效：不得被判过期
            if (RuntimeEnv.deadlineExpired()) {
                bad = bad + 10
            }
            bad
        }
        @Assert(f.get(), 0)
        // A 仍保持自己的过期 deadline，未被 B 的写入覆盖
        @Assert(RuntimeEnv.deadlineExpired(), true)
        RuntimeEnv.clearDeadline()
        @Assert(RuntimeEnv.deadlineExpired(), false)
    }

    /** 函数表基址线程私有：子线程看不到 A 的基址，A 也不被子的写入覆盖。 */
    @TestCase
    public func fnTableBaseIsThreadLocal(): Unit {
        MachineEnv.reset()
        MachineEnv.setFnTableBase(4096)
        let f = spawn {
            // 旧实现：读到 4096
            let saw = MachineEnv.fnTableBase
            MachineEnv.setFnTableBase(8192)
            saw
        }
        @Assert(f.get(), 0)
        @Assert(MachineEnv.fnTableBase, 4096)
        MachineEnv.reset()
    }

    /** helper 栈线程私有：A 压入的 hid 对子线程不可见；子线程找不到即返回 1。 */
    @TestCase
    public func userHelperStackIsThreadLocal(): Unit {
        UserHelperTable.resetForTest()
        UserHelperTable.push(0u16, [UserHelperEntry(
            params: [LocalType.I64], ret: LocalType.I64,
            impl: { a => a[0] })])
        let hid = Int64(HelperId.USER_BASE)
        @Assert(UserHelperTable.find(hid).isSome(), true)
        let f = spawn {
            var bad = 0
            if (UserHelperTable.find(hid).isSome()) {
                bad = bad + 1
            }
            // 子线程自己的栈压入后只影响自己
            UserHelperTable.push(0u16, [UserHelperEntry(
                params: [LocalType.I64], ret: LocalType.I64,
                impl: { a => a[0] })])
            if (UserHelperTable.find(hid).isNone()) {
                bad = bad + 10
            }
            bad
        }
        @Assert(f.get(), 0)
        // 子线程退出后 A 的栈不受影响
        @Assert(UserHelperTable.find(hid).isSome(), true)
        UserHelperTable.resetForTest()
    }
}
