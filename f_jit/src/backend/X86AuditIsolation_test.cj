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
package fountain::f_jit.backend

import std.sync.*
import std.unittest.*
import std.unittest.testmacro.*

/**
 * x86 发射审计表必须**按编译线程隔离**（`fix-x86-audit-isolation`）。
 *
 * 旧实现是进程级静态 `ArrayList`：并发编译时 `add` 互相踩，且 `resetAuditMemBases`
 * 会把别的编译已记录的项清掉 —— 清空的审计表让 `auditAllows([])` 返回 true，
 * 本该拒绝的非法内存基址被静默放行。
 *
 * 本用例用「另一线程写入后本线程快照必须为空」确定性地锁住隔离性；旧实现**必然失败**。
 */
@Test
public class X86AuditIsolation_test {
    @TestCase
    public func auditListIsThreadLocal(): Unit {
        BackendX86_64.resetAuditMemBases()
        let writer = spawn {
            BackendX86_64.noteMemBase(15)
            0
        }
        @Assert(writer.get(), 0)
        // 别的线程写过一条；本线程没写过 ⇒ 自己的快照必须是空的。
        @Assert(BackendX86_64.auditMemBasesSnapshot().size, 0)
        BackendX86_64.noteMemBase(4)
        @Assert(BackendX86_64.auditMemBasesSnapshot().size, 1)
        BackendX86_64.resetAuditMemBases()
        @Assert(BackendX86_64.auditMemBasesSnapshot().size, 0)
    }

    /** 绝对地址哨兵 `-1` 仍被允许；非法基址仍被拒绝（与隔离性无关的回归面）。 */
    @TestCase
    public func allowsSetUnchanged(): Unit {
        BackendX86_64.resetAuditMemBases()
        BackendX86_64.noteAbsMem()
        BackendX86_64.noteMemBase(4)
        @Assert(BackendX86_64.auditAllows(BackendX86_64.auditMemBasesSnapshot()), true)
        BackendX86_64.noteMemBase(0)
        @Assert(BackendX86_64.auditAllows(BackendX86_64.auditMemBasesSnapshot()), false)
        BackendX86_64.resetAuditMemBases()
    }
}
