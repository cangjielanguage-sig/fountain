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
package fountain::f_jit.compiler

import fountain::f_jit.base.LocalType
import fountain::f_jit.base.SourcePos

/**
 * 预定义函数注册表的**编译期快照**（§8.4「注册/注销只影响之后的 compile；已编译产物持有快照」）。
 *
 * **为什么是 `protected`（模块级）而不是 `internal`**：`compiler` 与根包都要用——
 * 根包的 `Compiler.registerFunction` 构造快照，`compiler.NameResolver` 消费它；
 * `internal` 只到「本包及子包」，跨兄弟包不可见（design D2 可见性三档）。
 *
 * **为什么是快照而不是直接持注册表**：已编译产物持有**注册当时的** slot → 签名映射，
 * 后续 register/unregister 不得改变既有产物的语义（§8.4 快照语义；与 D9「一份源码只出一份产物」同族）。
 *
 * slot = hid − 0x0100（§8.4：user helpers ↔ hid [0x0100, 0xFFFF]）。
 */
protected class PredefinedSnapshot {
    /** slot 序的注册名（数组下标即 slot）。 */
    public let names: Array<String>
    /** 每个 slot 的形参类型（LocalType 码序列）。 */
    public let paramTypes: Array<Array<UInt16>>
    /** 每个 slot 的返回类型（LocalType 码）。 */
    public let retTypes: Array<UInt16>

    public init(names: Array<String>, paramTypes: Array<Array<UInt16>>, retTypes: Array<UInt16>) {
        this.names = names
        this.paramTypes = paramTypes
        this.retTypes = retTypes
    }

    /** 空快照（无预定义函数时 `SourceCompiler` 用）。 */
    public static func empty(): PredefinedSnapshot {
        PredefinedSnapshot(Array<String>(), Array<Array<UInt16>>(), Array<UInt16>())
    }

    public func size(): Int64 {
        this.names.size
    }

    public func has(name: String): Bool {
        this.slotOf(name) >= 0
    }

    /** 名字 → slot；未命中 → −1。 */
    public func slotOf(name: String): Int64 {
        var i = 0
        while (i < this.names.size) {
            if (this.names[i] == name) {
                return i
            }
            i = i + 1
        }
        -1
    }

    public func paramTypesOf(name: String): Array<UInt16> {
        let s = this.slotOf(name)
        if (s < 0) {
            return Array<UInt16>()
        }
        this.paramTypes[s]
    }

    public func retTypeOf(name: String): UInt16 {
        let s = this.slotOf(name)
        if (s < 0) {
            return LocalType.NONE
        }
        this.retTypes[s]
    }

    /** 已注册清单文本（未注册诊断的 `hint`，§8.4 需求 4）。 */
    public func registeredList(): String {
        var sb = StringBuilder()
        sb.append('[')
        for (i in 0..this.names.size) {
            if (i > 0) {
                sb.append(', ')
            }
            sb.append(this.names[i])
        }
        sb.append(']')
        sb.toString()
    }
}

/**
 * 名字解析结果（design §4.3.3）：两个构造器，`Lowerer` **穷尽分派**。
 */
internal enum ResolvedCall {
    /** 命中 `recursive` 关键字 —— 自递归（顶层 `CALL_FUNC`、闭包层 `LOADL 0` + `CALL_CLOSURE`）。 */
    | Recursive
    /** 命中注册表 —— user helper，载荷 = slot（hid = slot + 0x0100）。 */
    | UserHelper(UInt16)
}

/**
 * 调用点名字解析（S3.8）——design §4.3.3 / §8.4 需求 4。
 *
 * 顺序（**冻结**）：`recursive` → 注册表（user helper）→ 未命中 `UnregisteredFunction`。
 * 非调用位置的未定义标识符 → `UndefinedIdentifier`（由 `requireValue` 判定）。
 * 编译期错误**不占用 §2 运行期错误码**（§8.4）。
 */
internal class NameResolver {
    private let snapshot: PredefinedSnapshot
    private let src: String

    public init(snapshot: PredefinedSnapshot, source: String) {
        this.snapshot = snapshot
        this.src = Lexer.normalizeNewlines(source)
    }

    /** 调用点解析：`recursive` → 注册表 → 未注册错误（消息含名字 / 位置 / 已注册清单）。 */
    public func resolve(name: String, pos: SourcePos): ResolvedCall {
        if (name == 'recursive') {
            return ResolvedCall.Recursive
        }
        let slot = this.snapshot.slotOf(name)
        if (slot < 0) {
            diagFail(DiagKind.UNREGISTERED_FUNCTION, this.src, 0, pos.line, pos.column,
                '调用了未注册的预定义函数「${name}」。已注册：${this.snapshot.registeredList()}。' +
                '请先经 Compiler.registerFunction 注册，或改用已注册的名字')
        }
        ResolvedCall.UserHelper(UInt16(slot))
    }

    /**
     * 非调用位置的名字：**必须**已是局部（参数 / 声明变量 / 闭包绑定）才合法。
     *
     * 局部性判定由调用方（降低阶段的作用域表）给出——名字解析只负责给出**准确诊断**：
     * 不是局部且未注册 ⇒ `UndefinedIdentifier`（design §4.3.3）。
     */
    public func requireValue(name: String, pos: SourcePos, isLocal: Bool): Unit {
        if (isLocal) {
            return
        }
        if (this.snapshot.has(name)) {
            return
        }
        diagFail(DiagKind.UNDEFINED_IDENTIFIER, this.src, 0, pos.line, pos.column,
            '未定义的标识符「${name}」（既不是局部/参数，也不是已注册的预定义函数）。' +
            '已注册：${this.snapshot.registeredList()}')
    }

    /** 注册表快照（降低阶段取签名用）。 */
    public func snapshotOf(): PredefinedSnapshot {
        this.snapshot
    }
}
