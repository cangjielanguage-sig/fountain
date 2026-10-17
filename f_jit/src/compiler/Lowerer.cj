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
import std.convert.*
import fountain::f_base.UnsafeBytes
import fountain::f_jit.base.LocalType
import fountain::f_jit.base.SourcePos
import fountain::f_jit.bytecode.ConstRegistry
import fountain::f_jit.bytecode.LocalTypes

/** 降低阶段的变量符号：名字 + 槽号 + 静态类型（字节码只记大类，§11.7）。 */
internal class VarSym {
    public let name: String
    public let slot: Int64
    public let ty: UInt16

    public init(name: String, slot: Int64, ty: UInt16) {
        this.name = name
        this.slot = slot
        this.ty = ty
    }
}

/** 单函数的降低上下文（design-m1 §4.3.5 / §4.3.10）。 */
internal class FnCtx {
    public let fnId: UInt32
    public let builder: BytecodeBuilder
    public let isClosure: Bool
    public let parent: ?FnCtx
    public let scopes: ArrayList<ArrayList<VarSym>>
    public let breakLabels: ArrayList<Int64>
    public let continueLabels: ArrayList<Int64>
    public let entryLabel: Int64
    public let captures: ArrayList<VarSym>

    public init(fnId: UInt32, builder: BytecodeBuilder, isClosure: Bool, parent: ?FnCtx) {
        this.fnId = fnId
        this.builder = builder
        this.isClosure = isClosure
        this.parent = parent
        this.scopes = ArrayList<ArrayList<VarSym>>()
        this.breakLabels = ArrayList<Int64>()
        this.continueLabels = ArrayList<Int64>()
        this.entryLabel = builder.newLabel()
        this.captures = ArrayList<VarSym>()
        this.scopes.add(ArrayList<VarSym>())
    }

    public func pushScope(): Unit {
        this.scopes.add(ArrayList<VarSym>())
    }

    public func popScope(): Unit {
        this.scopes.remove(at: this.scopes.size - 1)
    }

    public func declare(sym: VarSym, pos: SourcePos, src: String): Unit {
        let top = this.scopes[this.scopes.size - 1]
        for (s in top) {
            if (s.name == sym.name) {
                diagFail(DiagKind.SYNTAX_ERROR, src, 0, pos.line, pos.column,
                    '同一作用域重复定义「${sym.name}」')
            }
        }
        top.add(sym)
    }

    public func find(name: String): ?VarSym {
        var i = this.scopes.size - 1
        while (i >= 0) {
            for (s in this.scopes[i]) {
                if (s.name == name) {
                    return Some(s)
                }
            }
            i = i - 1
        }
        None
    }
}

/**
 * AST → 字节码（design-m1 §4.3.5；规格 §5 / §8.5–8.6 / §11.9）。
 *
 * 类型口径：类型表只记大类（§11.7），容器元素类型不入表；下标读按期望类型推导。
 */
internal class Lowerer {
    private let sess: CompileSession
    private let resolver: NameResolver
    private let src: String
    private var ctx: ?FnCtx = None
    private var entryFn: UInt32 = 0u32
    private var topParamTypes: Array<UInt16> = Array<UInt16>()
    private var topRetType: UInt16 = LocalType.I64
    private let closureRets = ArrayList<(UInt32, UInt16)>()
    /** 待排序的名字表条目（NameTable 要求按 (fnId, slot) 严格升序）。 */
    private let pendingNames = ArrayList<(UInt32, Int64, String)>()

    public init(sess: CompileSession, resolver: NameResolver) {
        this.sess = sess
        this.resolver = resolver
        this.src = sess.source
    }

    public func lowerTop(lambda: LambdaAst): UInt32 {
        let fnId = this.sess.newFnId()
        this.sess.entryFn = fnId
        this.entryFn = fnId
        this.topParamTypes = Lowerer.paramTypesOf(lambda)
        this.topRetType = Lowerer.retTypeOf(lambda)
        this.lowerLambda(lambda, fnId, None, ArrayList<String>(), lambda.params.size)
        this.flushNames()
        fnId
    }

    /** 按 `(fnId, slot)` 升序写入名字表（§11.6 稀疏名字段的顺序约束）。 */
    private func flushNames(): Unit {
        var arr = ArrayList<(UInt32, Int64, String)>()
        for (x in this.pendingNames) {
            arr.add(x)
        }
        var i = 1
        while (i < arr.size) {
            let cur = arr[i]
            var j = i - 1
            while (j >= 0) {
                let prev = arr[j]
                let gt = if (cur[0] == prev[0]) { cur[1] < prev[1] } else { cur[0] < prev[0] }
                if (gt) {
                    arr[j + 1] = prev
                    j = j - 1
                } else {
                    break
                }
            }
            arr[j + 1] = cur
            i = i + 1
        }
        for (x in arr) {
            this.sess.names.add(x[0], UInt32(x[1]), x[2])
        }
    }

    // ==================================================================
    // 函数级
    // ==================================================================

    private func lowerLambda(lambda: LambdaAst, fnId: UInt32, parent: ?FnCtx,
        captureNames: ArrayList<String>, nargs: Int64): Unit {
        let builder = BytecodeBuilder(fnId, this.sess.consts)
        let ctx = FnCtx(fnId, builder, parent.isSome(), parent)
        this.ctx = ctx
        ctx.builder.place(ctx.entryLabel)

        var base: Int64 = 0
        if (ctx.isClosure) {
            let _ = ctx.builder.allocSlot(LocalType.CLOSURE)
            base = 1
        }
        for (p in lambda.params) {
            let slot = ctx.builder.allocSlot(p.typeAnn.code())
            if (slot != base + Int64(ctx.scopes[0].size)) {
                codeFail('形参槽序错乱: ${slot} / ${base}')
            }
            ctx.scopes[0].add(VarSym(p.name, slot, p.typeAnn.code()))
            this.pendingNames.add((fnId, slot, p.name))
        }
        if (ctx.isClosure) {
            var i: Int64 = 0
            for (name in captureNames) {
                let outer = Lowerer.findIn(parent, name, this.src)
                let slot = ctx.builder.allocSlot(outer.ty)
                let sym = VarSym(name, slot, outer.ty)
                ctx.builder.emitU16(Op.LOAD_CAP, UInt16(i))
                ctx.builder.emitU16(Op.STOREL, UInt16(slot))
                ctx.captures.add(sym)
                ctx.scopes[0].add(sym)
                i = i + 1
            }
        }

        for (s in lambda.body) {
            this.lowerStmt(s)
        }
        match (lambda.retExpr) {
            case Some(e) =>
                let _ = this.lowerExprAs(e, this.fnRetType(ctx))
                ctx.builder.ret()
            case None => ctx.builder.retVoid()
        }
        let body = ctx.builder.finish()
        let types = this.typesOf(ctx)
        this.sess.addFunc(LoweredFunc(fnId, nargs, this.fnRetType(ctx), types, body,
            ctx.builder.pendingSites()))
        this.ctx = parent
    }

    private func typesOf(ctx: FnCtx): LocalTypes {
        let table = ctx.builder.slotTypeTable()
        let t = LocalTypes(Int64(table.size))
        for (i in 0..table.size) {
            t.set(i, UInt8(table[i]))
        }
        t
    }

    private func fnRetType(ctx: FnCtx): UInt16 {
        match (ctx.parent) {
            case None => this.topRetType
            case Some(_) => this.closureRetType(ctx.fnId)
        }
    }

    private func closureRetType(fnId: UInt32): UInt16 {
        for (p in this.closureRets) {
            if (p[0] == fnId) {
                return p[1]
            }
        }
        LocalType.I64
    }

    private func setClosureRetType(fnId: UInt32, t: UInt16): Unit {
        this.closureRets.add((fnId, t))
    }

    // ==================================================================
    // 语句
    // ==================================================================

    private func lowerStmt(s: AstStmt): Unit {
        let ctx = this.requireCtx()
        match (s) {
            case AstStmt.Decl(name, tyAnn, initE, pos) =>
                var declared: UInt16 = LocalType.NONE
                match (tyAnn) {
                    case Some(t) => declared = t.code()
                    case None => ()
                }
                var initTy: UInt16 = declared
                match (initE) {
                    case Some(e) => initTy = this.lowerExprAs(e, declared)
                    case None =>
                        if (declared == LocalType.NONE) {
                            diagFail(DiagKind.SYNTAX_ERROR, this.src, 0, pos.line, pos.column,
                                '无初始化的声明必须带类型注解（§11.7 局部类型）')
                        }
                }
                if (declared == LocalType.NONE) {
                    declared = initTy
                }
                if (declared == LocalType.NONE) {
                    diagFail(DiagKind.TYPE_MISMATCH, this.src, 0, pos.line, pos.column,
                        '无法推导局部「${name}」的类型')
                }
                let slot = ctx.builder.allocSlot(declared)
                ctx.builder.emitU16(Op.STOREL, UInt16(slot))
                ctx.declare(VarSym(name, slot, declared), pos, this.src)
                this.pendingNames.add((ctx.fnId, slot, name))
            case AstStmt.Assign(lhs, rhs, pos) => this.lowerAssign(lhs, rhs, pos)
            case AstStmt.MultiAssign(lhs, rhs, pos) => this.lowerMultiAssign(lhs, rhs, pos)
            case AstStmt.If(cond, thenS, elseS, _) =>
                let elseL = ctx.builder.newLabel()
                let endL = ctx.builder.newLabel()
                let _ = this.lowerExprAs(cond, LocalType.BOOL)
                ctx.builder.emitRel(Op.JZ, elseL)
                ctx.pushScope()
                this.lowerStmt(thenS)
                ctx.popScope()
                ctx.builder.emitRel(Op.JMP, endL)
                ctx.builder.place(elseL)
                match (elseS) {
                    case Some(e) =>
                        ctx.pushScope()
                        this.lowerStmt(e)
                        ctx.popScope()
                    case None => ()
                }
                ctx.builder.place(endL)
            case AstStmt.While(cond, body, _) =>
                let header = ctx.builder.newLabel()
                let endL = ctx.builder.newLabel()
                ctx.builder.place(header)
                let _ = this.lowerExprAs(cond, LocalType.BOOL)
                ctx.builder.emitRel(Op.JZ, endL)
                ctx.breakLabels.add(endL)
                ctx.continueLabels.add(header)
                ctx.pushScope()
                this.lowerStmt(body)
                ctx.popScope()
                ctx.breakLabels.remove(at: ctx.breakLabels.size - 1)
                ctx.continueLabels.remove(at: ctx.continueLabels.size - 1)
                ctx.builder.emitRel(Op.LOOP_BACK, header)
                ctx.builder.place(endL)
            case AstStmt.ForIn(binding, iterable, whereCond, body, _) =>
                this.lowerForIn(binding, iterable, whereCond, body)
            case AstStmt.Return(value, _) =>
                match (value) {
                    case Some(e) =>
                        if (this.tryLowerTailRecursive(e)) {
                            return
                        }
                        let _ = this.lowerExprAs(e, this.fnRetType(ctx))
                        ctx.builder.ret()
                    case None => ctx.builder.retVoid()
                }
            case AstStmt.ExprStmt(e, _) =>
                if (this.tryLowerTailRecursive(e)) {
                    return
                }
                let t = this.lowerExpr(e)
                if (t != LocalType.UNIT) {
                    ctx.builder.emit(Op.POP)
                }
            case AstStmt.Block(stmts, _) =>
                ctx.pushScope()
                for (st in stmts) {
                    this.lowerStmt(st)
                }
                ctx.popScope()
            case AstStmt.Break(_) =>
                if (ctx.breakLabels.size == 0) {
                    diagFail(DiagKind.SYNTAX_ERROR, this.src, 0, s.pos().line, s.pos().column,
                        'break 不在循环内')
                }
                ctx.builder.emitRel(Op.JMP, ctx.breakLabels[ctx.breakLabels.size - 1])
            case AstStmt.Continue(_) =>
                if (ctx.continueLabels.size == 0) {
                    diagFail(DiagKind.SYNTAX_ERROR, this.src, 0, s.pos().line, s.pos().column,
                        'continue 不在循环内')
                }
                ctx.builder.emitRel(Op.JMP, ctx.continueLabels[ctx.continueLabels.size - 1])
        }
    }

    private func lowerAssign(lhs: AstExpr, rhs: AstExpr, pos: SourcePos): Unit {
        let ctx = this.requireCtx()
        match (lhs) {
            case AstExpr.Var(name, vpos) =>
                let sym = this.requireVar(name, vpos)
                let _ = this.lowerExprAs(rhs, sym.ty)
                ctx.builder.emitU16(Op.STOREL, UInt16(sym.slot))
            case AstExpr.IndexTarget(target, index, _) =>
                let tt = this.lowerExpr(target)
                let _ = this.lowerExprAs(index, LocalType.I64)
                let _ = this.lowerExpr(rhs)
                if (tt == LocalType.LIST) {
                    ctx.builder.emit(Op.LIST_SET)
                } else if (tt == LocalType.MAP) {
                    ctx.builder.emit(Op.MAP_PUT)
                } else {
                    diagFail(DiagKind.TYPE_MISMATCH, this.src, 0, pos.line, pos.column,
                        '下标赋值的目标必须是 List 或 Map')
                }
                ctx.builder.emit(Op.POP)
            case _ =>
                diagFail(DiagKind.SYNTAX_ERROR, this.src, 0, pos.line, pos.column,
                    '赋值目标必须是局部变量或容器下标')
        }
    }

    private func lowerMultiAssign(lhs: Array<AstExpr>, rhs: Array<AstExpr>, pos: SourcePos): Unit {
        let ctx = this.requireCtx()
        if (lhs.size != rhs.size) {
            diagFail(DiagKind.SYNTAX_ERROR, this.src, 0, pos.line, pos.column,
                '多重赋值两侧个数不一致: ${lhs.size} / ${rhs.size}')
        }
        let tmpSlots = ArrayList<Int64>()
        for (r in rhs) {
            let t = this.lowerExpr(r)
            let slot = ctx.builder.allocSlot(t)
            ctx.builder.emitU16(Op.STOREL, UInt16(slot))
            tmpSlots.add(slot)
        }
        for (i in 0..lhs.size) {
            match (lhs[i]) {
                case AstExpr.Var(name, _) =>
                    if (name == '_') {
                        continue
                    }
                    let sym = this.requireVar(name, pos)
                    ctx.builder.emitU16(Op.LOADL, UInt16(tmpSlots[i]))
                    ctx.builder.emitU16(Op.STOREL, UInt16(sym.slot))
                case _ =>
                    diagFail(DiagKind.SYNTAX_ERROR, this.src, 0, pos.line, pos.column,
                        '多重赋值的左侧只能是局部变量或 _')
            }
        }
    }

    private func lowerForIn(binding: Array<String>, iterable: AstExpr, whereCond: ?AstExpr,
        body: AstStmt): Unit {
        let ctx = this.requireCtx()
        ctx.pushScope()
        let endL = ctx.builder.newLabel()
        let contL = ctx.builder.newLabel()
        ctx.breakLabels.add(endL)
        ctx.continueLabels.add(contL)
        let itTy = this.staticTypeOf(iterable)

        if (itTy == LocalType.RANGE) {
            match (iterable) {
                case AstExpr.RangeLit(start, endE, stepE, isClosed, _) =>
                    let iSlot = ctx.builder.allocSlot(LocalType.I64)
                    let eSlot = ctx.builder.allocSlot(LocalType.I64)
                    let sSlot = ctx.builder.allocSlot(LocalType.I64)
                    let _ = this.lowerExprAs(start, LocalType.I64)
                    ctx.builder.emitU16(Op.STOREL, UInt16(iSlot))
                    let _ = this.lowerExprAs(endE, LocalType.I64)
                    ctx.builder.emitU16(Op.STOREL, UInt16(eSlot))
                    match (stepE) {
                        case Some(se) => let _ = this.lowerExprAs(se, LocalType.I64)
                        case None => ctx.builder.emitI64(Op.PUSH_I64, 1)
                    }
                    ctx.builder.emitU16(Op.STOREL, UInt16(sSlot))
                    let header = ctx.builder.newLabel()
                    let negL = ctx.builder.newLabel()
                    let posL = ctx.builder.newLabel()
                    let condEndL = ctx.builder.newLabel()
                    ctx.builder.place(header)
                    ctx.builder.emitU16(Op.LOADL, UInt16(sSlot))
                    ctx.builder.emitI64(Op.PUSH_I64, 0)
                    ctx.builder.emit(Op.LT_I)
                    ctx.builder.emitRel(Op.JNZ, negL)
                    ctx.builder.place(posL)
                    ctx.builder.emitU16(Op.LOADL, UInt16(iSlot))
                    ctx.builder.emitU16(Op.LOADL, UInt16(eSlot))
                    ctx.builder.emit(if (isClosed) { Op.LE_I } else { Op.LT_I })
                    ctx.builder.emitRel(Op.JMP, condEndL)
                    ctx.builder.place(negL)
                    ctx.builder.emitU16(Op.LOADL, UInt16(iSlot))
                    ctx.builder.emitU16(Op.LOADL, UInt16(eSlot))
                    ctx.builder.emit(if (isClosed) { Op.GE_I } else { Op.GT_I })
                    ctx.builder.place(condEndL)
                    ctx.builder.emitRel(Op.JZ, endL)
                    if (binding.size != 1) {
                        diagFail(DiagKind.SYNTAX_ERROR, this.src, 0, 0, 0,
                            'Range 的 for-in 只能绑定一个变量')
                    }
                    let bSlot = ctx.builder.allocSlot(LocalType.I64)
                    ctx.builder.emitU16(Op.LOADL, UInt16(iSlot))
                    ctx.builder.emitU16(Op.STOREL, UInt16(bSlot))
                    ctx.declare(VarSym(binding[0], bSlot, LocalType.I64), SourcePos(0, 0), this.src)
                    this.pendingNames.add((ctx.fnId, bSlot, binding[0]))
                    this.lowerWhereAndBody(whereCond, body, contL)
                    ctx.builder.place(contL)
                    ctx.builder.emitU16(Op.LOADL, UInt16(iSlot))
                    ctx.builder.emitU16(Op.LOADL, UInt16(sSlot))
                    ctx.builder.emit(Op.IADD)
                    ctx.builder.emitU16(Op.STOREL, UInt16(iSlot))
                    ctx.builder.emitRel(Op.LOOP_BACK, header)
                    ctx.builder.place(endL)
                case _ =>
                    diagFail(DiagKind.TYPE_MISMATCH, this.src, 0, 0, 0,
                        'for-in 的区间形态必须是 RangeLit')
            }
        } else if (itTy == LocalType.MAP) {
            if (binding.size != 2) {
                diagFail(DiagKind.SYNTAX_ERROR, this.src, 0, 0, 0, 'Map 的 for-in 必须双绑定 (k, v)')
            }
            let hSlot = ctx.builder.allocSlot(LocalType.MAP)
            let _ = this.lowerExpr(iterable)
            ctx.builder.emitU16(Op.STOREL, UInt16(hSlot))
            let curSlot = ctx.builder.allocSlot(LocalType.I64)
            ctx.builder.emitU16(Op.LOADL, UInt16(hSlot))
            ctx.builder.emit(Op.MAP_ITER_BEGIN)
            ctx.builder.emitU16(Op.STOREL, UInt16(curSlot))
            let header = ctx.builder.newLabel()
            ctx.builder.place(header)
            ctx.builder.emitU16(Op.LOADL, UInt16(curSlot))
            ctx.builder.emitU8(Op.MAP_ITER_STEP, 0u8)
            ctx.builder.emitRel(Op.JZ, endL)
            let kSlot = ctx.builder.allocSlot(LocalType.I64)
            ctx.builder.emitU16(Op.LOADL, UInt16(curSlot))
            ctx.builder.emitU8(Op.MAP_ITER_STEP, 1u8)
            ctx.builder.emitU16(Op.STOREL, UInt16(kSlot))
            let vSlot = ctx.builder.allocSlot(LocalType.I64)
            ctx.builder.emitU16(Op.LOADL, UInt16(curSlot))
            ctx.builder.emitU8(Op.MAP_ITER_STEP, 2u8)
            ctx.builder.emitU16(Op.STOREL, UInt16(vSlot))
            ctx.declare(VarSym(binding[0], kSlot, LocalType.I64), SourcePos(0, 0), this.src)
            ctx.declare(VarSym(binding[1], vSlot, LocalType.I64), SourcePos(0, 0), this.src)
            this.pendingNames.add((ctx.fnId, kSlot, binding[0]))
            this.pendingNames.add((ctx.fnId, vSlot, binding[1]))
            this.lowerWhereAndBody(whereCond, body, contL)
            ctx.builder.place(contL)
            ctx.builder.emitRel(Op.LOOP_BACK, header)
            ctx.builder.place(endL)
            ctx.builder.emitU16(Op.LOADL, UInt16(curSlot))
            ctx.builder.emitU8(Op.MAP_ITER_STEP, 3u8)
            ctx.builder.emit(Op.POP)
        } else {
            let isStr = itTy == LocalType.STRING
            if (binding.size != 1) {
                diagFail(DiagKind.SYNTAX_ERROR, this.src, 0, 0, 0,
                    'List/String 的 for-in 只能绑定一个变量')
            }
            let hSlot = ctx.builder.allocSlot(if (isStr) { LocalType.STRING } else { LocalType.LIST })
            let _ = this.lowerExpr(iterable)
            ctx.builder.emitU16(Op.STOREL, UInt16(hSlot))
            let nSlot = ctx.builder.allocSlot(LocalType.I64)
            ctx.builder.emitU16(Op.LOADL, UInt16(hSlot))
            ctx.builder.emit(Op.LEN)
            ctx.builder.emitU16(Op.STOREL, UInt16(nSlot))
            let jSlot = ctx.builder.allocSlot(LocalType.I64)
            ctx.builder.emitI64(Op.PUSH_I64, 0)
            ctx.builder.emitU16(Op.STOREL, UInt16(jSlot))
            let header = ctx.builder.newLabel()
            ctx.builder.place(header)
            ctx.builder.emitU16(Op.LOADL, UInt16(jSlot))
            ctx.builder.emitU16(Op.LOADL, UInt16(nSlot))
            ctx.builder.emit(Op.LT_I)
            ctx.builder.emitRel(Op.JZ, endL)
            let bSlot = ctx.builder.allocSlot(LocalType.I64)
            ctx.builder.emitU16(Op.LOADL, UInt16(hSlot))
            ctx.builder.emitU16(Op.LOADL, UInt16(jSlot))
            ctx.builder.emit(if (isStr) { Op.STR_AT } else { Op.GET_IDX })
            ctx.builder.emitU16(Op.STOREL, UInt16(bSlot))
            ctx.declare(VarSym(binding[0], bSlot, LocalType.I64), SourcePos(0, 0), this.src)
            this.pendingNames.add((ctx.fnId, bSlot, binding[0]))
            this.lowerWhereAndBody(whereCond, body, contL)
            ctx.builder.place(contL)
            ctx.builder.emitU16(Op.LOADL, UInt16(jSlot))
            ctx.builder.emitI64(Op.PUSH_I64, 1)
            ctx.builder.emit(Op.IADD)
            ctx.builder.emitU16(Op.STOREL, UInt16(jSlot))
            ctx.builder.emitRel(Op.LOOP_BACK, header)
            ctx.builder.place(endL)
        }

        ctx.breakLabels.remove(at: ctx.breakLabels.size - 1)
        ctx.continueLabels.remove(at: ctx.continueLabels.size - 1)
        ctx.popScope()
    }

    private func lowerWhereAndBody(whereCond: ?AstExpr, body: AstStmt, contL: Int64): Unit {
        let ctx = this.requireCtx()
        match (whereCond) {
            case Some(c) =>
                let _ = this.lowerExprAs(c, LocalType.BOOL)
                ctx.builder.emitRel(Op.JZ, contL)
            case None => ()
        }
        this.lowerStmt(body)
    }

    /** 尾位置 `recursive(args)`：实参逆序 `STOREL` + 回边（§8.0 v0.17）。 */
    private func tryLowerTailRecursive(e: AstExpr): Bool {
        let ctx = this.requireCtx()
        match (e) {
            case AstExpr.Call(target, args, _) =>
                match (target) {
                    case AstExpr.RecursiveValue(_) =>
                        let base: Int64 = if (ctx.isClosure) { 1 } else { 0 }
                        if (Int64(args.size) + base > ctx.builder.slotCount()) {
                            return false
                        }
                        var i = args.size - 1
                        while (i >= 0) {
                            let _ = this.lowerExpr(args[i])
                            ctx.builder.emitU16(Op.STOREL, UInt16(i + base))
                            i = i - 1
                        }
                        ctx.builder.emitRel(Op.LOOP_BACK, ctx.entryLabel)
                        return true
                    case _ => return false
                }
            case _ => return false
        }
    }

    // ==================================================================
    // 表达式
    // ==================================================================

    private func lowerExprAs(e: AstExpr, expected: UInt16): UInt16 {
        let actual = this.lowerExpr(e)
        if (expected == LocalType.NONE || actual == LocalType.NONE || expected == actual) {
            return actual
        }
        if (expected == LocalType.F64 && actual == LocalType.I64) {
            let ctx = this.requireCtx()
            ctx.builder.emit(Op.TO_F64)
            return LocalType.F64
        }
        actual
    }

    private func lowerExpr(e: AstExpr): UInt16 {
        let ctx = this.requireCtx()
        match (e) {
            case AstExpr.Lit(t, pos) => this.lowerLiteral(t, pos)
            case AstExpr.Var(name, pos) =>
                let sym = this.requireVar(name, pos)
                ctx.builder.emitU16(Op.LOADL, UInt16(sym.slot))
                sym.ty
            case AstExpr.Binary(op, l, r, pos) => this.lowerBinary(op, l, r, pos)
            case AstExpr.Unary(op, x, pos) => this.lowerUnary(op, x, pos)
            case AstExpr.IfExpr(cond, thenE, elseE, _) =>
                let elseL = ctx.builder.newLabel()
                let endL = ctx.builder.newLabel()
                let _ = this.lowerExprAs(cond, LocalType.BOOL)
                ctx.builder.emitRel(Op.JZ, elseL)
                let t1 = this.lowerExpr(thenE)
                ctx.builder.emitRel(Op.JMP, endL)
                ctx.builder.place(elseL)
                let t2 = this.lowerExpr(elseE)
                ctx.builder.place(endL)
                if (t1 != t2) {
                    diagFail(DiagKind.TYPE_MISMATCH, this.src, 0, 0, 0,
                        'if 表达式的两个分支类型不一致（§5 值用法）')
                }
                t1
            case AstExpr.Call(target, args, pos) => this.lowerCall(target, args, pos)
            case AstExpr.Closure(lambda, _) =>
                this.lowerClosureExpr(lambda)
                LocalType.CLOSURE
            case AstExpr.IIFE(callee, args, _) =>
                let _ = this.lowerExpr(callee)
                for (a in args) {
                    let _ = this.lowerExpr(a)
                }
                ctx.builder.callClosure(UInt8(args.size))
                LocalType.I64
            case AstExpr.Interp(parts, _) => this.lowerInterp(parts)
            case AstExpr.StrAdd(l, r, _) =>
                let lt = this.lowerExpr(l)
                this.coerceToStr(lt)
                let rt = this.lowerExpr(r)
                this.coerceToStr(rt)
                ctx.builder.emit(Op.STR_CAT)
                LocalType.STRING
            case AstExpr.RegexOp(kind, re, s, repl, n, m, pos) =>
                this.lowerRegexOp(kind, re, s, repl, n, m, pos)
            case AstExpr.RangeLit(start, endE, stepE, isClosed, pos) =>
                let _ = this.lowerExprAs(start, LocalType.I64)
                let _ = this.lowerExprAs(endE, LocalType.I64)
                match (stepE) {
                    case Some(se) =>
                        if (Lowerer.isZeroIntLit(se)) {
                            diagFail(DiagKind.TYPE_MISMATCH, this.src, 0, pos.line, pos.column,
                                'Range step 不得为 0（§11.9）')
                        }
                        let _ = this.lowerExprAs(se, LocalType.I64)
                    case None => ctx.builder.emitI64(Op.PUSH_I64, 1)
                }
                ctx.builder.emitU8(Op.PUSH_BOOL, if (isClosed) { 1u8 } else { 0u8 })
                ctx.builder.emit(Op.RANGE_NEW)
                LocalType.RANGE
            case AstExpr.ListLit(elems, isEmpty, _) => this.lowerListLit(elems, isEmpty)
            case AstExpr.MapLit(pairs, isEmpty, _) => this.lowerMapLit(pairs, isEmpty)
            case AstExpr.TupleLit(_, pos) =>
                diagFail(DiagKind.TYPE_MISMATCH, this.src, 0, pos.line, pos.column,
                    '元组字面量只能用于多重赋值右侧（M1 无元组类型）')
            case AstExpr.RecursiveValue(_) => this.lowerRecursiveValue()
            case AstExpr.Index(target, index, _) =>
                let tt = this.lowerExpr(target)
                let _ = this.lowerExpr(index)
                if (tt == LocalType.LIST) {
                    ctx.builder.emit(Op.GET_IDX)
                    this.guessElemType(target)
                } else if (tt == LocalType.MAP) {
                    ctx.builder.emit(Op.GET_KEY)
                    this.guessElemType(target)
                } else if (tt == LocalType.STRING) {
                    ctx.builder.emit(Op.STR_AT)
                    LocalType.I64
                } else {
                    diagFail(DiagKind.TYPE_MISMATCH, this.src, 0, 0, 0,
                        '下标读的目标不是容器或字符串')
                }
            case AstExpr.IndexTarget(_, _, pos) =>
                diagFail(DiagKind.SYNTAX_ERROR, this.src, 0, pos.line, pos.column,
                    '下标赋值目标只能出现在赋值语句左侧')
            case AstExpr.MemberName(_, _, pos) =>
                diagFail(DiagKind.NOT_IMPL, this.src, 0, pos.line, pos.column, '成员访问属 M2')
        }
    }

    private func lowerLiteral(t: Token, pos: SourcePos): UInt16 {
        let ctx = this.requireCtx()
        match (t.kind) {
            case TokenKind.IntLit =>
                match (Lowerer.parseInt64(t.text)) {
                    case Some(v) =>
                        ctx.builder.emitI64(Op.PUSH_I64, v)
                        LocalType.I64
                    case None =>
                        let (sign, scale, coeff) = Lowerer.decimalParts(t.text, 0)
                        let hid = this.sess.consts.addDecimal(sign, scale, coeff)
                        ctx.builder.emitU16(Op.PUSH_KH, UInt16(hid))
                        LocalType.DECIMAL
                }
            case TokenKind.DecLit =>
                let (sign, scale, coeff) = Lowerer.decimalParts(t.text, 0)
                let hid = this.sess.consts.addDecimal(sign, scale, coeff)
                ctx.builder.emitU16(Op.PUSH_KH, UInt16(hid))
                LocalType.DECIMAL
            case TokenKind.F64Lit =>
                let v = Float64.parse(Lowerer.stripF64Suffix(t.text))
                ctx.builder.emitI64(Op.PUSH_F64, Int64(v.toBits()))
                LocalType.F64
            case TokenKind.StrLit =>
                let hid = this.sess.consts.addStr(t.text)
                ctx.builder.emitU16(Op.PUSH_KH, UInt16(hid))
                LocalType.STRING
            case TokenKind.RegexLit =>
                let hid = this.sess.consts.addRegex(t.text, t.flags)
                ctx.builder.emitU16(Op.PUSH_KH, UInt16(hid))
                LocalType.REGEX
            case TokenKind.KwTrue =>
                ctx.builder.emitU8(Op.PUSH_BOOL, 1u8)
                LocalType.BOOL
            case TokenKind.KwFalse =>
                ctx.builder.emitU8(Op.PUSH_BOOL, 0u8)
                LocalType.BOOL
            case TokenKind.KwNull =>
                ctx.builder.emit(Op.PUSH_NULL)
                LocalType.NONE
            case _ =>
                diagFail(DiagKind.SYNTAX_ERROR, this.src, 0, pos.line, pos.column, '未知字面量类别')
        }
    }

    private func lowerBinary(op: TokenKind, l: AstExpr, r: AstExpr, pos: SourcePos): UInt16 {
        let ctx = this.requireCtx()
        if (op == TokenKind.AndAnd) {
            let shortL = ctx.builder.newLabel()
            let endL = ctx.builder.newLabel()
            let _ = this.lowerExprAs(l, LocalType.BOOL)
            ctx.builder.emit(Op.DUP)
            ctx.builder.emitRel(Op.JZ, shortL)
            ctx.builder.emit(Op.POP)
            let _ = this.lowerExprAs(r, LocalType.BOOL)
            ctx.builder.emitRel(Op.JMP, endL)
            ctx.builder.place(shortL)
            ctx.builder.place(endL)
            return LocalType.BOOL
        }
        if (op == TokenKind.OrOr) {
            let shortL = ctx.builder.newLabel()
            let endL = ctx.builder.newLabel()
            let _ = this.lowerExprAs(l, LocalType.BOOL)
            ctx.builder.emit(Op.DUP)
            ctx.builder.emitRel(Op.JNZ, shortL)
            ctx.builder.emit(Op.POP)
            let _ = this.lowerExprAs(r, LocalType.BOOL)
            ctx.builder.emitRel(Op.JMP, endL)
            ctx.builder.place(shortL)
            ctx.builder.place(endL)
            return LocalType.BOOL
        }
        let lt = this.lowerExpr(l)
        let rt = this.lowerExpr(r)
        let t = this.promote(lt, rt, pos)
        match (op) {
            case TokenKind.Plus =>
                if (t == LocalType.STRING) {
                    this.coerceToStr(lt)
                    this.coerceToStr(rt)
                    ctx.builder.emit(Op.STR_CAT)
                } else {
                    this.coerceOperands(lt, rt, t, pos)
                    this.emitArith(t, Op.IADD, Op.FADD, Op.DEC_ADD)
                }
                t
            case TokenKind.Minus =>
                this.coerceOperands(lt, rt, t, pos)
                this.emitArith(t, Op.ISUB, Op.FSUB, Op.DEC_SUB)
                t
            case TokenKind.Star =>
                if (lt == LocalType.STRING && Lowerer.isNumeric(rt)) {
                    this.narrowTopToI64(rt, pos)
                    ctx.builder.emit(Op.STR_REPEAT)
                    LocalType.STRING
                } else if (rt == LocalType.STRING && Lowerer.isNumeric(lt)) {
                    // `n * s` 换序为 `s * n`（STR_REPEAT 操作数序固定）
                    ctx.builder.emit(Op.SWAP)
                    this.narrowTopToI64(lt, pos)
                    ctx.builder.emit(Op.STR_REPEAT)
                    LocalType.STRING
                } else {
                    this.coerceOperands(lt, rt, t, pos)
                    this.emitArith(t, Op.IMUL, Op.FMUL, Op.DEC_MUL)
                    t
                }
            case TokenKind.Slash =>
                if (t != LocalType.STRING) {
                    this.coerceOperands(lt, rt, t, pos)
                }
                // 整数 / Decimal 除法可能失败（除零 1/10）⇒ 失败点前记站点（§9.16）
                if (t == LocalType.I64 || t == LocalType.DECIMAL) {
                    ctx.builder.setSite(pos)
                }
                this.emitArith(t, Op.IDIV, Op.FDIV, Op.DEC_DIV)
                t
            case TokenKind.Percent =>
                if (t != LocalType.I64) {
                    diagFail(DiagKind.TYPE_MISMATCH, this.src, 0, pos.line, pos.column,
                        '% 仅支持 (Int64, Int64)')
                }
                ctx.builder.setSite(pos) // 取余除零 → 2
                ctx.builder.emit(Op.IMOD)
                LocalType.I64
            case TokenKind.EqEq | TokenKind.NotEq | TokenKind.Lt | TokenKind.Le | TokenKind.Gt |
                TokenKind.Ge =>
                this.coerceOperands(lt, rt, t, pos)
                this.emitCompare(op, t, pos)
            case TokenKind.Amp =>
                if (t == LocalType.BOOL) {
                    ctx.builder.emit(Op.AND_B)
                } else {
                    ctx.builder.emit(Op.BAND_I)
                }
                t
            case TokenKind.Pipe =>
                if (t == LocalType.BOOL) {
                    ctx.builder.emit(Op.OR_B)
                } else {
                    ctx.builder.emit(Op.BOR_I)
                }
                t
            case TokenKind.Caret =>
                if (t == LocalType.BOOL) {
                    ctx.builder.emit(Op.XOR_B)
                } else {
                    ctx.builder.emit(Op.BXOR_I)
                }
                t
            case TokenKind.Shl =>
                ctx.builder.emit(Op.SHL_I)
                LocalType.I64
            case TokenKind.Shr =>
                ctx.builder.emit(Op.SHR_I)
                LocalType.I64
            case _ =>
                diagFail(DiagKind.NOT_IMPL, this.src, 0, pos.line, pos.column, '未实现的二元运算')
        }
    }

    private func promote(lt: UInt16, rt: UInt16, pos: SourcePos): UInt16 {
        if (lt == rt) {
            return lt
        }
        if (lt == LocalType.STRING || rt == LocalType.STRING) {
            return LocalType.STRING
        }
        if ((lt == LocalType.DECIMAL && (rt == LocalType.I64 || rt == LocalType.F64)) ||
            (rt == LocalType.DECIMAL && (lt == LocalType.I64 || lt == LocalType.F64))) {
            return LocalType.DECIMAL
        }
        if ((lt == LocalType.I64 && rt == LocalType.F64) ||
            (lt == LocalType.F64 && rt == LocalType.I64)) {
            return LocalType.F64
        }
        diagFail(DiagKind.TYPE_MISMATCH, this.src, 0, pos.line, pos.column,
            '运算两侧类型不兼容: ${LocalType.name(lt)} / ${LocalType.name(rt)}')
    }

    /**
     * 混合数值提升的**栈上转换**：两侧已按 `[l, r]` 入栈，`t` 是提升后的公共类型。
     *
     * 只处理 I64/F64/Decimal 三者的提升（§11.9）；其余类型不插入任何指令。
     * 栈序技巧：右侧转换直接作用于栈顶；左侧需 `SWAP → 转换 → SWAP` 复原。
     */
    private static func isNumeric(t: UInt16): Bool {
        t == LocalType.I64 || t == LocalType.F64 || t == LocalType.DECIMAL
    }

    /** 字面量 0 判定（Range step 编译期拒绝用；非字面量留给运行期 helper 的 14）。 */
    private static func isZeroIntLit(e: AstExpr): Bool {
        match (e) {
            case AstExpr.Lit(t, _) =>
                if (t.kind == TokenKind.IntLit) {
                    match (Lowerer.parseInt64(t.text)) {
                        case Some(v) => v == 0
                        case None => false
                    }
                } else {
                    false
                }
            case _ => false
        }
    }

    /** n 位置运行期自动窄化（§11.9 v0.15）：F64/DEC → Int64，仅报错版（mode=0）。 */
    private func narrowTopToI64(from: UInt16, pos: SourcePos): Unit {
        let ctx = this.requireCtx()
        if (from == LocalType.I64) {
            return
        }
        if (from == LocalType.F64) {
            ctx.builder.emitU8(Op.TO_I64, 0u8)
        } else if (from == LocalType.DECIMAL) {
            ctx.builder.emitU8(Op.DEC_TO_I64, 0u8)
        } else {
            diagFail(DiagKind.TYPE_MISMATCH, this.src, 0, pos.line, pos.column,
                'n 位置不支持该类型: ${LocalType.name(from)}')
        }
    }

    private func coerceOperands(lt: UInt16, rt: UInt16, t: UInt16, pos: SourcePos): Unit {
        if (t != LocalType.I64 && t != LocalType.F64 && t != LocalType.DECIMAL) {
            return
        }
        if (lt == t && rt == t) {
            return
        }
        let ctx = this.requireCtx()
        if (rt != t) {
            this.coerceTop(rt, t, pos)
        }
        if (lt != t) {
            ctx.builder.emit(Op.SWAP)
            this.coerceTop(lt, t, pos)
            ctx.builder.emit(Op.SWAP)
        }
    }

    private func coerceTop(from: UInt16, to: UInt16, pos: SourcePos): Unit {
        let ctx = this.requireCtx()
        if (to == LocalType.F64 && from == LocalType.I64) {
            ctx.builder.emit(Op.TO_F64)
        } else if (to == LocalType.DECIMAL && from == LocalType.I64) {
            ctx.builder.emitU8(Op.TO_DEC, 0u8)
        } else if (to == LocalType.DECIMAL && from == LocalType.F64) {
            ctx.builder.emitU8(Op.TO_DEC, 1u8)
        } else {
            diagFail(DiagKind.TYPE_MISMATCH, this.src, 0, pos.line, pos.column,
                '无法提升 ${LocalType.name(from)} → ${LocalType.name(to)}')
        }
    }

    private func emitArith(t: UInt16, iop: UInt8, fop: UInt8, dop: UInt8): Unit {
        let ctx = this.requireCtx()
        if (t == LocalType.I64) {
            ctx.builder.emit(iop)
        } else if (t == LocalType.F64) {
            ctx.builder.emit(fop)
        } else if (t == LocalType.DECIMAL) {
            ctx.builder.emit(dop)
        } else if (t == LocalType.STRING) {
            ctx.builder.emit(Op.STR_CAT)
        } else {
            diagFail(DiagKind.TYPE_MISMATCH, this.src, 0, 0, 0, '算术运算的操作数类型不支持')
        }
    }

    private func emitCompare(op: TokenKind, t: UInt16, pos: SourcePos): UInt16 {
        let ctx = this.requireCtx()
        if (t == LocalType.I64) {
            ctx.builder.emit(Lowerer.cmpOp(op, Op.EQ_I, Op.NE_I, Op.LT_I, Op.LE_I, Op.GT_I, Op.GE_I))
        } else if (t == LocalType.F64) {
            ctx.builder.emit(Lowerer.cmpOp(op, Op.EQ_F, Op.NE_F, Op.LT_F, Op.LE_F, Op.GT_F, Op.GE_F))
        } else if (t == LocalType.STRING || t == LocalType.DECIMAL || t == LocalType.DATETIME ||
            t == LocalType.DURATION) {
            if (t == LocalType.STRING) {
                ctx.builder.emit(Op.CMP_STR)
            } else if (t == LocalType.DECIMAL) {
                ctx.builder.emit(Op.CMP_DEC)
            } else if (t == LocalType.DATETIME) {
                ctx.builder.emit(Op.CMP_DT)
            } else {
                ctx.builder.emit(Op.CMP_DUR)
            }
            ctx.builder.emitI64(Op.PUSH_I64, 0)
            ctx.builder.emit(Lowerer.cmpOp(op, Op.EQ_I, Op.NE_I, Op.LT_I, Op.LE_I, Op.GT_I, Op.GE_I))
        } else if (t == LocalType.BOOL) {
            if (op != TokenKind.EqEq && op != TokenKind.NotEq) {
                diagFail(DiagKind.TYPE_MISMATCH, this.src, 0, pos.line, pos.column,
                    'Bool 只支持 == / !=')
            }
            ctx.builder.emit(if (op == TokenKind.EqEq) { Op.EQ_I } else { Op.NE_I })
        } else {
            if (op == TokenKind.EqEq) {
                ctx.builder.emit(Op.EQ_H)
            } else if (op == TokenKind.NotEq) {
                ctx.builder.emit(Op.NE_H)
            } else {
                diagFail(DiagKind.TYPE_MISMATCH, this.src, 0, pos.line, pos.column,
                    '该类型只支持 == / !=（引用相等）')
            }
        }
        LocalType.BOOL
    }

    private static func cmpOp(op: TokenKind, eq: UInt8, ne: UInt8, lt: UInt8, le: UInt8, gt: UInt8,
        ge: UInt8): UInt8 {
        match (op) {
            case TokenKind.EqEq => eq
            case TokenKind.NotEq => ne
            case TokenKind.Lt => lt
            case TokenKind.Le => le
            case TokenKind.Gt => gt
            case _ => ge
        }
    }

    private func lowerUnary(op: TokenKind, x: AstExpr, pos: SourcePos): UInt16 {
        let ctx = this.requireCtx()
        let t = this.lowerExpr(x)
        match (op) {
            case TokenKind.Minus =>
                if (t == LocalType.I64) {
                    ctx.builder.emit(Op.INEG)
                } else if (t == LocalType.F64) {
                    ctx.builder.emit(Op.FNEG)
                } else if (t == LocalType.DECIMAL) {
                    let zero = this.sess.consts.addDecimal(0u8, 0, '0')
                    ctx.builder.emitU16(Op.PUSH_KH, UInt16(zero))
                    ctx.builder.emit(Op.SWAP)
                    ctx.builder.emit(Op.DEC_SUB)
                } else {
                    diagFail(DiagKind.TYPE_MISMATCH, this.src, 0, pos.line, pos.column,
                        '一元负号不支持该类型')
                }
                t
            case TokenKind.Bang =>
                ctx.builder.emit(Op.NOT_B)
                LocalType.BOOL
            case TokenKind.Tilde =>
                ctx.builder.emit(Op.BNOT_I)
                LocalType.I64
            case _ =>
                diagFail(DiagKind.NOT_IMPL, this.src, 0, pos.line, pos.column, '未实现的一元运算')
        }
    }

    /**
     * 显式数值转换（§11.9）：6 个方向全部开放，窄化（F64/DEC → I64、DEC → F64）仅此路径可达。
     *
     * 失败语义取**报错版**（`TO_I64 mode=0` / `DEC_TO_I64 mode=0`）；deopt 版留给后端
     * 在已判定函数无变更型调用时选择（M1 解释器路径不使用 deopt）。
     */
    private func lowerNumericCast(name: String, e: AstExpr, pos: SourcePos): UInt16 {
        let ctx = this.requireCtx()
        let from = this.lowerExpr(e)
        match (name) {
            case 'Int64' =>
                if (from == LocalType.I64) {
                    return LocalType.I64
                }
                if (from == LocalType.F64) {
                    ctx.builder.emitU8(Op.TO_I64, 0u8)
                    return LocalType.I64
                }
                if (from == LocalType.DECIMAL) {
                    ctx.builder.emitU8(Op.DEC_TO_I64, 0u8)
                    return LocalType.I64
                }
            case 'Float64' =>
                if (from == LocalType.F64) {
                    return LocalType.F64
                }
                if (from == LocalType.I64) {
                    ctx.builder.emit(Op.TO_F64)
                    return LocalType.F64
                }
                if (from == LocalType.DECIMAL) {
                    ctx.builder.emit(Op.DEC_TO_F64)
                    return LocalType.F64
                }
            case _ =>
                if (from == LocalType.DECIMAL) {
                    return LocalType.DECIMAL
                }
                if (from == LocalType.I64) {
                    ctx.builder.emitU8(Op.TO_DEC, 0u8)
                    return LocalType.DECIMAL
                }
                if (from == LocalType.F64) {
                    ctx.builder.emitU8(Op.TO_DEC, 1u8)
                    return LocalType.DECIMAL
                }
        }
        diagFail(DiagKind.TYPE_MISMATCH, this.src, 0, pos.line, pos.column,
            '不支持的数值转换: ${LocalType.name(from)} → ${name}')
    }

    private func lowerCall(target: AstExpr, args: Array<AstExpr>, pos: SourcePos): UInt16 {
        let ctx = this.requireCtx()
        match (target) {
            case AstExpr.RecursiveValue(_) =>
                if (ctx.isClosure) {
                    ctx.builder.emitU16(Op.LOADL, 0u16)
                    for (a in args) {
                        let _ = this.lowerExpr(a)
                    }
                    ctx.builder.callClosure(UInt8(args.size))
                    return this.closureRetType(ctx.fnId)
                }
                for (a in args) {
                    let _ = this.lowerExpr(a)
                }
                ctx.builder.callFunc(UInt16(this.entryFn), UInt8(args.size))
                this.topRetType
            case AstExpr.Var(name, vpos) =>
                match (ctx.find(name)) {
                    case Some(sym) =>
                        if (sym.ty != LocalType.CLOSURE) {
                            diagFail(DiagKind.TYPE_MISMATCH, this.src, 0, vpos.line, vpos.column,
                                '「${name}」不是可调用值')
                        }
                        ctx.builder.emitU16(Op.LOADL, UInt16(sym.slot))
                        for (a in args) {
                            let _ = this.lowerExpr(a)
                        }
                        ctx.builder.callClosure(UInt8(args.size))
                        LocalType.I64
                    case None =>
                        // 显式数值转换（§11.9）：形式由前端定义为 `Int64(x)` / `Float64(x)` / `Decimal(x)`
                        if (args.size == 1 && (name == 'Int64' || name == 'Float64' || name == 'Decimal')) {
                            return this.lowerNumericCast(name, args[0], vpos)
                        }
                        let r = this.resolver.resolve(name, vpos)
                        match (r) {
                            case ResolvedCall.Recursive =>
                                for (a in args) {
                                    let _ = this.lowerExpr(a)
                                }
                                ctx.builder.callFunc(UInt16(this.entryFn), UInt8(args.size))
                                this.topRetType
                            case ResolvedCall.UserHelper(slot) =>
                                for (a in args) {
                                    let _ = this.lowerExpr(a)
                                }
                                let ret = this.sess.registry.retTypeOf(name)
                                ctx.builder.callHelper(HelperCodec.hidOfSlot(slot), UInt8(args.size))
                                ret
                        }
                }
            case _ =>
                let _ = this.lowerExpr(target)
                for (a in args) {
                    let _ = this.lowerExpr(a)
                }
                ctx.builder.callClosure(UInt8(args.size))
                LocalType.I64
        }
    }

    private func lowerInterp(parts: Array<AstExpr>): UInt16 {
        let ctx = this.requireCtx()
        let empty = this.sess.consts.addStr('')
        ctx.builder.emitU16(Op.PUSH_KH, UInt16(empty))
        var i = 0
        while (i < parts.size) {
            let p = parts[i]
            if (i % 2 == 0) {
                let hid = this.sess.consts.addStr(Lowerer.textOfLit(p))
                ctx.builder.emitU16(Op.PUSH_KH, UInt16(hid))
            } else {
                let t = this.lowerExpr(p)
                this.emitToStr(t)
            }
            ctx.builder.emit(Op.STR_CAT)
            i = i + 1
        }
        LocalType.STRING
    }

    private static func textOfLit(e: AstExpr): String {
        match (e) {
            case AstExpr.Lit(t, _) => t.text
            case _ => ''
        }
    }

    private func coerceToStr(t: UInt16): Unit {
        if (t == LocalType.STRING) {
            return
        }
        this.emitToStr(t)
    }

    private func emitToStr(t: UInt16): Unit {
        let ctx = this.requireCtx()
        ctx.builder.emitU8(Op.TO_STR, UInt8(t & 0xFFu16))
    }

    private func lowerRegexOp(kind: TokenKind, re: AstExpr, s: AstExpr, repl: ?AstExpr, n: ?Int64,
        m: ?Int64, pos: SourcePos): UInt16 {
        let ctx = this.requireCtx()
        if (kind == TokenKind.Tilde || kind == TokenKind.BangTilde) {
            let _ = this.lowerExpr(re)
            let _ = this.lowerExprAs(s, LocalType.STRING)
            ctx.builder.emit(Op.REGEX_IS_MATCH)
            if (kind == TokenKind.BangTilde) {
                ctx.builder.emit(Op.NOT_B)
            }
            return LocalType.BOOL
        }
        let _ = this.lowerExpr(re)
        let _ = this.lowerExprAs(s, LocalType.STRING)
        match (repl) {
            case Some(r) => let _ = this.lowerExprAs(r, LocalType.STRING)
            case None => diagFail(DiagKind.SYNTAX_ERROR, this.src, 0, pos.line, pos.column,
                '替换缺少替换串')
        }
        match (m) {
            case Some(mv) =>
                match (n) {
                    case Some(nv) =>
                        ctx.builder.emitI64(Op.PUSH_I64, nv)
                        ctx.builder.emitI64(Op.PUSH_I64, mv)
                        ctx.builder.callHelper(HelperCodec.REGEX_REPLACE_RANGE, 5u8)
                    case None =>
                        diagFail(DiagKind.SYNTAX_ERROR, this.src, 0, pos.line, pos.column,
                            '区间替换缺少起始序号')
                }
            case None =>
                match (n) {
                    case Some(nv) =>
                        ctx.builder.emitI64(Op.PUSH_I64, nv)
                        ctx.builder.callHelper(HelperCodec.REGEX_REPLACE_NTH, 4u8)
                    case None => ctx.builder.callHelper(HelperCodec.REGEX_REPLACE_ALL, 3u8)
                }
        }
        LocalType.STRING
    }

    private func lowerListLit(elems: Array<AstExpr>, isEmpty: Bool): UInt16 {
        let ctx = this.requireCtx()
        if (isEmpty || elems.size == 0) {
            ctx.builder.emit(Op.MAKE_LIST)
            return LocalType.LIST
        }
        var childIdx = ArrayList<UInt32>()
        var allConst = true
        for (e in elems) {
            match (this.constIndexOf(e)) {
                case Some(i) => childIdx.add(UInt32(i))
                case None =>
                    allConst = false
                    break
            }
        }
        if (allConst) {
            let hid = this.sess.consts.addList(childIdx.toArray())
            ctx.builder.emitU16(Op.PUSH_KH, UInt16(hid))
            return LocalType.LIST
        }
        ctx.builder.emit(Op.MAKE_LIST)
        for (e in elems) {
            let _ = this.lowerExpr(e)
            ctx.builder.emit(Op.LIST_APPEND)
            ctx.builder.emit(Op.POP)
        }
        LocalType.LIST
    }

    private func lowerMapLit(pairs: Array<(AstExpr, AstExpr)>, isEmpty: Bool): UInt16 {
        let ctx = this.requireCtx()
        if (isEmpty || pairs.size == 0) {
            ctx.builder.emit(Op.MAKE_MAP)
            return LocalType.MAP
        }
        var allConst = true
        var kids = ArrayList<(UInt32, UInt32)>()
        for (kv in pairs) {
            match (this.constIndexOf(kv[0])) {
                case Some(ki) =>
                    match (this.constIndexOf(kv[1])) {
                        case Some(vi) => kids.add((UInt32(ki), UInt32(vi)))
                        case None =>
                            allConst = false
                            break
                    }
                case None =>
                    allConst = false
                    break
            }
        }
        if (allConst) {
            let hid = this.sess.consts.addMap(kids.toArray())
            ctx.builder.emitU16(Op.PUSH_KH, UInt16(hid))
            return LocalType.MAP
        }
        ctx.builder.emit(Op.MAKE_MAP)
        let slot = ctx.builder.allocSlot(LocalType.MAP)
        ctx.builder.emitU16(Op.STOREL, UInt16(slot))
        for (kv in pairs) {
            ctx.builder.emitU16(Op.LOADL, UInt16(slot))
            let _ = this.lowerExpr(kv[0])
            let _ = this.lowerExpr(kv[1])
            ctx.builder.emit(Op.MAP_PUT)
            ctx.builder.emit(Op.POP)
        }
        ctx.builder.emitU16(Op.LOADL, UInt16(slot))
        LocalType.MAP
    }

    private func constIndexOf(e: AstExpr): ?Int64 {
        match (e) {
            case AstExpr.Lit(t, _) =>
                match (t.kind) {
                    case TokenKind.IntLit =>
                        match (Lowerer.parseInt64(t.text)) {
                            case Some(v) => Some(this.sess.consts.addI64(v))
                            case None =>
                                let (sg, sc, co) = Lowerer.decimalParts(t.text, 0)
                                Some(this.sess.consts.addDecimal(sg, sc, co))
                        }
                    case TokenKind.DecLit =>
                        let (sg, sc, co) = Lowerer.decimalParts(t.text, 0)
                        Some(this.sess.consts.addDecimal(sg, sc, co))
                    case TokenKind.F64Lit =>
                        let v = Float64.parse(Lowerer.stripF64Suffix(t.text))
                        Some(this.sess.consts.addF64(v.toBits()))
                    case TokenKind.StrLit =>
                        if (!t.text.contains(Parser.INTERP_START)) {
                            Some(this.sess.consts.addStr(t.text))
                        } else {
                            None
                        }
                    case TokenKind.RegexLit => Some(this.sess.consts.addRegex(t.text, t.flags))
                    case TokenKind.KwTrue => Some(this.sess.consts.addI64(1))
                    case TokenKind.KwFalse => Some(this.sess.consts.addI64(0))
                    case _ => None
                }
            case AstExpr.RangeLit(start, endE, stepE, isClosed, _) =>
                match (start) {
                    case AstExpr.Lit(st, _) =>
                        match (endE) {
                            case AstExpr.Lit(et, _) =>
                                match ((Lowerer.parseInt64(st.text), Lowerer.parseInt64(et.text))) {
                                    case (Some(sv), Some(ev)) =>
                                        var stepv: Int64 = 1
                                        match (stepE) {
                                            case Some(se) =>
                                                match (se) {
                                                    case AstExpr.Lit(set2, _) =>
                                                        match (Lowerer.parseInt64(set2.text)) {
                                                            case Some(x) => stepv = x
                                                            case None => return None
                                                        }
                                                    case _ => return None
                                                }
                                            case None => ()
                                        }
                                        Some(this.sess.consts.addRange(sv, ev, stepv, isClosed))
                                    case _ => None
                                }
                            case _ => None
                        }
                    case _ => None
                }
            case _ => None
        }
    }

    // ==================================================================
    // 闭包
    // ==================================================================

    private func lowerClosureExpr(lambda: LambdaAst): Unit {
        let outer = this.requireCtx()
        let fnId = this.sess.newFnId()
        let outerNames = ArrayList<String>()
        for (sc in outer.scopes) {
            for (s in sc) {
                outerNames.add(s.name)
            }
        }
        let free = Lowerer.freeVarsOf(lambda, outerNames)
        outer.builder.emitI64(Op.PUSH_I64, Int64(fnId))
        for (name in free) {
            let sym = this.requireVar(name, lambda.pos)
            outer.builder.emitU16(Op.LOADL, UInt16(sym.slot))
        }
        this.setClosureRetType(fnId, Lowerer.retTypeOf(lambda))
        this.lowerLambda(lambda, fnId, Some(outer), free, lambda.params.size + 1)
        outer.builder.callHelper(HelperCodec.CLOSURE_NEW, UInt8(free.size + 1))
    }

    private func lowerRecursiveValue(): UInt16 {
        let ctx = this.requireCtx()
        if (ctx.isClosure) {
            ctx.builder.emitU16(Op.LOADL, 0u16)
            return LocalType.CLOSURE
        }
        let adapterId = this.sess.newFnId()
        this.setClosureRetType(adapterId, this.topRetType)
        let builder = BytecodeBuilder(adapterId, this.sess.consts)
        let actx = FnCtx(adapterId, builder, true, None)
        this.ctx = actx
        actx.builder.place(actx.entryLabel)
        let _ = actx.builder.allocSlot(LocalType.CLOSURE)
        var i = 0
        while (i < this.topParamTypes.size) {
            let _ = actx.builder.allocSlot(this.topParamTypes[i])
            actx.builder.emitU16(Op.LOADL, UInt16(i + 1))
            i = i + 1
        }
        actx.builder.callFunc(UInt16(this.entryFn), UInt8(this.topParamTypes.size))
        actx.builder.ret()
        let body = actx.builder.finish()
        let types = this.typesOf(actx)
        this.sess.addFunc(LoweredFunc(adapterId, Int64(this.topParamTypes.size) + 1, this.topRetType,
            types, body, actx.builder.pendingSites()))
        this.ctx = ctx
        ctx.builder.emitI64(Op.PUSH_I64, Int64(adapterId))
        ctx.builder.callHelper(HelperCodec.CLOSURE_NEW, 1u8)
        LocalType.CLOSURE
    }

    // ==================================================================
    // 工具
    // ==================================================================

    private func requireCtx(): FnCtx {
        match (this.ctx) {
            case Some(c) => c
            case None => codeFail('降低上下文缺失')
        }
    }

    private func requireVar(name: String, pos: SourcePos): VarSym {
        let ctx = this.requireCtx()
        match (ctx.find(name)) {
            case Some(s) => s
            case None =>
                this.resolver.requireValue(name, pos, false)
                diagFail(DiagKind.UNDEFINED_IDENTIFIER, this.src, 0, pos.line, pos.column,
                    '未定义的标识符「${name}」')
        }
    }

    private static func findIn(parent: ?FnCtx, name: String, src: String): VarSym {
        match (parent) {
            case Some(p) =>
                match (p.find(name)) {
                    case Some(s) => s
                    case None =>
                        diagFail(DiagKind.UNDEFINED_IDENTIFIER, src, 0, 0, 0,
                            '捕获的变量「${name}」不在外层作用域')
                }
            case None =>
                diagFail(DiagKind.UNDEFINED_IDENTIFIER, src, 0, 0, 0,
                    '捕获的变量「${name}」没有外层函数')
        }
    }

    private func staticTypeOf(e: AstExpr): UInt16 {
        match (e) {
            case AstExpr.Var(name, _) =>
                match (this.ctx) {
                    case Some(c) =>
                        match (c.find(name)) {
                            case Some(s) => s.ty
                            case None => LocalType.NONE
                        }
                    case None => LocalType.NONE
                }
            case _ => Lowerer.staticTypeOfTop(e)
        }
    }

    private func guessElemType(target: AstExpr): UInt16 {
        match (target) {
            case AstExpr.ListLit(elems, _, _) =>
                if (elems.size > 0) {
                    return this.staticTypeOf(elems[0])
                }
                LocalType.I64
            case AstExpr.MapLit(pairs, _, _) =>
                if (pairs.size > 0) {
                    return this.staticTypeOf(pairs[0][1])
                }
                LocalType.I64
            case _ => LocalType.I64
        }
    }

    private static func paramTypesOf(lambda: LambdaAst): Array<UInt16> {
        var out = ArrayList<UInt16>()
        for (p in lambda.params) {
            out.add(p.typeAnn.code())
        }
        out.toArray()
    }

    private static func retTypeOf(lambda: LambdaAst): UInt16 {
        match (lambda.retExpr) {
            case Some(e) => Lowerer.staticTypeOfTop(e)
            case None => LocalType.UNIT
        }
    }

    private static func staticTypeOfTop(e: AstExpr): UInt16 {
        match (e) {
            case AstExpr.Lit(t, _) =>
                match (t.kind) {
                    case TokenKind.IntLit => LocalType.I64
                    case TokenKind.DecLit => LocalType.DECIMAL
                    case TokenKind.F64Lit => LocalType.F64
                    case TokenKind.StrLit => LocalType.STRING
                    case TokenKind.RegexLit => LocalType.REGEX
                    case TokenKind.KwTrue => LocalType.BOOL
                    case TokenKind.KwFalse => LocalType.BOOL
                    case TokenKind.KwNull => LocalType.NONE
                    case _ => LocalType.I64
                }
            case AstExpr.Interp(_, _) => LocalType.STRING
            case AstExpr.StrAdd(_, _, _) => LocalType.STRING
            case AstExpr.RangeLit(_, _, _, _, _) => LocalType.RANGE
            case AstExpr.ListLit(_, _, _) => LocalType.LIST
            case AstExpr.MapLit(_, _, _) => LocalType.MAP
            case AstExpr.Closure(_, _) => LocalType.CLOSURE
            case AstExpr.RecursiveValue(_) => LocalType.CLOSURE
            case AstExpr.RegexOp(k, _, _, _, _, _, _) =>
                if (k == TokenKind.Tilde || k == TokenKind.BangTilde) {
                    LocalType.BOOL
                } else {
                    LocalType.STRING
                }
            case AstExpr.Binary(op, _, _, _) =>
                match (op) {
                    case TokenKind.EqEq | TokenKind.NotEq | TokenKind.Lt | TokenKind.Le |
                        TokenKind.Gt | TokenKind.Ge | TokenKind.AndAnd | TokenKind.OrOr => LocalType.BOOL
                    case _ => LocalType.I64
                }
            case AstExpr.Unary(op, _, _) =>
                if (op == TokenKind.Bang) {
                    LocalType.BOOL
                } else {
                    LocalType.I64
                }
            case AstExpr.IfExpr(_, t, _, _) => Lowerer.staticTypeOfTop(t)
            case _ => LocalType.I64
        }
    }

    private static func freeVarsOf(lambda: LambdaAst, outerNames: ArrayList<String>): ArrayList<String> {
        let free = ArrayList<String>()
        let locals = ArrayList<String>()
        for (p in lambda.params) {
            locals.add(p.name)
        }
        for (s in lambda.body) {
            Lowerer.scanStmt(s, locals, outerNames, free)
        }
        match (lambda.retExpr) {
            case Some(e) => Lowerer.scanExpr(e, locals, outerNames, free)
            case None => ()
        }
        free
    }

    private static func scanStmt(s: AstStmt, locals: ArrayList<String>, outer: ArrayList<String>,
        free: ArrayList<String>): Unit {
        match (s) {
            case AstStmt.Decl(name, _, initE, _) =>
                match (initE) {
                    case Some(e) => Lowerer.scanExpr(e, locals, outer, free)
                    case None => ()
                }
                if (!locals.contains(name)) {
                    locals.add(name)
                }
            case AstStmt.Assign(l, r, _) =>
                Lowerer.scanExpr(l, locals, outer, free)
                Lowerer.scanExpr(r, locals, outer, free)
            case AstStmt.MultiAssign(ls, rs, _) =>
                for (e in ls) {
                    Lowerer.scanExpr(e, locals, outer, free)
                }
                for (e in rs) {
                    Lowerer.scanExpr(e, locals, outer, free)
                }
            case AstStmt.If(c, t, e, _) =>
                Lowerer.scanExpr(c, locals, outer, free)
                Lowerer.scanStmt(t, locals, outer, free)
                match (e) {
                    case Some(x) => Lowerer.scanStmt(x, locals, outer, free)
                    case None => ()
                }
            case AstStmt.While(c, b, _) =>
                Lowerer.scanExpr(c, locals, outer, free)
                Lowerer.scanStmt(b, locals, outer, free)
            case AstStmt.ForIn(binding, it, w, b, _) =>
                Lowerer.scanExpr(it, locals, outer, free)
                match (w) {
                    case Some(c) => Lowerer.scanExpr(c, locals, outer, free)
                    case None => ()
                }
                for (n in binding) {
                    if (!locals.contains(n)) {
                        locals.add(n)
                    }
                }
                Lowerer.scanStmt(b, locals, outer, free)
            case AstStmt.Return(v, _) =>
                match (v) {
                    case Some(e) => Lowerer.scanExpr(e, locals, outer, free)
                    case None => ()
                }
            case AstStmt.ExprStmt(e, _) => Lowerer.scanExpr(e, locals, outer, free)
            case AstStmt.Block(ss, _) =>
                for (x in ss) {
                    Lowerer.scanStmt(x, locals, outer, free)
                }
            case _ => ()
        }
    }

    private static func scanExpr(e: AstExpr, locals: ArrayList<String>, outer: ArrayList<String>,
        free: ArrayList<String>): Unit {
        match (e) {
            case AstExpr.Var(n, _) =>
                if (!locals.contains(n) && outer.contains(n) && !free.contains(n)) {
                    free.add(n)
                }
            case AstExpr.Binary(_, l, r, _) =>
                Lowerer.scanExpr(l, locals, outer, free)
                Lowerer.scanExpr(r, locals, outer, free)
            case AstExpr.Unary(_, x, _) => Lowerer.scanExpr(x, locals, outer, free)
            case AstExpr.IfExpr(c, t, el, _) =>
                Lowerer.scanExpr(c, locals, outer, free)
                Lowerer.scanExpr(t, locals, outer, free)
                Lowerer.scanExpr(el, locals, outer, free)
            case AstExpr.Call(t, args, _) =>
                Lowerer.scanExpr(t, locals, outer, free)
                for (a in args) {
                    Lowerer.scanExpr(a, locals, outer, free)
                }
            case AstExpr.Closure(l, _) =>
                let inner = ArrayList<String>()
                for (x in locals) {
                    inner.add(x)
                }
                for (p in l.params) {
                    if (!inner.contains(p.name)) {
                        inner.add(p.name)
                    }
                }
                for (s in l.body) {
                    Lowerer.scanStmt(s, inner, outer, free)
                }
                match (l.retExpr) {
                    case Some(x) => Lowerer.scanExpr(x, inner, outer, free)
                    case None => ()
                }
            case AstExpr.IIFE(c, args, _) =>
                Lowerer.scanExpr(c, locals, outer, free)
                for (a in args) {
                    Lowerer.scanExpr(a, locals, outer, free)
                }
            case AstExpr.Interp(parts, _) =>
                for (p in parts) {
                    Lowerer.scanExpr(p, locals, outer, free)
                }
            case AstExpr.StrAdd(l, r, _) =>
                Lowerer.scanExpr(l, locals, outer, free)
                Lowerer.scanExpr(r, locals, outer, free)
            case AstExpr.RegexOp(_, re, s, rp, _, _, _) =>
                Lowerer.scanExpr(re, locals, outer, free)
                Lowerer.scanExpr(s, locals, outer, free)
                match (rp) {
                    case Some(x) => Lowerer.scanExpr(x, locals, outer, free)
                    case None => ()
                }
            case AstExpr.RangeLit(a, b, c, _, _) =>
                Lowerer.scanExpr(a, locals, outer, free)
                Lowerer.scanExpr(b, locals, outer, free)
                match (c) {
                    case Some(x) => Lowerer.scanExpr(x, locals, outer, free)
                    case None => ()
                }
            case AstExpr.ListLit(es, _, _) =>
                for (x in es) {
                    Lowerer.scanExpr(x, locals, outer, free)
                }
            case AstExpr.MapLit(ps, _, _) =>
                for (kv in ps) {
                    Lowerer.scanExpr(kv[0], locals, outer, free)
                    Lowerer.scanExpr(kv[1], locals, outer, free)
                }
            case AstExpr.TupleLit(es, _) =>
                for (x in es) {
                    Lowerer.scanExpr(x, locals, outer, free)
                }
            case AstExpr.Index(t, i, _) =>
                Lowerer.scanExpr(t, locals, outer, free)
                Lowerer.scanExpr(i, locals, outer, free)
            case AstExpr.IndexTarget(t, i, _) =>
                Lowerer.scanExpr(t, locals, outer, free)
                Lowerer.scanExpr(i, locals, outer, free)
            case AstExpr.MemberName(_, t, _) => Lowerer.scanExpr(t, locals, outer, free)
            case _ => ()
        }
    }

    /** 十进制字面量 → `(sign, scale, coeff)`；按 UTF-8 字节扫描（§11.5）。 */
    private static func decimalParts(text: String, extraScale: Int32): (UInt8, Int32, String) {
        let bs = text.unsafeBytes()
        var i = 0
        var neg = false
        if (i < bs.size && (bs[i] == 0x2Du8 || bs[i] == 0x2Bu8)) {
            neg = bs[i] == 0x2Du8
            i = i + 1
        }
        var intDigits = ArrayList<UInt8>()
        while (i < bs.size && bs[i] >= 0x30u8 && bs[i] <= 0x39u8) {
            intDigits.add(bs[i])
            i = i + 1
        }
        var fracDigits = ArrayList<UInt8>()
        if (i < bs.size && bs[i] == 0x2Eu8) {
            i = i + 1
            while (i < bs.size && bs[i] >= 0x30u8 && bs[i] <= 0x39u8) {
                fracDigits.add(bs[i])
                i = i + 1
            }
        }
        var exp: Int64 = 0
        if (i < bs.size && (bs[i] == 0x65u8 || bs[i] == 0x45u8)) {
            i = i + 1
            var eneg = false
            if (i < bs.size && (bs[i] == 0x2Du8 || bs[i] == 0x2Bu8)) {
                eneg = bs[i] == 0x2Du8
                i = i + 1
            }
            var ev: Int64 = 0
            while (i < bs.size && bs[i] >= 0x30u8 && bs[i] <= 0x39u8) {
                ev = ev * 10 + Int64(bs[i] - 0x30u8)
                i = i + 1
            }
            exp = if (eneg) { 0 - ev } else { ev }
        }
        var digits = ArrayList<UInt8>()
        for (b in intDigits) {
            digits.add(b)
        }
        for (b in fracDigits) {
            digits.add(b)
        }
        var j = 0
        while (j + 1 < digits.size && digits[j] == 0x30u8) {
            j = j + 1
        }
        var coeff = ArrayList<UInt8>()
        var k = j
        while (k < digits.size) {
            coeff.add(digits[k])
            k = k + 1
        }
        if (coeff.size == 0) {
            coeff.add(0x30u8)
        }
        let scale = Int32(fracDigits.size) - Int32(exp) + extraScale
        (if (neg) { 1u8 } else { 0u8 }, scale, String.fromUtf8(coeff.toArray()))
    }

    private static func parseInt64(s: String): ?Int64 {
        let bs = s.unsafeBytes()
        if (bs.size == 0) {
            return None
        }
        var neg = false
        var i = 0
        if (bs[0] == 0x2Du8 || bs[0] == 0x2Bu8) {
            neg = bs[0] == 0x2Du8
            i = 1
        }
        if (i >= bs.size) {
            return None
        }
        var v: Int64 = 0
        while (i < bs.size) {
            let c = bs[i]
            if (c < 0x30u8 || c > 0x39u8) {
                return None
            }
            let d = Int64(c - 0x30u8)
            if (v > 922337203685477580 || (v == 922337203685477580 && d > 7)) {
                return None
            }
            v = v * 10 + d
            i = i + 1
        }
        if (neg) {
            -v
        } else {
            v
        }
    }

    private static func stripF64Suffix(s: String): String {
        if (s.endsWith('f64')) {
            return s[0..s.size - 3]
        }
        s
    }
}
