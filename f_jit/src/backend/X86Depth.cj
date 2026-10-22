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

import std.collection.{ArrayList, HashMap}
import fountain::f_jit.bytecode.InsnDecoder

/**
 * x86_64 操作数栈深度分析（供 `alignBeforeCall` 决定 16 字节对齐补丁）。
 *
 * 背景：`X86Lower` 逐指令降低时若用**线性累加**的深度，分支汇合点会与运行期不一致
 * （典型：`JZ` 的失败分支运行期深度 0、线性深度 1），导致 `sub rsp, 8` 的奇偶算反、
 * `call` 前栈未 16 字节对齐（x86_64 专属缺陷）。
 *
 * 本模块以**控制流数据流**求每条指令入口深度：指令的栈增量由 `X86Lower` 的探针遍采集
 * （`delta[off]`），因此不维护第二份手写栈效应表，也就不存在表与降低代码漂移的问题。
 */
internal class X86Depth {
    /** 终止类指令：其后无后继（函数在此结束）。 */
    private static func isTerminal(op: UInt8): Bool {
        op == 0x01u8 || // TRAP
        op == 0x05u8 || // BAIL
        op == 0x7Cu8 || // RET
        op == 0x7Du8 || // RET_VOID
        op == 0x7Eu8 || // RET_NULL
        op == 0x87u8 // ABORT
    }

    /** 有条件的相对跳转（目标 + 顺序后继）。 */
    private static func isCondJump(op: UInt8): Bool {
        op == 0x71u8 || op == 0x72u8 // JZ / JNZ
    }

    private static func rel32Of(ops: Array<UInt8>): Int64 {
        let u = Int64(ops[0]) | (Int64(ops[1]) << 8) | (Int64(ops[2]) << 16) | (Int64(ops[3]) << 24)
        let v = if (u >= 0x80000000) {
            u - 0x100000000
        } else {
            u
        }
        v
    }

    /**
     * 求每条指令入口的操作数栈深度。
     *
     * - `delta[off]` = 该指令的净栈变化（由调用方以探针遍采集）；
     * - 同一偏移从不同前驱到达且深度不同 ⇒ `None`（放弃 JIT，退回解释器）；
     * - 跳转目标越界、指令偏移缺失增量、未识别指令 ⇒ `None`。
     */
    static func analyze(code: Array<UInt8>, codeOff: Int64, codeLen: Int64,
        delta: HashMap<Int64, Int64>): ?HashMap<Int64, Int64> {
        if (codeLen <= 0) {
            return None
        }
        let end = codeOff + codeLen
        let depthAt = HashMap<Int64, Int64>()
        // 工作列表以扁平数组模拟栈：[off0, depth0, off1, depth1, ...]
        let work = ArrayList<Int64>()
        work.add(codeOff)
        work.add(0)
        while (work.size >= 2) {
            let d = work[work.size - 1]
            let off = work[work.size - 2]
            work.remove(at: work.size - 1)
            work.remove(at: work.size - 1)
            if (off < codeOff || off >= end) {
                return None
            }
            match (depthAt.get(off)) {
                case Some(prev) =>
                    if (prev != d) {
                        return None
                    }
                    continue
                case None => depthAt[off] = d
            }
            let insn = InsnDecoder.decode(code, off)
            let next = off + insn.size
            if (next > end) {
                return None
            }
            let step = match (delta.get(off)) {
                case Some(v) => v
                case None => return None
            }
            let out = d + step
            if (out < 0) {
                return None
            }
            if (X86Depth.isTerminal(insn.op)) {
                continue
            }
            if (insn.op == 0x70u8 || insn.op == 0x74u8) {
                // JMP / LOOP_BACK：仅目标（`target == end` = 跳到函数尾，合法，不分析）
                let target = next + X86Depth.rel32Of(insn.operands)
                if (target < codeOff || target > end) {
                    return None
                }
                if (target < end) {
                    work.add(target)
                    work.add(out)
                }
            } else if (X86Depth.isCondJump(insn.op)) {
                // JZ / JNZ：目标 + 顺序后继
                let target = next + X86Depth.rel32Of(insn.operands)
                if (target < codeOff || target > end) {
                    return None
                }
                if (target < end) {
                    work.add(target)
                    work.add(out)
                }
                if (next < end) {
                    work.add(next)
                    work.add(out)
                }
            } else if (next < end) {
                work.add(next)
                work.add(out)
            }
        }
        depthAt
    }
}
