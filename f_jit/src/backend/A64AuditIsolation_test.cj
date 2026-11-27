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
    public func auditListIsThreadLocal(): Unit {
        A64Emitter.resetAuditMemBases()
        let writer = spawn {
            A64Emitter.noteMemBase(19)
            0
        }
        @Assert(writer.get(), 0)
        // 别的线程写过一条；本线程没写过 ⇒ 自己的快照必须是空的。
        @Assert(A64Emitter.auditMemBasesSnapshot().size, 0)
        A64Emitter.noteMemBase(29)
        @Assert(A64Emitter.auditMemBasesSnapshot().size, 1)
        A64Emitter.resetAuditMemBases()
        @Assert(A64Emitter.auditMemBasesSnapshot().size, 0)
    }
}
