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
import std.reflect.ClassTypeInfo
import std.reflect.InterfaceTypeInfo
import std.reflect.TypeInfo
import std.sync.Mutex
import fountain::f_base.UnsafeBytes
import fountain::f_jit.base.CallContext
import fountain::f_jit.base.ErrCode
import fountain::f_jit.base.JitException
import fountain::f_jit.base.LocalType
import fountain::f_jit.base.TypeToken
import fountain::f_jit.compiler.ClassRegistrySnapshot
import fountain::f_jit.compiler.HostClosureSigDecl
import fountain::f_jit.runtime.DbgDump
import fountain::f_jit.runtime.HandleTable
import fountain::f_jit.runtime.IterTable
import fountain::f_jit.runtime.JitContext
import fountain::f_jit.runtime.PromotionGroup
import fountain::f_jit.runtime.RuntimeEnv
import fountain::f_jit.runtime.SignatureDescriptor
import fountain::f_jit.runtime.UserHelperEntry
import fountain::f_jit.runtime.UserHelperTable

/**
 * S6.5 统一函数包装 `call<T>`（§8.2 六步）。
 *
 * 执行器由装载层注入（机器码或纯字节码同一接口）：
 * `body(ctx, cells)` 返回结果 cell；`replay(ctx, cells)` 供 `-1 DEOPT` 透明重跑。
 */
public class JitFunction <: Resource {
    /** 全局调用窗口：HandleTable 只有一个窗口，桥的 open/body/reset 必须串行。 */
    private static let callMtx: Mutex = Mutex()

    /**
     * 无参 `call` 的默认调用上下文（`deadline = None`）。
     *
     * `CallContext` 是 **struct**（值语义）⇒ 传参时逐值复制，各调用方拿到的是副本，
     * 不存在"共享可变状态"；这里只是省掉每次构造（`static let` 由运行时惰性初始化，线程安全）。
     */
    private static let DEFAULT_CONTEXT = CallContext()
    private let nargs: Int64
    private let retType: UInt16
    private let paramTypes: Array<UInt16>
    private let body: (JitContext, Array<Int64>) -> Int64
    private let replay: (JitContext, Array<Int64>) -> Int64
    private let report: String
    /** 诊断报告工厂（装载层注入；None = 不分配转储缓冲，保持旧行为）。 */
    private var diagMaxLocals: Int64 = 0
    private var diagReporter: ?((JitContext, CPointer<Int64>) -> String) = None
    // ---- 生命周期（S6.10）：0 Ready / 1 Unloading / 2 Unloaded ----
    private let mtx: Mutex = Mutex()
    /**
     * 本单元在进程级编译缓存里的键（`CompileCache.finish` 发布时写入）。
     *
     * `unload` 进入终态时据此把自己逐出缓存——否则同源再编译会命中已死单元
     * （H2：规格「卸载状态机与资产清点」早已要求「按未命中重编」）。
     */
    private var cacheKey: ?String = None
    private var state: Int64 = 0
    private var active: Int64 = 0
    private var release: ?(() -> Unit) = None
    /** 产物是否由机器码执行器承载（false = 纯字节码；用于 T52/诊断）。 */
    private var jitBacked: Bool = false
    /** 本单元的 user helper 表（m2 §15；空 = 无 user helper，调用期不压栈）。 */
    private var helperEntries: Array<UserHelperEntry> = Array<UserHelperEntry>()
    // ---- 逃逸闭包（§14.3，M2-8：统一 JitFunction）----
    /** 非 None = 闭包包装实例；指向承载闭包 fnId 的单元入口实例。 */
    private var owner: ?JitFunction = None
    private var closureId: Int64 = 0
    /** 本实例承接的逃逸闭包条目（包装实例非 None；单元实例恒 None）。 */
    private var entry: ?EscapedClosure = None
    /** 桥注入：`(ctx, closureId, args) -> cell`（闭包帧 `locals[0]`）。 */
    private var closureRunner: ?((JitContext, Int64, Array<Int64>) -> Int64) = None
    /** 单元侧：本单元发出、尚未释放的逃逸闭包（含未承接的组）；受 mtx 保护。 */
    private let escaped = ArrayList<EscapedClosure>()
    private var escapedSeq: Int64 = 0
    /** 最近一次 `retType=12` 返回的条目（`callForFn` 承接用；取走即清空）。 */
    private var lastEscaped: ?EscapedClosure = None
    /** 入口形参的 14 声明类名（`is C` 边界校验，§16.2）。 */
    private var paramClasses: Array<?String> = Array<?String>()
    /** 入口形参的 HostClosure 声明签名（验签，§4）。 */
    private var paramSigs: Array<?SignatureDescriptor> = Array<?SignatureDescriptor>()
    /** 本单元的类注册表快照（Q5.11；桥侧静态知识）。 */
    private var classSnapshot: ?ClassRegistrySnapshot = None

    public init(nargs: Int64, retType: UInt16, paramTypes: Array<UInt16>,
        body: (JitContext, Array<Int64>) -> Int64,
        replay: (JitContext, Array<Int64>) -> Int64, report: String) {
        this(nargs, retType, paramTypes, body, replay, report, None)
    }

    public init(nargs: Int64, retType: UInt16, paramTypes: Array<UInt16>,
        body: (JitContext, Array<Int64>) -> Int64,
        replay: (JitContext, Array<Int64>) -> Int64, report: String,
        release: ?(() -> Unit)) {
        this.nargs = nargs
        this.retType = retType
        this.paramTypes = paramTypes
        this.body = body
        this.replay = replay
        this.report = report
        this.release = release
    }

    /**
     * 装载层注入诊断能力（T50）：`maxNLocals` 决定转储缓冲大小，`reporter` 在
     * `errCode > 0` 时按转储内容组装报告文本。
     */
    internal func bindDiagnostics(maxNLocals: Int64,
        reporter: (JitContext, CPointer<Int64>) -> String): Unit {
        this.diagMaxLocals = maxNLocals
        this.diagReporter = reporter
    }

    /** 六步调用：长度 → 封送 → 执行 → 解包 → `T` 校验 → 返回。 */
    public func call<T>(args: Array<Any>): T {
        // 薄委托：错误语义与 `call(args, ctx)` 完全一致（>0 抛 JitException、−2 抛 InterruptedException）
        this.call<T>(args, JitFunction.DEFAULT_CONTEXT)
    }

    /**
     * 带调用选项的六步调用（D3）：`deadline` 到期 ⇒ H22 写 −2 ⇒ `InterruptedException`。
     *
     * **deadline 用栈式保存/恢复**而不是每次覆盖：`callMtx` 只串行化顶层调用，同一线程的
     * 重入（宿主闭包体内再调 JIT）不受锁约束，直接 `setDeadline` 会把外层期限冲掉。
     * 严格浮点由 `CompileOptions.strictFp` 在**产物层**决定（`FDIV` / `FDIV_CHK`），调用选项不再携带。
     */
    public func call<T>(args: Array<Any>, options: CallContext): T {
        let saved = RuntimeEnv.deadlineNanos
        RuntimeEnv.setDeadline(RuntimeEnv.deadlineNanosOf(options.deadline))
        try {
            // HandleTable 是进程级单窗口：open/执行/reset 必须串行，否则并发调用会互相清窗。
            synchronized (JitFunction.callMtx) {
                this.enter()
                try {
                    return this.callLocked<T>(args, options)
                } finally {
                    this.exit()
                }
            }
        } finally {
            RuntimeEnv.setDeadline(saved)
        }
    }

    /** 未卸载/未进入卸载态 → 允许调用；否则 19（§8.7）。包装实例按闭包条目记账。 */
    private func enter(): Unit {
        match (this.owner) {
            case Some(o) => o.enterClosure(this.entryOrFail())
            case None => this.enterUnit()
        }
    }

    private func exit(): Unit {
        match (this.owner) {
            case Some(o) => o.exitClosure(this.entryOrFail())
            case None => this.exitUnit()
        }
    }

    private func enterUnit(): Unit {
        synchronized(this.mtx) {
            if (this.state != 0) {
                throw JitException(ErrCode.CALL_CONTRACT, -1, 0, None,
                    '单元已卸载或正在卸载（§8.7）')
            }
            this.active = this.active + 1
        }
    }

    private func exitUnit(): Unit {
        synchronized(this.mtx) {
            this.active = this.active - 1
        }
    }

    private func entryOrFail(): EscapedClosure {
        match (this.entry) {
            case Some(e) => e
            case None => throw JitException(ErrCode.HELPER_PANIC, -1, 0, None,
                '闭包包装缺少条目（m2 §14.3）')
        }
    }

    /**
     * 卸载：包装实例 → 释放**本闭包**（排空本闭包在飞调用，§14.3）；入口实例 → 单元终态。
     *
     * 单元进入终态时**先**级联释放登记在册的逃逸闭包（含未承接的组），**再**释放代码内存/常量。
     */
    public func close(timeoutMs: Int64): Bool {
        if (this.owner.isSome()) {
            return this.closeClosure(timeoutMs)
        }
        synchronized(this.mtx) {
            if (this.state == 2) {
                return true
            }
            this.state = 1
        }
        var spins: Int64 = 0
        let limit = if (timeoutMs <= 0) { 0 } else { timeoutMs * 100000 }
        while (true) {
            let drained = synchronized(this.mtx) {
                this.active == 0
            }
            if (drained) {
                break
            }
            if (spins >= limit) {
                synchronized(this.mtx) {
                    this.state = 0
                }
                return false
            }
            spins = spins + 1
        }
        var groups = ArrayList<PromotionGroup>()
        var rel: ?(() -> Unit) = None
        synchronized(this.mtx) {
            this.state = 2
            // 终态即逐出：同键编译此后必须按未命中重编（否则拿到的是已死单元）。
            // 超时回退路径不走这里 —— 那时单元仍可用，逐出会造出同键的两份产物。
            match (this.cacheKey) {
                case Some(k) =>
                    this.cacheKey = None
                    CompileCache.remove(k)
                case None => ()
            }
            // 登记在册的逃逸闭包全部置终态并拷出组（锁内不归还句柄：releaseAll 会进 HandleTable）。
            for (e in this.escaped) {
                if (e.state != 2) {
                    e.state = 2
                    groups.add(e.group)
                }
            }
            this.escaped.clear()
            this.lastEscaped = None
            rel = this.release
            this.release = None
        }
        // ① 先级联释放逃逸闭包；② 再释放单元资产（代码内存/常量）。
        for (g in groups) {
            g.releaseAll()
        }
        match (rel) {
            case Some(f) => f()
            case None => ()
        }
        true
    }

    /**
     * 闭包包装释放（原 public `unloadFn`，M2 §14.3；现为 `close()` 的私有实现）。
     *
     * 只放掉**这个函数值**捕获的提升槽：单元继续可用、不动编译缓存。
     */
    private func closeClosure(timeoutMs: Int64): Bool {
        match (this.owner) {
            case Some(o) => o.unloadClosure(this.entryOrFail(), timeoutMs)
            case None => false
        }
    }

    /** 关闭一个逃逸闭包：卸载中 → 排空本闭包在飞调用 → 已释放（幂等、超时回退）。 */
    private func unloadClosure(e: EscapedClosure, timeoutMs: Int64): Bool {
        synchronized(this.mtx) {
            if (e.state == 2) {
                return true
            }
            e.state = 1
        }
        var spins: Int64 = 0
        let limit = if (timeoutMs <= 0) { 0 } else { timeoutMs * 100000 }
        while (true) {
            let drained = synchronized(this.mtx) {
                e.active == 0
            }
            if (drained) {
                break
            }
            if (spins >= limit) {
                // 释放未发生：条目恢复可用，调用方看到 false。
                synchronized(this.mtx) {
                    e.state = 0
                }
                return false
            }
            spins = spins + 1
        }
        synchronized(this.mtx) {
            e.state = 2
            this.dropEscaped(e)
        }
        e.group.releaseAll()
        true
    }

    /** 包装实例调用入口：单元未卸载 + 本闭包未释放（同一临界区内记账，无 TOCTOU）。 */
    private func enterClosure(e: EscapedClosure): Unit {
        synchronized(this.mtx) {
            if (this.state != 0) {
                throw JitException(ErrCode.CALL_CONTRACT, -1, 0, None,
                    '单元已卸载或正在卸载（§8.7）')
            }
            if (e.state != 0) {
                throw JitException(ErrCode.CALL_CONTRACT, -1, 0, None,
                    '闭包包装已释放（m2 §14.3）')
            }
            this.active = this.active + 1
            e.active = e.active + 1
        }
    }

    private func exitClosure(e: EscapedClosure): Unit {
        synchronized(this.mtx) {
            this.active = this.active - 1
            e.active = e.active - 1
        }
    }

    /** 登记一个提升组（组产生处调用，与是否被 `callForFn` 承接无关）。 */
    private func registerEscaped(g: PromotionGroup): EscapedClosure {
        synchronized(this.mtx) {
            this.escapedSeq = this.escapedSeq + 1
            let e = EscapedClosure(this.escapedSeq, g)
            this.escaped.add(e)
            e
        }
    }

    /** 测试/桥内部：直接登记一个组（构造未承接条目用）。 */
    internal func newEscapedClosure(g: PromotionGroup): EscapedClosure {
        this.registerEscaped(g)
    }

    internal func closureReleased(e: EscapedClosure): Bool {
        synchronized(this.mtx) {
            e.state == 2
        }
    }

    private func dropEscaped(e: EscapedClosure): Unit {
        var i = 0
        while (i < this.escaped.size) {
            if (this.escaped[i].seq == e.seq) {
                this.escaped.remove(at: i)
                return
            }
            i = i + 1
        }
    }

    /** 便捷重载（默认为不等待活跃调用）。 */
    /** 本次产物是否走机器码路径（装载层在成功创建 JitExecutor 后置 true）。 */
    public func isJitBacked(): Bool {
        this.jitBacked
    }

    /** 装载层内部：标记机器码产物。 */
    internal func markJitBacked(): Unit {
        this.jitBacked = true
    }

    /** 装载层内部：绑定本单元 user helper 表（slot 0 = hid 0x0100）。 */
    internal func bindUserHelpers(entries: Array<UserHelperEntry>): Unit {
        this.helperEntries = entries
    }

    /** 装载层内部：绑定入口形参的 14 类名 / HostClosure 签名 / 类快照。 */
    internal func bindEntryMeta(paramClasses: Array<?String>,
        paramSigs: Array<?HostClosureSigDecl>,
        classSnap: ?ClassRegistrySnapshot): Unit {
        this.paramClasses = paramClasses
        let sigs = ArrayList<?SignatureDescriptor>()
        for (s in paramSigs) {
            match (s) {
                case Some(d) => sigs.add(Some(SignatureDescriptor(d.params, d.ret,
                    paramNames: d.paramNames, retName: d.retName)))
                case None => sigs.add(None)
            }
        }
        this.paramSigs = sigs.toArray()
        this.classSnapshot = classSnap
    }

    /** 装载层内部：绑定本单元在编译缓存里的键（卸载时据此逐出）。 */
    internal func bindCacheKey(key: String): Unit {
        synchronized(this.mtx) {
            this.cacheKey = Some(key)
        }
    }

    /** 装载层内部：绑定闭包调用器（包装器调用走既有闭包帧，§14.3）。 */
    internal func bindClosureRunner(r: (JitContext, Int64, Array<Int64>) -> Int64): Unit {
        this.closureRunner = Some(r)
    }

    /**
     * 桥内部构造闭包包装实例（宿主不直接调用）。
     *
     * `nargs < 0` / `retType == NONE` 表示签名未知：调用期按实参/`T` 动态封送与解包。
     */
    internal static func wrapClosure(owner: JitFunction, id: JitClosureId,
        entry: EscapedClosure, nargs: Int64, retType: UInt16,
        paramTypes: Array<UInt16>): JitFunction {
        let body = { ctx: JitContext, cells: Array<Int64> =>
            owner.invokeClosure(ctx, id.id, cells)
        }
        let f = JitFunction(nargs, retType, paramTypes, body, body, '')
        f.owner = Some(owner)
        f.closureId = id.id
        f.entry = Some(entry)
        f
    }

    /**
     * 是否已关闭（`std.core.Resource`，§8.7/§14.3）。
     *
     * 入口实例：单元已卸载（终态 `state=2`）；闭包包装实例：本函数值已释放（含单元卸载级联）。
     */
    public func isClosed(): Bool {
        match (this.owner) {
            case None =>
                let closed = synchronized(this.mtx) {
                    this.state == 2
                }
                return closed
            case Some(o) =>
                match (this.entry) {
                    case Some(e) => return o.closureReleased(e)
                    case None => return false
                }
        }
    }

    /**
     * 返回闭包的强类型入口（m2 §9.1/§14）：调用单元 → 取回返回闭包 → 交宿主可调用包装。
     *
     * `Fn` = 返回闭包的函数类型（编译期已知）；解析失败时退化为动态签名（零运行期函数判定）。
     */
    public func callForFn<Fn>(args: Array<Any>): JitFunction {
        if (this.owner.isSome()) {
            return JitFunction.contractFail('包装实例不可再 callForFn（m2 §9.1）')
        }
        if (this.retType != LocalType.CLOSURE) {
            return JitFunction.contractFail('callForFn 要求单元返回闭包（retType=12）')
        }
        let typeName = TypeInfo.of<Fn>().name
        // 整个过程在 `callMtx` 内完成（A6/P2-4）：`lastEscaped` 是**单元级**字段，
        // 锁外读取会让两个线程拿到彼此的条目（一侧释放会提前归还另一侧的捕获）。
        // 取完立即清空，禁止跨调用残留。
        synchronized (JitFunction.callMtx) {
            this.enter()
            var id = JitClosureId(JitClosureId.INVALID)
            var entry: ?EscapedClosure = None
            try {
                id = this.callLocked<JitClosureId>(args, JitFunction.DEFAULT_CONTEXT)
                entry = this.lastEscaped
                this.lastEscaped = None
            } finally {
                this.exit()
            }
            let e = match (entry) {
                case Some(x) => x
                case None => return JitFunction.contractFail('闭包提升组缺失（m2 §14.3）')
            }
            match (JitFunction.parseFnType(typeName)) {
                case Some(sig) =>
                    JitFunction.wrapClosure(this, id, e, Int64(sig.params.size), sig.ret,
                        sig.params)
                case None =>
                    JitFunction.wrapClosure(this, id, e, -1, LocalType.NONE, Array<UInt16>())
            }
        }
    }

    /** `Resource.close()`：不等待在飞调用（等价 `close(0)`，丢弃排空结果）。 */
    public func close(): Unit {
        let _ = this.close(0)
    }

    /** 桥/测试内部：本单元持有的类注册表快照（Q5.11）。 */
    internal func classSnapshotOf(): ?ClassRegistrySnapshot {
        this.classSnapshot
    }

    /** 桥/测试内部：最近一次 `retType=12` 调用的条目（未承接时用于手工包装）。 */
    internal func lastEscapedClosure(): ?EscapedClosure {
        this.lastEscaped
    }

    /** 桥/测试内部：最近一次 `retType=12` 调用的提升组。 */
    internal func lastPromotionGroup(): ?PromotionGroup {
        match (this.lastEscaped) {
            case Some(e) => Some(e.group)
            case None => None
        }
    }

    private func callLocked<T>(args: Array<Any>, options: CallContext): T {
        // 已释放的包装实例在 `enterClosure` 就被 19 拦下（同一临界区判定，避免 TOCTOU）。
        let isWrapper = this.owner.isSome()
        if (isWrapper && !HandleTable.isLiveHandle(this.closureId)) {
            return JitFunction.contractFail('闭包句柄已失效（旧 ID 校验拦截）')
        }
        // 1. 参数个数（包装实例签名未知时按实参个数动态）
        if (!(isWrapper && this.nargs < 0)) {
            if (Int64(args.size) != this.nargs) {
                return JitFunction.contractFail('实参个数不符：期望 ${this.nargs}，实际 ${args.size}')
            }
        }
        // 5（前置）：`T` 与签名返回类型一致（包装实例签名未知时以 `T` 为解包类型）
        let want = JitFunction.localTypeOf<T>()
        let dynamicRet = isWrapper && this.retType == LocalType.NONE
        match (want) {
            case Some(t) =>
                if (!dynamicRet && t != this.retType) {
                    return JitFunction.contractFail('T 与返回类型不符（§8.2 第 5 步）')
                }
            case None => return JitFunction.contractFail('T 不是可解包类型')
        }
        let unboxCode = if (dynamicRet) {
            match (want) {
                case Some(t) => t
                case None => LocalType.NONE
            }
        } else {
            this.retType
        }
        let dynamicArgs = isWrapper && Int64(this.paramTypes.size) != Int64(args.size)
        let helpers = if (isWrapper) {
            match (this.owner) {
                case Some(o) => o.helperEntries
                case None => this.helperEntries
            }
        } else {
            this.helperEntries
        }
        let marshal = CallMarshal()
        // 每次调用独立窗口：执行期分配的句柄在 finally 统一回收（design §9.5 / T27）。
        HandleTable.openWindow(HandleTable.initialCapacity)
        let ctx = JitContext.create(hwBase: HandleTable.windowBaseOf(),
            hwCap: HandleTable.windowCapOf(), fnId: 0, dbgBase: 0)
        // `ctx.flags` bit0 是历史保留位（X3）：严格浮点已改为产物级 opcode 差异，
        // 运行期不再有读者；这里不再写入。
        HandleTable.syncTo(ctx)
        let dump = match (this.diagReporter) {
            case Some(_) => DbgDump.allocateDump(this.diagMaxLocals)
            case None => CPointer<Int64>()
        }
        if (!dump.isNull()) {
            ctx.attachDump(dump)
        }
        try {
            if (helpers.size > 0) {
                UserHelperTable.push(0u16, helpers)
            }
            // 2. 封送
            let cells = Array<Int64>(args.size, repeat: 0)
            var i = 0
            while (i < args.size) {
                if (dynamicArgs) {
                    cells[i] = JitFunction.marshalDynamic(marshal, args[i])
                } else if (isWrapper) {
                    cells[i] = JitFunction.marshalDeclared(marshal, this.paramTypes[i], args[i])
                } else {
                    let code = this.paramTypes[i]
                    if (code == LocalType.HOST_CLOSURE) {
                        cells[i] = marshal.marshalHostClosure(args[i], this.sigAt(i))
                    } else {
                        cells[i] = marshal.marshalArg(code, args[i], className: this.classAt(i))
                    }
                }
                i = i + 1
            }
            // 3. 执行 + 三态收尾
            let cell = this.body(ctx, cells)
            let report = match (this.diagReporter) {
                case Some(f) => if (ctx.errCode > 0) { f(ctx, dump) } else { this.report }
                case None => this.report
            }
            let ret = JitReport.finish(ctx, cell, { => this.replay(ctx, cells) }, report)
            // 4. 解包；句柄型返回值已取成宿主对象，立即归还句柄（否则每次调用泄漏 1 槽）
            // G1：unbox 可能以契约错误抛出，而 `ret` 在此之前已被 `escape`（逃逸槽不受
            // `resetWindow` 回收）⇒ 异常路径必须同样归还，否则每次契约失败泄漏 1 槽。
            var v: Any = 0
            try {
                v = marshal.makeRetUnboxer(unboxCode)(ret)
            } catch (e: Exception) {
                let _ = JitFunction.releaseReturnHandle(ret, unboxCode, this.returnGroup())
                throw e
            }
            let _ = JitFunction.releaseReturnHandle(ret, unboxCode, this.returnGroup())
            if (unboxCode == LocalType.CLOSURE) {
                // 组产生处登记（B1）：未承接的组也随单元卸载兜底释放。
                match (marshal.closureGroupOf()) {
                    case Some(g) => this.lastEscaped = Some(this.registerEscaped(g))
                    case None => ()
                }
            }
            // 6. 返回 T
            match (v as T) {
                case Some(x) => return x
                case None => return JitFunction.contractFail('返回值与 T 不符')
            }
        } finally {
            if (helpers.size > 0) {
                UserHelperTable.pop()
            }
            marshal.cleanup()
            // 迭代器表是**调用级**资源：正常返回 / 抛错 / 中断 / DEOPT 重放四条出口都在
            // finally 收尾，跨调用的陈旧游标一律失效（A5/P2-2）。
            IterTable.clearAll()
            HandleTable.resetWindow(-1)
            if (!dump.isNull()) {
                DbgDump.freeDump(dump)
            }
            JitContext.free(ctx)
        }
    }

    /**
     * 归还返回位置的逃逸句柄（A2/P2-3）。
     *
     * 覆盖 4–14（12 除外，闭包有自己的提升组）、**15** 与 **16–19**：后两组此前落在
     * `4..14` 条件外，每次「返回 Any / 返回 JSON 节点」都泄漏 1 槽（跨调用单调增长）。
     * 包装闭包返回的句柄若属于提升组（捕获的 14/容器），释放权在 `close`，此处不归。
     */
    internal static func releaseReturnHandle(ret: Int64, unboxCode: UInt16,
        group: ?PromotionGroup): Bool {
        if (!JitFunction.isReturnedHandle(unboxCode)) {
            return false
        }
        match (group) {
            case Some(g) => if (g.contains(ret)) { return false }
            case None => ()
        }
        HandleTable.releaseEscaped(ret)
        true
    }

    /**
     * 句柄型返回码：**单点派生**自 `LocalType.isHandle`（4–19）去掉闭包 12。
     *
     * 历史上这里是硬编码码集（4–14 去 12 + 15 + 16–19），新增句柄码（如 M3 之后）容易漏 ⇒
     * 漏释放。改为派生后，"句柄码扩展"与"返回值归还"两件事自动同步。
     */
    internal static func isReturnedHandle(unboxCode: UInt16): Bool {
        LocalType.isHandle(unboxCode) && unboxCode != LocalType.CLOSURE
    }

    private func classAt(i: Int64): ?String {
        if (i >= 0 && i < this.paramClasses.size) {
            this.paramClasses[i]
        } else {
            None
        }
    }

    private func sigAt(i: Int64): ?SignatureDescriptor {
        if (i >= 0 && i < this.paramSigs.size) {
            this.paramSigs[i]
        } else {
            None
        }
    }

    /** 本包装实例承接的提升组（返回值归还判定用；单元实例 None）。 */
    private func returnGroup(): ?PromotionGroup {
        match (this.entry) {
            case Some(e) => Some(e.group)
            case None => None
        }
    }

    /** 包装实例的已声明参数行（13 的验签在 Q5.10 接入；其余同 `call<T>`）。 */
    private static func marshalDeclared(m: CallMarshal, code: UInt16, v: Any): Int64 {
        if (code == LocalType.HOST_CLOSURE) {
            return JitFunction.contractFail('HostClosure 参数缺少声明签名（m2 §4）')
        }
        m.marshalArg(code, v)
    }

    /** 包装实例签名未知时的动态封送（按宿主值大类；包装值本身拒绝作实参）。 */
    private static func marshalDynamic(m: CallMarshal, v: Any): Int64 {
        match (v) {
            case i: Int64 => return i
            case f: Float64 => return m.marshalArg(LocalType.F64, f)
            case b: Bool => return m.marshalArg(LocalType.BOOL, b)
            case u: Unit =>
                let _ = u
                return 0
            case _: JitFunction =>
                return JitFunction.contractFail('包装值不得直接作实参（m2 §9.1）')
            case _ => ()
        }
        let tok = HandleTable.tokenOf(v)
        if (tok != TypeToken.RESERVED) {
            let code = LocalType.fromToken(tok)
            if (code != LocalType.NONE) {
                return m.marshalArg(code, v)
            }
        }
        match (v) {
            case o: Object => return m.marshalArg(LocalType.HOST_OBJECT, o)
            case _ => return JitFunction.contractFail('该实参类型不可封送（§8.2.1）')
        }
    }

    /** 包装器调用：桥注入的闭包帧执行（`locals[0]` = 闭包句柄）。 */
    private func invokeClosure(ctx: JitContext, ch: Int64, args: Array<Int64>): Int64 {
        match (this.closureRunner) {
            case Some(r) => r(ctx, ch, args)
            case None =>
                throw JitException(ErrCode.HELPER_PANIC, -1, 0, None,
                    '闭包包装缺少桥调用器（m2 §14.3）')
        }
    }

    /** 解析 `TypeInfo` 的函数类型名（`(T1, T2) -> R`）；失败 → None（退化为动态签名）。 */
    private static func parseFnType(name: String): ?JitFnSig {
        let b = name.unsafeBytes()
        // 本机 `TypeInfo` 的函数类型名形如 `Closure<(Int64)->Int64>`；也兼容裸 `(T) -> R`。
        var begin = 0
        var end = b.size
        if (name.startsWith('Closure<') && end > 9) {
            begin = 8
            end = end - 1
        }
        var arrow = -1
        var i = begin
        while (i + 1 < end) {
            if (b[i] == 0x2Du8 && b[i + 1] == 0x3Eu8) {
                arrow = i
                break
            }
            i = i + 1
        }
        if (arrow < 0) {
            return None
        }
        var lp = -1
        var rp = -1
        i = begin
        while (i < arrow) {
            if (b[i] == 0x28u8) {
                lp = i
            }
            if (b[i] == 0x29u8) {
                rp = i
            }
            i = i + 1
        }
        if (lp < 0 || rp <= lp) {
            return None
        }
        let params = ArrayList<UInt16>()
        var start = lp + 1
        if (rp > start) {
            i = start
            while (i <= rp) {
                if (i == rp || b[i] == 0x2Cu8) {
                    let part = JitFunction.typeNameOf(b, start, i)
                    match (JitFunction.codeOfTypeName(part)) {
                        case Some(c) => params.add(c)
                        case None => return None
                    }
                    start = i + 1
                }
                i = i + 1
            }
        }
        let retName = JitFunction.typeNameOf(b, arrow + 2, end)
        match (JitFunction.codeOfTypeName(retName)) {
            case Some(r) => Some(JitFnSig(params.toArray(), r))
            case None => None
        }
    }

    /** 取 `[start, end)` 的 ASCII 文本并去掉空白。 */
    private static func typeNameOf(b: Array<UInt8>, start: Int64, end: Int64): String {
        let out = ArrayList<UInt8>()
        var i = start
        while (i < end) {
            if (b[i] != 0x20u8 && b[i] != 0x09u8) {
                out.add(b[i])
            }
            i = i + 1
        }
        String.fromUtf8(out.toArray())
    }

    /** 去掉命名空间前缀（`std.collection.ArrayList<Int64>` → `ArrayList<Int64>`）。 */
    private static func simpleTypeName(name: String): String {
        let b = name.unsafeBytes()
        var lastDot = -1
        var i = 0
        while (i < b.size) {
            let c = b[i]
            if (c == 0x3Cu8) { // '<'：只在前缀段找分隔符
                break
            }
            if (c == 0x2Eu8) { // '.'
                lastDot = i
            }
            i = i + 1
        }
        if (lastDot <= 0) {
            return name
        }
        let n = b.size - lastDot - 1
        var out = Array<UInt8>(n, repeat: 0u8)
        var j = 0
        while (j < n) {
            out[j] = b[lastDot + 1 + j]
            j = j + 1
        }
        String.fromUtf8(out)
    }

    private static func codeOfTypeName(name: String): ?UInt16 {
        let sn = JitFunction.simpleTypeName(name)
        match (sn) {
            case 'Int64' => Some(LocalType.I64)
            case 'Float64' => Some(LocalType.F64)
            case 'Bool' => Some(LocalType.BOOL)
            case 'Unit' => Some(LocalType.UNIT)
            case 'String' => Some(LocalType.STRING)
            case 'Decimal' => Some(LocalType.DECIMAL)
            case 'DateTime' => Some(LocalType.DATETIME)
            case 'Duration' => Some(LocalType.DURATION)
            case 'Regex' => Some(LocalType.REGEX)
            // M3：与 `localTypeOf` 同表（闭包签名里的 Any / JSON 不能被误记为 14）
            case 'Any' => Some(LocalType.ANY)
            case 'JsonValue' => Some(LocalType.JSON_VALUE)
            case 'JsonObject' => Some(LocalType.JSON_OBJECT)
            case 'JsonArray' => Some(LocalType.JSON_ARRAY)
            case 'JsonNull' => Some(LocalType.JSON_NULL)
            case _ =>
                if (sn.startsWith('Range')) {
                    Some(LocalType.RANGE)
                } else if (sn.startsWith('ArrayList')) {
                    Some(LocalType.LIST)
                } else if (sn.startsWith('HashMap')) {
                    Some(LocalType.MAP)
                } else if (sn.isEmpty()) {
                    None
                } else {
                    // 注册类（或其它类）统一按 14；具体类由前端/验签静态知识承担。
                    Some(LocalType.HOST_OBJECT)
                }
        }
    }

    private static func localTypeOf<T>(): ?UInt16 {
        let info = TypeInfo.of<T>()
        let n = JitFunction.simpleTypeName(info.name)
        if (n == 'Int64') {
            return Some(LocalType.I64)
        }
        if (n == 'Float64') {
            return Some(LocalType.F64)
        }
        if (n == 'Bool') {
            return Some(LocalType.BOOL)
        }
        if (n == 'Unit') {
            return Some(LocalType.UNIT)
        }
        if (n == 'String') {
            return Some(LocalType.STRING)
        }
        if (n == 'Decimal') {
            return Some(LocalType.DECIMAL)
        }
        if (n == 'DateTime') {
            return Some(LocalType.DATETIME)
        }
        if (n == 'Duration') {
            return Some(LocalType.DURATION)
        }
        if (n == 'Regex') {
            return Some(LocalType.REGEX)
        }
        if (n.startsWith('Range')) {
            return Some(LocalType.RANGE)
        }
        if (n.startsWith('ArrayList')) {
            return Some(LocalType.LIST)
        }
        if (n.startsWith('HashMap')) {
            return Some(LocalType.MAP)
        }
        if (n == 'JitClosureId') {
            return Some(LocalType.CLOSURE)
        }
        // M3：Any 与 JSON 谱系（A3.1/D2）——缺这四行时 `call<Any>` / `call<Json*>` 恒报
        // 「T 不是可解包类型」，P0-2 的宿侧通路完全不可达。
        if (n == 'Any') {
            return Some(LocalType.ANY)
        }
        if (n == 'JsonValue') {
            return Some(LocalType.JSON_VALUE)
        }
        if (n == 'JsonObject') {
            return Some(LocalType.JSON_OBJECT)
        }
        if (n == 'JsonArray') {
            return Some(LocalType.JSON_ARRAY)
        }
        if (n == 'JsonNull') {
            return Some(LocalType.JSON_NULL)
        }
        // 注册类 / 宿主类实例统一按 14 承接（具体类由 call<T> 的单态化适配器校验）。
        // 接口同样是 14：`v as T` 对接口是合法转换（X：接口作为返回类型）。
        match (info) {
            case _: ClassTypeInfo => Some(LocalType.HOST_OBJECT)
            case _: InterfaceTypeInfo => Some(LocalType.HOST_OBJECT)
            case _ => None
        }
    }

    private static func contractFail<T>(msg: String): T {
        throw JitException(ErrCode.CALL_CONTRACT, -1, 0, None, msg)
    }
}

/** `callForFn<Fn>` 解析出的返回闭包签名（`Fn` 的函数类型名 → LocalType 编码）。 */
protected class JitFnSig {
    public let params: Array<UInt16>
    public let ret: UInt16

    public init(params: Array<UInt16>, ret: UInt16) {
        this.params = params
        this.ret = ret
    }
}
