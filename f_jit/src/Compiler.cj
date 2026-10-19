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
import fountain::f_jit.base.SourceCompileException
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
            if (this.indexOfLocked(f.name) >= 0) {
                throw SourceCompileException('DuplicateRegistration', 0, 0, 0, '',
                    '预定义函数重名: ${f.name}')
            }
            if (Int64(this.fns.size) >= this.maxPredefined) {
                throw SourceCompileException('NotImpl', 0, 0, 0, '',
                    '预定义函数数量超过上限 ${this.maxPredefined}（§8.4）')
            }
            this.fns.add(f)
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
            true
        }
    }

    public func hasFunction(name: String): Bool {
        synchronized(this.mtx) {
            this.indexOfLocked(name) >= 0
        }
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
            for (f in this.fns) {
                names.add(f.name)
                params.add(f.paramTypes)
                rets.add(f.retType)
            }
            PredefinedSnapshot(names.toArray(), params.toArray(), rets.toArray())
        }
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
