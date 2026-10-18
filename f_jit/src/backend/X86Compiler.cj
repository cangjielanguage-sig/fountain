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

import std.collection.ArrayList
import fountain::f_jit.bytecode.FuncEntry
import fountain::f_jit.bytecode.InsnDecoder
import fountain::f_jit.bytecode.LoadedUnit

/**
 * S5.4 x86_64 单函数编排（最小路径）：帧序 + 指令降低 + 出口。
 *
 * 与 `A64Compiler` 同构：只支持无分支、无 helper、无跨函数调用的指令子集；
 * 遇到未支持指令返回 `None`，调用方降级解释器。分支/重定位在后续片补。
 */
public class X86Compiler {
    /** 编译单函数；含未支持指令 → None。 */
    public static func compileFunction(unit: LoadedUnit, fn: FuncEntry): ?Array<UInt8> {
        let out = ArrayList<UInt8>()
        for (b in BackendX86_64.emitPrologue(fn.fnId, Int64(fn.nargs), Int64(fn.nLocals),
            Int64(fn.maxStack))) {
            out.add(b)
        }
        var pc = Int64(fn.codeOff)
        let end = pc + Int64(fn.codeLen)
        while (pc < end) {
            let insn = InsnDecoder.decode(unit.code, pc)
            match (X86Compiler.lower(insn.op, insn.operands)) {
                case Some(bs) =>
                    for (b in bs) {
                        out.add(b)
                    }
                case None => return None
            }
            pc = pc + insn.size
        }
        for (b in BackendX86_64.emitEpilogue()) {
            out.add(b)
        }
        out.toArray()
    }

    private static func lower(op: UInt8, ops: Array<UInt8>): ?Array<UInt8> {
        match (op) {
            case 0x00u8 => Some(BackendX86_64.emitNop())
            case 0x10u8 => Some(BackendX86_64.emitPushI64(X86Compiler.i8(ops, 0)))
            case 0x12u8 => Some(BackendX86_64.emitPushI64(X86Compiler.i64(ops, 0)))
            case 0x17u8 => Some(BackendX86_64.emitDup())
            case 0x19u8 => Some(BackendX86_64.emitPop())
            case 0x1Bu8 => Some(BackendX86_64.emitSwap())
            case 0x20u8 => Some(BackendX86_64.emitLoadL(X86Compiler.u8(ops, 0)))
            case 0x21u8 => Some(BackendX86_64.emitStoreL(X86Compiler.u8(ops, 0)))
            case 0x22u8 => Some(BackendX86_64.emitLoadL(0))
            case 0x23u8 => Some(BackendX86_64.emitLoadL(1))
            case 0x24u8 => Some(BackendX86_64.emitLoadL(2))
            case 0x25u8 => Some(BackendX86_64.emitLoadL(3))
            case 0x30u8 => Some(BackendX86_64.emitIAdd())
            case 0x31u8 => Some(BackendX86_64.emitISub())
            case 0x32u8 => Some(BackendX86_64.emitIMul())
            case 0x62u8 => Some(BackendX86_64.emitBAnd())
            case 0x63u8 => Some(BackendX86_64.emitBOr())
            case 0x64u8 => Some(BackendX86_64.emitBXor())
            case 0x7Cu8 => Some(BackendX86_64.emitEpilogue())
            case 0x7Du8 => Some(BackendX86_64.emitEpilogue())
            case 0x7Eu8 => Some(BackendX86_64.emitEpilogue())
            case _ => None
        }
    }

    private static func u8(bs: Array<UInt8>, at: Int64): Int64 {
        Int64(bs[at])
    }

    private static func i8(bs: Array<UInt8>, at: Int64): Int64 {
        let v = Int64(bs[at])
        if (v >= 128) {
            v - 256
        } else {
            v
        }
    }

    private static func i64(bs: Array<UInt8>, at: Int64): Int64 {
        var u: UInt64 = 0
        var i = 7
        while (i >= 0) {
            u = (u << 8) | UInt64(bs[at + i])
            i = i - 1
        }
        Int64(u)
    }
}
