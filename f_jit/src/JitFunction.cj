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

import std.reflect.TypeInfo
import std.sync.Mutex
import fountain::f_jit.base.ErrCode
import fountain::f_jit.base.JitException
import fountain::f_jit.base.LocalType
import fountain::f_jit.runtime.DbgDump
import fountain::f_jit.runtime.HandleTable
import fountain::f_jit.runtime.JitContext

/**
 * S6.5 统一函数包装 `call<T>`（§8.2 六步）。
 *
 * 执行器由装载层注入（机器码或纯字节码同一接口）：
 * `body(ctx, cells)` 返回结果 cell；`replay(ctx, cells)` 供 `-1 DEOPT` 透明重跑。
 */
public class JitFunction {
    /** 全局调用窗ロ：HandleTable 只有一个窗口，桥的 open/body/reset 必须串行。 */
    private static let callMtx: Mutex = Mutex()
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
    private var state: Int64 = 0
    private var active: Int64 = 0
    private var release: ?(() -> Unit) = None
    /** 产物是否由机器码执行器承载（false = 纯字节码；用于 T52/诊断）。 */
    private var jitBacked: Bool = false

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
        // HandleTable 是进程级单窗口：open/执行/reset 必须串行，否则并发调用会互相清窗。
        synchronized (JitFunction.callMtx) {
            this.enter()
            try {
                return this.callLocked<T>(args)
            } finally {
                this.exit()
            }
        }
    }

    /** 未卸载/未进入卸载态 → 允许调用；否则 19（§8.7）。 */
    private func enter(): Unit {
        synchronized(this.mtx) {
            if (this.state != 0) {
                throw JitException(ErrCode.CALL_CONTRACT, -1, 0, None,
                    '单元已卸载或正在卸载（§8.7）')
            }
            this.active = this.active + 1
        }
    }

    private func exit(): Unit {
        synchronized(this.mtx) {
            this.active = this.active - 1
        }
    }

    /** 卸载：等待活跃调用排空；超时恢复 Ready 返回 false；双卸载幂等。 */
    public func unload(timeoutMs: Int64): Bool {
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
        synchronized(this.mtx) {
            this.state = 2
            match (this.release) {
                case Some(f) =>
                    this.release = None
                    f()
                case None => ()
            }
        }
        true
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

    public func unload(): Bool {
        this.unload(0)
    }

    public func isUnloaded(): Bool {
        synchronized(this.mtx) {
            this.state == 2
        }
    }

    private func callLocked<T>(args: Array<Any>): T {
        // 1. 参数个数
        if (Int64(args.size) != this.nargs) {
            return JitFunction.contractFail('实参个数不符：期望 ${this.nargs}，实际 ${args.size}')
        }
        // 5（前置）：`T` 与签名返回类型一致
        let want = JitFunction.localTypeOf<T>()
        match (want) {
            case Some(t) =>
                if (t != this.retType) {
                    return JitFunction.contractFail('T 与返回类型不符（§8.2 第 5 步）')
                }
            case None => return JitFunction.contractFail('T 不是可解包类型')
        }
        let marshal = CallMarshal()
        // 每次调用独立窗口：执行期分配的句柄在 finally 统一回收（design §9.5 / T27）。
        HandleTable.openWindow(HandleTable.initialCapacity)
        let ctx = JitContext.create(hwBase: HandleTable.windowBaseOf(),
            hwCap: HandleTable.windowCapOf(), fnId: 0, dbgBase: 0)
        HandleTable.syncTo(ctx)
        let dump = match (this.diagReporter) {
            case Some(_) => DbgDump.allocateDump(this.diagMaxLocals)
            case None => CPointer<Int64>()
        }
        if (!dump.isNull()) {
            ctx.attachDump(dump)
        }
        try {
            // 2. 封送
            let cells = Array<Int64>(args.size, repeat: 0)
            var i = 0
            while (i < args.size) {
                cells[i] = marshal.marshalArg(this.paramTypes[i], args[i])
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
            let v = marshal.makeRetUnboxer(this.retType)(ret)
            if (this.retType >= LocalType.STRING && this.retType <= LocalType.MAP) {
                HandleTable.releaseEscaped(ret)
            }
            // 6. 返回 T
            match (v as T) {
                case Some(x) => return x
                case None => return JitFunction.contractFail('返回值与 T 不符')
            }
        } finally {
            marshal.cleanup()
            HandleTable.resetWindow(-1)
            if (!dump.isNull()) {
                DbgDump.freeDump(dump)
            }
            JitContext.free(ctx)
        }
    }

    private static func localTypeOf<T>(): ?UInt16 {
        let n = TypeInfo.of<T>().name
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
        None
    }

    private static func contractFail<T>(msg: String): T {
        throw JitException(ErrCode.CALL_CONTRACT, -1, 0, None, msg)
    }
}
