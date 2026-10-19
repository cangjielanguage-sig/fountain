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
import fountain::f_jit.bytecode.LoadedUnit
import fountain::f_jit.runtime.HelperAddresses

/**
 * S5.4 x86_64 单函数编排：帧序 + `X86Lower` 指令降低 + 收敛块。
 *
 * 与 `A64Compiler` 同构；调用模板、控制流、常量镜像都由 `X86Lower` 一次性回填。
 * 遇到未支持指令返回 `None`，调用方整单元降级解释器。
 */
public class X86Compiler {
    /** 无镜像/入口表的最小入口（测试/旧调用）。 */
    public static func compileFunction(unit: LoadedUnit, fn: FuncEntry): ?Array<UInt8> {
        X86Compiler.compileFunctionWith(unit, fn, 0, 0)
    }

    public static func compileFunctionWith(unit: LoadedUnit, fn: FuncEntry,
        constBase: Int64, fnTableBase: Int64): ?Array<UInt8> {
        let pre = BackendX86_64.emitPrologue(fn.fnId, Int64(fn.nargs),
            Int64(fn.nLocals), Int64(fn.maxStack))
        let lower = X86Lower(fn, constBase, fnTableBase)
        lower.lower(unit)
        if (!lower.success()) {
            return None
        }
        // 出口：RET/RET_VOID/BAIL(-1) 的共同落点
        lower.bindLabel('epilogue')
        lower.appendBytes(BackendX86_64.emitEpilogue())
        // 收敛块：写好的 errCode 已在 ctx；此处只做一次转储并返回 0
        lower.bindLabel('checkfail')
        lower.appendBytes([0x48u8, 0x83u8, 0xE4u8, 0xF0u8]) // and rsp,-16
        lower.appendBytes([0x49u8, 0x8Bu8, 0x7Fu8, 0x38u8]) // mov rdi,[r15+56]
        lower.appendBytes([0x49u8, 0x8Bu8, 0x37u8]) // mov rsi,[r15]
        lower.movImm64(2, Int64(fn.fnId)) // rdx = fnId
        lower.movImm64(1, Int64(fn.nLocals)) // rcx = nLocals
        lower.appendBytes([0x4Cu8, 0x8Du8, 0x45u8, 0xE0u8]) // lea r8,[rbp-32]
        lower.movImm64(0, HelperAddresses.dump())
        lower.appendCallRax()
        lower.appendXorEax()
        lower.jumpTo('epilogue')
        let body = match (lower.finish()) {
            case Some(b) => b
            case None => return None
        }
        let out = ArrayList<UInt8>()
        for (b in pre) {
            out.add(b)
        }
        for (b in body) {
            out.add(b)
        }
        out.toArray()
    }
}
