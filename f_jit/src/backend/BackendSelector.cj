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
import fountain::f_jit.bytecode.LoadedUnit

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

    public func compile(unit: LoadedUnit, sink: CodeBuffer): Bool {
        // S5.4 骨架：指令 lowering 在 S5.5/S5.6 落地；当前一律降级解释器。
        false
    }

    public func entryThunkBase(): Int64 {
        match (this.thunkBuf) {
            case Some(b) => b.base
            case None => 0
        }
    }

    public func entryThunkFor(fnId: UInt32): Int64 {
        if (Int64(fnId) >= this.thunkCount) {
            return 0
        }
        this.entryThunkBase() + Int64(fnId) * 16
    }

    // ---- P5.4 entryThunk（每函数 16 B：endbr64; jmp rel32）----

    private var thunkBuf: ?CodeBuffer = None
    private var thunkCount: Int64 = 0

    /** 为 `entries` 建 thunk 区并 seal；失败 → false（调用方降级解释器）。 */
    internal func prepareThunks(entries: Array<Int64>): Bool {
        this.releaseThunks()
        if (entries.size == 0) {
            return true
        }
        let buf = match (CodeBuffer.alloc(entries.size * 16)) {
            case Some(b) => b
            case None => return false
        }
        var i = 0
        while (i < entries.size) {
            let thunkAddr = buf.base + i * 16
            let rel = entries[i] - (thunkAddr + 9)
            let bs = ArrayList<UInt8>()
            for (x in [0xF3u8, 0x0Fu8, 0x1Eu8, 0xFAu8]) {
                bs.add(x)
            }
            if (rel >= -2147483648 && rel <= 2147483647) {
                bs.add(0xE9u8) // jmp rel32
                BackendX86_64.w32(bs, BackendX86_64.i32bits(rel))
            } else {
                // 远目标：mov rax, imm64; jmp rax（整槽 16 B）
                bs.add(0x48u8)
                bs.add(0xB8u8)
                BackendX86_64.w64(bs, entries[i])
                bs.add(0xFFu8)
                bs.add(0xE0u8)
            }
            if (!buf.write(bs.toArray(), i * 16)) {
                buf.free()
                return false
            }
            i = i + 1
        }
        if (!buf.seal()) {
            buf.free()
            return false
        }
        this.thunkBuf = Some(buf)
        this.thunkCount = entries.size
        true
    }

    internal func thunkBytes(fnId: UInt32): Array<UInt8> {
        if (Int64(fnId) >= this.thunkCount) {
            return Array<UInt8>()
        }
        match (this.thunkBuf) {
            case Some(b) => b.read(Int64(fnId) * 16, 16)
            case None => Array<UInt8>()
        }
    }

    internal func releaseThunks(): Unit {
        match (this.thunkBuf) {
            case Some(b) => b.free()
            case None => ()
        }
        this.thunkBuf = None
        this.thunkCount = 0
    }

    // ---- S5.5 第一片：常量 / 栈 / 局部 ----

    internal static func emitNop(): Array<UInt8> {
        [0x90u8]
    }

    /** `PUSH_I64 v`：`movabs rax, v; push rax`。 */
    internal static func emitPushI64(v: Int64): Array<UInt8> {
        let out = ArrayList<UInt8>()
        out.add(0x48u8)
        out.add(0xB8u8)
        BackendX86_64.w64(out, v)
        out.add(0x50u8)
        out.toArray()
    }

    /** `DUP`：`push qword [rsp]`。 */
    internal static func emitDup(): Array<UInt8> {
        [0xFFu8, 0x34u8, 0x24u8]
    }

    /** `POP`：`add rsp, 8`。 */
    internal static func emitPop(): Array<UInt8> {
        [0x48u8, 0x83u8, 0xC4u8, 0x08u8]
    }

    /** `SWAP`：交换 `[rsp]` 与 `[rsp+8]`。 */
    internal static func emitSwap(): Array<UInt8> {
        [0x48u8, 0x8Bu8, 0x04u8, 0x24u8, 0x48u8, 0x8Bu8, 0x4Cu8, 0x24u8, 0x08u8,
         0x48u8, 0x89u8, 0x0Cu8, 0x24u8, 0x48u8, 0x89u8, 0x44u8, 0x24u8, 0x08u8]
    }

    /** `LOADL idx`：`push qword [rbp-32-8idx]`。 */
    internal static func emitLoadL(idx: Int64): Array<UInt8> {
        let out = ArrayList<UInt8>()
        out.add(0xFFu8)
        out.add(0xB5u8)
        BackendX86_64.w32(out, BackendX86_64.i32bits(0 - (32 + 8 * idx)))
        out.toArray()
    }

    /** `STOREL idx`：`pop qword [rbp-32-8idx]`。 */
    internal static func emitStoreL(idx: Int64): Array<UInt8> {
        let out = ArrayList<UInt8>()
        out.add(0x48u8)
        out.add(0x8Fu8)
        out.add(0x85u8)
        BackendX86_64.w32(out, BackendX86_64.i32bits(0 - (32 + 8 * idx)))
        out.toArray()
    }

    // ---- S5.5 整型二元 / 分支 ----

    private static func binOp(opBytes: Array<UInt8>): Array<UInt8> {
        let out = ArrayList<UInt8>()
        for (b in [0x48u8, 0x8Bu8, 0x44u8, 0x24u8, 0x08u8]) {
            out.add(b) // mov rax,[rsp+8]
        }
        for (b in opBytes) {
            out.add(b)
        }
        for (b in [0x48u8, 0x89u8, 0x44u8, 0x24u8, 0x08u8]) {
            out.add(b) // mov [rsp+8],rax
        }
        for (b in [0x48u8, 0x83u8, 0xC4u8, 0x08u8]) {
            out.add(b) // add rsp,8
        }
        out.toArray()
    }

    internal static func emitIAdd(): Array<UInt8> {
        BackendX86_64.binOp([0x48u8, 0x03u8, 0x04u8, 0x24u8])
    }

    internal static func emitISub(): Array<UInt8> {
        BackendX86_64.binOp([0x48u8, 0x2Bu8, 0x04u8, 0x24u8])
    }

    internal static func emitIMul(): Array<UInt8> {
        BackendX86_64.binOp([0x48u8, 0x0Fu8, 0xAFu8, 0x04u8, 0x24u8])
    }

    internal static func emitBAnd(): Array<UInt8> {
        BackendX86_64.binOp([0x48u8, 0x23u8, 0x04u8, 0x24u8])
    }

    internal static func emitBOr(): Array<UInt8> {
        BackendX86_64.binOp([0x48u8, 0x0Bu8, 0x04u8, 0x24u8])
    }

    internal static func emitBXor(): Array<UInt8> {
        BackendX86_64.binOp([0x48u8, 0x33u8, 0x04u8, 0x24u8])
    }

    private static func cmpOp(setcc: Array<UInt8>): Array<UInt8> {
        let out = ArrayList<UInt8>()
        for (x in [0x48u8, 0x8Bu8, 0x44u8, 0x24u8, 0x08u8, 0x48u8, 0x3Bu8, 0x04u8, 0x24u8]) {
            out.add(x)
        }
        for (x in setcc) {
            out.add(x)
        }
        for (x in [0x0Fu8, 0xB6u8, 0xC0u8, 0x48u8, 0x89u8, 0x44u8, 0x24u8, 0x08u8,
            0x48u8, 0x83u8, 0xC4u8, 0x08u8]) {
            out.add(x)
        }
        out.toArray()
    }

    internal static func emitCmpEq(): Array<UInt8> {
        BackendX86_64.cmpOp([0x0Fu8, 0x94u8, 0xC0u8])
    }

    internal static func emitCmpNe(): Array<UInt8> {
        BackendX86_64.cmpOp([0x0Fu8, 0x95u8, 0xC0u8])
    }

    internal static func emitCmpLe(): Array<UInt8> {
        BackendX86_64.cmpOp([0x0Fu8, 0x9Eu8, 0xC0u8])
    }

    internal static func emitCmpGt(): Array<UInt8> {
        BackendX86_64.cmpOp([0x0Fu8, 0x9Fu8, 0xC0u8])
    }

    internal static func emitCmpGe(): Array<UInt8> {
        BackendX86_64.cmpOp([0x0Fu8, 0x9Du8, 0xC0u8])
    }

    internal static func emitCmpLt(): Array<UInt8> {
        BackendX86_64.cmpOp([0x0Fu8, 0x9Cu8, 0xC0u8])
    }

    /**
     * 模板 A：`CALL_HELPER hid, argc`。
     *
     * `rdi=ctx(r15)`、`rsi=&args`（最深实参 = `rsp+8*(argc-1)`）、`rdx=argc`；
     * `call rax` 后结果替换最深槽并收参；尾随 `CHECK_ERR`（rel 占位）。
     */
    internal static func emitCallHelper(helperAddr: Int64, argc: Int64): Array<UInt8> {
        let out = ArrayList<UInt8>()
        for (x in [0x4Cu8, 0x89u8, 0xFFu8]) {
            out.add(x) // mov rdi,r15
        }
        for (x in [0x48u8, 0x8Du8, 0x74u8, 0x24u8]) {
            out.add(x) // lea rsi,[rsp+disp8]
        }
        out.add(UInt8(8 * (argc - 1)))
        for (x in [0xBAu8]) {
            out.add(x) // mov edx,argc
        }
        BackendX86_64.w32(out, BackendX86_64.i32bits(argc))
        out.add(0x48u8)
        out.add(0xB8u8)
        BackendX86_64.w64(out, helperAddr)
        for (x in [0xFFu8, 0xD0u8]) {
            out.add(x) // call rax
        }
        for (x in [0x48u8, 0x89u8, 0x84u8, 0x24u8]) {
            out.add(x) // mov [rsp+disp32],rax
        }
        BackendX86_64.w32(out, BackendX86_64.i32bits(8 * (argc - 1)))
        for (x in [0x48u8, 0x83u8, 0xC4u8, UInt8(8 * (argc - 1))]) {
            out.add(x) // add rsp,8*(argc-1)
        }
        for (x in [0x49u8, 0x83u8, 0x3Fu8, 0x00u8, 0x0Fu8, 0x85u8, 0x00u8, 0x00u8, 0x00u8,
            0x00u8]) {
            out.add(x) // CHECK_ERR（占位）
        }
        out.toArray()
    }

    /**
     * 模板 B：`CALL_FUNC fid`。
     *
     * `mov rax, fnTableBase; call [rax+8*fid]`；返回后重写 `ctx.fnId=self`，
     * 尾随 `CHECK_ERR`（rel 占位）。
     */
    internal static func emitCallFunc(fnTableBase: Int64, fid: UInt32,
        selfFnId: UInt32): Array<UInt8> {
        let out = ArrayList<UInt8>()
        out.add(0x48u8)
        out.add(0xB8u8)
        BackendX86_64.w64(out, fnTableBase)
        for (x in [0xFFu8, 0x90u8]) {
            out.add(x) // call qword [rax+disp32]
        }
        BackendX86_64.w32(out, BackendX86_64.i32bits(8 * Int64(fid)))
        for (x in [0x41u8, 0xC7u8, 0x47u8, 0x28u8]) {
            out.add(x) // mov dword [r15+40], self
        }
        BackendX86_64.w32(out, UInt32(Int64(selfFnId)))
        for (x in [0x49u8, 0x83u8, 0x3Fu8, 0x00u8, 0x0Fu8, 0x85u8, 0x00u8, 0x00u8, 0x00u8,
            0x00u8]) {
            out.add(x) // CHECK_ERR（占位）
        }
        out.toArray()
    }

    /**
     * 模板 C：`CALL_CLOSURE argc`（骨架）。
     *
     * H55 取 fnId → H57 取 fnTable 基址 → `call [base+8*fnId]` → 重写 `ctx.fnId`
     * → 结果替换闭包槽并收参；每个 helper 后 CHECK_ERR（rel 占位）。
     */
    internal static func emitCallClosure(h55: Int64, h57: Int64, argc: Int64,
        selfFnId: UInt32): Array<UInt8> {
        let out = ArrayList<UInt8>()
        let disp = 8 * argc
        // H55(ctx, &closure, 1)
        for (x in [0x4Cu8, 0x89u8, 0xFFu8, 0x48u8, 0x8Du8, 0x74u8, 0x24u8]) {
            out.add(x)
        }
        out.add(UInt8(disp))
        for (x in [0xBAu8]) {
            out.add(x)
        }
        BackendX86_64.w32(out, 1u32)
        out.add(0x48u8)
        out.add(0xB8u8)
        BackendX86_64.w64(out, h55)
        for (x in [0xFFu8, 0xD0u8, 0x48u8, 0x89u8, 0x84u8, 0x24u8]) {
            out.add(x)
        }
        BackendX86_64.w32(out, BackendX86_64.i32bits(disp))
        BackendX86_64.appendCheckErr(out)
        // H57(ctx, &0, 0)
        for (x in [0x4Cu8, 0x89u8, 0xFFu8, 0x48u8, 0x8Du8, 0x74u8, 0x24u8]) {
            out.add(x)
        }
        out.add(UInt8(disp))
        for (x in [0x31u8, 0xD2u8]) {
            out.add(x) // xor edx,edx
        }
        out.add(0x48u8)
        out.add(0xB8u8)
        BackendX86_64.w64(out, h57)
        for (x in [0xFFu8, 0xD0u8]) {
            out.add(x)
        }
        BackendX86_64.appendCheckErr(out)
        // call [rax + r11*8]
        for (x in [0x4Cu8, 0x8Bu8, 0x9Cu8, 0x24u8]) {
            out.add(x)
        }
        BackendX86_64.w32(out, BackendX86_64.i32bits(disp))
        for (x in [0x42u8, 0xFFu8, 0x14u8, 0xD8u8]) {
            out.add(x)
        }
        for (x in [0x41u8, 0xC7u8, 0x47u8, 0x28u8]) {
            out.add(x)
        }
        BackendX86_64.w32(out, UInt32(Int64(selfFnId)))
        BackendX86_64.appendCheckErr(out)
        for (x in [0x48u8, 0x89u8, 0x84u8, 0x24u8]) {
            out.add(x)
        }
        BackendX86_64.w32(out, BackendX86_64.i32bits(disp))
        for (x in [0x48u8, 0x81u8, 0xC4u8]) {
            out.add(x)
        }
        BackendX86_64.w32(out, BackendX86_64.i32bits(disp))
        out.toArray()
    }

    /** `IS_TYPE v`：tag == v → 顶格布尔（0/1）。 */
    internal static func emitIsType(v: Int64): Array<UInt8> {
        let out = ArrayList<UInt8>()
        for (x in [0x48u8, 0x8Bu8, 0x04u8, 0x24u8, 0x48u8, 0x89u8, 0xC1u8,
            0x48u8, 0xC1u8, 0xE9u8, 0x30u8, 0x48u8, 0x81u8, 0xF9u8]) {
            out.add(x)
        }
        BackendX86_64.w32(out, BackendX86_64.i32bits(v))
        for (x in [0x0Fu8, 0x94u8, 0xC0u8, 0x0Fu8, 0xB6u8, 0xC0u8, 0x48u8, 0x89u8, 0x04u8,
            0x24u8]) {
            out.add(x)
        }
        out.toArray()
    }

    /** `LOAD_CAP idx`：push locals[0]（闭包句柄）+ push idx，再走 H56 模板 A。 */
    internal static func emitLoadCap(h56: Int64, idx: Int64): Array<UInt8> {
        let out = ArrayList<UInt8>()
        for (x in [0xFFu8, 0xB5u8]) {
            out.add(x)
        }
        BackendX86_64.w32(out, BackendX86_64.i32bits(-32))
        out.add(0x48u8)
        out.add(0xB8u8)
        BackendX86_64.w64(out, idx)
        out.add(0x50u8)
        for (x in BackendX86_64.emitCallHelper(h56, 2)) {
            out.add(x)
        }
        out.toArray()
    }

    /** `BREAKPOINT`：发布版空操作。 */
    internal static func emitBreakpoint(): Array<UInt8> {
        [0x90u8]
    }

    /** `ABORT`：写 errCode=99 → RETV=0 → jmp epilogue（rel 占位）。 */
    internal static func emitAbort(): Array<UInt8> {
        [0x41u8, 0xC7u8, 0x07u8, 0x63u8, 0x00u8, 0x00u8, 0x00u8,
         0x31u8, 0xC0u8, 0xE9u8, 0x00u8, 0x00u8, 0x00u8, 0x00u8]
    }

    /** `THROW`：顶格 code 写入 ctx.errCode → RETV=0 → jmp epilogue（rel 占位）。 */
    internal static func emitThrow(): Array<UInt8> {
        [0x48u8, 0x8Bu8, 0x04u8, 0x24u8, 0x41u8, 0x89u8, 0x07u8,
         0x31u8, 0xC0u8, 0xE9u8, 0x00u8, 0x00u8, 0x00u8, 0x00u8]
    }

    /** `GUARD v`：取 cell 高 16 位 tag，不等于 v → bail（rel 占位）。 */
    internal static func emitGuard(v: Int64): Array<UInt8> {
        let out = ArrayList<UInt8>()
        for (x in [0x48u8, 0x8Bu8, 0x04u8, 0x24u8, 0x48u8, 0x89u8, 0xC1u8,
            0x48u8, 0xC1u8, 0xE9u8, 0x30u8, 0x48u8, 0x81u8, 0xF9u8]) {
            out.add(x) // mov rax,[rsp]; mov rcx,rax; shr rcx,48; cmp rcx,v
        }
        BackendX86_64.w32(out, BackendX86_64.i32bits(v))
        for (x in [0x0Fu8, 0x85u8, 0x00u8, 0x00u8, 0x00u8, 0x00u8]) {
            out.add(x) // jne bail（占位）
        }
        out.toArray()
    }

    /** `GUARD_NNZ`：顶格为 0 → bail（rel 占位）。 */
    internal static func emitGuardNnz(): Array<UInt8> {
        [0x48u8, 0x8Bu8, 0x04u8, 0x24u8, 0x48u8, 0x85u8, 0xC0u8, 0x0Fu8, 0x84u8,
         0x00u8, 0x00u8, 0x00u8, 0x00u8]
    }

    /** `TO_I64`：NaN + ±2^63 越界判定（jae/jb bail）；通过后 cvttsd2si。 */
    internal static func emitToI64RangeGuarded(): Array<UInt8> {
        [0xF2u8, 0x0Fu8, 0x10u8, 0x04u8, 0x24u8,
         0x66u8, 0x0Fu8, 0x2Eu8, 0xC0u8,
         0x0Fu8, 0x8Au8, 0x00u8, 0x00u8, 0x00u8, 0x00u8,
         0x48u8, 0xB8u8, 0x00u8, 0x00u8, 0x00u8, 0x00u8, 0x00u8, 0x00u8, 0xE0u8, 0x43u8,
         0x66u8, 0x48u8, 0x0Fu8, 0x6Eu8, 0xC8u8,
         0x66u8, 0x0Fu8, 0x2Eu8, 0xC1u8,
         0x0Fu8, 0x83u8, 0x00u8, 0x00u8, 0x00u8, 0x00u8,
         0x48u8, 0xB8u8, 0x00u8, 0x00u8, 0x00u8, 0x00u8, 0x00u8, 0x00u8, 0xE0u8, 0xC3u8,
         0x66u8, 0x48u8, 0x0Fu8, 0x6Eu8, 0xC8u8,
         0x66u8, 0x0Fu8, 0x2Eu8, 0xC1u8,
         0x0Fu8, 0x82u8, 0x00u8, 0x00u8, 0x00u8, 0x00u8,
         0xF2u8, 0x48u8, 0x0Fu8, 0x2Cu8, 0xC0u8,
         0x48u8, 0x89u8, 0x04u8, 0x24u8]
    }

    /** `TO_I64`：NaN 前置 `jp bail`；越界判定待补。 */
    internal static func emitToI64Checked(): Array<UInt8> {
        [0xF2u8, 0x0Fu8, 0x10u8, 0x04u8, 0x24u8,
         0x66u8, 0x0Fu8, 0x2Eu8, 0xC0u8,
         0x0Fu8, 0x8Au8, 0x00u8, 0x00u8, 0x00u8, 0x00u8,
         0xF2u8, 0x48u8, 0x0Fu8, 0x2Cu8, 0xC0u8,
         0x48u8, 0x89u8, 0x04u8, 0x24u8]
    }

    /** `TO_I64`：`cvttsd2si rax,xmm0`（无检查；仅供已证明有界的路径）。 */
    internal static func emitToI64(): Array<UInt8> {
        [0xF2u8, 0x0Fu8, 0x10u8, 0x04u8, 0x24u8,
         0xF2u8, 0x48u8, 0x0Fu8, 0x2Cu8, 0xC0u8,
         0x48u8, 0x89u8, 0x04u8, 0x24u8]
    }

    /** `TO_F64`：`cvtsi2sd xmm0,rax`。 */
    internal static func emitToF64(): Array<UInt8> {
        [0x48u8, 0x8Bu8, 0x04u8, 0x24u8,
         0xF2u8, 0x48u8, 0x0Fu8, 0x2Au8, 0xC0u8,
         0xF2u8, 0x0Fu8, 0x11u8, 0x04u8, 0x24u8]
    }

    /** 浮点比较：`ucomisd` + `setnp` + `setcc` + and（NaN 全 false）。 */
    private static func fCmpOp(setcc: Array<UInt8>): Array<UInt8> {
        let out = ArrayList<UInt8>()
        for (x in [0xF2u8, 0x0Fu8, 0x10u8, 0x44u8, 0x24u8, 0x08u8,
            0xF2u8, 0x0Fu8, 0x10u8, 0x0Cu8, 0x24u8, 0x66u8, 0x0Fu8, 0x2Eu8, 0xC1u8,
            0x0Fu8, 0x9Bu8, 0xC0u8]) {
            out.add(x) // movsd xmm0,[rsp+8]; movsd xmm1,[rsp]; ucomisd; setnp al
        }
        for (x in setcc) {
            out.add(x)
        }
        for (x in [0x20u8, 0xD0u8, 0x0Fu8, 0xB6u8, 0xC0u8, 0x48u8, 0x89u8, 0x44u8, 0x24u8,
            0x08u8, 0x48u8, 0x83u8, 0xC4u8, 0x08u8]) {
            out.add(x) // and al,dl; movzx; 回写；收栈
        }
        out.toArray()
    }

    internal static func emitCmpEqF(): Array<UInt8> {
        BackendX86_64.fCmpOp([0x0Fu8, 0x94u8, 0xC2u8])
    }

    internal static func emitCmpNeF(): Array<UInt8> {
        BackendX86_64.fCmpOp([0x0Fu8, 0x95u8, 0xC2u8])
    }

    internal static func emitCmpLtF(): Array<UInt8> {
        BackendX86_64.fCmpOp([0x0Fu8, 0x92u8, 0xC2u8])
    }

    internal static func emitCmpLeF(): Array<UInt8> {
        BackendX86_64.fCmpOp([0x0Fu8, 0x96u8, 0xC2u8])
    }

    internal static func emitCmpGtF(): Array<UInt8> {
        BackendX86_64.fCmpOp([0x0Fu8, 0x97u8, 0xC2u8])
    }

    internal static func emitCmpGeF(): Array<UInt8> {
        BackendX86_64.fCmpOp([0x0Fu8, 0x93u8, 0xC2u8])
    }

    private static func fBinOp(opBytes: Array<UInt8>): Array<UInt8> {
        let out = ArrayList<UInt8>()
        for (x in [0xF2u8, 0x0Fu8, 0x10u8, 0x44u8, 0x24u8, 0x08u8,
            0xF2u8, 0x0Fu8, 0x10u8, 0x0Cu8, 0x24u8]) {
            out.add(x) // movsd xmm0,[rsp+8]; movsd xmm1,[rsp]
        }
        for (x in opBytes) {
            out.add(x)
        }
        for (x in [0xF2u8, 0x0Fu8, 0x11u8, 0x44u8, 0x24u8, 0x08u8, 0x48u8, 0x83u8, 0xC4u8,
            0x08u8]) {
            out.add(x) // movsd [rsp+8],xmm0; add rsp,8
        }
        // NaN 规范化：ucomisd xmm0,xmm0; jnp .n; movabs rax,CANON; movq xmm0,rax
        for (x in [0x66u8, 0x0Fu8, 0x2Eu8, 0xC0u8, 0x0Fu8, 0x8Bu8, 0x00u8, 0x00u8, 0x00u8,
            0x00u8, 0x48u8, 0xB8u8, 0x00u8, 0x00u8, 0x00u8, 0x00u8, 0x00u8, 0x00u8, 0xF8u8,
            0x7Fu8, 0x66u8, 0x48u8, 0x0Fu8, 0x6Eu8, 0xC0u8]) {
            out.add(x)
        }
        out.toArray()
    }

    internal static func emitFAdd(): Array<UInt8> {
        BackendX86_64.fBinOp([0xF2u8, 0x0Fu8, 0x58u8, 0xC1u8])
    }

    internal static func emitFSub(): Array<UInt8> {
        BackendX86_64.fBinOp([0xF2u8, 0x0Fu8, 0x5Cu8, 0xC1u8])
    }

    internal static func emitFMul(): Array<UInt8> {
        BackendX86_64.fBinOp([0xF2u8, 0x0Fu8, 0x59u8, 0xC1u8])
    }

    internal static func emitFDiv(): Array<UInt8> {
        BackendX86_64.fBinOp([0xF2u8, 0x0Fu8, 0x5Eu8, 0xC1u8])
    }

    /** `PUSH_BOOL v`：`push 0/1`。 */
    internal static func emitPushBool(v: Bool): Array<UInt8> {
        if (v) {
            [0x6Au8, 0x01u8]
        } else {
            [0x6Au8, 0x00u8]
        }
    }

    /** `PUSH_NULL`：`push 0`。 */
    internal static func emitPushNull(): Array<UInt8> {
        [0x6Au8, 0x00u8]
    }

    internal static func emitPushI8(v: Int64): Array<UInt8> {
        BackendX86_64.emitPushI64(v)
    }

    internal static func emitPushI32(v: Int64): Array<UInt8> {
        BackendX86_64.emitPushI64(v)
    }

    /** `DUP2`：复制顶两格。 */
    internal static func emitDup2(): Array<UInt8> {
        [0x48u8, 0x8Bu8, 0x04u8, 0x24u8, 0x48u8, 0x8Bu8, 0x4Cu8, 0x24u8, 0x08u8,
         0x50u8, 0x51u8]
    }

    /** `POP2`：收两格。 */
    internal static func emitPop2(): Array<UInt8> {
        [0x48u8, 0x83u8, 0xC4u8, 0x10u8]
    }

    internal static func emitLoadL0(): Array<UInt8> {
        BackendX86_64.emitLoadL(0)
    }

    internal static func emitLoadL3(): Array<UInt8> {
        BackendX86_64.emitLoadL(3)
    }

    internal static func emitIAddWrap(): Array<UInt8> {
        BackendX86_64.emitIAdd()
    }

    /** `PUSH_KH idx`：常量镜像地址已烘焙为绝对地址，`mov rax,[imm64]; push rax`。 */
    internal static func emitPushKh(constAddr: Int64): Array<UInt8> {
        let out = ArrayList<UInt8>()
        out.add(0x48u8)
        out.add(0xA1u8)
        BackendX86_64.w64(out, constAddr)
        out.add(0x50u8)
        out.toArray()
    }

    /** `PUSH_F64 bits`：`movabs rax,bits; push rax`。 */
    internal static func emitPushF64(bits: UInt64): Array<UInt8> {
        let out = ArrayList<UInt8>()
        out.add(0x48u8)
        out.add(0xB8u8)
        var k = 0
        while (k < 8) {
            out.add(UInt8((bits >> (8 * UInt64(k))) & 0xFFu64))
            k = k + 1
        }
        out.add(0x50u8)
        out.toArray()
    }

    /** `PUSH_UNIT`：`push 0`。 */
    internal static func emitPushUnit(): Array<UInt8> {
        [0x6Au8, 0x00u8]
    }

    private static func unaryTop(opBytes: Array<UInt8>): Array<UInt8> {
        let out = ArrayList<UInt8>()
        for (x in [0x48u8, 0x8Bu8, 0x04u8, 0x24u8]) {
            out.add(x) // mov rax,[rsp]
        }
        for (x in opBytes) {
            out.add(x)
        }
        for (x in [0x48u8, 0x89u8, 0x04u8, 0x24u8]) {
            out.add(x) // mov [rsp],rax
        }
        out.toArray()
    }

    internal static func emitINeg(): Array<UInt8> {
        BackendX86_64.unaryTop([0x48u8, 0xF7u8, 0xD8u8])
    }

    internal static func emitBNot(): Array<UInt8> {
        BackendX86_64.unaryTop([0x48u8, 0xF7u8, 0xD0u8])
    }

    /** `PICK n`：`push qword [rsp+8n]`。 */
    internal static func emitPick(n: Int64): Array<UInt8> {
        let out = ArrayList<UInt8>()
        for (x in [0xFFu8, 0xB4u8, 0x24u8]) {
            out.add(x)
        }
        BackendX86_64.w32(out, BackendX86_64.i32bits(8 * n))
        out.toArray()
    }

    private static func divModOp(storeRdx: Bool): Array<UInt8> {
        let out = ArrayList<UInt8>()
        for (x in [0x48u8, 0x8Bu8, 0x44u8, 0x24u8, 0x08u8, 0x48u8, 0x8Bu8, 0x0Cu8, 0x24u8,
            0x48u8, 0x85u8, 0xC9u8]) {
            out.add(x) // a → rax, b → rcx, test rcx,rcx
        }
        for (x in [0x0Fu8, 0x84u8, 0x00u8, 0x00u8, 0x00u8, 0x00u8]) {
            out.add(x) // jz bail2（占位）
        }
        for (x in [0x48u8, 0x83u8, 0xF9u8, 0xFFu8, 0x0Fu8, 0x85u8, 0x00u8, 0x00u8, 0x00u8,
            0x00u8]) {
            out.add(x) // cmp rcx,-1; jne ok（占位）
        }
        for (x in [0x48u8, 0xBAu8, 0x00u8, 0x00u8, 0x00u8, 0x00u8, 0x00u8, 0x00u8, 0x00u8,
            0x80u8, 0x48u8, 0x39u8, 0xD0u8, 0x0Fu8, 0x85u8, 0x00u8, 0x00u8, 0x00u8, 0x00u8]) {
            out.add(x) // mov rdx,INT64_MIN; cmp rax,rdx; jne ok（占位）
        }
        for (x in [0x48u8, 0x99u8, 0x48u8, 0xF7u8, 0xF9u8]) {
            out.add(x) // cqo; idiv rcx
        }
        if (storeRdx) {
            for (x in [0x48u8, 0x89u8, 0x54u8, 0x24u8, 0x08u8]) {
                out.add(x)
            }
        } else {
            for (x in [0x48u8, 0x89u8, 0x44u8, 0x24u8, 0x08u8]) {
                out.add(x)
            }
        }
        for (x in [0x48u8, 0x83u8, 0xC4u8, 0x08u8]) {
            out.add(x)
        }
        out.toArray()
    }

    internal static func emitIDiv(): Array<UInt8> {
        BackendX86_64.divModOp(false)
    }

    internal static func emitIMod(): Array<UInt8> {
        BackendX86_64.divModOp(true)
    }

    private static func shiftOp(shiftBytes: Array<UInt8>): Array<UInt8> {
        let out = ArrayList<UInt8>()
        for (x in [0x48u8, 0x8Bu8, 0x44u8, 0x24u8, 0x08u8, 0x48u8, 0x8Bu8, 0x0Cu8, 0x24u8]) {
            out.add(x)
        }
        for (x in shiftBytes) {
            out.add(x)
        }
        for (x in [0x48u8, 0x89u8, 0x44u8, 0x24u8, 0x08u8, 0x48u8, 0x83u8, 0xC4u8, 0x08u8]) {
            out.add(x)
        }
        out.toArray()
    }

    internal static func emitShl(): Array<UInt8> {
        BackendX86_64.shiftOp([0x48u8, 0xD3u8, 0xE0u8])
    }

    internal static func emitShr(): Array<UInt8> {
        BackendX86_64.shiftOp([0x48u8, 0xD3u8, 0xF8u8])
    }

    internal static func emitUShr(): Array<UInt8> {
        BackendX86_64.shiftOp([0x48u8, 0xD3u8, 0xE8u8])
    }

    /** `JMP rel32`（占位 0，P5.8 回填）。 */
    internal static func emitJmp(): Array<UInt8> {
        [0xE9u8, 0x00u8, 0x00u8, 0x00u8, 0x00u8]
    }

    /** `JZ rel32`（占位 0）。 */
    internal static func emitJz(): Array<UInt8> {
        [0x0Fu8, 0x84u8, 0x00u8, 0x00u8, 0x00u8, 0x00u8]
    }

    /** `JNZ rel32`（占位 0）。 */
    internal static func emitJnz(): Array<UInt8> {
        [0x0Fu8, 0x85u8, 0x00u8, 0x00u8, 0x00u8, 0x00u8]
    }

    /** `SET_SITE s`：`mov dword [r15+8], s`。 */
    internal static func emitSetSite(site: Int64): Array<UInt8> {
        let out = ArrayList<UInt8>()
        for (b in [0x41u8, 0xC7u8, 0x4Fu8, 0x08u8]) {
            out.add(b)
        }
        BackendX86_64.w32(out, BackendX86_64.i32bits(site))
        out.toArray()
    }

    /** `CHECK_ERR`：`cmp qword [r15],0; jne rel32`（rel 占位 0，P5.8 回填）。 */
    internal static func emitCheckErr(): Array<UInt8> {
        [0x49u8, 0x83u8, 0x3Fu8, 0x00u8, 0x0Fu8, 0x85u8, 0x00u8, 0x00u8, 0x00u8, 0x00u8]
    }

    /** `<bail:k>`：写槽 k → `xor eax,eax` → `jmp rel32`（rel 占位 0）。 */
    internal static func emitBail(k: Int64): Array<UInt8> {
        let out = ArrayList<UInt8>()
        for (b in [0x41u8, 0xC7u8, 0x07u8]) {
            out.add(b)
        }
        BackendX86_64.w32(out, BackendX86_64.i32bits(k))
        for (b in [0x31u8, 0xC0u8, 0xE9u8]) {
            out.add(b)
        }
        BackendX86_64.w32(out, 0u32)
        out.toArray()
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

    private static func appendCheckErr(out: ArrayList<UInt8>): Unit {
        for (x in [0x49u8, 0x83u8, 0x3Fu8, 0x00u8, 0x0Fu8, 0x85u8, 0x00u8, 0x00u8, 0x00u8,
            0x00u8]) {
            out.add(x)
        }
    }

    private static func w64(out: ArrayList<UInt8>, v: Int64): Unit {
        var k = 0
        while (k < 8) {
            out.add(UInt8((v >> (8 * k)) & 0xFF))
            k = k + 1
        }
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

    public func compile(unit: LoadedUnit, sink: CodeBuffer): Bool {
        false // S5.9 落地
    }

    public func entryThunkBase(): Int64 {
        0
    }

    public func entryThunkFor(fnId: UInt32): Int64 {
        0
    }
}
