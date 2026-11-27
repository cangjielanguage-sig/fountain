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
 * 发射审计表必须**按编译线程隔离**（`optimize-compile-path` C0）。
 *
 * 旧实现是进程级 `ArrayList`：并发编译会 `IndexOutOfBoundsException`，
 * 且 `resetAuditMemBases` 会清掉别的编译的审计项。本用例用「另一线程写入后本线程快照必须为空」
 * 确定性锁住隔离性——旧实现必然失败。
 */
@Test
public class A64AuditIsolation_test {
    @TestCase
    public func auditListsArePerEmitterIsolated(): Unit {
        // 每个发射器一份审计表（`optimize-emit-audit`）：并发编译各用各的实例，互不可见。
        let local = A64Emitter()
        let remote = A64Emitter()
        local.resetAudit()
        remote.resetAudit()
        let writer = spawn {
            remote.noteMemBase(19)
            0
        }
        @Assert(writer.get(), 0)
        // 另一个实例写过一条；本实例没写过 ⇒ 自己的快照必须是空的。
        @Assert(local.auditSnapshot().size, 0)
        local.noteMemBase(29)
        @Assert(local.auditSnapshot().size, 1)
        local.resetAudit()
        @Assert(local.auditSnapshot().size, 0)
        // 对方那份不受影响
        @Assert(remote.auditSnapshot().size, 1)
    }
}
