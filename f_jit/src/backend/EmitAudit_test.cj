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

import std.unittest.*
import std.unittest.testmacro.*

/**
 * G5 发射审计（双后端）：内存访问的**概念基址**必须落在受控集合内。
 *
 * - x86_64：`{rsp(4), rbp(5), r15(15)}`——`X86Lower.lower` 结束时用同一判定自检
 *   （不通过 ⇒ `ok=false`，整单元退回解释器）；
 * - aarch64：`{x19(19), x20(20), x29(29), sp(31)}`——`A64Compiler` 同款自检。
 *
 * 这条约束等价于「机器码不得把 helper 返回的 `cell` 当指针解引用」：任何解引用都必然有
 * 基址寄存器，而合法基址只有栈/帧/ctx（aarch64 另含操作数栈指针 x20）。
 */
@Test
public class EmitAudit_test {

    /** x86_64：允许集 = `{4,5,15}`，越界（如 `rax(0)`、`rsi(6)`）必须拒绝。 */
    @TestCase
    public func x86AllowedBases(): Unit {
        @Assert(BackendX86_64.auditAllows([]), true)
        @Assert(BackendX86_64.auditAllows([4, 5, 15]), true)
        @Assert(BackendX86_64.auditAllows([4, 15, 5, 4]), true)
        @Assert(BackendX86_64.auditAllows([0]), false)
        @Assert(BackendX86_64.auditAllows([4, 6]), false)
        @Assert(BackendX86_64.auditAllows([15, 2]), false)
    }

    /** aarch64：允许集 = `{19,20,29,31}`，越界（如 `x0(0)`、`x16(16)`）必须拒绝。 */
    @TestCase
    public func a64AllowedBases(): Unit {
        @Assert(A64Emitter.auditAllows([]), true)
        @Assert(A64Emitter.auditAllows([19, 20, 29, 31]), true)
        @Assert(A64Emitter.auditAllows([0]), false)
        @Assert(A64Emitter.auditAllows([16]), false)
        @Assert(A64Emitter.auditAllows([29, 30]), false)
    }

    /** 采集/重置语义：`noteMemBase` 追加、`reset` 清空（生产路径依赖这一对）。 */
    @TestCase
    public func x86NoteAndReset(): Unit {
        BackendX86_64.resetAuditMemBases()
        BackendX86_64.noteMemBase(5)
        BackendX86_64.noteMemBase(15)
        @Assert(BackendX86_64.auditMemBasesSnapshot().size, 2)
        BackendX86_64.resetAuditMemBases()
        @Assert(BackendX86_64.auditMemBasesSnapshot().size, 0)
    }

    @TestCase
    public func a64NoteAndReset(): Unit {
        A64Emitter.resetAuditMemBases()
        A64Emitter.noteMemBase(20)
        A64Emitter.noteMemBase(31)
        @Assert(A64Emitter.auditMemBasesSnapshot().size, 2)
        A64Emitter.resetAuditMemBases()
        @Assert(A64Emitter.auditMemBasesSnapshot().size, 0)
    }
}
