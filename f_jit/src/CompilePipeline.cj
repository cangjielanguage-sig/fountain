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
package fountain::f_jit

import std.collection.ArrayList
import fountain::f_jit.base.DummyDiagnosticsSink
import fountain::f_jit.base.ErrCode
import fountain::f_jit.base.JitException
import fountain::f_jit.base.JitMode
import fountain::f_jit.base.LocalType
import fountain::f_jit.base.PublicCtor
import fountain::f_jit.base.SourceCompileException
import fountain::f_jit.base.TypeToken
import fountain::f_jit.base.Version
import fountain::f_jit.bytecode.OpInfo
import fountain::f_jit.bytecode.FbcReader
import fountain::f_jit.bytecode.Fingerprint
import fountain::f_jit.bytecode.LoadedUnit
import fountain::f_jit.bytecode.LocalTypes
import fountain::f_jit.compiler.HostClosureSigDecl
import fountain::f_jit.compiler.PredefinedSnapshot
import fountain::f_jit.compiler.SourceCompiler
import fountain::f_jit.compiler.ClassRegistrySnapshot
import fountain::f_jit.backend.JitExecutor
import fountain::f_jit.runtime.DbgDump
import fountain::f_jit.runtime.HandleTable
import fountain::f_jit.runtime.Interp
import fountain::f_jit.runtime.JitClosure
import fountain::f_jit.runtime.JitContext
import fountain::f_jit.runtime.UserHelperEntry

/**
 * S6.8 源码管线（§8）：`compile(source)` 四步——源码 → 字节码 → 执行器 → `JitFunction`。
 *
 * 进程级去重键 = 源码 FNV-1a-128；同源复用同一 `JitFunction`（`CompileCache`）。
 * 失败在 `compile` 时刻抛出（`SourceCompileException`），不进入运行期错误槽。
 */
protected class CompilePipeline {
    public static func runSource(source: String, c: Compiler): JitFunction {
        let major = c.opts.verMajor
        if (!Version.supportedMajors().contains(major)) {
            throw SourceCompileException('UnsupportedVersion', 0, 0, 0, '',
                '不受支持的 verMajor=${major}（支持：${CompilePipeline.majorsText()}）')
        }
        // 版本与严格浮点都是**产物属性**：同源不同配置必须各自成键，否则会互相命中缓存。
        let key = 'src/${CompilePipeline.modeKey(c.opts.jit)}/v${major}' +
            '/fp${CompilePipeline.bit(c.opts.strictFp)}/${Fingerprint.fnv1a128(source)}'
        match (CompileCache.lookup(key)) {
            case Some(f) => return f
            case None => ()
        }
        if (CompileCache.claim(key)) {
            try {
                let snap = c.snapshot()
                // 公开入口产出**本实现支持的最新版本**（M3）：LocalType 合法集 0–19。
                // 原为 M2（0–14），导致公开 `compile` 完全编不了 `Any` / JSON 字面量
                // （「局部槽类型码非法: 15」）——M3 的 Any 通道因此只在测试直连
                // `SourceCompiler` 时可用；A2 端到端验收把这一口径纠正到 M3。
                let cu = SourceCompiler(snap, DummyDiagnosticsSink(),
                    verMajor: major, strictFp: c.opts.strictFp,
                    classes: c.classSnapshot()).compile(source)
                let unit = FbcReader.load(cu.raw)
                let fn = CompilePipeline.makeFunctionWith(unit, cu.entryFn, c.opts,
                    Some(snap), cu.ctorHelpers, cu.entryParamClasses, cu.entryParamSigs,
                    c.classSnapshot())
                CompileCache.finish(key, fn)
                return fn
            } catch (e: Exception) {
                CompileCache.fail(key, e.message)
                throw e
            }
        }
        match (CompileCache.awaitReady(key)) {
            case Some(f) => f
            case None =>
                let msg = match (CompileCache.failureOf(key)) {
                    case Some(m) => m
                    case None => '编译失败'
                }
                throw SourceCompileException('CompileFailed', 0, 0, 0, '', msg)
        }
    }

    /** S6.9 字节码管线：`.fbc` → 校验 → 执行器；整份 raw 的 FNV-1a-128 去重。 */
    public static func runUnit(raw: Array<UInt8>, c: Compiler): JitFunction {
        let key = 'fbc/${CompilePipeline.modeKey(c.opts.jit)}/${Fingerprint.fnv1a128(raw)}'
        match (CompileCache.lookup(key)) {
            case Some(f) => return f
            case None => ()
        }
        if (CompileCache.claim(key)) {
            try {
                // 分发入口无注册表上下文：14 槽 / user helper 在加载期拒绝（design-m2 D12）。
                let unit = FbcReader.loadWithoutRegistry(raw)
                CompilePipeline.rejectUserHelpers(unit)
                let fn = CompilePipeline.makeFunction(unit, unit.header.entryFn, c.opts)
                CompileCache.finish(key, fn)
                return fn
            } catch (e: Exception) {
                CompileCache.fail(key, e.message)
                throw e
            }
        }
        match (CompileCache.awaitReady(key)) {
            case Some(f) => f
            case None =>
                let msg = match (CompileCache.failureOf(key)) {
                    case Some(m) => m
                    case None => '装载失败'
                }
                throw SourceCompileException('CompileFailed', 0, 0, 0, '', msg)
        }
    }

    /** 纯解释器形态：一次性登记常量句柄，后续每次调用复用。 */
    private static func pinConsts(unit: LoadedUnit): Array<Int64> {
        let probe = Interp(unit)
        var i = 0
        while (i < unit.consts.size) {
            let _ = probe.constHandle(i)
            i = i + 1
        }
        probe.pinnedConstIds()
    }

    private static func releaseConsts(ids: Array<Int64>): Unit {
        var i = 0
        while (i < ids.size) {
            if (ids[i] != 0) {
                HandleTable.releaseConst(ids[i])
            }
            i = i + 1
        }
    }

    /** 缓存键的引擎维度：`Off`/`Auto`/`Force` 产物不同，不能互相命中。 */
    /** 布尔 → 缓存键片段（`1` / `0`）。 */
    private static func bit(v: Bool): String {
        if (v) {
            '1'
        } else {
            '0'
        }
    }

    /** 支持的主版本清单（错误消息用）。 */
    private static func majorsText(): String {
        let ms = Version.supportedMajors()
        var out = ''
        var i = 0
        while (i < ms.size) {
            if (i > 0) {
                out = out + '/'
            }
            out = out + '${ms[i]}'
            i = i + 1
        }
        out
    }

    private static func modeKey(m: JitMode): String {
        match (m) {
            case JitMode.Off => 'off'
            case JitMode.Auto => 'auto'
            case JitMode.Force => 'force'
        }
    }

    /** 加载期拒绝 user helper（hid ≥ 0x0100，§8.4）→ 18。 */
    private static func rejectUserHelpers(unit: LoadedUnit): Unit {
        var off = 0
        while (off < unit.code.size) {
            let op = unit.code[off]
            let len = OpInfo.OPCODE_TABLE[Int64(op)].len
            if ((op == 0x75u8 || op == 0x76u8 || op == 0x77u8) && len >= 3 && off + 2 < unit.code.size) {
                let hid = UInt16(unit.code[off + 1]) | (UInt16(unit.code[off + 2]) << 8)
                if (hid >= 0x0100u16) {
                    throw JitException(ErrCode.NOT_IMPL, -1, 0, None,
                        '单元含 user helper（hid=0x${hid}），M1 加载期拒绝（§8.4）')
                }
            }
            off = off + len
        }
    }

    /** 字节码形态执行器（机器码装载由 S6.9/桥接管，接口不变）。 */
    private static func makeFunction(unit: LoadedUnit, entryFn: UInt32,
        opts: CompileOptions): JitFunction {
        CompilePipeline.makeFunctionWith(unit, entryFn, opts, None, Array<PublicCtor>(),
            Array<?String>(), Array<?HostClosureSigDecl>(), None)
    }

    private static func makeFunctionWith(unit: LoadedUnit, entryFn: UInt32,
        opts: CompileOptions, snap: ?PredefinedSnapshot,
        ctors: Array<PublicCtor>, paramClasses: Array<?String>,
        paramSigs: Array<?HostClosureSigDecl>,
        classSnap: ?ClassRegistrySnapshot): JitFunction {
        let idx = CompilePipeline.indexOf(unit, entryFn)
        let e = unit.dir.get(entryFn)
        let types = unit.types[idx]
        let params = Array<UInt16>(Int64(e.nargs), repeat: 0)
        var i = 0
        while (i < Int64(e.nargs)) {
            params[i] = UInt16(types.get(i))
            i = i + 1
        }
        // S6.9：Linux + 已支持指令集尝试 JIT；`Off` 或任何一步失败静默退回解释器（T7/T9）。
        let executor: ?JitExecutor = if (opts.jit == JitMode.Off) {
            None
        } else {
            JitExecutor.create(unit, entryFn)
        }
        // 常量句柄只登记一次：JIT 路径由执行器持有；纯解释器路径此处登记、卸载时归还。
        let constIds = match (executor) {
            case Some(ex) => ex.pinnedConstIds()
            case None => CompilePipeline.pinConsts(unit)
        }
        let body: (JitContext, Array<Int64>) -> Int64 = { ctx, cells =>
            match (executor) {
                case Some(ex) => ex.invoke(ctx, cells)
                case None => Interp(unit, constIds).run(entryFn, cells, ctx)
            }
        }
        // DEOPT(-1) 的透明重跑必须走解释器（§8.5）。
        let replay: (JitContext, Array<Int64>) -> Int64 = { ctx, cells =>
            Interp(unit, constIds).run(entryFn, cells, ctx)
        }
        let release: ?(() -> Unit) = match (executor) {
            case Some(ex) => Some({ => ex.release() })
            case None => Some({ => CompilePipeline.releaseConsts(constIds) })
        }
        let fn = JitFunction(Int64(e.nargs), e.retType, params, body, replay, '', release)
        fn.bindUserHelpers(CompilePipeline.userHelpers(snap, ctors))
        fn.bindEntryMeta(paramClasses, paramSigs, classSnap)
        fn.bindClosureRunner({ ctx, ch, args =>
            CompilePipeline.invokeClosure(unit, executor, constIds, ctx, ch, args)
        })
        match (executor) {
            case Some(_) => fn.markJitBacked()
            case None => ()
        }
        // T50：桥侧报告（源码行 + 变量清单），与差分层/解释器共用一份组装逻辑。
        fn.bindDiagnostics(CompilePipeline.maxNLocals(unit)) { ctx, dump =>
            CompilePipeline.reportOf(unit, entryFn, ctx, dump)
        }
        fn
    }

    /** 闭包包装调用：新桥调用 + 闭包帧 `locals[0]`（§14.3）。 */
    private static func invokeClosure(unit: LoadedUnit, executor: ?JitExecutor,
        constIds: Array<Int64>, ctx: JitContext, ch: Int64, args: Array<Int64>): Int64 {
        let closure = match (HandleTable.getAs(ch, TypeToken.CLOSURE)) {
            case Some(v) =>
                match (v) {
                    case c: JitClosure => c
                    case _ => throw JitException(ErrCode.CALL_CONTRACT, -1, 0, None,
                        '闭包槽载荷类型不符（§14.3）')
                }
            case None => throw JitException(ErrCode.CALL_CONTRACT, -1, 0, None,
                '闭包句柄无效（§14.3）')
        }
        let cells = Array<Int64>(args.size + 1, repeat: 0)
        cells[0] = ch
        var i = 0
        while (i < args.size) {
            cells[i + 1] = args[i]
            i = i + 1
        }
        let fid = UInt32(closure.fnId)
        match (executor) {
            case Some(ex) =>
                match (ex.invokeFn(ctx, fid, cells)) {
                    case Some(r) => r
                    case None => Interp(unit, constIds).run(fid, cells, ctx)
                }
            case None => Interp(unit, constIds).run(fid, cells, ctx)
        }
    }

    /** 构造本单元的 user helper 表：预定义函数（slot 序）+ 构造器（接在快照之后）。 */
    private static func userHelpers(snap: ?PredefinedSnapshot,
        ctors: Array<PublicCtor>): Array<UserHelperEntry> {
        let out = ArrayList<UserHelperEntry>()
        match (snap) {
            case Some(s) =>
                var i = 0
                while (i < s.size()) {
                    let impl: (Array<Any>) -> Any = match (s.implOf(i)) {
                        case Some(f) => f
                        case None => { _ => 0 }
                    }
                    out.add(UserHelperEntry(params: s.paramTypes[i], ret: s.retTypes[i], impl: impl))
                    i = i + 1
                }
            case None => ()
        }
        for (c in ctors) {
            out.add(UserHelperEntry(params: c.params, ret: LocalType.HOST_OBJECT, impl: c.adapter))
        }
        out.toArray()
    }

    /** 转储缓冲槽数上限（目录全域）。 */
    private static func maxNLocals(unit: LoadedUnit): Int64 {
        var m: Int64 = 0
        var i = 0
        while (i < unit.dir.size) {
            let n = Int64(unit.dir.at(i).nLocals)
            if (n > m) {
                m = n
            }
            i = i + 1
        }
        m
    }

    /** 失败报告（`errCode > 0`）；`fnId` 取转储首格编码（`fnId+1`），未转储则回落到入口。 */
    private static func reportOf(unit: LoadedUnit, entryFn: UInt32, ctx: JitContext,
        dump: CPointer<Int64>): String {
        let marker = unsafe { dump.read(0) }
        let fnId = if (marker != 0) { marker - 1 } else { Int64(entryFn) }
        DbgDump.report(ctx.errCode, ctx.site, fnId,
            CompilePipeline.typesOf(unit, fnId), unit.site, unit.name, dump)
    }

    private static func typesOf(unit: LoadedUnit, fnId: Int64): LocalTypes {
        var i = 0
        while (i < unit.dir.size) {
            if (Int64(unit.dir.at(i).fnId) == fnId) {
                return unit.types[i]
            }
            i = i + 1
        }
        unit.types[0]
    }

    private static func indexOf(unit: LoadedUnit, fnId: UInt32): Int64 {
        var i = 0
        while (i < unit.dir.size) {
            if (unit.dir.at(i).fnId == fnId) {
                return i
            }
            i = i + 1
        }
        0
    }
}
