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
import std.sync.Mutex
import fountain::f_jit.base.ClassDescriptor
import fountain::f_jit.base.SourceCompileException
import fountain::f_jit.base.PredefinedFunction
import fountain::f_jit.base.JitBindings
import fountain::f_jit.base.DummyDiagnosticsSink
import fountain::f_jit.compiler.ClassRegistrySnapshot
import fountain::f_jit.compiler.PredefinedSnapshot

/**
 * 编译器门面（design §7.3.1、plan S6.1–S6.2）。
 *
 * 职责只有注册表：`registerFunction` / `unregisterFunction` / `hasFunction` /
 * `registeredNames`，并在 `compile` 时给出**注册当时的快照**（§8.4 快照语义）。
 */
public class Compiler {
    public let name: String
    public let opts: CompileOptions
    private let maxPredefined: Int64
    private let mtx: Mutex = Mutex()
    private let fns: ArrayList<PredefinedFunction> = ArrayList<PredefinedFunction>()
    /** 宿主侧类注册表（M2；快照语义与函数注册表同族）。 */
    private let classes: ClassRegistry = ClassRegistry()

    /**
     * 无参形态：等价于 `Compiler(CompileOptions(DummyDiagnosticsSink()))`。
     *
     * 用于"只要编译、不关心诊断"的快速上手场景；需要收集诊断时显式传 `CompileOptions`。
     */
    public init() {
        this(CompileOptions(DummyDiagnosticsSink()))
    }

    public init(opts: CompileOptions) {
        this('compiler', opts, 256)
    }

    public init(name: String, opts: CompileOptions, maxPredefined: Int64) {
        this.name = name
        this.opts = opts
        this.maxPredefined = maxPredefined
    }

    /** 注册；重名 → `DuplicateRegistration`，超过上限 → `NotImpl`。 */
    public func registerFunction(f: PredefinedFunction): Unit {
        synchronized(this.mtx) {
            if (this.indexOfLocked(f.name) >= 0 || this.classes.hasFunction(f.name)) {
                throw SourceCompileException('DuplicateRegistration', 0, 0, 0, '',
                    '预定义函数重名: ${f.name}')
            }
            if (Int64(this.fns.size) >= this.maxPredefined) {
                throw SourceCompileException('NotImpl', 0, 0, 0, '',
                    '预定义函数数量超过上限 ${this.maxPredefined}（§8.4）')
            }
            this.fns.add(f)
            this.classes.noteFunction(f.name)
        }
    }

    /** 注销；返回是否存在并已移除。 */
    public func unregisterFunction(name: String): Bool {
        synchronized(this.mtx) {
            let i = this.indexOfLocked(name)
            if (i < 0) {
                return false
            }
            this.fns.remove(at: i)
            this.classes.removeFunction(name)
            true
        }
    }

    public func hasFunction(name: String): Bool {
        synchronized(this.mtx) {
            this.indexOfLocked(name) >= 0
        }
    }

    /**
     * 注册一个类描述符（m2 §12.4）。
     *
     * 类名冲突（已注册类/函数名/内建/关键字）→ `RegistrationException` 且不登记；
     * 方法表的 `bind` 同时进入预定义函数面（`u.m()` 的 hid 来源），同名已存在则复用。
     */
    public func registerClass(desc: ClassDescriptor): Unit {
        this.classes.register(desc)
        synchronized(this.mtx) {
            for (m in desc.methods) {
                if (this.indexOfLocked(m.bind.name) < 0) {
                    if (!this.classes.hasFunction(m.bind.name)) {
                        this.fns.add(m.bind)
                    }
                    this.classes.noteFunction(m.bind.name)
                }
            }
        }
    }

    /** 反射自动注册（m2 §12.5）；`enabled=false` 用于关闭反射的构建。 */
    public func registerType<T>(enabled!: Bool = true,
        bindings!: JitBindings = JitBindings.empty()): Unit where T <: Object {
        ReflectRegistrar.registerType<T>(into: this.classes, diag: this.opts.diagnostics,
            enabled: enabled, bindings: bindings)
    }

    /**
     * 注册接口（X）：接口不是 `Object` 子类型，不能复用 `registerType` 的泛型约束。
     *
     * 接口方法必须由 `@JitBind` 提供绑定（反射调用抽象方法必失败）。
     */
    public func registerInterface<I>(enabled!: Bool = true,
        bindings!: JitBindings = JitBindings.empty()): Unit {
        ReflectRegistrar.registerInterface<I>(into: this.classes, diag: this.opts.diagnostics,
            enabled: enabled, bindings: bindings)
    }

    /** 类是否已注册（诊断/测试）。 */
    public func hasClass(name: String): Bool {
        match (this.classes.resolve(name)) {
            case Some(_) => true
            case None => false
        }
    }

    /** 编译期类快照（注册变更不影响已编译单元）。 */
    protected func classSnapshot(): ClassRegistrySnapshot {
        this.classes.snapshot()
    }

    /** 注册名（按注册顺序）。 */
    public func registeredNames(): Array<String> {
        synchronized(this.mtx) {
            let out = ArrayList<String>()
            for (f in this.fns) {
                out.add(f.name)
            }
            out.toArray()
        }
    }

    /** 端到端编译源码（S6.8）：失败在 compile 时刻抛出，返回统一包装。 */
    public func compile(source: String): JitFunction {
        CompilePipeline.runSource(source, this)
    }

    /** 当前注册表快照（编译期使用；注册/注销不影响已编译产物）。 */
    protected func snapshot(): PredefinedSnapshot {
        synchronized(this.mtx) {
            let names = ArrayList<String>()
            let params = ArrayList<Array<UInt16>>()
            let rets = ArrayList<UInt16>()
            let impls = ArrayList<(Array<Any>) -> Any>()
            for (f in this.fns) {
                names.add(f.name)
                params.add(f.paramTypes)
                rets.add(f.retType)
                impls.add(f.impl)
            }
            // 反射自动注册生成的包装函数并入同一 slot 空间（与手工注册可混用）。
            for (f in this.classes.autoFunctions()) {
                if (!Compiler.containsName(names, f.name)) {
                    names.add(f.name)
                    params.add(f.paramTypes)
                    rets.add(f.retType)
                    impls.add(f.impl)
                }
            }
            PredefinedSnapshot(names.toArray(), params.toArray(), rets.toArray(),
                impls: impls.toArray())
        }
    }

    private static func containsName(names: ArrayList<String>, name: String): Bool {
        var i = 0
        while (i < names.size) {
            if (names[i] == name) {
                return true
            }
            i = i + 1
        }
        false
    }

    private func indexOfLocked(name: String): Int64 {
        var i = 0
        while (i < this.fns.size) {
            if (this.fns[i].name == name) {
                return i
            }
            i = i + 1
        }
        -1
    }
}
