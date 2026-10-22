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
package fountain::f_jit.base

/**
 * 类注册协议值类型 —— `doc/jit-bytecode-m2.md` §12.2 / §12.4 / §15、
 * `design-m2.md` §2.2、spec「类描述符与字段项」「方法与构造器项」。
 *
 * 这些类型只在**宿主侧注册调用栈**使用：描述符是编译期快照的输入，不落入 `.fbc`，
 * 也不进入三引擎差分。字段类型码用 LocalType（0–14）；构造器形参面沿用预定义函数
 * 合法集（0–8/10–11/13/14）。
 */

/** 注册期字段类型合法集：M2 为 LocalType 0–14（15 起属 M3）。 */
func isRegistrationLocalType(code: UInt16): Bool {
    code <= LocalType.HOST_OBJECT
}

/**
 * 字段项（struct）：`name → index/type/mutable/typeRef`。
 *
 * `type` 是仓颉关键字，按语言规则用原始标识符 `` `type` `` 承载（仓库既有先例：
 * `f_http` 的 `ContentDisposition`）。`mutable=false` 表示 `let` 字段：前端拒绝写入，
 * 裸 H65 由运行期防御返回 19（双防线）。
 */
public struct PublicField {
    /** 字段名（前端解析用）。 */
    public let name: String

    /** LocalType 编码 0–14（v0.8.20 起含 9=Regex）。 */
    public let `type`: UInt16

    /** H64/H65 的 index 实参（字节码只见 index 与类型码）。 */
    public let index: UInt16

    /** `var` / `let` 标志。 */
    public let mutable: Bool

    /** 14 型字段的目标类名（链式解析 `u.a.b`）；其余类型不消费。 */
    public let typeRef: ?String

    /**
     * 13 型字段的**函数签名**：形参类别序列（`LocalType` 码）。
     *
     * 字段也能持有 HostClosure（`u.cb(a)`），但该调用的签名无法从字段名或 `typeRef` 推出。
     * 手工注册可显式给出，`CALL_HOST` 因此能带 `sigId` 走精确签名；自动注册（`std.reflect`）
     * 给不出函数类型信息 ⇒ 留空 ⇒ 该字段调用退回旧的 `argc` 分派。
     */
    public let sigParams: Array<UInt16>

    /** 13 型字段的形参类名（非 14 位置为空串）；与 `sigParams` 等长。 */
    public let sigParamNames: Array<String>

    /** 13 型字段的返回类别；非 13 型为 `LocalType.NONE`。 */
    public let sigRet: UInt16

    /** 13 型字段的返回类名（`sigRet != 14` 时为空串）。 */
    public let sigRetName: String

    public init(name!: String, `type`!: UInt16, index!: UInt16, mutable!: Bool,
        typeRef!: ?String, sigParams!: Array<UInt16> = Array<UInt16>(),
        sigParamNames!: Array<String> = Array<String>(), sigRet!: UInt16 = LocalType.NONE,
        sigRetName!: String = '') {
        if (!isRegistrationLocalType(`type`)) {
            throw JitException(ErrCode.CALL_CONTRACT, -1, -1, None,
                '字段「${name}」的类型码非法: ${`type`}（M2 允许 0–14，§12.2）')
        }
        if (sigParams.size != sigParamNames.size) {
            throw JitException(ErrCode.CALL_CONTRACT, -1, -1, None,
                '字段「${name}」的签名类名个数与形参个数不符: ${sigParamNames.size} / ${sigParams.size}')
        }
        this.name = name
        this.`type` = `type`
        this.index = index
        this.mutable = mutable
        this.typeRef = typeRef
        this.sigParams = sigParams.clone()
        this.sigParamNames = sigParamNames.clone()
        this.sigRet = sigRet
        this.sigRetName = sigRetName
    }

    /** 该字段是否带完整函数签名（13 型且形参类别已给出）。 */
    public func hasSignature(): Bool {
        this.`type` == LocalType.HOST_CLOSURE && this.sigRet != LocalType.NONE
    }
}

/**
 * 方法项：`u.m(a…)` 的绑定目标（§12.1 包装模式的显式登记）。
 *
 * `bind` 的首参固定为该类（LocalType 14），签名 `(C, T…) -> R`；本类型在构造期
 * 强制这一契约，避免把普通预定义函数误登记为方法。
 */
public class PublicMethod {
    public let name: String
    public let bind: PredefinedFunction

    public init(name!: String, bind!: PredefinedFunction) {
        if (bind.paramTypes.size == 0 || bind.paramTypes[0] != LocalType.HOST_OBJECT) {
            throw JitException(ErrCode.CALL_CONTRACT, -1, -1, None,
                '方法「${name}」的 bind 首参必须为该类（LocalType 14，§12.4）')
        }
        this.name = name
        this.bind = bind
    }
}

/**
 * 构造器项：对外签名 `(T1,…,Tn) -> C`，执行体按 `(Array<Any>) -> Any` 承载。
 *
 * 实参以已解包的仓颉值装箱传入，返回值须为 C 实例（与 `PredefinedFunction.impl`
 * 同一约定）。适配器异常 → 21、防御性失败 → 99，由调用方（构造降低 / H 通道）处理。
 */
public class PublicCtor {
    /** 形参类型序列（重载解析；含 14 → 嵌套构造）。 */
    public let params: Array<UInt16>

    /** 构造执行体（宿主侧；反射自动生成或手工注册，语义等价）。 */
    public let adapter: (Array<Any>) -> Any

    public init(params!: Array<UInt16>, adapter!: (Array<Any>) -> Any) {
        for (t in params) {
            let ok = (t <= LocalType.RANGE) || (t == LocalType.LIST) || (t == LocalType.MAP) ||
                (t == LocalType.HOST_CLOSURE) || (t == LocalType.HOST_OBJECT)
            if (!ok) {
                throw JitException(ErrCode.CALL_CONTRACT, -1, -1, None,
                    '构造器形参类型码非法: ${t}（M2 允许 0–8/10–11/13/14，§15）')
            }
        }
        this.params = params.clone()
        this.adapter = adapter
    }
}

/**
 * 类注册描述符：`name` + 字段表 + 方法绑定表 + 构造器表（§12.4 最小注册表、§15 扩展）。
 *
 * **快照语义**：构造时对三个数组做防御性拷贝，入参数组或其它描述符的后续变更不会
 * 反向影响本实例（与 §8.4 注册表快照语义一致）。
 */
public class ClassDescriptor {
    /** 注册类名（源语言可作类型注解；未注册 → 编译错误）。 */
    public let name: String

    /** 实例字段表（name → index/type/mutable/typeRef）。 */
    public let fields: Array<PublicField>

    /** 方法绑定表（`u.m(a…)` → 预定义调用）。 */
    public let methods: Array<PublicMethod>

    /** 构造器表（`C(args…)` 重载解析）。 */
    public let ctors: Array<PublicCtor>

    /**
     * 祖先类名链（M2.2）：**直接父类在前**，逐级到 `Object`，不含自身。
     *
     * 只为「静态子类型判定」而存在（`E as T ?? F` 的合法性检查）。前端**不据此做成员解析**
     * ——成员查找仍只查本类条目（v0.8.31）。手工注册的类若不填，则该类只与自身同型。
     */
    public let parents: Array<String>

    public init(name!: String, fields!: Array<PublicField>, methods!: Array<PublicMethod>,
        ctors!: Array<PublicCtor>, parents!: Array<String> = Array<String>()) {
        this.name = name
        this.fields = fields.clone()
        this.methods = methods.clone()
        this.ctors = ctors.clone()
        this.parents = parents.clone()
    }
}
