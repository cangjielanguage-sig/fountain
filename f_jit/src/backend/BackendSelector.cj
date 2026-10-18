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

    /** 溢出检查版二元：`<op> rax,[rsp]; jo <bail:3>`（rel 占位）。 */
    private static func binOpChecked(opBytes: Array<UInt8>): Array<UInt8> {
        let out = ArrayList<UInt8>()
        for (b in [0x48u8, 0x8Bu8, 0x44u8, 0x24u8, 0x08u8]) {
            out.add(b) // mov rax,[rsp+8]
        }
        for (b in opBytes) {
            out.add(b)
        }
        for (b in [0x0Fu8, 0x80u8, 0x00u8, 0x00u8, 0x00u8, 0x00u8]) {
            out.add(b) // jo <bail:3>
        }
        for (b in [0x48u8, 0x89u8, 0x44u8, 0x24u8, 0x08u8]) {
            out.add(b)
        }
        for (b in [0x48u8, 0x83u8, 0xC4u8, 0x08u8]) {
            out.add(b)
        }
        out.toArray()
    }

    internal static func emitIAdd(): Array<UInt8> {
        BackendX86_64.binOpChecked([0x48u8, 0x03u8, 0x04u8, 0x24u8])
    }

    internal static func emitISub(): Array<UInt8> {
        BackendX86_64.binOpChecked([0x48u8, 0x2Bu8, 0x04u8, 0x24u8])
    }

    internal static func emitIMul(): Array<UInt8> {
        BackendX86_64.binOpChecked([0x48u8, 0x0Fu8, 0xAFu8, 0x04u8, 0x24u8])
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
        selfFnId: UInt32, argc: Int64): Array<UInt8> {
        let out = ArrayList<UInt8>()
        for (x in [0x4Cu8, 0x89u8, 0xFFu8, 0x48u8, 0x8Du8, 0x74u8, 0x24u8]) {
            out.add(x) // rdi=ctx; rsi=&args[0]
        }
        out.add(UInt8(8 * (argc - 1)))
        out.add(0xBAu8)
        BackendX86_64.w32(out, BackendX86_64.i32bits(argc))
        out.add(0x48u8)
        out.add(0xB8u8)
        BackendX86_64.w64(out, fnTableBase)
        for (x in [0xFFu8, 0x90u8]) {
            out.add(x) // call qword [rax+8*fid]
        }
        BackendX86_64.w32(out, BackendX86_64.i32bits(8 * Int64(fid)))
        BackendX86_64.appendCheckErr(out)
        for (x in [0x49u8, 0xC7u8, 0x47u8, 0x28u8]) {
            out.add(x) // mov qword [r15+40], self
        }
        BackendX86_64.w32(out, UInt32(Int64(selfFnId)))
        for (x in [0x48u8, 0x89u8, 0x84u8, 0x24u8]) {
            out.add(x) // 结果写回 args[0]
        }
        BackendX86_64.w32(out, BackendX86_64.i32bits(8 * (argc - 1)))
        for (x in [0x48u8, 0x83u8, 0xC4u8]) {
            out.add(x) // add rsp,8*(argc-1)
        }
        out.add(UInt8(8 * (argc - 1)))
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
        // H57(ctx) 零参
        for (x in [0x4Cu8, 0x89u8, 0xFFu8, 0x31u8, 0xF6u8, 0x31u8, 0xD2u8]) {
            out.add(x) // rdi=ctx; rsi=0; rdx=0
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

    internal static func emitRegexReplaceAll(h58: Int64): Array<UInt8> {
        BackendX86_64.emitCallHelper(h58, 3)
    }

    internal static func emitRegexReplaceNth(h59: Int64): Array<UInt8> {
        BackendX86_64.emitCallHelper(h59, 4)
    }

    internal static func emitRegexReplaceRange(h72: Int64): Array<UInt8> {
        BackendX86_64.emitCallHelper(h72, 6)
    }

    /** 零参 helper（`MAKE_LIST`/`MAKE_MAP`）：无实参，结果压栈。 */
    internal static func emitCallHelper0(helperAddr: Int64): Array<UInt8> {
        let out = ArrayList<UInt8>()
        for (x in [0x4Cu8, 0x89u8, 0xFFu8, 0x31u8, 0xF6u8, 0x31u8, 0xD2u8, 0x48u8, 0xB8u8]) {
            out.add(x) // rdi=ctx; rsi=rdx=0; movabs
        }
        BackendX86_64.w64(out, helperAddr)
        for (x in [0xFFu8, 0xD0u8, 0x50u8]) {
            out.add(x) // call rax; push rax
        }
        BackendX86_64.appendCheckErr(out)
        out.toArray()
    }

    /**
     * `CAST tok mode`（§12.4）：`DUP` 保留原值 → 压 tok → `call H17`（永失败不置错）。
     *
     * 命中：弹掉判定结果继续；未命中：mode0 → `<bail:7>`、mode1 → `<deopt>`
     * （rel32 占位，P5.8 回填）。值型恒等/静态相容 = 空操作（前端不发射本指令）。
     */
    internal static func emitCast(h17: Int64, tok: Int64, mode: Int64): Array<UInt8> {
        let out = ArrayList<UInt8>()
        for (x in [0xFFu8, 0x34u8, 0x24u8]) {
            out.add(x) // DUP
        }
        out.add(0x48u8)
        out.add(0xB8u8)
        BackendX86_64.w64(out, tok)
        out.add(0x50u8) // push tok
        for (x in [0x4Cu8, 0x89u8, 0xFFu8, 0x48u8, 0x8Du8, 0x74u8, 0x24u8, 0x08u8,
            0xBAu8, 0x02u8, 0x00u8, 0x00u8, 0x00u8, 0x48u8, 0xB8u8]) {
            out.add(x) // rdi=ctx; rsi=&value; edx=2; movabs h17
        }
        BackendX86_64.w64(out, h17)
        for (x in [0xFFu8, 0xD0u8, 0x48u8, 0x89u8, 0x84u8, 0x24u8,
            0x08u8, 0x00u8, 0x00u8, 0x00u8, 0x48u8, 0x83u8, 0xC4u8, 0x08u8,
            0x85u8, 0xC0u8, 0x0Fu8, 0x84u8, 0x00u8, 0x00u8, 0x00u8, 0x00u8,
            0x58u8, 0xE9u8, 0x00u8, 0x00u8, 0x00u8, 0x00u8,
            0x58u8, 0x49u8, 0xC7u8, 0x07u8]) {
            out.add(x) // call; 回写; 收 tok; test; jz; pop; jmp; .m: pop; mov qword [r15],k
        }
        BackendX86_64.w32(out, BackendX86_64.i32bits(if (mode == 0) { 7 } else { -1 }))
        for (x in [0x31u8, 0xC0u8, 0xE9u8, 0x00u8, 0x00u8, 0x00u8, 0x00u8]) {
            out.add(x)
        }
        out.toArray()
    }

    /** `STR_TO_REGEX`：H69 单参模板 A。 */
    internal static func emitStrToRegex(h69: Int64): Array<UInt8> {
        BackendX86_64.emitCallHelper(h69, 1)
    }

    /** Map 迭代 helper 路由。 */
    internal static func emitMapIterBegin(h49: Int64): Array<UInt8> {
        BackendX86_64.emitCallHelper(h49, 1)
    }

    internal static func emitMapIterStep(h62: Int64): Array<UInt8> {
        BackendX86_64.emitCallHelper(h62, 2)
    }

    /** 容器变更 helper 路由。 */
    internal static func emitMapPut(h44: Int64): Array<UInt8> {
        BackendX86_64.emitCallHelper(h44, 3)
    }

    internal static func emitListInsert(h45: Int64): Array<UInt8> {
        BackendX86_64.emitCallHelper(h45, 3)
    }

    internal static func emitListSet(h46: Int64): Array<UInt8> {
        BackendX86_64.emitCallHelper(h46, 3)
    }

    internal static func emitListRemove(h47: Int64): Array<UInt8> {
        BackendX86_64.emitCallHelper(h47, 2)
    }

    internal static func emitMapRemove(h48: Int64): Array<UInt8> {
        BackendX86_64.emitCallHelper(h48, 2)
    }

    /** 区间 helper 路由。 */
    internal static func emitRangeNew(h41: Int64): Array<UInt8> {
        BackendX86_64.emitCallHelper(h41, 4)
    }

    internal static func emitRangeContains(h42: Int64): Array<UInt8> {
        BackendX86_64.emitCallHelper(h42, 2)
    }

    /** Decimal helper 路由。 */
    internal static func emitDecAdd(h24: Int64): Array<UInt8> {
        BackendX86_64.emitCallHelper(h24, 2)
    }

    internal static func emitDecToI64(h30: Int64): Array<UInt8> {
        BackendX86_64.emitCallHelper(h30, 1)
    }

    /** 字符串 helper 路由。 */
    internal static func emitStrSub(h50: Int64): Array<UInt8> {
        BackendX86_64.emitCallHelper(h50, 3)
    }

    internal static func emitStrReplace(h51: Int64): Array<UInt8> {
        BackendX86_64.emitCallHelper(h51, 3)
    }

    internal static func emitStrRepeat(h60: Int64): Array<UInt8> {
        BackendX86_64.emitCallHelper(h60, 2)
    }

    /** 正则 helper 路由：双参模板 A。 */
    internal static func emitRegexIsMatch(h52: Int64): Array<UInt8> {
        BackendX86_64.emitCallHelper(h52, 2)
    }

    internal static func emitRegexFind(h53: Int64): Array<UInt8> {
        BackendX86_64.emitCallHelper(h53, 2)
    }

    /** 容器 helper 路由：均为双参模板 A。 */
    internal static func emitListGet(h02: Int64): Array<UInt8> {
        BackendX86_64.emitCallHelper(h02, 2)
    }

    internal static func emitListAdd(h43: Int64): Array<UInt8> {
        BackendX86_64.emitCallHelper(h43, 2)
    }

    internal static func emitMapGet(h04: Int64): Array<UInt8> {
        BackendX86_64.emitCallHelper(h04, 2)
    }

    /** `TO_STR`：H33 单参模板 A。 */
    internal static func emitToStr(h33: Int64): Array<UInt8> {
        BackendX86_64.emitCallHelper(h33, 1)
    }

    /** `ASSERT code`：弹 bool；false → 内联 BAIL(code)（rel 占位）。 */
    internal static func emitAssert(code: Int64): Array<UInt8> {
        let out = ArrayList<UInt8>()
        for (x in [0x48u8, 0x8Bu8, 0x04u8, 0x24u8, 0x48u8, 0x83u8, 0xC4u8, 0x08u8,
            0x48u8, 0x85u8, 0xC0u8, 0x0Fu8, 0x85u8, 0x00u8, 0x00u8, 0x00u8, 0x00u8]) {
            out.add(x) // pop; test; jnz ok（跳过 bail）
        }
        for (x in [0x49u8, 0xC7u8, 0x07u8]) {
            out.add(x)
        }
        BackendX86_64.w32(out, BackendX86_64.i32bits(code))
        for (x in [0x31u8, 0xC0u8, 0xE9u8, 0x00u8, 0x00u8, 0x00u8, 0x00u8]) {
            out.add(x)
        }
        out.toArray()
    }

    /** `STACK_GUARD need`：剩余栈 = (rbp-FRAME)-rsp；不足 → jb deopt（rel 占位）。 */
    internal static func emitStackGuard(frame: Int64, need: Int64): Array<UInt8> {
        let out = ArrayList<UInt8>()
        for (x in [0x48u8, 0x89u8, 0xE8u8, 0x48u8, 0x2Du8]) {
            out.add(x) // mov rax,rbp; sub rax,FRAME
        }
        BackendX86_64.w32(out, BackendX86_64.i32bits(frame))
        for (x in [0x48u8, 0x29u8, 0xE0u8, 0x48u8, 0x3Du8]) {
            out.add(x) // sub rax,rsp; cmp rax,need
        }
        BackendX86_64.w32(out, BackendX86_64.i32bits(need))
        for (x in [0x0Fu8, 0x82u8, 0x00u8, 0x00u8, 0x00u8, 0x00u8]) {
            out.add(x) // jb deopt（占位）
        }
        out.toArray()
    }

    /** `CHECK_ERR_NC`：发布版空操作（调试断言由构建开关另行发射）。 */
    internal static func emitCheckErrNc(): Array<UInt8> {
        Array<UInt8>()
    }

    /** `TRAP`：`int3`（调试面）。 */
    internal static func emitTrap(): Array<UInt8> {
        [0xCCu8]
    }

    /** `BREAKPOINT`：发布版空操作。 */
    internal static func emitBreakpoint(): Array<UInt8> {
        [0x90u8]
    }

    /** `ABORT`：写 errCode=99 → RETV=0 → jmp epilogue（rel 占位）。 */
    internal static func emitAbort(): Array<UInt8> {
        [0x49u8, 0xC7u8, 0x07u8, 0x63u8, 0x00u8, 0x00u8, 0x00u8,
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

    /**
     * 浮点比较（§12.4）：`cmpsd` 谓词——EQ=0、LT=1、LE=2、NE=4；
     * GT/GE 交换操作数后用 1/2。无序语义：NE=true，其余 false。
     */
    private static func fCmpOp(swapped: Bool, predicate: UInt8): Array<UInt8> {
        let out = ArrayList<UInt8>()
        if (swapped) {
            for (x in [0xF2u8, 0x0Fu8, 0x10u8, 0x04u8, 0x24u8,
                0xF2u8, 0x0Fu8, 0x10u8, 0x4Cu8, 0x24u8, 0x08u8]) {
                out.add(x) // xmm0=b, xmm1=a
            }
        } else {
            for (x in [0xF2u8, 0x0Fu8, 0x10u8, 0x44u8, 0x24u8, 0x08u8,
                0xF2u8, 0x0Fu8, 0x10u8, 0x0Cu8, 0x24u8]) {
                out.add(x) // xmm0=a, xmm1=b
            }
        }
        for (x in [0xF2u8, 0x0Fu8, 0xC2u8, 0xC1u8, predicate,
            0x66u8, 0x48u8, 0x0Fu8, 0x7Eu8, 0xC0u8,
            0x83u8, 0xE0u8, 0x01u8,
            0x48u8, 0x89u8, 0x44u8, 0x24u8, 0x08u8,
            0x48u8, 0x83u8, 0xC4u8, 0x08u8]) {
            out.add(x) // cmpsd; movq rax,xmm0; and eax,1; 写回; 收栈
        }
        out.toArray()
    }

    internal static func emitCmpEqF(): Array<UInt8> {
        BackendX86_64.fCmpOp(false, 0u8)
    }

    internal static func emitCmpNeF(): Array<UInt8> {
        BackendX86_64.fCmpOp(false, 4u8)
    }

    internal static func emitCmpLtF(): Array<UInt8> {
        BackendX86_64.fCmpOp(false, 1u8)
    }

    internal static func emitCmpLeF(): Array<UInt8> {
        BackendX86_64.fCmpOp(false, 2u8)
    }

    internal static func emitCmpGtF(): Array<UInt8> {
        BackendX86_64.fCmpOp(true, 1u8)
    }

    internal static func emitCmpGeF(): Array<UInt8> {
        BackendX86_64.fCmpOp(true, 2u8)
    }

    /** NaN 规范化尾：`ucomisd xmm0,xmm0; jnp .n; movabs rax,CANON; movq xmm0,rax`。 */
    private static func appendNanTail(out: ArrayList<UInt8>): Unit {
        for (x in [0x66u8, 0x0Fu8, 0x2Eu8, 0xC0u8, 0x0Fu8, 0x8Bu8, 0x00u8, 0x00u8, 0x00u8,
            0x00u8, 0x48u8, 0xB8u8, 0x00u8, 0x00u8, 0x00u8, 0x00u8, 0x00u8, 0x00u8, 0xF8u8,
            0x7Fu8, 0x66u8, 0x48u8, 0x0Fu8, 0x6Eu8, 0xC0u8]) {
            out.add(x)
        }
    }

    private static func fBinOp(commutative: Bool, opByte: UInt8): Array<UInt8> {
        let out = ArrayList<UInt8>()
        if (commutative) {
            for (x in [0xF2u8, 0x0Fu8, 0x10u8, 0x04u8, 0x24u8]) {
                out.add(x) // movsd xmm0,[rsp]
            }
        } else {
            for (x in [0xF2u8, 0x0Fu8, 0x10u8, 0x44u8, 0x24u8, 0x08u8]) {
                out.add(x) // movsd xmm0,[rsp+8]
            }
        }
        out.add(0xF2u8)
        out.add(0x0Fu8)
        out.add(opByte)
        if (commutative) {
            for (x in [0x44u8, 0x24u8, 0x08u8]) {
                out.add(x) // op xmm0,[rsp+8]
            }
        } else {
            for (x in [0x04u8, 0x24u8]) {
                out.add(x) // op xmm0,[rsp]
            }
        }
        BackendX86_64.appendNanTail(out)
        for (x in [0xF2u8, 0x0Fu8, 0x11u8, 0x44u8, 0x24u8, 0x08u8,
            0x48u8, 0x83u8, 0xC4u8, 0x08u8]) {
            out.add(x) // 写回; 收栈
        }
        out.toArray()
    }

    internal static func emitFAdd(): Array<UInt8> {
        BackendX86_64.fBinOp(true, 0x58u8)
    }

    internal static func emitFSub(): Array<UInt8> {
        BackendX86_64.fBinOp(false, 0x5Cu8)
    }

    internal static func emitFMul(): Array<UInt8> {
        BackendX86_64.fBinOp(true, 0x59u8)
    }

    internal static func emitFDiv(): Array<UInt8> {
        BackendX86_64.fBinOp(false, 0x5Eu8)
    }

    /** `FDIV_CHK`：前置 `ucomisd 除数,0`（NaN 继续、等于 0 → `<bail:1>`），后接 FDIV。 */
    internal static func emitFDivChk(): Array<UInt8> {
        let out = ArrayList<UInt8>()
        for (x in [0x66u8, 0x0Fu8, 0x57u8, 0xC9u8, 0x66u8, 0x0Fu8, 0x2Eu8, 0x0Cu8, 0x24u8,
            0x0Fu8, 0x8Au8, 0x00u8, 0x00u8, 0x00u8, 0x00u8,
            0x0Fu8, 0x84u8, 0x00u8, 0x00u8, 0x00u8, 0x00u8]) {
            out.add(x) // xorpd xmm1,xmm1; ucomisd xmm1,[rsp]; jp .go; je <bail:1>
        }
        for (x in BackendX86_64.emitFDiv()) {
            out.add(x)
        }
        out.toArray()
    }

    /** 符号域单目：`movq xmm1,mask; xorpd/andpd xmm0,xmm1; <NaN 尾>; 写回`。 */
    private static func fSignOp(mask: Int64, opBytes: Array<UInt8>): Array<UInt8> {
        let out = ArrayList<UInt8>()
        out.add(0x48u8)
        out.add(0xB8u8)
        BackendX86_64.w64(out, mask)
        for (x in [0x66u8, 0x48u8, 0x0Fu8, 0x6Eu8, 0xC8u8]) {
            out.add(x) // movq xmm1,rax
        }
        for (x in opBytes) {
            out.add(x)
        }
        BackendX86_64.appendNanTail(out)
        for (x in [0xF2u8, 0x0Fu8, 0x11u8, 0x04u8, 0x24u8]) {
            out.add(x)
        }
        out.toArray()
    }

    internal static func emitFNeg(): Array<UInt8> {
        BackendX86_64.fSignOp(-9223372036854775807 - 1, [0x66u8, 0x0Fu8, 0x57u8, 0xC1u8])
    }

    internal static func emitFAbs(): Array<UInt8> {
        BackendX86_64.fSignOp(9223372036854775807, [0x66u8, 0x0Fu8, 0x54u8, 0xC1u8])
    }

    /** `FSQRT`：`sqrtsd xmm0,[rsp]; <NaN 尾>; 写回`。 */
    internal static func emitFSqrt(): Array<UInt8> {
        let out = ArrayList<UInt8>()
        for (x in [0xF2u8, 0x0Fu8, 0x51u8, 0x04u8, 0x24u8]) {
            out.add(x)
        }
        BackendX86_64.appendNanTail(out)
        for (x in [0xF2u8, 0x0Fu8, 0x11u8, 0x04u8, 0x24u8]) {
            out.add(x)
        }
        out.toArray()
    }

    /**
     * `FMIN`/`FMAX`：任一操作数 NaN → 直接产 CANON；否则 `minsd/maxsd`。
     */
    private static func fMinMax(opByte: UInt8): Array<UInt8> {
        let out = ArrayList<UInt8>()
        for (x in [0xF2u8, 0x0Fu8, 0x10u8, 0x44u8, 0x24u8, 0x08u8,
            0xF2u8, 0x0Fu8, 0x10u8, 0x0Cu8, 0x24u8,
            0x66u8, 0x0Fu8, 0x2Eu8, 0xC0u8,
            0x0Fu8, 0x8Au8, 0x00u8, 0x00u8, 0x00u8, 0x00u8,
            0x66u8, 0x0Fu8, 0x2Eu8, 0xC9u8,
            0x0Fu8, 0x8Au8, 0x00u8, 0x00u8, 0x00u8, 0x00u8]) {
            out.add(x) // 双 NaN 自检，jp .canon
        }
        out.add(0xF2u8)
        out.add(0x0Fu8)
        out.add(opByte)
        out.add(0xC1u8) // min/max xmm0,xmm1
        for (x in [0xE9u8, 0x00u8, 0x00u8, 0x00u8, 0x00u8]) {
            out.add(x) // jmp .done
        }
        for (x in [0x48u8, 0xB8u8]) {
            out.add(x) // .canon
        }
        BackendX86_64.w64(out, Int64(0x7FF8000000000000))
        for (x in [0x66u8, 0x48u8, 0x0Fu8, 0x6Eu8, 0xC0u8,
            0xF2u8, 0x0Fu8, 0x11u8, 0x44u8, 0x24u8, 0x08u8,
            0x48u8, 0x83u8, 0xC4u8, 0x08u8]) {
            out.add(x) // movq xmm0,rax; .done: 写回; 收栈
        }
        out.toArray()
    }

    /**
     * 取整族基线序列（§12.4）：NaN → CANON；|x|≥2^63 直通；否则
     * `cvttsd2si` + `cvtsi2sd`，floor/ceil 再按比较修正 ±1。
     */
    private static func fRoundOp(kind: Int64): Array<UInt8> {
        let out = ArrayList<UInt8>()
        for (x in [0x66u8, 0x0Fu8, 0x2Eu8, 0xC0u8,
            0x0Fu8, 0x8Au8, 0x00u8, 0x00u8, 0x00u8, 0x00u8]) {
            out.add(x) // ucomisd 自检；jp .canon
        }
        out.add(0x48u8)
        out.add(0xB8u8)
        BackendX86_64.w64(out, 0x43E0000000000000) // +2^63
        for (x in [0x66u8, 0x48u8, 0x0Fu8, 0x6Eu8, 0xC8u8,
            0x66u8, 0x0Fu8, 0x2Eu8, 0xC1u8,
            0x0Fu8, 0x83u8, 0x00u8, 0x00u8, 0x00u8, 0x00u8]) {
            out.add(x) // movq; ucomisd; jae .pass
        }
        out.add(0x48u8)
        out.add(0xB8u8)
        BackendX86_64.w64(out, -4332462841530417152) // -2^63 的 double 位型 0xC3E0...
        for (x in [0x66u8, 0x48u8, 0x0Fu8, 0x6Eu8, 0xC8u8,
            0x66u8, 0x0Fu8, 0x2Eu8, 0xC1u8,
            0x0Fu8, 0x82u8, 0x00u8, 0x00u8, 0x00u8, 0x00u8]) {
            out.add(x) // movq; ucomisd; jb .pass
        }
        for (x in [0xF2u8, 0x48u8, 0x0Fu8, 0x2Cu8, 0xC0u8,
            0xF2u8, 0x48u8, 0x0Fu8, 0x2Au8, 0xC8u8]) {
            out.add(x) // cvttsd2si rax,xmm0; cvtsi2sd xmm1,rax
        }
        if (kind == 1 || kind == 2) {
            for (x in [0x66u8, 0x0Fu8, 0x2Eu8, 0xC1u8]) {
                out.add(x) // ucomisd xmm1,xmm0
            }
            if (kind == 1) {
                for (x in [0x0Fu8, 0x86u8, 0x00u8, 0x00u8, 0x00u8, 0x00u8]) {
                    out.add(x) // jbe .store（floor：t <= x 无需修正）
                }
            } else {
                for (x in [0x0Fu8, 0x83u8, 0x00u8, 0x00u8, 0x00u8, 0x00u8]) {
                    out.add(x) // jae .store（ceil：t >= x 无需修正）
                }
            }
            out.add(0x48u8)
            out.add(0xB8u8)
            BackendX86_64.w64(out, 0x3FF0000000000000) // 1.0
            for (x in [0x66u8, 0x48u8, 0x0Fu8, 0x6Eu8, 0xD0u8]) {
                out.add(x) // movq xmm2,rax
            }
            if (kind == 1) {
                for (x in [0xF2u8, 0x0Fu8, 0x5Cu8, 0xCAu8]) {
                    out.add(x) // subsd xmm1,xmm2
                }
            } else {
                for (x in [0xF2u8, 0x0Fu8, 0x58u8, 0xCAu8]) {
                    out.add(x) // addsd xmm1,xmm2
                }
            }
        } else if (kind == 3) {
            // FROUND：round-half-even
            for (x in [0xF2u8, 0x0Fu8, 0x10u8, 0xD0u8, 0xF2u8, 0x0Fu8, 0x5Cu8, 0xD1u8]) {
                out.add(x) // xmm2 = x - t
            }
            out.add(0x48u8)
            out.add(0xB9u8)
            BackendX86_64.w64(out, 0x3FE0000000000000) // +0.5
            for (x in [0x66u8, 0x48u8, 0x0Fu8, 0x6Eu8, 0xD9u8,
                0x66u8, 0x0Fu8, 0x2Eu8, 0xD3u8,
                0x0Fu8, 0x87u8, 0x00u8, 0x00u8, 0x00u8, 0x00u8]) {
                out.add(x) // movq xmm3,rcx; ucomisd; ja .plus
            }
            out.add(0x48u8)
            out.add(0xB9u8)
            BackendX86_64.w64(out, -4620693217682128896) // -0.5
            for (x in [0x66u8, 0x48u8, 0x0Fu8, 0x6Eu8, 0xD9u8,
                0x66u8, 0x0Fu8, 0x2Eu8, 0xD3u8,
                0x0Fu8, 0x82u8, 0x00u8, 0x00u8, 0x00u8, 0x00u8]) {
                out.add(x) // movq xmm3,rcx; ucomisd; jb .minus
            }
            for (x in [0x48u8, 0xA9u8, 0x01u8, 0x00u8, 0x00u8, 0x00u8,
                0x0Fu8, 0x84u8, 0x00u8, 0x00u8, 0x00u8, 0x00u8]) {
                out.add(x) // test rax,1; jz .store（偶数保持）
            }
            for (x in [0x66u8, 0x0Fu8, 0x57u8, 0xDBu8, 0x66u8, 0x0Fu8, 0x2Eu8, 0xD3u8,
                0x0Fu8, 0x87u8, 0x00u8, 0x00u8, 0x00u8, 0x00u8,
                0xE9u8, 0x00u8, 0x00u8, 0x00u8, 0x00u8]) {
                out.add(x) // xorpd xmm3; ucomisd; ja .plus; jmp .minus
            }
            // .plus
            out.add(0x48u8)
            out.add(0xB8u8)
            BackendX86_64.w64(out, 0x3FF0000000000000)
            for (x in [0x66u8, 0x48u8, 0x0Fu8, 0x6Eu8, 0xD8u8,
                0xF2u8, 0x0Fu8, 0x58u8, 0xCBu8,
                0xE9u8, 0x00u8, 0x00u8, 0x00u8, 0x00u8]) {
                out.add(x) // movq xmm3,rax; addsd xmm1,xmm3; jmp .store
            }
            // .minus
            out.add(0x48u8)
            out.add(0xB8u8)
            BackendX86_64.w64(out, 0x3FF0000000000000)
            for (x in [0x66u8, 0x48u8, 0x0Fu8, 0x6Eu8, 0xD8u8,
                0xF2u8, 0x0Fu8, 0x5Cu8, 0xCBu8]) {
                out.add(x) // movq xmm3,rax; subsd xmm1,xmm3
            }
        }
        for (x in [0xF2u8, 0x0Fu8, 0x11u8, 0x0Cu8, 0x24u8,
            0xE9u8, 0x00u8, 0x00u8, 0x00u8, 0x00u8]) {
            out.add(x) // .store: 写回; jmp .done
        }
        for (x in [0xF2u8, 0x0Fu8, 0x11u8, 0x04u8, 0x24u8,
            0xE9u8, 0x00u8, 0x00u8, 0x00u8, 0x00u8]) {
            out.add(x) // .pass: 写回原值; jmp .done
        }
        out.add(0x48u8)
        out.add(0xB8u8)
        BackendX86_64.w64(out, 0x7FF8000000000000)
        for (x in [0x66u8, 0x48u8, 0x0Fu8, 0x6Eu8, 0xC0u8,
            0xF2u8, 0x0Fu8, 0x11u8, 0x04u8, 0x24u8]) {
            out.add(x) // .canon: CANON → 写回
        }
        out.toArray()
    }

    internal static func emitFTrunc(): Array<UInt8> {
        BackendX86_64.fRoundOp(0)
    }

    internal static func emitFFloor(): Array<UInt8> {
        BackendX86_64.fRoundOp(1)
    }

    internal static func emitFCeil(): Array<UInt8> {
        BackendX86_64.fRoundOp(2)
    }

    internal static func emitFRound(): Array<UInt8> {
        BackendX86_64.fRoundOp(3)
    }

    internal static func emitFMin(): Array<UInt8> {
        BackendX86_64.fMinMax(0x5Du8)
    }

    internal static func emitFMax(): Array<UInt8> {
        BackendX86_64.fMinMax(0x5Fu8)
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
        BackendX86_64.binOp([0x48u8, 0x03u8, 0x04u8, 0x24u8])
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
        let out = ArrayList<UInt8>()
        for (x in [0x48u8, 0x8Bu8, 0x04u8, 0x24u8, 0x48u8, 0xF7u8, 0xD8u8,
            0x0Fu8, 0x80u8, 0x00u8, 0x00u8, 0x00u8, 0x00u8,
            0x48u8, 0x89u8, 0x04u8, 0x24u8]) {
            out.add(x) // mov rax,[rsp]; neg; jo bail3; 写回
        }
        out.toArray()
    }

    /** `IABS`：`pop rax; test; jns .ok; neg; jo bail3; .ok: push rax`。 */
    internal static func emitIAbs(): Array<UInt8> {
        [0x58u8, 0x48u8, 0x85u8, 0xC0u8,
         0x0Fu8, 0x89u8, 0x00u8, 0x00u8, 0x00u8, 0x00u8,
         0x48u8, 0xF7u8, 0xD8u8,
         0x0Fu8, 0x80u8, 0x00u8, 0x00u8, 0x00u8, 0x00u8,
         0x50u8]
    }

    /** `IMIN`/`IMAX`：`cmovl`（max）/`cmovge`（min）。 */
    private static func iminMax(cmov: Array<UInt8>): Array<UInt8> {
        let out = ArrayList<UInt8>()
        for (x in [0x48u8, 0x8Bu8, 0x0Cu8, 0x24u8, 0x48u8, 0x8Bu8, 0x44u8, 0x24u8, 0x08u8,
            0x48u8, 0x83u8, 0xC4u8, 0x08u8, 0x48u8, 0x3Bu8, 0xC1u8]) {
            out.add(x)
        }
        for (x in cmov) {
            out.add(x)
        }
        for (x in [0x48u8, 0x89u8, 0x04u8, 0x24u8]) {
            out.add(x)
        }
        out.toArray()
    }

    internal static func emitIMin(): Array<UInt8> {
        BackendX86_64.iminMax([0x48u8, 0x0Fu8, 0x4Du8, 0xC1u8])
    }

    internal static func emitIMax(): Array<UInt8> {
        BackendX86_64.iminMax([0x48u8, 0x0Fu8, 0x4Cu8, 0xC1u8])
    }

    /** `ICLZ`：`bsr` + `xor 63`（0 → 64 走分支）。 */
    internal static func emitIClz(): Array<UInt8> {
        [0x48u8, 0x8Bu8, 0x0Cu8, 0x24u8,
         0x48u8, 0xC7u8, 0xC0u8, 0x40u8, 0x00u8, 0x00u8, 0x00u8,
         0x48u8, 0x85u8, 0xC9u8,
         0x0Fu8, 0x84u8, 0x00u8, 0x00u8, 0x00u8, 0x00u8,
         0x48u8, 0x0Fu8, 0xBDu8, 0xC1u8,
         0x48u8, 0x35u8, 0x3Fu8, 0x00u8, 0x00u8, 0x00u8,
         0x48u8, 0x89u8, 0x04u8, 0x24u8]
    }

    /** `IPOPCNT`：SWAR（SSE2 基线，不依赖 POPCNT 指令）。 */
    internal static func emitIPopcnt(): Array<UInt8> {
        let out = ArrayList<UInt8>()
        for (x in [0x48u8, 0x8Bu8, 0x04u8, 0x24u8, 0x48u8, 0x89u8, 0xC1u8,
            0x48u8, 0xD1u8, 0xE9u8, 0x48u8, 0xBAu8]) {
            out.add(x) // mov rax,[rsp]; mov rcx,rax; shr rcx,1; movabs m1
        }
        BackendX86_64.w64(out, 0x5555555555555555)
        for (x in [0x48u8, 0x21u8, 0xD1u8, 0x48u8, 0x29u8, 0xC8u8,
            0x48u8, 0x89u8, 0xC1u8, 0x48u8, 0xBAu8]) {
            out.add(x) // and rcx,rdx; sub rax,rcx; mov rcx,rax; movabs m2
        }
        BackendX86_64.w64(out, 0x3333333333333333)
        for (x in [0x48u8, 0x21u8, 0xD0u8, 0x48u8, 0x21u8, 0xD1u8,
            0x48u8, 0xC1u8, 0xE9u8, 0x02u8, 0x48u8, 0x01u8, 0xC8u8,
            0x48u8, 0x89u8, 0xC1u8, 0x48u8, 0xC1u8, 0xE9u8, 0x04u8,
            0x48u8, 0x01u8, 0xC8u8, 0x48u8, 0xBAu8]) {
            out.add(x) // 标准 SWAR 折叠
        }
        BackendX86_64.w64(out, 0x0F0F0F0F0F0F0F0F)
        for (x in [0x48u8, 0x21u8, 0xD0u8, 0x48u8, 0xBAu8]) {
            out.add(x)
        }
        BackendX86_64.w64(out, 0x0101010101010101)
        for (x in [0x48u8, 0x0Fu8, 0xAFu8, 0xC2u8, 0x48u8, 0xC1u8, 0xE8u8, 0x38u8,
            0x48u8, 0x89u8, 0x04u8, 0x24u8]) {
            out.add(x)
        }
        out.toArray()
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

    /**
     * `IDIV`（§12.4）：÷0 → `<bail:1>`；`INT64_MIN/-1` → `<bail:3>`；`cqo; idiv` 商写回。
     */
    internal static func emitIDiv(): Array<UInt8> {
        let out = ArrayList<UInt8>()
        for (x in [0x48u8, 0x8Bu8, 0x44u8, 0x24u8, 0x08u8, 0x48u8, 0x8Bu8, 0x0Cu8, 0x24u8,
            0x48u8, 0x85u8, 0xC9u8]) {
            out.add(x) // a→rax, b→rcx, test
        }
        for (x in [0x0Fu8, 0x84u8, 0x00u8, 0x00u8, 0x00u8, 0x00u8]) {
            out.add(x) // jz <bail:1>
        }
        for (x in [0x48u8, 0x83u8, 0xF9u8, 0xFFu8, 0x0Fu8, 0x85u8, 0x00u8, 0x00u8, 0x00u8,
            0x00u8]) {
            out.add(x) // cmp rcx,-1; jne .ok
        }
        for (x in [0x48u8, 0xBAu8, 0x00u8, 0x00u8, 0x00u8, 0x00u8, 0x00u8, 0x00u8, 0x00u8,
            0x80u8, 0x48u8, 0x39u8, 0xD0u8, 0x0Fu8, 0x84u8, 0x00u8, 0x00u8, 0x00u8, 0x00u8]) {
            out.add(x) // mov rdx,INT64_MIN; cmp; je <bail:3>
        }
        for (x in [0x48u8, 0x99u8, 0x48u8, 0xF7u8, 0xF9u8,
            0x48u8, 0x89u8, 0x44u8, 0x24u8, 0x08u8, 0x48u8, 0x83u8, 0xC4u8, 0x08u8]) {
            out.add(x) // cqo; idiv rcx; 商写回; 收栈
        }
        out.toArray()
    }

    /**
     * `IMOD`（§12.4）：÷0 → `<bail:2>`；除数为 -1 → 余数恒 0（不报溢出）。
     */
    internal static func emitIMod(): Array<UInt8> {
        let out = ArrayList<UInt8>()
        for (x in [0x48u8, 0x8Bu8, 0x44u8, 0x24u8, 0x08u8, 0x48u8, 0x8Bu8, 0x0Cu8, 0x24u8,
            0x48u8, 0x85u8, 0xC9u8]) {
            out.add(x)
        }
        for (x in [0x0Fu8, 0x84u8, 0x00u8, 0x00u8, 0x00u8, 0x00u8]) {
            out.add(x) // jz <bail:2>
        }
        for (x in [0x48u8, 0x83u8, 0xF9u8, 0xFFu8, 0x0Fu8, 0x84u8, 0x00u8, 0x00u8, 0x00u8,
            0x00u8]) {
            out.add(x) // cmp rcx,-1; je .zero
        }
        for (x in [0x48u8, 0x99u8, 0x48u8, 0xF7u8, 0xF9u8,
            0x48u8, 0x89u8, 0x54u8, 0x24u8, 0x08u8, 0x48u8, 0x83u8, 0xC4u8, 0x08u8,
            0xE9u8, 0x00u8, 0x00u8, 0x00u8, 0x00u8]) {
            out.add(x) // cqo; idiv; 余数写回; 收栈; jmp .done
        }
        for (x in [0x31u8, 0xD2u8,
            0x48u8, 0x89u8, 0x54u8, 0x24u8, 0x08u8,
            0x48u8, 0x83u8, 0xC4u8, 0x08u8]) {
            out.add(x) // .zero: xor edx,edx; 写回; 收栈
        }
        out.toArray()
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

    /** `NOT_B`：`xor qword [rsp],1`。 */
    internal static func emitNotB(): Array<UInt8> {
        [0x48u8, 0x83u8, 0x34u8, 0x24u8, 0x01u8]
    }

    internal static func emitAndB(): Array<UInt8> {
        BackendX86_64.binOp([0x48u8, 0x23u8, 0x04u8, 0x24u8])
    }

    internal static func emitOrB(): Array<UInt8> {
        BackendX86_64.binOp([0x48u8, 0x0Bu8, 0x04u8, 0x24u8])
    }

    internal static func emitXorB(): Array<UInt8> {
        BackendX86_64.binOp([0x48u8, 0x33u8, 0x04u8, 0x24u8])
    }

    /** `CMP_I`：三向比较，结果 -1/0/1。 */
    internal static func emitCmpI(): Array<UInt8> {
        [0x48u8, 0x8Bu8, 0x44u8, 0x24u8, 0x08u8,
         0x48u8, 0x8Bu8, 0x0Cu8, 0x24u8,
         0x48u8, 0x83u8, 0xC4u8, 0x08u8,
         0x48u8, 0x3Bu8, 0xC1u8,
         0x0Fu8, 0x9Fu8, 0xC2u8,
         0x0Fu8, 0x9Cu8, 0xC0u8,
         0x0Fu8, 0xB6u8, 0xC0u8,
         0x0Fu8, 0xB6u8, 0xD2u8,
         0x29u8, 0xD0u8,
         0x48u8, 0x98u8,
         0x48u8, 0x89u8, 0x04u8, 0x24u8]
    }

    /** `EQ_H`/`NE_H`：句柄即整数，复用整数比较。 */
    internal static func emitEqH(): Array<UInt8> {
        BackendX86_64.emitCmpEq()
    }

    internal static func emitNeH(): Array<UInt8> {
        BackendX86_64.emitCmpNe()
    }

    /** `CMP_STR`/`CMP_DEC`/`CMP_DT`/`CMP_DUR`：双参 helper 路由。 */
    internal static func emitCmpStr(h09: Int64): Array<UInt8> {
        BackendX86_64.emitCallHelper(h09, 2)
    }

    internal static func emitCmpDec(h11: Int64): Array<UInt8> {
        BackendX86_64.emitCallHelper(h11, 2)
    }

    internal static func emitCmpDt(h13: Int64): Array<UInt8> {
        BackendX86_64.emitCallHelper(h13, 2)
    }

    internal static func emitCmpDur(h15: Int64): Array<UInt8> {
        BackendX86_64.emitCallHelper(h15, 2)
    }

    /** `CALL_HELPER_NC`：模板 A 去掉尾随 `CHECK_ERR`。 */
    internal static func emitCallHelperNC(helperAddr: Int64, argc: Int64): Array<UInt8> {
        let full = BackendX86_64.emitCallHelper(helperAddr, argc)
        full[0..(full.size - 10)]
    }

    /** `CALL_HELPER_V`：结果不压栈；收全部实参；保留 `CHECK_ERR`。 */
    internal static func emitCallHelperV(helperAddr: Int64, argc: Int64): Array<UInt8> {
        let out = ArrayList<UInt8>()
        for (x in [0x4Cu8, 0x89u8, 0xFFu8, 0x48u8, 0x8Du8, 0x74u8, 0x24u8]) {
            out.add(x)
        }
        out.add(UInt8(8 * (argc - 1)))
        out.add(0xBAu8)
        BackendX86_64.w32(out, BackendX86_64.i32bits(argc))
        out.add(0x48u8)
        out.add(0xB8u8)
        BackendX86_64.w64(out, helperAddr)
        for (x in [0xFFu8, 0xD0u8, 0x48u8, 0x83u8, 0xC4u8]) {
            out.add(x) // call rax; add rsp,8*argc
        }
        out.add(UInt8(8 * argc))
        BackendX86_64.appendCheckErr(out)
        out.toArray()
    }

    /** 零参 `CALL_HELPER_V`（`LOOP_BACK` 的 H22）。 */
    internal static func emitCallHelper0V(helperAddr: Int64): Array<UInt8> {
        let out = ArrayList<UInt8>()
        for (x in [0x4Cu8, 0x89u8, 0xFFu8, 0x31u8, 0xF6u8, 0x31u8, 0xD2u8, 0x48u8, 0xB8u8]) {
            out.add(x)
        }
        BackendX86_64.w64(out, helperAddr)
        for (x in [0xFFu8, 0xD0u8]) {
            out.add(x)
        }
        BackendX86_64.appendCheckErr(out)
        out.toArray()
    }

    /** `LOOP_BACK`：`STACK_GUARD need` + `call H22` + `jmp target`（rel 占位）。 */
    internal static func emitLoopBack(h22: Int64, frame: Int64, need: Int64): Array<UInt8> {
        let out = ArrayList<UInt8>()
        for (x in BackendX86_64.emitStackGuard(frame, need)) {
            out.add(x)
        }
        for (x in BackendX86_64.emitCallHelper0V(h22)) {
            out.add(x)
        }
        for (x in [0xE9u8, 0x00u8, 0x00u8, 0x00u8, 0x00u8]) {
            out.add(x)
        }
        out.toArray()
    }

    /** `RET`：`mov rax,[rsp]; jmp .epilogue`。 */
    internal static func emitRet(): Array<UInt8> {
        [0x48u8, 0x8Bu8, 0x04u8, 0x24u8, 0xE9u8, 0x00u8, 0x00u8, 0x00u8, 0x00u8]
    }

    /** `RET_VOID`/`RET_NULL`：`xor eax,eax; jmp .epilogue`。 */
    internal static func emitRetVoid(): Array<UInt8> {
        [0x31u8, 0xC0u8, 0xE9u8, 0x00u8, 0x00u8, 0x00u8, 0x00u8]
    }

    /** `GUARD_TYPE mode`：mode0 → H19 + `CHECK_ERR`；mode1 → H17 + `<deopt>`。 */
    internal static func emitGuardType(h17: Int64, h19: Int64, tok: Int64,
        mode: Int64): Array<UInt8> {
        if (mode == 0) {
            let out = ArrayList<UInt8>()
            out.add(0x48u8)
            out.add(0xB8u8)
            BackendX86_64.w64(out, tok)
            out.add(0x50u8)
            for (x in BackendX86_64.emitCallHelper(h19, 2)) {
                out.add(x)
            }
            return out.toArray()
        }
        let out = ArrayList<UInt8>()
        for (x in [0xFFu8, 0x34u8, 0x24u8]) {
            out.add(x) // DUP
        }
        out.add(0x48u8)
        out.add(0xB8u8)
        BackendX86_64.w64(out, tok)
        out.add(0x50u8)
        for (x in [0x4Cu8, 0x89u8, 0xFFu8, 0x48u8, 0x8Du8, 0x74u8, 0x24u8, 0x08u8,
            0xBAu8, 0x02u8, 0x00u8, 0x00u8, 0x00u8, 0x48u8, 0xB8u8]) {
            out.add(x)
        }
        BackendX86_64.w64(out, h17)
        for (x in [0xFFu8, 0xD0u8, 0x48u8, 0x89u8, 0x84u8, 0x24u8,
            0x08u8, 0x00u8, 0x00u8, 0x00u8, 0x48u8, 0x83u8, 0xC4u8, 0x08u8,
            0x85u8, 0xC0u8, 0x0Fu8, 0x84u8, 0x00u8, 0x00u8, 0x00u8, 0x00u8,
            0x58u8, 0xE9u8, 0x00u8, 0x00u8, 0x00u8, 0x00u8,
            0x58u8, 0x49u8, 0xC7u8, 0x07u8, 0xFFu8, 0xFFu8, 0xFFu8, 0xFFu8,
            0x31u8, 0xC0u8, 0xE9u8, 0x00u8, 0x00u8, 0x00u8, 0x00u8]) {
            out.add(x)
        }
        out.toArray()
    }

    /** `TYPE_OF`：H18 单参 + `CHECK_ERR`。 */
    internal static func emitTypeOf(h18: Int64): Array<UInt8> {
        BackendX86_64.emitCallHelper(h18, 1)
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

    /** `<bail:k>`：写 qword 槽 k → `xor eax,eax` → `jmp rel32`（rel 占位 0）。 */
    internal static func emitBail(k: Int64): Array<UInt8> {
        let out = ArrayList<UInt8>()
        for (b in [0x49u8, 0xC7u8, 0x07u8]) {
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
