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

import fountain::f_jit.base.SourcePos

/**
 * 语法树（S3.7）——design-m1 §4.3.2（`AstExpr` / `AstStmt` / `LambdaAst` / `ParamAst` / `TypeRef`）。
 *
 * **形态**：`AstExpr` / `AstStmt` 用 **enum**（只带载荷构造器、可递归定义、做穷尽 `match`）；
 * `LambdaAst` / `ParamAst` 用 **struct**（记录型骨架、值语义、无身份）。
 * 可选类型一律前缀 `?T`（仓颉**没有** `T?` 后缀写法）；数组一律 `Array<T>`；
 * 构造器参数**按位置**书写（仓颉 enum 构造器不支持参数名）——含义见各构造器的文档行。
 *
 * **与设计稿的形态偏差（显式记录，走 `opsx-update` 前不改设计）**：
 *
 * `pos` 以**末位显式参数**承载，而不是「隐式的节点属性」。理由：仓颉 enum 构造器不支持在
 * 构造器列表之外追加公共字段，**构造器的载荷就是全部可携带数据**——要在穷尽 `match` 的模型里
 * 落实「行信息不丢」（设计 §4.3.2 位置链：Token → AST → SET_SITE → 站点表 → 运行期报告），
 * 只能把 `SourcePos` 放进载荷。除此之外构造器形状（参数序）与设计稿逐项一致。
 *
 * 另一处微扩展：`AstStmt` 增 `Break` / `Continue`（§5 降低模式必有，设计稿构造器清单未列）；
 * `AstExpr` 增 `Index`（附 A.6「容器索引读」的承载）与保留 M2 的 `MemberName`。
 */

/**
 * 类型注解节点（design §4.3.2：M1 仅 `Builtin`；M2 追加宿主闭包 / 宿主对象，M3 追加 `Any`）。
 *
 * `HostClosureT` 的载荷按位置 = `(params, ret)`（仓颉 enum 构造器不支持参数名）；
 * `HostObjectT` 的载荷 = 注册类名。`HostClosureT` 的 T/R 已由解析器按
 * `jit-bytecode-m2 §3` 校验（0–8/10–11/14 与 M3 的 15，禁高阶）。
 *
 * **M3 追加的三个构造器**：
 * - `AnyT`（15）：盒类型。与 `Builtin(15)` 等值，但**单列**——15 在声明面有多处专属禁令
 *   （不得作 HostObject 字段类型、不得作 `any_box` 的目标、不得二次装箱），单列让这些判定
 *   不必靠「魔法数字 15」来猜意图；
 * - `ListOf` / `MapOf`：容器**元素/键值类型**（m3 §3「异构容器」）。字节码类型表仍只记大类
 *   10/11（§11.7 不变），元素类型是**前端的并行静态知识**，只为两件事存在：异构容器元素
 *   写入点的装箱发射（m3 §3 第 ④ 类插入点）与元素读的静态类型。
 */
internal enum TypeRef {
    /**
     * 内建类型码：值 = `LocalType` 码（§11.7）。
     *
     * 只用于**无类型实参**的内建类型（标量、`Closure`、`Regex` 等）与 JSON 谱系码 16–19。
     * 容器走 `ListOf` / `MapOf`（见下），因为它们必须携带元素/键值类型。
     */
    | Builtin(UInt16)

    /** `Any`（`LocalType.ANY = 15`）：装箱搬运类型，见 `jit-bytecode-m3 §1/§3`。 */
    | AnyT

    /** `List<T>`：`T` 为元素类型注解（可为 `AnyT` / `Builtin` / 嵌套容器 / 宿主类）。 */
    | ListOf(TypeRef)

    /** `Map<K, V>`：键值类型注解。 */
    | MapOf(TypeRef, TypeRef)

    /**
     * 宿主闭包函数类型 `(T1, …, Tn) -> R`。
     *
     * 载荷按位置 = `(params, paramNames, ret, retName)`（仓颉 enum 构造器不支持参数名）：
     * - `params` / `ret`：`LocalType` 码；
     * - `paramNames` / `retName`：14 位置的**具体类名**，其余位置为空串。
     *
     * 类名必须进 AST：`(User) -> R` 与 `(Order) -> R` 的码完全相同（都是 `[14] -> R`），
     * 只凭码无法把两个签名分开——签名注册表（`JitHost.registerSignature`）按「码 + 类名」
     * 查 id，前端因此必须保留类名（GAP-04/GAP-05 的共同前提）。
     */
    | HostClosureT(Array<UInt16>, Array<String>, UInt16, String)

    /** 已注册类名（opaque 形参/局部/返回；LocalType 14）。 */
    | HostObjectT(String)

    /** 类型注解 → `LocalType` 码（降低阶段读形参/声明的静态类型）。 */
    public func code(): UInt16 {
        match (this) {
            case Builtin(c) => c
            case AnyT => 15u16
            case ListOf(_) => 10u16
            case MapOf(_, _) => 11u16
            case HostClosureT(_, _, _, _) => 13u16
            case HostObjectT(_) => 14u16
        }
    }

    /** 容器元素类型码（`List<T>` 的 T、`Map<K,V>` 的 V）；非容器或无实参 → `NONE`。 */
    public func elemCode(): UInt16 {
        match (this) {
            case ListOf(t) => t.code()
            case MapOf(_, v) => v.code()
            case _ => 0xFFFFu16
        }
    }

    /** 容器键类型码（仅 `Map<K,V>` 的 K）；其余 → `NONE`。 */
    public func keyCode(): UInt16 {
        match (this) {
            case MapOf(k, _) => k.code()
            case _ => 0xFFFFu16
        }
    }

    /** HostClosure 的返回码；其余 → `LocalType.NONE`。 */
    public func hostRet(): UInt16 {
        match (this) {
            case HostClosureT(_, _, r, _) => r
            case _ => 0xFFFFu16
        }
    }

    /** HostClosure 的形参类别序列；其余 → 空。 */
    public func hostParams(): Array<UInt16> {
        match (this) {
            case HostClosureT(p, _, _, _) => p
            case _ => Array<UInt16>()
        }
    }

    /** HostClosure 的形参类名序列（非 14 位置为空串）；其余 → 空。 */
    public func hostParamNames(): Array<String> {
        match (this) {
            case HostClosureT(_, n, _, _) => n
            case _ => Array<String>()
        }
    }

    /** HostClosure 的返回类名（`ret == 14` 时有值，否则空串）。 */
    public func hostRetName(): String {
        match (this) {
            case HostClosureT(_, _, _, rn) => rn
            case _ => ''
        }
    }

    /** HostObject 的类名；其余 → None。 */
    public func objectName(): ?String {
        match (this) {
            case HostObjectT(n) => Some(n)
            case _ => None
        }
    }
}

/** 形参：`name` + 类型注解 + 槽位（`locals[slot]`）+ 位置。 */
internal struct ParamAst {
    public let name: String
    public let typeAnn: TypeRef
    public let slot: Int64
    public let pos: SourcePos

    public init(name: String, typeAnn: TypeRef, slot: Int64, pos: SourcePos) {
        this.name = name
        this.typeAnn = typeAnn
        this.slot = slot
        this.pos = pos
    }
}

/**
 * lambda 骨架：`params`（可为空）+ 语句序列 + **尾表达式**（隐式返回）。
 *
 * §8.0「返回值 = 闭包体执行的最后一个表达式的值」。
 */
internal struct LambdaAst {
    public let params: Array<ParamAst>
    public let body: Array<AstStmt>
    public let retExpr: ?AstExpr
    public let pos: SourcePos

    public init(params: Array<ParamAst>, body: Array<AstStmt>, retExpr: ?AstExpr, pos: SourcePos) {
        this.params = params
        this.body = body
        this.retExpr = retExpr
        this.pos = pos
    }
}

/**
 * 表达式节点。
 *
 * 参数序（与设计稿一致，**末位为位置**）：`Lit`(token) / `Var`(name) / `Binary`(op, l, r) /
 * `Unary`(op, x) / `IfExpr`(cond, thenE, elseE) / `Call`(target, args) / `Closure`(lambda) /
 * `IIFE`(closure, args) / `Interp`(parts) / `StrAdd`(l, r) / `RegexOp`(kind, re, s, r, n, m) /
 * `RangeLit`(start, end, step, isClosed) / `ListLit`(elems, isEmpty) / `MapLit`(pairs, isEmpty) /
 * `TupleLit`(elems) / `RecursiveValue` / `Index`(target, index) / `MemberName`(name)。
 */
internal enum AstExpr {
    /** 字面量 token：`IntLit` / `DecLit` / `F64Lit` / `RegexLit` / 无插值 `StrLit` / `true` `false` `null`。 */
    | Lit(Token, SourcePos)
    /** 变量引用（普通局部 / 参数 / 闭包捕获。名字解析后。 */
    | Var(String, SourcePos)
    /** 二元运算：`op` ∈ 算术 / 比较 / 位 / 移位 / 逻辑确定性运算。 */
    | Binary(TokenKind, AstExpr, AstExpr, SourcePos)
    /** 一元运算：`Minus`（取负） / `Bang`（逻辑非） / `Tilde`（位取反）。 */
    | Unary(TokenKind, AstExpr, SourcePos)
    /** **值用法** if（仓颉语义：必须有 else）。 */
    | IfExpr(AstExpr, AstExpr, AstExpr, SourcePos)
    /** 调用：`target` 为被调用 Callee（闭包值或 builtin 名），`args` 从左到右求值。 */
    | Call(AstExpr, Array<AstExpr>, SourcePos)
    /** 闭包表达式（求值 = `closure_new`，§8.6）。 */
    | Closure(LambdaAst, SourcePos)
    /** 立即调用 IIFE：`closure(args)`，不经过任何绑定名（§8.5）。 */
    | IIFE(AstExpr, Array<AstExpr>, SourcePos)
    /**
     * 插值串：**偶数下标 = 文本片段**（`Lit`），**奇数下标 = 表达式片段**；
     * 文本片段也可能为空（`"${x}"` ⇒ 首尾两个空文本片段），保证交替关系恒定（S3.12 端据此折叠）。
     */
    | Interp(Array<AstExpr>, SourcePos)
    /** String 混合加法的显式承载（一侧静态为 String 时由解析器产出，§11.9 v0.18.15）。 */
    | StrAdd(AstExpr, AstExpr, SourcePos)
    /**
     * 正则操作符：`Tilde` / `BangTilde` → `REGEX_IS_MATCH`（后者加 `NOT_B`）；
     * `Slash` → 替换三形（`r` 必存在；`n` 缺省且无 `m` ⇒ `/g`；`n` 有值 ⇒ 第 n 个；`m` 有值 ⇒ 区间）。
     */
    | RegexOp(TokenKind, AstExpr, AstExpr, ?AstExpr, ?Int64, ?Int64, SourcePos)
    /** 区间字面量 `a..b(:s)` / `a..=b(:s)`：`isClosed` 由 `..=` 决定。 */
    | RangeLit(AstExpr, AstExpr, ?AstExpr, Bool, SourcePos)
    /** 列表字面量：`isEmpty` 为真时走运行期构造（§3.3 v0.18），否则走常量路径。 */
    | ListLit(Array<AstExpr>, Bool, SourcePos)
    /** 映射字面量，同 `ListLit` 的两形态。 */
    | MapLit(Array<(AstExpr, AstExpr)>, Bool, SourcePos)
    /** 一维元组字面量：**不可作为值传递**，仅多重赋值的 RHS 形态（§5 降低模式）。 */
    | TupleLit(Array<AstExpr>, SourcePos)
    /** `recursive` 作右值（值化自引用闭包，§8.0 v0.12）。 */
    | RecursiveValue(SourcePos)
    /** 容器 / 字符串下标读（`list[i]`、`map[k]`、`s[a..b]` 的索引形态）。 */
    | Index(AstExpr, AstExpr, SourcePos)
    /** 索引赋值目标（容器变更：`list[i] = v` / `map[k] = v`，§9.15；仅语句位置）。 */
    | IndexTarget(AstExpr, AstExpr, SourcePos)
    /** M1 成员访问的预留位（M2 解析器改为产出 `FieldGet`；保留供旧路径/诊断）。 */
    | MemberName(String, AstExpr, SourcePos)
    /** M2 成员读 `u.f`（m2 §12.4）：参数序 = obj, field。 */
    | FieldGet(AstExpr, String, SourcePos)
    /** M2 成员写 `u.f = v`：参数序 = obj, field, value（表达式形态返回 Unit）。 */
    | FieldSet(AstExpr, String, AstExpr, SourcePos)
    /** M2 成员调用 `u.m(a…)`：参数序 = obj, method, args。 */
    | MethodCall(AstExpr, String, Array<AstExpr>, SourcePos)
    /** M2 构造 `C(args…)`：参数序 = className, args。 */
    | CtorCall(String, Array<AstExpr>, SourcePos)
    /**
     * 收窄转型 `E as T` / `E as T ?? V`：参数序 = expr, 目标类型, 兜底（可缺省）。
     *
     * **静态能定的不查运行期**：`E` 的静态类型已是 `T` 或其子类 ⇒ 直接取 `E`（零动作）。
     * 其余可判定相容的情形（下转型、类名未跟踪但两侧都是 14）⇒ 运行期按类判定：
     * 命中取 `E`；`as T`（无兜底）失败报错 `BAD_CAST`，`as T ?? V` 失败取 `V`。
     * 与 `T` 不相容、`T` 为函数类型 ⇒ 编译期报错。判定见 `Lowerer.lowerCastOr`。
     */
    | CastOr(AstExpr, TypeRef, ?AstExpr, SourcePos)

    /**
     * 类型问答 `E is T`（m3 §3）：参数序 = expr, 目标类型。
     *
     * 左值静态类型为 15 ⇒ 运行期 `any_is`（H79）；左值非 15 ⇒ **静态判定**（同型 / 上行 →
     * 常量 true；不相容 → 编译错误），不发射 helper。结果静态类型恒为 Bool。
     */
    | IsType(AstExpr, TypeRef, SourcePos)

    /**
     * JSON 字面量（m3 §11）：载荷 = `(原文, 静态类型码)`。
     *
     * 静态类型码在**解析期**由体首非空白字符决定：`{` ⇒ `JSON_OBJECT(17)`、`[` ⇒
     * `JSON_ARRAY(18)`；标量顶层（数字/字符串/`true`/`false`/`null`）在解析期即编译错误
     * （m3 §12-8①：标量只作元素）。原文进常量（kind 11）或经 H83 构造，见 `lowerJsonLit`。
     */
    | JsonLit(String, UInt16, SourcePos)

    /** 位置（驱动 `setSite` 与编译期诊断；design §4.3.2）。 */
    public func pos(): SourcePos {
        match (this) {
            case Lit(_, p) => p
            case Var(_, p) => p
            case Binary(_, _, _, p) => p
            case Unary(_, _, p) => p
            case IfExpr(_, _, _, p) => p
            case Call(_, _, p) => p
            case Closure(_, p) => p
            case IIFE(_, _, p) => p
            case Interp(_, p) => p
            case StrAdd(_, _, p) => p
            case RegexOp(_, _, _, _, _, _, p) => p
            case RangeLit(_, _, _, _, p) => p
            case ListLit(_, _, p) => p
            case MapLit(_, _, p) => p
            case TupleLit(_, p) => p
            case RecursiveValue(p) => p
            case Index(_, _, p) => p
            case IndexTarget(_, _, p) => p
            case MemberName(_, _, p) => p
            case FieldGet(_, _, p) => p
            case FieldSet(_, _, _, p) => p
            case MethodCall(_, _, _, p) => p
            case CtorCall(_, _, p) => p
            case CastOr(_, _, _, p) => p
            case IsType(_, _, p) => p
            case JsonLit(_, _, p) => p
        }
    }
}

/**
 * 语句节点。参数序：`Decl`(name, typeAnn, init) / `Assign`(lhs, rhs) /
 * `MultiAssign`(lhs, rhs) / `If`(cond, thenS, elseS) / `While`(cond, body) /
 * `ForIn`(binding, iterable, where, body) / `Return`(value) / `ExprStmt`(e) / `Block`(stmts) /
 * `Break` / `Continue`（末位均为位置）。
 */
internal enum AstStmt {
    /** 声明即首写（明确赋值起点，§7 校验 10）。 */
    | Decl(String, ?TypeRef, ?AstExpr, SourcePos)
    | Assign(AstExpr, AstExpr, SourcePos)
    /** 多重赋值：LHS 槽可用 `_`（对应 RHS 仍求值后丢弃，§5 降低模式）。 */
    | MultiAssign(Array<AstExpr>, Array<AstExpr>, SourcePos)
    /** **语句用法** if：`elseS` 可缺省（仓颉允许裸 if）。 */
    | If(AstExpr, AstStmt, ?AstStmt, SourcePos)
    | While(AstExpr, AstStmt, SourcePos)
    /** `for (x in iterable where cond)`：Map 双绑定时 `binding` 为两个名字。 */
    | ForIn(Array<String>, AstExpr, ?AstExpr, AstStmt, SourcePos)
    | Return(?AstExpr, SourcePos)
    | ExprStmt(AstExpr, SourcePos)
    | Block(Array<AstStmt>, SourcePos)
    /** `break` = `JMP end`（§5 降低模式；AST 层需独立节点才能做标签绑定）。 */
    | Break(SourcePos)
    /** `continue` = `JMP` 至回边之前（保证每轮回边都经过安全点）。 */
    | Continue(SourcePos)

    /** 位置。 */
    public func pos(): SourcePos {
        match (this) {
            case Decl(_, _, _, p) => p
            case Assign(_, _, p) => p
            case MultiAssign(_, _, p) => p
            case If(_, _, _, p) => p
            case While(_, _, p) => p
            case ForIn(_, _, _, _, p) => p
            case Return(_, p) => p
            case ExprStmt(_, p) => p
            case Block(_, p) => p
            case Break(p) => p
            case Continue(p) => p
        }
    }
}
