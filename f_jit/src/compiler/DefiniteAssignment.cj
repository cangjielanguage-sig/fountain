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
import std.collection.HashMap
import fountain::f_jit.base.LocalType
import fountain::f_jit.base.SourcePos

/**
 * 明确赋值与空安全的数据流分析（S3.9）——design §4.3.4 / §7 校验 10 / §5「明确赋值分析与回边」。
 *
 * 三条硬规则（**全部在编译期**，违规 = 编译错误）：
 *
 * 1. **先写后读**：非参数局部在被读取的**所有可达路径**上必须已被 `STOREL` 显式写入
 *    （参数槽 `locals[0..nargs-1]` 由调用方赋值，天然满足）；
 * 2. **回边不动点**：循环（`while` 与经降低的 `for-in`）**不保证至少执行一轮** ⇒
 *    **仅**在循环体内 `STOREL` 的局部，在循环出口之后**一律不视为已赋值**；
 * 3. **空安全**：句柄型局部（LocalType 4–12）恒为有效句柄（≠0）⇒
 *    `PUSH_NULL`（`null` 字面值）**不得作为其赋值源直存**。
 *
 * **零值填充不可观察**（§3.1）：prologue 的卫生填充只为确定性，本分析保证填充值永不出现在
 * 可观察语义中——因此「读未赋值」必须**在编译期**被拒，不能推迟为运行期错误。
 *
 * 分析形态：**抽象解释 + 不动点迭代**。局部变量集合以「名字 → 是否已赋值」的稀疏表承载；
 * 分支汇合取**交集**（全部分支都赋值才算已赋值）；循环体以入口状态迭代至稳定，
 * 但**出口状态取入口状态**（不是体的出口状态）——这是规则 2 的直接兑现。
 */
internal class DefiniteAssignment {
    private let src: String
    /** 名字 → 声明类型（未声明 ⇒ `LocalType.NONE`）；句柄型判定依据。 */
    private let typeOf: (String) -> UInt16

    public init(source: String, typeOf: (String) -> UInt16) {
        this.src = Lexer.normalizeNewlines(source)
        this.typeOf = typeOf
    }

    // ------------------------------------------------------------------
    // 入口
    // ------------------------------------------------------------------

    /**
     * 分析一个函数的体（顶层 lambda 或嵌套闭包）。
     *
     * 参数槽视为入口已赋值（`locals[0..nargs-1]` 由调用方赋值，§11.7）。
     * 违规 → 抛 `SourceCompileException(kind=NotAssigned)`。
     */
    public func analyze(lambda: LambdaAst): Bool {
        var state = HashMap<String, Bool>()
        for (p in lambda.params) {
            state.add(p.name, true)
        }
        this.walkBlock(lambda.body, state)
        match (lambda.retExpr) {
            case Some(e) => this.walkExpr(e, state)
            case None => ()
        }
        true
    }

    // ------------------------------------------------------------------
    // 语句
    // ------------------------------------------------------------------

    private func walkBlock(stmts: Array<AstStmt>, state: HashMap<String, Bool>): Unit {
        for (s in stmts) {
            this.walkStmt(s, state)
        }
    }

    private func walkStmt(s: AstStmt, state: HashMap<String, Bool>): Unit {
        match (s) {
            case AstStmt.Decl(name, ty, initE, pos) =>
                match (initE) {
                    case Some(e) =>
                        // **先求值右侧**（右侧读取的变量必须此前已赋值），声明本身 = 首写
                        this.walkExpr(e, state)
                        this.checkNullStore(name, ty, e, pos)
                        state.add(name, true)
                    case None =>
                        // `var x: T` 无初始化：**声明 ≠ 赋值**（§5 / §7 校验 10）
                        state.add(name, false)
                }
            case AstStmt.Assign(lhs, rhs, pos) =>
                this.walkExpr(rhs, state)
                match (lhs) {
                    case AstExpr.Var(n, p) =>
                        if (n != '_') {
                            this.checkNullStore(n, None, rhs, pos)
                            state.add(n, true)
                        }
                    case AstExpr.IndexTarget(t, i, _) =>
                        // 容器变更：目标与下标都必须是**已赋值**的读取
                        this.walkExpr(t, state)
                        this.walkExpr(i, state)
                    case _ =>
                        this.walkExpr(lhs, state)
                }
            case AstStmt.MultiAssign(lhs, rhs, _) =>
                // RHS 从左到右求值（§5 降低模式）⇒ 全部读取发生在任何写入之前
                for (r in rhs) {
                    this.walkExpr(r, state)
                }
                for (l in lhs) {
                    match (l) {
                        case AstExpr.Var(n, _) =>
                            if (n != '_') {
                                state.add(n, true)
                            }
                        case _ => this.walkExpr(l, state)
                    }
                }
            case AstStmt.If(cond, thenS, elseS, _) =>
                this.walkExpr(cond, state)
                var thenState = DefiniteAssignment.clone(state)
                this.walkStmt(thenS, thenState)
                match (elseS) {
                    case Some(es) =>
                        var elseState = DefiniteAssignment.clone(state)
                        this.walkStmt(es, elseState)
                        // 汇合取交集：全部分支都赋值才算出口已赋值
                        DefiniteAssignment.intersectInto(state, thenState, elseState)
                    case None =>
                        // 裸 if：出口状态 = 入口状态（then 分支的赋值不向出口传播）
                        ()
                }
            case AstStmt.While(cond, body, _) =>
                this.walkExpr(cond, state)
                this.walkLoop(body, state)
            case AstStmt.ForIn(names, iterable, whereCond, body, _) =>
                this.walkExpr(iterable, state)
                // 绑定变量在体内的状态：入口已赋值（声明即首写）
                var bodyState = DefiniteAssignment.clone(state)
                for (n in names) {
                    bodyState.add(n, true)
                }
                match (whereCond) {
                    case Some(c) => this.walkExpr(c, bodyState)
                    case None => ()
                }
                this.walkStmt(body, bodyState)
                // 循环出口：体赋值不向出口传播（规则 2）
            case AstStmt.Return(v, _) =>
                match (v) {
                    case Some(e) => this.walkExpr(e, state)
                    case None => ()
                }
            case AstStmt.ExprStmt(e, _) => this.walkExpr(e, state)
            case AstStmt.Block(stmts, _) => this.walkBlock(stmts, state)
            case AstStmt.Break(_) => ()
            case AstStmt.Continue(_) => ()
        }
    }

    /**
     * 循环体：**入口状态 → 不动点**，出口取入口状态（循环不保证执行一轮）。
     *
     * 迭代的意义：体内的**读取**可能引用「体的上一轮写入」（例如 `while (c) { x = x + 1 }`
     * 中 `x` 的读取在体外已赋值时合法）；若体内先读后写且体外未赋值 ⇒ 仍会被拒绝。
     */
    private func walkLoop(body: AstStmt, state: HashMap<String, Bool>): Unit {
        var bodyState = DefiniteAssignment.clone(state)
        var guard: Int64 = 0
        while (guard < 8) {
            let before = DefiniteAssignment.snapshotKeys(bodyState)
            this.walkStmt(body, bodyState)
            let after = DefiniteAssignment.snapshotKeys(bodyState)
            if (DefiniteAssignment.sameKeys(before, after)) {
                break
            }
            guard = guard + 1
        }
    }

    // ------------------------------------------------------------------
    // 表达式
    // ------------------------------------------------------------------

    private func walkExpr(e: AstExpr, state: HashMap<String, Bool>): Unit {
        match (e) {
            case AstExpr.Lit(_, _) => ()
            case AstExpr.Var(n, pos) =>
                // `DateTime` / `Duration` 是内建构造命名空间（`DateTime.now()` 等），不是局部
                if (n == '_' || n == 'DateTime' || n == 'Duration') {
                    return
                }
                var assigned = false
                match (state.get(n)) {
                    case Some(v) => assigned = v
                    case None => assigned = false
                }
                if (!assigned) {
                    diagFail(DiagKind.NOT_ASSIGNED, this.src, 0, pos.line, pos.column,
                        '局部变量「${n}」在读取路径上未必已被赋值（§7 校验 10：循环出口不视为已赋值；' +
                        '局部无默认值，请在读取前显式赋值）')
                }
            case AstExpr.Binary(_, l, r, _) =>
                this.walkExpr(l, state)
                this.walkExpr(r, state)
            case AstExpr.Unary(_, x, _) => this.walkExpr(x, state)
            case AstExpr.IfExpr(c, t, f, _) =>
                this.walkExpr(c, state)
                this.walkExpr(t, state)
                this.walkExpr(f, state)
            case AstExpr.Call(t, args, pos) =>
                this.walkCallee(t, state, pos)
                for (a in args) {
                    this.walkExpr(a, state)
                }
            case AstExpr.Closure(lam, _) =>
                // 闭包体在**声明点**以当前状态分析（捕获 = 读取，§8.5）
                this.analyzeClosureAt(lam, state)
            case AstExpr.IIFE(c, args, _) =>
                this.walkExpr(c, state)
                for (a in args) {
                    this.walkExpr(a, state)
                }
            case AstExpr.Interp(parts, _) =>
                for (i in 0..parts.size) {
                    // 奇数下标 = 表达式片段；文本片段是 `Lit`，走同一入口无害
                    if (i % 2 == 1) {
                        this.walkExpr(parts[i], state)
                    }
                }
            case AstExpr.StrAdd(l, r, _) =>
                this.walkExpr(l, state)
                this.walkExpr(r, state)
            case AstExpr.RegexOp(_, re, s, r, _, _, _) =>
                this.walkExpr(re, state)
                this.walkExpr(s, state)
                match (r) {
                    case Some(rr) => this.walkExpr(rr, state)
                    case None => ()
                }
            case AstExpr.RangeLit(a, b, st, _, _) =>
                this.walkExpr(a, state)
                this.walkExpr(b, state)
                match (st) {
                    case Some(sv) => this.walkExpr(sv, state)
                    case None => ()
                }
            case AstExpr.ListLit(elems, _, _) =>
                for (x in elems) {
                    this.walkExpr(x, state)
                }
            case AstExpr.MapLit(pairs, _, _) =>
                for (kv in pairs) {
                    this.walkExpr(kv[0], state)
                    this.walkExpr(kv[1], state)
                }
            case AstExpr.TupleLit(elems, _) =>
                for (x in elems) {
                    this.walkExpr(x, state)
                }
            case AstExpr.RecursiveValue(_) => ()
            case AstExpr.Index(t, i, _) =>
                this.walkExpr(t, state)
                this.walkExpr(i, state)
            case AstExpr.IndexTarget(t, i, _) =>
                this.walkExpr(t, state)
                this.walkExpr(i, state)
            case AstExpr.MemberName(_, t, _) => this.walkExpr(t, state)
        }
    }

    /**
     * 被调用者：`recursive` / 预定义函数是名字而非局部；闭包变量必须是已赋值的局部。
     */
    private func walkCallee(t: AstExpr, state: HashMap<String, Bool>, pos: SourcePos): Unit {
        match (t) {
            case AstExpr.Var(n, _) =>
                // `recursive` 与数值转换内建（`Int64`/`Float64`/`Decimal`）是名字而非局部
                if (n == 'recursive' || n == 'Int64' || n == 'Float64' || n == 'Decimal') {
                    return
                }
            case _ => ()
        }
        this.walkExpr(t, state)
    }

    /** 闭包体：以**创建点**的状态分析（捕获即读取 ⇒ 声明后才首次赋值的变量被捕获 = 编译错误）。 */
    private func analyzeClosureAt(lam: LambdaAst, outer: HashMap<String, Bool>): Unit {
        var state = HashMap<String, Bool>()
        for (p in lam.params) {
            state.add(p.name, true)
        }
        // 捕获：体对外层名的读取，按创建点的状态校验（读取集由本方法内的 walkExpr 完成）
        this.walkBlockWithOuter(lam.body, state, outer)
        match (lam.retExpr) {
            case Some(e) => this.walkExprWithOuter(e, state, outer)
            case None => ()
        }
    }

    private func walkBlockWithOuter(stmts: Array<AstStmt>, state: HashMap<String, Bool>,
        outer: HashMap<String, Bool>): Unit {
        for (s in stmts) {
            this.walkStmtWithOuter(s, state, outer)
        }
    }

    /** 体内读取：命中内层局部用内层状态，否则**按外层创建点状态校验**（捕获未赋值 ⇒ 拒绝）。 */
    private func walkExprWithOuter(e: AstExpr, state: HashMap<String, Bool>, outer: HashMap<String, Bool>): Unit {
        match (e) {
            case AstExpr.Var(n, pos) =>
                match (state.get(n)) {
                    case Some(_) => ()
                    case None =>
                        var ok = false
                        match (outer.get(n)) {
                            case Some(v) => ok = v
                            case None => ok = false
                        }
                        if (!ok) {
                            diagFail(DiagKind.NOT_ASSIGNED, this.src, 0, pos.line, pos.column,
                                '闭包捕获的变量「${n}」在闭包创建点未必已被赋值（§8.5：捕获 = 创建时刻的值快照）')
                        }
                }
            case AstExpr.Closure(inner, _) =>
                this.analyzeClosureAt(inner, DefiniteAssignment.merge(state, outer))
            case AstExpr.Binary(_, l, r, _) =>
                this.walkExprWithOuter(l, state, outer)
                this.walkExprWithOuter(r, state, outer)
            case AstExpr.Unary(_, x, _) => this.walkExprWithOuter(x, state, outer)
            case AstExpr.IfExpr(c, th, el, _) =>
                this.walkExprWithOuter(c, state, outer)
                this.walkExprWithOuter(th, state, outer)
                this.walkExprWithOuter(el, state, outer)
            case AstExpr.Call(tg, args, _) =>
                this.walkExprWithOuter(tg, state, outer)
                for (a in args) {
                    this.walkExprWithOuter(a, state, outer)
                }
            case AstExpr.IIFE(c, args, _) =>
                this.walkExprWithOuter(c, state, outer)
                for (a in args) {
                    this.walkExprWithOuter(a, state, outer)
                }
            case AstExpr.Interp(parts, _) =>
                for (x in parts) {
                    this.walkExprWithOuter(x, state, outer)
                }
            case AstExpr.StrAdd(l, r, _) =>
                this.walkExprWithOuter(l, state, outer)
                this.walkExprWithOuter(r, state, outer)
            case AstExpr.RegexOp(_, re, s2, rp, _, _, _) =>
                this.walkExprWithOuter(re, state, outer)
                this.walkExprWithOuter(s2, state, outer)
                match (rp) {
                    case Some(x) => this.walkExprWithOuter(x, state, outer)
                    case None => ()
                }
            case AstExpr.RangeLit(a, b, c, _, _) =>
                this.walkExprWithOuter(a, state, outer)
                this.walkExprWithOuter(b, state, outer)
                match (c) {
                    case Some(x) => this.walkExprWithOuter(x, state, outer)
                    case None => ()
                }
            case AstExpr.ListLit(es, _, _) =>
                for (x in es) {
                    this.walkExprWithOuter(x, state, outer)
                }
            case AstExpr.MapLit(ps, _, _) =>
                for (kv in ps) {
                    this.walkExprWithOuter(kv[0], state, outer)
                    this.walkExprWithOuter(kv[1], state, outer)
                }
            case AstExpr.TupleLit(es, _) =>
                for (x in es) {
                    this.walkExprWithOuter(x, state, outer)
                }
            case AstExpr.Index(tg, i, _) =>
                this.walkExprWithOuter(tg, state, outer)
                this.walkExprWithOuter(i, state, outer)
            case AstExpr.MemberName(_, tg, _) => this.walkExprWithOuter(tg, state, outer)
            case _ => this.walkExpr(e, state)
        }
    }

    private func walkStmtWithOuter(s: AstStmt, state: HashMap<String, Bool>, outer: HashMap<String, Bool>): Unit {
        match (s) {
            case AstStmt.Decl(name, _, initE, _) =>
                match (initE) {
                    case Some(e) =>
                        this.walkExprWithOuter(e, state, outer)
                        state.add(name, true)
                    case None => state.add(name, false)
                }
            case AstStmt.Assign(lhs, rhs, _) =>
                this.walkExprWithOuter(rhs, state, outer)
                match (lhs) {
                    case AstExpr.Var(n, _) => state.add(n, true)
                    case _ => this.walkExprWithOuter(lhs, state, outer)
                }
            case AstStmt.Block(stmts, _) => this.walkBlockWithOuter(stmts, state, outer)
            case AstStmt.ExprStmt(e, _) => this.walkExprWithOuter(e, state, outer)
            case AstStmt.Return(v, _) =>
                match (v) {
                    case Some(e) => this.walkExprWithOuter(e, state, outer)
                    case None => ()
                }
            case AstStmt.If(c, t, f, _) =>
                this.walkExprWithOuter(c, state, outer)
                this.walkStmtWithOuter(t, state, outer)
                match (f) {
                    case Some(fs) => this.walkStmtWithOuter(fs, state, outer)
                    case None => ()
                }
            case AstStmt.While(c, b, _) =>
                this.walkExprWithOuter(c, state, outer)
                this.walkStmtWithOuter(b, state, outer)
            case _ => this.walkStmt(s, state)
        }
    }

    // ------------------------------------------------------------------
    // 空安全：`PUSH_NULL` 不得直存句柄型槽
    // ------------------------------------------------------------------

    /**
     * 空安全（§3.1 / §7 校验 10）：`null` 字面值**不得**作为句柄型局部的赋值源直存
     * ——句柄型局部恒为有效句柄（≠0），M1 的 null 只存在于互操作边界与栈上瞬态值。
     */
    private func checkNullStore(name: String, ty: ?TypeRef, initE: AstExpr, pos: SourcePos): Unit {
        match (initE) {
            case AstExpr.Lit(t, _) =>
                if (t.kind != TokenKind.KwNull) {
                    return
                }
            case _ => return
        }
        var code = LocalType.NONE
        match (ty) {
            case Some(v) =>
                match (v) {
                    case TypeRef.Builtin(c) => code = c
                }
            case None => code = this.typeOf(name)
        }
        if (code != LocalType.NONE && LocalType.isHandle(code)) {
            diagFail(DiagKind.NOT_ASSIGNED, this.src, 0, pos.line, pos.column,
                'null 不得直存句柄型局部「${name}」（§3.1 空安全：句柄型局部恒为有效句柄 ≠ 0；' +
                'M1 的 null 只存在于互操作边界与栈上瞬态值）')
        }
    }

    // ------------------------------------------------------------------
    // 集合小工具（HashMap<String, Bool>）
    // ------------------------------------------------------------------

    private static func clone(s: HashMap<String, Bool>): HashMap<String, Bool> {
        var out = HashMap<String, Bool>()
        for ((k, v) in s) {
            out.add(k, v)
        }
        out
    }

    /** 汇合取交集：两个分支都赋值才算出口已赋值。 */
    private static func intersectInto(target: HashMap<String, Bool>, a: HashMap<String, Bool>,
        b: HashMap<String, Bool>): Unit {
        for ((k, _) in a) {
            var inB = false
            match (b.get(k)) {
                case Some(v) => inB = v
                case None => inB = false
            }
            target.add(k, inB)
        }
    }

    private static func merge(a: HashMap<String, Bool>, b: HashMap<String, Bool>): HashMap<String, Bool> {
        var out = DefiniteAssignment.clone(a)
        for ((k, v) in b) {
            match (out.get(k)) {
                case Some(_) => ()
                case None => out.add(k, v)
            }
        }
        out
    }

    /** 不动点判据：键集与取值都不再变化。 */
    private static func snapshotKeys(s: HashMap<String, Bool>): Array<String> {
        var out = ArrayList<String>()
        for ((k, v) in s) {
            if (v) {
                out.add(k)
            }
        }
        out.toArray()
    }

    private static func sameKeys(a: Array<String>, b: Array<String>): Bool {
        if (a.size != b.size) {
            return false
        }
        for (x in a) {
            var found = false
            for (y in b) {
                if (x == y) {
                    found = true
                }
            }
            if (!found) {
                return false
            }
        }
        true
    }
}
