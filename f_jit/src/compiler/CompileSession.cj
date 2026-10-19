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

import std.collection.ArrayList
import fountain::f_jit.base.DiagnosticsSink
import fountain::f_jit.base.PublicCtor
import fountain::f_jit.base.SourcePos
import fountain::f_jit.base.Version
import fountain::f_jit.bytecode.ConstRegistry
import fountain::f_jit.bytecode.FuncDir
import fountain::f_jit.bytecode.LocalTypes
import fountain::f_jit.bytecode.NameTable
import fountain::f_jit.bytecode.SiteTable

/**
 * 一次 `compile` 的**单元级累加器** —— design-m1 §4.3.10。
 *
 * 三件事：
 *
 * 1. `FuncBody`（struct，只读结果）：单函数的 code 片段 + `maxStack` + `flags`；
 * 2. `LoweredFunc`（struct）：`FuncBody` 与其**配套上下文**（fnId / 形参个数 / 返回类型 /
 *    局部类型表 / 待落地站点）—— 汇编期需要的四样信息必须随体一起走，否则「目录与类型表按
 *    fnId 序一一对应」这条隐含前提无法在类型层面被保证；
 * 3. `CompileSession`（class，可变）：fnId 分配器 + 常量 / 站点 / 名字 / 目录四张共享表。
 *
 * **与设计稿的一处形态偏差（显式记录）**：设计稿把产物分成 `types: ArrayList<LocalTypes>` 与
 * `bodies: ArrayList<FuncBody>` 两条平行数组；本实现改为**一条 `funcs: ArrayList<LoweredFunc>`**
 * ——理由是「每份类型表必须与该函数的体一一对应」只能在**同一条记录里**被静态保证
 * （平行数组的下标错位编译器查不出来，只会在加载期以「类型表长度不符」拒绝）。
 */
internal struct FuncBody {
    /** code 段片段（尚未加 `codeOff` 基准，站点立即数在此形态下是**函数内相对偏移**）。 */
    public let code: Array<UInt8>
    /** 操作数栈上界（帧计算，§3.1）。 */
    public let maxStack: Int64
    /** `FuncFlags` 位域（§11.7）。 */
    public let flags: UInt16

    public init(code: Array<UInt8>, maxStack: Int64, flags: UInt16) {
        this.code = code
        this.maxStack = maxStack
        this.flags = flags
    }
}

/**
 * 待落地的站点：`relOff` = `SET_SITE` 在该函数体内的偏移；汇编期按 `codeOff` 转成绝对偏移，
 * 同时回填 `SET_SITE` 的立即数并写进站点表（§11.6 覆盖率：$11.6 全量 SET_SITE 必有条目）。
 */
internal struct PendingSite {
    public let relOff: Int64
    public let pos: SourcePos

    public init(relOff: Int64, pos: SourcePos) {
        this.relOff = relOff
        this.pos = pos
    }
}

/** 一个函数的降低产物体与其配套上下文（见本文件头部第 2 点）。 */
internal struct LoweredFunc {
    public let fnId: UInt32
    public let nargs: Int64
    public let retType: UInt16
    public let types: LocalTypes
    public let body: FuncBody
    public let sites: Array<PendingSite>

    public init(fnId: UInt32, nargs: Int64, retType: UInt16, types: LocalTypes, body: FuncBody,
        sites: Array<PendingSite>) {
        this.fnId = fnId
        this.nargs = nargs
        this.retType = retType
        this.types = types
        this.body = body
        this.sites = sites
    }

    /** 局部槽数 = `FuncEntry.nLocals`（§11.7）。 */
    public func nLocals(): Int64 {
        this.types.size
    }

    /** code 片段长度 = `FuncEntry.codeLen`。 */
    public func codeLen(): Int64 {
        this.body.code.size
    }
}

internal class CompileSession {
    /** 规范化后的源码（诊断位置口径，design §4.3.1）。 */
    public let source: String
    /** 注册表快照（"本题编译" 的 slot → 签名映射，§8.4 快照语义）。 */
    public let registry: PredefinedSnapshot
    public let diagnostics: DiagnosticsSink

    /** 常量表（拼装期写、汇编期冻结）。 */
    public let consts: ConstRegistry
    /** 站点表（前端写，随产物走）。 */
    public let sites: SiteTable
    /** 名字表（稀疏；只登记源码级命名槽，§11.6）。 */
    public let names: NameTable
    /** 函数目录（§11.7）。 */
    public let dir: FuncDir

    /** 入口函数号（顶层 lambda；汇编期写 `FbcHeader.entryFn`）。 */
    public var entryFn: UInt32 = 0u32

    /** 汇编目标主版本（M1 缺省；M2 目标显式传 2，design-m2 D12）。 */
    public let verMajor: UInt16

    /** 已降低的函数（按登记顺序 = fnId 分配顺序）。 */
    private let funcs: ArrayList<LoweredFunc>
    private var nextFnId: UInt32
    /** 构造器物化出的单元私有 user helper（slot 序，m2 §15）。 */
    private let ctorHelpers: ArrayList<PublicCtor>
    private let ctorKeys: ArrayList<String>

    public init(source: String, registry: PredefinedSnapshot, diagnostics: DiagnosticsSink,
        verMajor!: UInt16 = Version.MAJOR) {
        this.source = source
        this.registry = registry
        this.diagnostics = diagnostics
        this.verMajor = verMajor
        this.consts = ConstRegistry()
        this.sites = SiteTable()
        this.names = NameTable()
        this.dir = FuncDir()
        this.funcs = ArrayList<LoweredFunc>()
        this.nextFnId = 0u32
        this.ctorHelpers = ArrayList<PublicCtor>()
        this.ctorKeys = ArrayList<String>()
    }

    /**
     * 分配下一个 fnId（0 = 入口；其后是嵌套闭包与按需生成的 `recursive` 值化适配器，§8.0 单元形态）。
     *
     * 这里的分配顺序就是 `dir` 的登记顺序，也是 code 段的布局顺序。
     */
    public func newFnId(): UInt32 {
        let id = this.nextFnId
        this.nextFnId = id + 1u32
        id
    }

    /** 已登记的待汇编函数数（= 目录项数）。 */
    public prop funcCount: Int64 {
        get() {
            this.funcs.size
        }
    }

    /** 第 `i` 个降低产物（登记序）。 */
    public func funcAt(i: Int64): LoweredFunc {
        if (i < 0 || i >= this.funcs.size) {
            diagFail(DiagKind.CODE_GEN, this.source, 0, 1, 1, '汇编会话函数下标越界: ${i}')
        }
        this.funcs[i]
    }

    /** 登记一个函数的降低产物（`Lowerer` 逐个产出、 `Assembler` 一次性消费）。 */
    public func addFunc(f: LoweredFunc): Unit {
        let t = LocalTypes(f.types.size)
        for (i in 0..f.types.size) {
            t.set(i, f.types.get(i))
        }
        this.funcs.add(LoweredFunc(f.fnId, f.nargs, f.retType, t, f.body, f.sites))
    }

    /**
     * 构造器 → 单元私有 user helper slot（m2 §15：零新指令/新 helper）。
     *
     * 同一 `(类名, 构造器下标)` 幂等复用同一 slot；slot 接在预定义快照之后，
     * hid = slot + 0x0100（`HelperCodec.hidOfSlot`）。
     */
    public func allocCtorHelper(className: String, ctorIndex: Int64, ctor: PublicCtor): UInt16 {
        let key = '${className}#${ctorIndex}'
        var i = 0
        while (i < this.ctorKeys.size) {
            if (this.ctorKeys[i] == key) {
                return UInt16(this.registry.size() + Int64(i))
            }
            i = i + 1
        }
        this.ctorKeys.add(key)
        this.ctorHelpers.add(ctor)
        UInt16(this.registry.size() + Int64(this.ctorHelpers.size - 1))
    }

    /** 本单元物化出的构造器 helper（按 slot 序）。 */
    public func ctorHelperList(): Array<PublicCtor> {
        this.ctorHelpers.toArray()
    }
}
