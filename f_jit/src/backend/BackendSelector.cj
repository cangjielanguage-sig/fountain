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
import fountain::f_base.Arch
import fountain::f_base.OS
import fountain::f_jit.base.DiagCode
import fountain::f_jit.base.DiagnosticLevel
import fountain::f_jit.base.DiagnosticsSink
import fountain::f_jit.base.Engine
import fountain::f_jit.base.JitMode

/**
 * 引擎选择（design §6.3.4、§12.1、plan S5.3）。
 *
 * | 模式 | Linux + 支持指令集 | 其他 |
 * |---|---|---|
 * | `Off` | Interp | Interp |
 * | `Auto` / `Force` | Jit + 对应后端 | Interp（`Warn/JitFallback`，绝不报错） |
 *
 * 当前指令集支持集 = 仓颉 SDK for Linux 的支持集（x86_64 / aarch64）。
 */
public class BackendSelector {
    /** 按当前平台选择。 */
    protected static func select(mode: JitMode, diag: DiagnosticsSink): (Engine, ?Backend) {
        BackendSelector.selectFor(mode, OS.current, Arch.current, diag)
    }

    /** 可注入 OS/Arch 的矩阵入口（测试用；语义与 `select` 完全一致）。 */
    protected static func selectFor(mode: JitMode, os: OS, arch: Arch,
        diag: DiagnosticsSink): (Engine, ?Backend) {
        if (mode == JitMode.Off) {
            return (Engine.Interp, None)
        }
        if (!os.isLinux) {
            diag.diag(DiagnosticLevel.Warn, DiagCode.JitFallback,
                '非 Linux 平台（${os}）：JIT 不可用，降级解释器（§12.1）')
            return (Engine.Interp, None)
        }
        match (arch) {
            case Arch.x86_64 => (Engine.Jit, Some(BackendX86_64()))
            case Arch.aarch64 => (Engine.Jit, Some(BackendAArch64()))
        }
    }
}

/** x86_64 后端（P5.4–P5.8 落地；当前为契约占位）。 */
internal class BackendX86_64 <: Backend {
    public prop name: String {
        get() {
            'x86_64'
        }
    }

    public func abiSummary(): String {
        'CTX=r15 FP=rbp SP=rsp RETV=rax TMP=r10/r11'
    }

    public func entryThunkBase(): Int64 {
        0
    }

    public func entryThunkFor(fnId: UInt32): Int64 {
        0
    }

    // ---- P5.4 帧序列（§12.3、§4 prologue）----

    /** FRAME = align16(32 + 8×(nLocals + maxStack))。 */
    internal static func frameSize(nLocals: Int64, maxStack: Int64): Int64 {
        let raw = 32 + 8 * (nLocals + maxStack)
        ((raw + 15) / 16) * 16
    }

    /**
     * 序言：`endbr64` → 保存 rbp/r15 → `r15 = ctx` → 写 `ctx.fnId` → `sub rsp, FRAME`
     * → args 拷入 `locals[i]`（`[rbp-32-8i]`）→ 其余局部槽清 0（卫生填充）。
     */
    internal static func emitPrologue(fnId: UInt32, nargs: Int64, nLocals: Int64,
        maxStack: Int64): Array<UInt8> {
        let frame = BackendX86_64.frameSize(nLocals, maxStack)
        let out = ArrayList<UInt8>()
        // endbr64；push rbp；mov rbp,rsp；mov [rbp-8],r15；mov r15,rdi
        for (b in [0xF3u8, 0x0Fu8, 0x1Eu8, 0xFAu8, 0x55u8, 0x48u8, 0x89u8, 0xE5u8,
            0x4Cu8, 0x89u8, 0x7Du8, 0xF8u8, 0x49u8, 0x89u8, 0xFFu8]) {
            out.add(b)
        }
        // mov dword [r15+40], fnId
        for (b in [0x41u8, 0xC7u8, 0x47u8, 0x28u8]) {
            out.add(b)
        }
        BackendX86_64.w32(out, BackendX86_64.i32bits(Int64(fnId)))
        // sub rsp, FRAME
        out.add(0x48u8)
        out.add(0x81u8)
        out.add(0xECu8)
        BackendX86_64.w32(out, BackendX86_64.i32bits(frame))
        var i: Int64 = 0
        while (i < nargs) {
            // mov rax,[rsi+8i]
            out.add(0x48u8)
            out.add(0x8Bu8)
            out.add(0x46u8)
            out.add(UInt8(i * 8))
            // mov [rbp-(32+8i)],rax
            out.add(0x48u8)
            out.add(0x89u8)
            out.add(0x85u8)
            BackendX86_64.w32(out, BackendX86_64.i32bits(0 - (32 + 8 * i)))
            i = i + 1
        }
        while (i < nLocals) {
            // mov qword [rbp-(32+8i)], 0
            out.add(0x48u8)
            out.add(0xC7u8)
            out.add(0x85u8)
            BackendX86_64.w32(out, BackendX86_64.i32bits(0 - (32 + 8 * i)))
            BackendX86_64.w32(out, 0u32)
            i = i + 1
        }
        out.toArray()
    }

    /** 出口：恢复 r15 → `rsp=rbp` → pop rbp → ret（RET/RET_VOID/BAIL 统一跳这里）。 */
    internal static func emitEpilogue(): Array<UInt8> {
        [0x4Cu8, 0x8Bu8, 0x7Du8, 0xF8u8, 0x48u8, 0x89u8, 0xECu8, 0x5Du8, 0xC3u8]
    }

    /** Int64 → 低 32 位（两补码，不做范围检查）。 */
    private static func i32bits(v: Int64): UInt32 {
        let m: Int64 = 4294967296
        UInt32(((v % m) + m) % m)
    }

    private static func w32(out: ArrayList<UInt8>, v: UInt32): Unit {
        var k = 0
        while (k < 4) {
            out.add(UInt8((v >> (8 * UInt32(k))) & 0xFFu32))
            k = k + 1
        }
    }
}

/** AArch64 后端（P5.9 落地；当前为契约占位）。 */
internal class BackendAArch64 <: Backend {
    public prop name: String {
        get() {
            'aarch64'
        }
    }

    public func abiSummary(): String {
        'CTX=x19 FP=x29 SP=sp RETV=x0 TMP=x9/x10'
    }

    public func entryThunkBase(): Int64 {
        0
    }

    public func entryThunkFor(fnId: UInt32): Int64 {
        0
    }
}
