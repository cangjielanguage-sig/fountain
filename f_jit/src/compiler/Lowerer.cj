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
import fountain::f_jit.base.PublicCtor
import fountain::f_jit.base.SourcePos
import fountain::f_jit.bytecode.ConstRegistry
import fountain::f_jit.bytecode.LocalTypes

/** 降低阶段的变量符号：名字 + 槽号 + 静态类型（字节码只记大类，§11.7）。 */
internal class VarSym {
    public let name: String
    public let slot: Int64
    public let ty: UInt16
    /** 13 型：HostClosure 的返回类型码（CALL_HOST 的结果静态类型）。 */
    public let hostRet: UInt16
    /** 14 型：具体类名（成员访问链的类型跟踪，m2 §12.4）。 */
    public let objectName: ?String
    /** 捕获来源（m2 §14.7）；赋值可保守降级（只升不降）。 */
    public var origin: UInt8
    /** 12 型局部：闭包的 fnId（取闭包静态返回类型；`UInt32.Max` = 未知）。 */
    public let closureFnId: UInt32

    public init(name: String, slot: Int64, ty: UInt16,
        hostRet!: UInt16 = LocalType.NONE, objectName!: ?String = None,
        origin!: UInt8 = CaptureOrigin.VALUE, closureFnId!: UInt32 = UInt32.Max) {
        this.name = name
        this.slot = slot
        this.ty = ty
        this.hostRet = hostRet
        this.objectName = objectName
        this.origin = origin
        this.closureFnId = closureFnId
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
    private let view: ClassRegistryView
    private let src: String
    private var ctx: ?FnCtx = None
    private var entryFn: UInt32 = 0u32
    private var topParamTypes: Array<UInt16> = Array<UInt16>()
    private var topRetType: UInt16 = LocalType.I64
    private let closureRets = ArrayList<(UInt32, UInt16)>()
    /** 待排序的名字表条目（NameTable 要求按 (fnId, slot) 严格升序）。 */
    private let pendingNames = ArrayList<(UInt32, Int64, String)>()
    /** 最近一次 `lowerExpr` 产物的静态类知识（14 型链式解析，m2 §12.4）。 */
    private var lastObjectName: ?String = None
    /** 最近一次 `lowerExpr` 产物的 HostClosure 返回码（13 型调用结果）。 */
    private var lastHostRet: UInt16 = LocalType.NONE
    /** 最近一次 `lowerExpr` 产出的内部闭包 fnId（12 型局部的静态返回类型来源）。 */
    private var lastClosureFnId: UInt32 = UInt32.Max
    /** 闭包静态捕获描述符（m2 §14.8；**不进 `.fbc`**）。 */
    private let captureDescs = ArrayList<CaptureDescriptor>()
    /** > 0 表示当前正在降低「返回位置」表达式（逃逸判定）。 */
    private var escapingDepth: Int64 = 0
    /** 第 1 步：句柄型捕获（路径 B/C）放开（Q3.10）。 */
    private static const ALLOW_ESCAPING_HANDLES: Bool = true

    public init(sess: CompileSession, resolver: NameResolver,
        view!: ClassRegistryView = ClassRegistryView(ClassRegistrySnapshot.empty())) {
        this.sess = sess
        this.resolver = resolver
        this.view = view
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
            let code = p.typeAnn.code()
            let slot = ctx.builder.allocSlot(code)
            if (slot != base + Int64(ctx.scopes[0].size)) {
                codeFail('形参槽序错乱: ${slot} / ${base}')
            }
            ctx.scopes[0].add(VarSym(p.name, slot, code, hostRet: p.typeAnn.hostRet(),
                objectName: p.typeAnn.objectName(),
                origin: if (code <= LocalType.UNIT) {
                    CaptureOrigin.VALUE
                } else {
                    CaptureOrigin.PARAMETER
                }))
            this.pendingNames.add((fnId, slot, p.name))
        }
        if (ctx.isClosure) {
            var i: Int64 = 0
            for (name in captureNames) {
                let outer = Lowerer.findIn(parent, name, this.src)
                let slot = ctx.builder.allocSlot(outer.ty)
                let sym = VarSym(name, slot, outer.ty, hostRet: outer.hostRet,
                    objectName: outer.objectName, origin: outer.origin,
                    closureFnId: outer.closureFnId)
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
        var retT: UInt16 = LocalType.UNIT
        match (lambda.retExpr) {
            case Some(e) =>
                // 返回位置的闭包表达式是「逃逸」的（m2 §14.7：仅跨桥返回方向）。
                this.escapingDepth = this.escapingDepth + 1
                retT = this.lowerExprAs(e, this.fnRetType(ctx))
                this.escapingDepth = this.escapingDepth - 1
                if (retT == LocalType.UNIT) {
                    ctx.builder.retVoid()
                } else {
                    ctx.builder.ret()
                }
            case None => ctx.builder.retVoid()
        }
        if (ctx.isClosure) {
            this.setClosureRetType(fnId, retT)
        }
        let body = ctx.builder.finish()
        let types = this.typesOf(ctx)
        this.sess.addFunc(LoweredFunc(fnId, nargs, retT, types, body,
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

    /** 本单元的闭包静态捕获描述符（登记序 = 闭包出现序）。 */
    public func captureDescriptors(): Array<CaptureDescriptor> {
        this.captureDescs.toArray()
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
        // 先按静态预判登记、降低完再按实际类型**覆盖**（`closureRetType` 取首个匹配，
        // 所以这里必须就地改值而不是追加）。
        var i = 0
        while (i < this.closureRets.size) {
            if (this.closureRets[i][0] == fnId) {
                this.closureRets[i] = (fnId, t)
                return
            }
            i = i + 1
        }
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
                var declaredHostRet: UInt16 = LocalType.NONE
                var declaredObject: ?String = None
                match (tyAnn) {
                    case Some(t) =>
                        declared = t.code()
                        declaredHostRet = t.hostRet()
                        declaredObject = t.objectName()
                    case None => ()
                }
                var initTy: UInt16 = declared
                var declaredClosureFnId: UInt32 = UInt32.Max
                match (initE) {
                    case Some(e) =>
                        initTy = this.lowerExprAs(e, declared)
                        if (initTy == LocalType.CLOSURE) {
                            declaredClosureFnId = this.lastClosureFnId
                        }
                    case None =>
                        if (declared == LocalType.NONE) {
                            diagFail(DiagKind.SYNTAX_ERROR, this.src, 0, pos.line, pos.column,
                                '无初始化的声明必须带类型注解（§11.7 局部类型）')
                        }
                }
                if (declared == LocalType.NONE) {
                    declared = initTy
                    if (declared == LocalType.HOST_CLOSURE) {
                        declaredHostRet = this.lastHostRet
                    }
                    if (declared == LocalType.HOST_OBJECT) {
                        declaredObject = this.lastObjectName
                    }
                }
                if (declared == LocalType.NONE) {
                    diagFail(DiagKind.TYPE_MISMATCH, this.src, 0, pos.line, pos.column,
                        '无法推导局部「${name}」的类型')
                }
                let slot = ctx.builder.allocSlot(declared)
                ctx.builder.emitU16(Op.STOREL, UInt16(slot))
                var declaredOrigin: UInt8 = CaptureOrigin.WINDOW
                if (declared <= LocalType.UNIT) {
                    declaredOrigin = CaptureOrigin.VALUE
                } else {
                    match (initE) {
                        case Some(e) => declaredOrigin = this.originOfExpr(e, declared)
                        case None => ()
                    }
                }
                ctx.declare(VarSym(name, slot, declared, hostRet: declaredHostRet,
                    objectName: declaredObject, origin: declaredOrigin,
                    closureFnId: declaredClosureFnId), pos, this.src)
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
                        this.escapingDepth = this.escapingDepth + 1
                        let _ = this.lowerExprAs(e, this.fnRetType(ctx))
                        this.escapingDepth = this.escapingDepth - 1
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
                sym.origin = Lowerer.worseOrigin(sym.origin, this.originOfExpr(rhs, sym.ty))
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
            case AstExpr.MemberName(name, tg, mpos) =>
                match (this.hostObjectClassOf(tg)) {
                    case Some(className) =>
                        this.lowerHostFieldSet(className, name, tg, rhs, mpos)
                    case None =>
                        diagFail(DiagKind.TYPE_MISMATCH, this.src, 0, mpos.line, mpos.column,
                            '字段写「.${name}」的接收者不是静态已知的注册类（m2 §12.4）')
                }
            case AstExpr.FieldSet(tg, field, _, fpos) =>
                match (this.hostObjectClassOf(tg)) {
                    case Some(className) =>
                        this.lowerHostFieldSet(className, field, tg, rhs, fpos)
                    case None =>
                        diagFail(DiagKind.TYPE_MISMATCH, this.src, 0, fpos.line, fpos.column,
                            '字段写「.${field}」的接收者不是静态已知的注册类（m2 §12.4）')
                }
            case _ =>
                diagFail(DiagKind.SYNTAX_ERROR, this.src, 0, pos.line, pos.column,
                    '赋值目标必须是局部变量、容器下标或宿主字段')
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
        this.lastObjectName = None
        this.lastHostRet = LocalType.NONE
        match (e) {
            case AstExpr.Lit(t, pos) => this.lowerLiteral(t, pos)
            case AstExpr.Var(name, pos) =>
                let sym = this.requireVar(name, pos)
                ctx.builder.emitU16(Op.LOADL, UInt16(sym.slot))
                this.lastObjectName = sym.objectName
                this.lastHostRet = sym.hostRet
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
            case AstExpr.CastOr(e, t, fb, pos) => this.lowerCastOr(e, t, fb, pos)
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
            case AstExpr.Interp(parts, pos) => this.lowerInterp(parts, pos)
            case AstExpr.StrAdd(l, r, pos) =>
                let lt = this.lowerExpr(l)
                this.coerceToStr(lt, pos)
                let rt = this.lowerExpr(r)
                this.coerceToStr(rt, pos)
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
            case AstExpr.MemberName(name, tg, pos) => this.lowerMemberValue(name, tg, pos)
            case AstExpr.FieldGet(tg, field, pos) => this.lowerMemberValue(field, tg, pos)
            case AstExpr.FieldSet(tg, field, v, pos) =>
                match (this.hostObjectClassOf(tg)) {
                    case Some(className) => this.lowerHostFieldSet(className, field, tg, v, pos)
                    case None =>
                        diagFail(DiagKind.TYPE_MISMATCH, this.src, 0, pos.line, pos.column,
                            '字段写「.${field}」的接收者不是静态已知的注册类（m2 §12.4）')
                }
                LocalType.UNIT
            case AstExpr.MethodCall(tg, method, args, pos) =>
                match (this.hostObjectClassOf(tg)) {
                    case Some(className) =>
                        match (this.view.fieldOf(className, method)) {
                            case Some(f) =>
                                if (f.`type` == LocalType.HOST_CLOSURE) {
                                    this.lowerHostClosureFieldInvoke(className, method, tg, args, pos)
                                } else {
                                    this.lowerHostMethodCall(className, method, tg, args, pos)
                                }
                            case None =>
                                this.lowerHostMethodCall(className, method, tg, args, pos)
                        }
                    case None =>
                        this.lowerBuiltinMemberCall(method, tg, args, pos)
                }
            case AstExpr.CtorCall(className, args, pos) =>
                this.lowerCtorCall(className, args, pos)
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
        match (this.tryLowerTemporal(op, lt, rt, pos)) {
            case Some(t) => return t
            case None => ()
        }
        let t = this.promote(lt, rt, pos)
        match (op) {
            case TokenKind.Plus =>
                if (t == LocalType.STRING) {
                    // 两个操作数都已入栈：`rt` 在栈顶、`lt` 在 [rsp+8]（§12.4 二元约定）。
                    // 不能按「先 lt 后 rt」的顺序连续 TO_STR —— 那会把 lt 的转换作用到 rt 上。
                    this.coerceToStr(rt, pos)
                    if (lt != LocalType.STRING) {
                        ctx.builder.emit(Op.SWAP)
                        this.coerceToStr(lt, pos)
                        ctx.builder.emit(Op.SWAP)
                    }
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
    /**
     * DateTime / Duration 算术（§11.9 量纲约定）：
     *
     * - `dt − dt → dur`、`dt ± dur → dt`、`dur + dur / dur − dur → dur`；
     * - `dur × Int64` / `Int64 × dur → dur`、`dur ÷ n → dur`（n 位置允许 F64/Decimal 窄化）。
     *
     * 这些组合**不参与数值提升**，必须在 `promote` 之前短路；命中后返回结果类型。
     */
    private func tryLowerTemporal(op: TokenKind, lt: UInt16, rt: UInt16, pos: SourcePos): ?UInt16 {
        let ctx = this.requireCtx()
        if (op == TokenKind.Minus && lt == LocalType.DATETIME && rt == LocalType.DATETIME) {
            ctx.builder.setSite(pos)
            ctx.builder.emit(Op.DT_DIFF)
            return Some(LocalType.DURATION)
        }
        if (op == TokenKind.Plus && lt == LocalType.DATETIME && rt == LocalType.DURATION) {
            ctx.builder.setSite(pos)
            ctx.builder.emit(Op.DT_ADD)
            return Some(LocalType.DATETIME)
        }
        if (op == TokenKind.Minus && lt == LocalType.DATETIME && rt == LocalType.DURATION) {
            ctx.builder.setSite(pos)
            ctx.builder.emit(Op.DT_SUB)
            return Some(LocalType.DATETIME)
        }
        if (op == TokenKind.Plus && lt == LocalType.DURATION && rt == LocalType.DATETIME) {
            ctx.builder.emit(Op.SWAP)
            ctx.builder.setSite(pos)
            ctx.builder.emit(Op.DT_ADD)
            return Some(LocalType.DATETIME)
        }
        if (op == TokenKind.Plus && lt == LocalType.DURATION && rt == LocalType.DURATION) {
            ctx.builder.setSite(pos)
            ctx.builder.emit(Op.DUR_ADD)
            return Some(LocalType.DURATION)
        }
        if (op == TokenKind.Minus && lt == LocalType.DURATION && rt == LocalType.DURATION) {
            ctx.builder.setSite(pos)
            ctx.builder.emit(Op.DUR_SUB)
            return Some(LocalType.DURATION)
        }
        if (op == TokenKind.Star && lt == LocalType.DURATION && rt == LocalType.I64) {
            ctx.builder.setSite(pos)
            ctx.builder.emit(Op.DUR_MUL)
            return Some(LocalType.DURATION)
        }
        if (op == TokenKind.Star && lt == LocalType.I64 && rt == LocalType.DURATION) {
            ctx.builder.emit(Op.SWAP)
            ctx.builder.setSite(pos)
            ctx.builder.emit(Op.DUR_MUL)
            return Some(LocalType.DURATION)
        }
        if (op == TokenKind.Slash && lt == LocalType.DURATION && Lowerer.isNumeric(rt)) {
            this.narrowTopToI64(rt, pos)
            ctx.builder.setSite(pos)
            ctx.builder.emit(Op.DUR_DIV)
            return Some(LocalType.DURATION)
        }
        None
    }

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

    /**
     * 成员**值**（m2 §12.4）：`u.f` → H64；`Duration.<unit>` 走 M1 常量路径。
     *
     * 仅对静态已知为某注册类的 14 型表达式合法；类的静态知识沿 `Var` / 字段 `typeRef` /
     * 构造结果传递（前端只查注册表条目，不做继承谱系上溯，v0.8.31）。
     */
    private func lowerMemberValue(name: String, tg: AstExpr, pos: SourcePos): UInt16 {
        let ctx = this.requireCtx()
        match (this.hostObjectClassOf(tg)) {
            case Some(className) => return this.lowerHostFieldGet(className, name, tg, pos)
            case None => ()
        }
        match (tg) {
            case AstExpr.Var(ns, _) =>
                if (ns == 'Duration') {
                    let nanos = match (name) {
                        case 'Zero' => 0
                        case 'nanosecond' => 1
                        case 'microsecond' => 1000
                        case 'millisecond' => 1000000
                        case 'second' => 1000000000
                        case 'minute' => 60000000000
                        case 'hour' => 3600000000000
                        case 'day' => 86400000000000
                        case _ =>
                            diagFail(DiagKind.NOT_IMPL, this.src, 0, pos.line, pos.column,
                                'Duration.${name} 不是已支持的时间单位')
                    }
                    let hid = this.sess.consts.addDuration(nanos)
                    ctx.builder.emitU16(Op.PUSH_KH, UInt16(hid))
                    return LocalType.DURATION
                }
                diagFail(DiagKind.TYPE_MISMATCH, this.src, 0, pos.line, pos.column,
                    '成员访问「.${name}」的接收者不是静态已知的注册类（m2 §12.4：仅 14 型表达式可用点号）')
            case _ =>
                diagFail(DiagKind.TYPE_MISMATCH, this.src, 0, pos.line, pos.column,
                    '成员访问「.${name}」的接收者不是静态已知的注册类（m2 §12.4）')
        }
    }

    /** `u.f` → `H64(obj, index)`（值型零登记；句柄型条件分配），返回字段静态类型。 */
    private func lowerHostFieldGet(className: String, fieldName: String, tg: AstExpr,
        pos: SourcePos): UInt16 {
        let ctx = this.requireCtx()
        let f = this.view.requireField(className, fieldName, pos, this.src)
        let rt = this.lowerExpr(tg)
        if (rt != LocalType.HOST_OBJECT) {
            diagFail(DiagKind.TYPE_MISMATCH, this.src, 0, pos.line, pos.column,
                '成员访问「.${fieldName}」的接收者不是 HostObject（实际类型码 ${rt}，m2 §12.4）')
        }
        ctx.builder.emitI64(Op.PUSH_I64, Int64(f.index))
        ctx.builder.setSite(pos)
        ctx.builder.callHelper(HelperCodec.HOST_GET_FIELD, 2u8)
        this.lastObjectName = if (f.`type` == LocalType.HOST_OBJECT) { f.typeRef } else { None }
        this.lastHostRet = LocalType.NONE
        f.`type`
    }

    /** `u.f = v` → `H65(obj, index, v)`；`let` 字段 → 编译错误（m2 §12.4 降级表）。 */
    private func lowerHostFieldSet(className: String, fieldName: String, tg: AstExpr,
        rhs: AstExpr, pos: SourcePos): Unit {
        let ctx = this.requireCtx()
        let f = this.view.requireField(className, fieldName, pos, this.src)
        if (!f.mutable) {
            diagFail(DiagKind.TYPE_MISMATCH, this.src, 0, pos.line, pos.column,
                '字段「${className}.${fieldName}」是 let（mutable=false），不可写（m2 §12.4）')
        }
        let rt = this.lowerExpr(tg)
        if (rt != LocalType.HOST_OBJECT) {
            diagFail(DiagKind.TYPE_MISMATCH, this.src, 0, pos.line, pos.column,
                '字段写「.${fieldName}」的接收者不是 HostObject（实际类型码 ${rt}）')
        }
        ctx.builder.emitI64(Op.PUSH_I64, Int64(f.index))
        let _ = this.lowerExprAs(rhs, f.`type`)
        ctx.builder.setSite(pos)
        ctx.builder.callHelper(HelperCodec.HOST_SET_FIELD, 3u8)
        ctx.builder.emit(Op.POP)
        this.lastObjectName = None
        this.lastHostRet = LocalType.NONE
    }

    /** `u.m(a…)` → 预定义调用 `m(u, a…)`（hid 由方法表 bind 解析，m2 §12.4）。 */
    private func lowerHostMethodCall(className: String, methodName: String, tg: AstExpr,
        args: Array<AstExpr>, pos: SourcePos): UInt16 {
        let ctx = this.requireCtx()
        let m = this.view.requireMethod(className, methodName, pos, this.src)
        let slot = this.sess.registry.slotOf(m.bind.name)
        if (slot < 0) {
            diagFail(DiagKind.UNREGISTERED_FUNCTION, this.src, 0, pos.line, pos.column,
                '方法「${className}.${methodName}」的绑定「${m.bind.name}」未注册为预定义函数' +
                '（m2 §12.4：方法表 bind 是包装调用的 hid 来源）')
        }
        let want = m.bind.paramTypes.size - 1
        if (Int64(args.size) != want) {
            diagFail(DiagKind.TYPE_MISMATCH, this.src, 0, pos.line, pos.column,
                '方法「${className}.${methodName}」实参个数不符：需要 ${want}，实际 ${args.size}' +
                '（m2 §12.4 静态签名）')
        }
        let rt = this.lowerExpr(tg)
        if (rt != LocalType.HOST_OBJECT) {
            diagFail(DiagKind.TYPE_MISMATCH, this.src, 0, pos.line, pos.column,
                '方法调用「.${methodName}」的接收者不是 HostObject（实际类型码 ${rt}）')
        }
        var i = 0
        while (i < args.size) {
            let expected = m.bind.paramTypes[i + 1]
            let actual = this.lowerExprAs(args[i], expected)
            if (expected != LocalType.NONE && actual != LocalType.NONE && actual != expected) {
                diagFail(DiagKind.TYPE_MISMATCH, this.src, 0, pos.line, pos.column,
                    '方法「${className}.${methodName}」第 ${i + 1} 个实参类型不符：' +
                    '需要 ${LocalType.name(expected)}，实际 ${LocalType.name(actual)}（m2 §12.4）')
            }
            i = i + 1
        }
        ctx.builder.setSite(pos)
        ctx.builder.callHelper(HelperCodec.hidOfSlot(UInt16(slot)), UInt8(args.size + 1))
        this.lastObjectName = if (m.bind.retType == LocalType.HOST_OBJECT) {
            Some(className)
        } else {
            None
        }
        this.lastHostRet = LocalType.NONE
        m.bind.retType
    }

    /**
     * 14 型表达式的静态类名（链路：局部声明 / 字段 `typeRef` / 方法返回值 / 构造结果）。
     * 其余 → None（点号接收者合法性判定）。
     */
    private func hostObjectClassOf(e: AstExpr): ?String {
        match (e) {
            case AstExpr.Var(name, _) =>
                match (this.requireCtx().find(name)) {
                    case Some(sym) =>
                        if (sym.ty == LocalType.HOST_OBJECT) {
                            sym.objectName
                        } else {
                            None
                        }
                    case None => None
                }
            case AstExpr.MemberName(fieldName, inner, _) =>
                match (this.hostObjectClassOf(inner)) {
                    case Some(cls) =>
                        match (this.view.fieldOf(cls, fieldName)) {
                            case Some(f) =>
                                if (f.`type` == LocalType.HOST_OBJECT) {
                                    f.typeRef
                                } else {
                                    None
                                }
                            case None => None
                        }
                    case None => None
                }
            case AstExpr.FieldGet(inner, fieldName, _) =>
                match (this.hostObjectClassOf(inner)) {
                    case Some(cls) =>
                        match (this.view.fieldOf(cls, fieldName)) {
                            case Some(f) =>
                                if (f.`type` == LocalType.HOST_OBJECT) {
                                    f.typeRef
                                } else {
                                    None
                                }
                            case None => None
                        }
                    case None => None
                }
            case AstExpr.CastOr(_, t, _, _) => t.objectName()
            case AstExpr.MethodCall(inner, methodName, _, _) =>
                match (this.hostObjectClassOf(inner)) {
                    case Some(cls) =>
                        match (this.view.methodOf(cls, methodName)) {
                            case Some(m) =>
                                // 只认注册期记录的返回类名（M2.2）；空 = 不知道。
                                // 旧实现返回**接收者**的类名，等价于假设「方法返回 this」——
                                // 那是猜的，会让 `u.getAddr() as User` 通过静态检查（类型混淆）。
                                if (m.bind.retType == LocalType.HOST_OBJECT && m.bind.retName != '') {
                                    Some(m.bind.retName)
                                } else {
                                    None
                                }
                            case None => None
                        }
                    case None => None
                }
            case AstExpr.CtorCall(className, _, _) =>
                if (this.view.isRegistered(className)) {
                    Some(className)
                } else {
                    None
                }
            case AstExpr.Call(target, _, _) =>
                match (target) {
                    case AstExpr.Var(cname, _) =>
                        if (this.view.isRegistered(cname)) {
                            Some(cname)
                        } else {
                            None
                        }
                    case AstExpr.MemberName(methodName, inner, _) =>
                        match (this.hostObjectClassOf(inner)) {
                            case Some(cls) =>
                                match (this.view.methodOf(cls, methodName)) {
                                    case Some(m) =>
                                        if (m.bind.retType == LocalType.HOST_OBJECT) {
                                            Some(cls)
                                        } else {
                                            None
                                        }
                                    case None => None
                                }
                            case None => None
                        }
                    case _ => None
                }
            case _ => None
        }
    }


    /**
     * 成员**调用**（M1 扩展）：`DateTime.now/parse/of` 与 `Duration.parse`。
     *
     * `DateTime.of` 取 3–7 个位置参数（年、月、日、时、分、秒、纳秒；缺省段为 0）；
     * `Duration.parse` 与 `fountain::f_data` 的 `Duration.parse` 同形（`1h2m3s`、`-1m2s`）。
     */
    private func lowerBuiltinMemberCall(name: String, tg: AstExpr, args: Array<AstExpr>,
        pos: SourcePos): UInt16 {
        let ctx = this.requireCtx()
        match (this.hostObjectClassOf(tg)) {
            case Some(className) =>
                return this.lowerHostMethodCall(className, name, tg, args, pos)
            case None => ()
        }
        // v0.17 `regexStr.regex()`（f_regex 扩展）：字符串 → Regex（无 flags）。
        if (name == 'regex' && args.size == 0) {
            let t = this.lowerExpr(tg)
            if (t != LocalType.STRING) {
                diagFail(DiagKind.TYPE_MISMATCH, this.src, 0, pos.line, pos.column,
                    'regex() 只接受 String 接收者')
            }
            ctx.builder.setSite(pos)
            ctx.builder.callHelper(HelperCodec.STR_TO_REGEX, 1u8)
            return LocalType.REGEX
        }
        match (tg) {
            case AstExpr.Var(ns, _) =>
                if (ns == 'DateTime') {
                    if (name == 'now') {
                        if (args.size != 0) {
                            diagFail(DiagKind.TYPE_MISMATCH, this.src, 0, pos.line, pos.column,
                                'DateTime.now() 不接受参数')
                        }
                        ctx.builder.callHelper(HelperCodec.DATETIME_NOW, 0u8)
                        return LocalType.DATETIME
                    }
                    if (name == 'parse') {
                        if (args.size != 1) {
                            diagFail(DiagKind.TYPE_MISMATCH, this.src, 0, pos.line, pos.column,
                                'DateTime.parse(s) 需要 1 个字符串参数')
                        }
                        let _ = this.lowerExprAs(args[0], LocalType.STRING)
                        ctx.builder.setSite(pos)
                        ctx.builder.callHelper(HelperCodec.DATETIME_PARSE, 1u8)
                        return LocalType.DATETIME
                    }
                    if (name == 'of') {
                        if (args.size < 3 || args.size > 7) {
                            diagFail(DiagKind.TYPE_MISMATCH, this.src, 0, pos.line, pos.column,
                                'DateTime.of 需要 3–7 个整数参数（年、月、日[, 时, 分, 秒[, 纳秒]]）')
                        }
                        for (a in args) {
                            let _ = this.lowerExprAs(a, LocalType.I64)
                        }
                        ctx.builder.setSite(pos)
                        ctx.builder.callHelper(HelperCodec.DATETIME_OF, UInt8(args.size))
                        return LocalType.DATETIME
                    }
                    diagFail(DiagKind.NOT_IMPL, this.src, 0, pos.line, pos.column,
                        'DateTime.${name}() 尚未支持')
                }
                if (ns == 'Duration') {
                    if (name == 'parse') {
                        if (args.size != 1) {
                            diagFail(DiagKind.TYPE_MISMATCH, this.src, 0, pos.line, pos.column,
                                'Duration.parse(s) 需要 1 个字符串参数')
                        }
                        let _ = this.lowerExprAs(args[0], LocalType.STRING)
                        ctx.builder.setSite(pos)
                        ctx.builder.callHelper(HelperCodec.DURATION_PARSE, 1u8)
                        return LocalType.DURATION
                    }
                    diagFail(DiagKind.NOT_IMPL, this.src, 0, pos.line, pos.column,
                        'Duration.${name}() 尚未支持')
                }
                diagFail(DiagKind.NOT_IMPL, this.src, 0, pos.line, pos.column, '成员调用属 M2')
            case _ =>
                diagFail(DiagKind.NOT_IMPL, this.src, 0, pos.line, pos.column, '成员调用属 M2')
        }
    }

    /**
     * `C(args…)` → `CALL_HELPER <ctor-hid>`（m2 §15）。
     *
     * 每条 `PublicCtor` 物化为单元私有 user helper；重载按静态类型匹配，无匹配/歧义 →
     * 编译错误。结果类型 = 14 + 具体类名（可直接进入成员链）。
     */
    private func lowerCtorCall(className: String, args: Array<AstExpr>, pos: SourcePos): UInt16 {
        let ctx = this.requireCtx()
        let ctors = this.view.requireCtors(className, pos, this.src)
        let matches = ArrayList<Int64>()
        var i = 0
        while (i < ctors.size) {
            if (Lowerer.ctorMatches(ctors[i], args, this)) {
                matches.add(i)
            }
            i = i + 1
        }
        if (matches.size == 0) {
            diagFail(DiagKind.TYPE_MISMATCH, this.src, 0, pos.line, pos.column,
                '类「${className}」没有匹配实参的构造器（m2 §15 重载静态匹配）')
        }
        if (matches.size > 1) {
            diagFail(DiagKind.TYPE_MISMATCH, this.src, 0, pos.line, pos.column,
                '构造器调用「${className}」重载歧义：${matches.size} 个候选（m2 §15）')
        }
        let idx = matches[0]
        let ctor = ctors[idx]
        // 实参左→右求值（按选中构造器的形参类型做窄化/校验）。
        var j = 0
        while (j < args.size) {
            let _ = this.lowerExprAs(args[j], ctor.params[j])
            j = j + 1
        }
        let slot = this.sess.allocCtorHelper(className, idx, ctor)
        ctx.builder.setSite(pos)
        ctx.builder.callHelper(HelperCodec.hidOfSlot(slot), UInt8(args.size))
        this.lastObjectName = Some(className)
        this.lastHostRet = LocalType.NONE
        LocalType.HOST_OBJECT
    }

    /** 构造器重载的静态匹配（14 型实参按静态类知识判定）。 */
    private static func ctorMatches(ctor: PublicCtor, args: Array<AstExpr>,
        l: Lowerer): Bool {
        if (ctor.params.size != args.size) {
            return false
        }
        var j = 0
        while (j < args.size) {
            let expected = ctor.params[j]
            if (expected == LocalType.HOST_OBJECT) {
                match (l.hostObjectClassOf(args[j])) {
                    case Some(_) => ()
                    case None => return false
                }
            } else {
                let actual = l.staticTypeFull(args[j])
                if (actual == LocalType.NONE) {
                    return false
                }
                if (actual != expected) {
                    let coercible = (expected == LocalType.F64 && actual == LocalType.I64)
                    if (!coercible) {
                        return false
                    }
                }
            }
            j = j + 1
        }
        true
    }

    /** JSON 谱系类名（m3 内建码 16–19；本层拒绝直接构造）。 */
    private static func isJsonFamily(name: String): Bool {
        name == 'JsonValue' || name == 'JsonObject' || name == 'JsonArray' || name == 'JsonNull'
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
                        if (sym.ty == LocalType.HOST_CLOSURE) {
                            // m2 §3：HostClosure 分支按声明类型静态判定，发射期间零运行期查找。
                            if (this.sess.registry.has(name)) {
                                diagFail(DiagKind.SYNTAX_ERROR, this.src, 0, vpos.line, vpos.column,
                                    '名字冲突：「${name}」既是 HostClosure 形参/局部，又是已注册的 user helper' +
                                    '（m2 §3：禁止静默择一，请改名）')
                            }
                            // m2 §2/§5：`[h_fn, a1..an]` —— 句柄先入栈（栈底），实参左→右。
                            ctx.builder.emitU16(Op.LOADL, UInt16(sym.slot))
                            for (a in args) {
                                let _ = this.lowerExpr(a)
                            }
                            // T31：宿主异常/引擎失败的 site = CALL_HOST 偏移（20/21 分类依据）。
                            ctx.builder.setSite(vpos)
                            ctx.builder.callHost(UInt8(args.size))
                            let r = sym.hostRet
                            this.lastHostRet = LocalType.NONE
                            return if (r == LocalType.NONE) { LocalType.I64 } else { r }
                        }
                        if (sym.ty != LocalType.CLOSURE) {
                            diagFail(DiagKind.TYPE_MISMATCH, this.src, 0, vpos.line, vpos.column,
                                '「${name}」不是可调用值')
                        }
                        ctx.builder.emitU16(Op.LOADL, UInt16(sym.slot))
                        for (a in args) {
                            let _ = this.lowerExpr(a)
                        }
                        ctx.builder.callClosure(UInt8(args.size))
                        if (sym.closureFnId != UInt32.Max) {
                            this.closureRetType(sym.closureFnId)
                        } else {
                            LocalType.I64
                        }
                    case None =>
                        // JSON 谱系是 M3 内建码，零注册、无注册构造器（v0.8.30）。
                        if (Lowerer.isJsonFamily(name)) {
                            diagFail(DiagKind.TYPE_MISMATCH, this.src, 0, vpos.line, vpos.column,
                                '「${name}」属 JSON 谱系内建类型（16–19），无注册构造器（m2 §15/v0.8.30）')
                        }
                        // 已注册类名 → 字节码侧构造（m2 §15）。
                        if (this.view.isRegistered(name)) {
                            return this.lowerCtorCall(name, args, vpos)
                        }
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
                                // T60：预定义函数面的 21 归属需要调用点（与 H64/H65 同口径）。
                                ctx.builder.setSite(vpos)
                                ctx.builder.callHelper(HelperCodec.hidOfSlot(slot), UInt8(args.size))
                                ret
                            case ResolvedCall.HostClosureCall =>
                                notImplFail('HostClosure 调用降低尚未接入（Q3.5）')
                        }
                }
            case AstExpr.MemberName(name, tg, mpos) =>
                if (this.staticTypeFull(target) == LocalType.HOST_CLOSURE) {
                    return this.lowerHostClosureInvoke(target, args, mpos)
                }
                this.lowerBuiltinMemberCall(name, tg, args, mpos)
            case _ =>
                if (this.staticTypeFull(target) == LocalType.HOST_CLOSURE) {
                    return this.lowerHostClosureInvoke(target, args, pos)
                }
                let _ = this.lowerExpr(target)
                for (a in args) {
                    let _ = this.lowerExpr(a)
                }
                ctx.builder.callClosure(UInt8(args.size))
                LocalType.I64
        }
    }

    /**
     * `E as T` / `E as T ?? V`（M2.3）：**能编译期定的不查运行期**，判不了的运行期按类判定。
     *
     * 判定顺序：
     * 1. 静态已可推断为 `T` 或其子类 ⇒ 直接取 `E`（零动作）；
     * 2. 两侧都是 14、相容但静态不确定（下转型，或左面类名未跟踪）⇒ 运行期查 `$as$<T>`；
     * 3. 与 `T` 不相容 / `T` 是函数类型 ⇒ 编译期报错；
     * 4. `V` 必须是 `T` 或其子类，且**只在转型失败时求值**。
     *
     * 运行期形态（`$as$<T>` 是注册期合成的 `(14) -> Bool` 自动函数，走反射父链判定，
     * 子类实例算命中）：
     *
     * ```
     * lower E → STOREL tmp
     * LOADL tmp ; CALL_HELPER $as$T 1 ; JZ fail
     * LOADL tmp ; JMP end
     * fail:  <as>      CALL_HELPER H77 0（恒置 7 BAD_CAST）
     *        <as ?? V> lower V
     * end:
     * ```
     *
     * 为什么失败要另用 H77 而不是让 `$as$<T>` 自己抛：user helper 抛出的普通异常会被统一
     * 转 21（宿主异常），而转型失败必须是 **7 BAD_CAST**；固定 helper 直接 `failWith` 才不改码值。
     */
    private func lowerCastOr(e: AstExpr, t: TypeRef, fb: ?AstExpr, pos: SourcePos): UInt16 {
        let ctx = this.requireCtx()
        let tCode = t.code()
        let sCode = this.staticTypeFull(e)
        let tName = match (t.objectName()) {
            case Some(n) => n
            case None => ''
        }
        let sName = match (this.hostObjectClassOf(e)) {
            case Some(n) => n
            case None => ''
        }
        let sDesc = if (sCode == LocalType.HOST_OBJECT && sName != '') {
            '${sName}'
        } else {
            LocalType.name(sCode)
        }
        var needRuntime = false
        if (tCode == LocalType.HOST_OBJECT) {
            if (sCode != LocalType.HOST_OBJECT) {
                diagFail(DiagKind.TYPE_MISMATCH, this.src, 0, pos.line, pos.column,
                    '`as ${tName}` 的左面静态类型是 ${sDesc}，不是注册类实例——类型不相容')
            }
            if (sName == '') {
                // 类名未跟踪：编译期分不清「是 T / 是 T 的父类 / 无关」⇒ 交给运行期
                needRuntime = true
            } else if (sName != tName && !this.view.isSameOrSubclass(sName, tName)) {
                if (this.view.isSameOrSubclass(tName, sName)) {
                    // 下转型：运行期才知道成不成
                    needRuntime = true
                } else {
                    diagFail(DiagKind.TYPE_MISMATCH, this.src, 0, pos.line, pos.column,
                        '`as ${tName}` 与左面类型 ${sName} 无继承关系——类型不相容')
                }
            }
        } else if (tCode == LocalType.HOST_CLOSURE) {
            diagFail(DiagKind.TYPE_MISMATCH, this.src, 0, pos.line, pos.column,
                '`as` 暂不支持函数类型：形参码不在符号表里，无法静态比对签名（M2.3 边界）')
        } else if (sCode != tCode) {
            diagFail(DiagKind.TYPE_MISMATCH, this.src, 0, pos.line, pos.column,
                '`as ${LocalType.name(tCode)}` 的左面静态类型是 ${sDesc}——类型不相容')
        }
        match (fb) {
            case Some(v) =>
                // 兜底：必须是 T 或其子类（整体类型仍取 T）
                let fCode = this.staticTypeFull(v)
                let fName = match (this.hostObjectClassOf(v)) {
                    case Some(n) => n
                    case None => ''
                }
                if (tCode == LocalType.HOST_OBJECT) {
                    if (fCode != LocalType.HOST_OBJECT || fName == '' ||
                        !this.view.isSameOrSubclass(fName, tName)) {
                        diagFail(DiagKind.TYPE_MISMATCH, this.src, 0, pos.line, pos.column,
                            '`??` 右面必须是 ${tName} 或其子类（实际：' +
                            (if (fName != '') { fName } else { LocalType.name(fCode) }) + '）')
                    }
                } else if (fCode != tCode) {
                    diagFail(DiagKind.TYPE_MISMATCH, this.src, 0, pos.line, pos.column,
                        '`??` 右面必须是 ${LocalType.name(tCode)}（实际：${LocalType.name(fCode)}）')
                }
            case None => ()
        }
        if (!needRuntime) {
            let _ = this.lowerExpr(e)
        } else {
            let slot = this.sess.registry.slotOf('$as$' + tName)
            if (slot < 0) {
                diagFail(DiagKind.TYPE_MISMATCH, this.src, 0, pos.line, pos.column,
                    '内部错误：类「${tName}」缺少转型判定函数（注册期未合成 `$as$` 条目）')
            }
            let tmp = ctx.builder.allocSlot(LocalType.HOST_OBJECT)
            let failL = ctx.builder.newLabel()
            let endL = ctx.builder.newLabel()
            let _ = this.lowerExpr(e)
            ctx.builder.emitU16(Op.STOREL, UInt16(tmp))
            ctx.builder.emitU16(Op.LOADL, UInt16(tmp))
            ctx.builder.setSite(pos)
            ctx.builder.callHelper(HelperCodec.hidOfSlot(UInt16(slot)), 1u8)
            ctx.builder.emitRel(Op.JZ, failL)
            ctx.builder.emitU16(Op.LOADL, UInt16(tmp))
            ctx.builder.emitRel(Op.JMP, endL)
            ctx.builder.place(failL)
            match (fb) {
                case Some(v) =>
                    let _ = this.lowerExpr(v)
                case None =>
                    ctx.builder.setSite(pos)
                    // H77 恒抛；它的返回值（1 格）正好与命中分支的栈深对齐
                    ctx.builder.callHelper(HelperCodec.CAST_FAIL, 0u8)
            }
            ctx.builder.place(endL)
        }
        this.lastObjectName = t.objectName()
        this.lastHostRet = LocalType.NONE
        tCode
    }

    /**
     * 13 型非局部表达式作被调：先求句柄存临时槽 → `LOADL`（栈底）→ 实参左→右 → `CALL_HOST`。
     * 布局 `[h_fn, a1..an]`（m2 §2/§5）；被调表达式仍先于实参求值。
     */
    private func lowerHostClosureInvoke(target: AstExpr, args: Array<AstExpr>,
        pos: SourcePos): UInt16 {
        let ctx = this.requireCtx()
        let ret = this.hostRetOrI64(target)
        let tslot = ctx.builder.allocSlot(LocalType.HOST_CLOSURE)
        let _ = this.lowerExpr(target)
        ctx.builder.emitU16(Op.STOREL, UInt16(tslot))
        ctx.builder.emitU16(Op.LOADL, UInt16(tslot))
        for (a in args) {
            let _ = this.lowerExpr(a)
        }
        ctx.builder.setSite(pos)
        ctx.builder.callHost(UInt8(args.size))
        ret
    }

    /**
     * 被调表达式的 HostClosure **返回码**（`CALL_HOST` 的结果静态类型）。
     *
     * `Var` 从符号表取（形参/局部的 `typeAnn.hostRet()` 已在声明处落表）；字段形态
     * （`u.cb(...)`）的签名不在 `PublicField.typeRef` 里（该字段只承载类名）⇒ 退回 `I64`，
     * 保持 M2 现状而不是把返回值判成未知。
     */
    private func hostRetOrI64(target: AstExpr): UInt16 {
        match (target) {
            case AstExpr.Var(name, _) =>
                match (this.requireCtx().find(name)) {
                    case Some(s) =>
                        if (s.hostRet == LocalType.NONE) {
                            LocalType.I64
                        } else {
                            s.hostRet
                        }
                    case None => LocalType.I64
                }
            case _ => LocalType.I64
        }
    }

    /** `u.cb(a…)`（13 型字段）：H64 求句柄 → 临时槽 → LOADL → 实参 → CALL_HOST。 */
    private func lowerHostClosureFieldInvoke(className: String, field: String, tg: AstExpr,
        args: Array<AstExpr>, pos: SourcePos): UInt16 {
        let ctx = this.requireCtx()
        let tslot = ctx.builder.allocSlot(LocalType.HOST_CLOSURE)
        let _ = this.lowerHostFieldGet(className, field, tg, pos)
        ctx.builder.emitU16(Op.STOREL, UInt16(tslot))
        ctx.builder.emitU16(Op.LOADL, UInt16(tslot))
        for (a in args) {
            let _ = this.lowerExpr(a)
        }
        ctx.builder.setSite(pos)
        ctx.builder.callHost(UInt8(args.size))
        LocalType.I64
    }

    private func lowerInterp(parts: Array<AstExpr>, pos: SourcePos): UInt16 {
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
                this.emitToStr(t, pos)
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

    private func coerceToStr(t: UInt16, pos: SourcePos): Unit {
        if (t == LocalType.STRING) {
            return
        }
        this.emitToStr(t, pos)
    }

    /**
     * `TO_STR` 的 `t` 是 **§6 文本化标签**，不是 `LocalType`：
     * `0=I64 1=F64 2=Bool 3=String 4=Decimal 5=DateTime 6=Duration 7=Range 8=Regex`。
     *
     * 两套编号只在 0–2 重合（`LocalType` 的 3 是 Unit、4 才是 String），
     * 直接透传会把 String 当 Decimal、把 Decimal 当 DateTime——插值串在 JIT 侧
     * 因此报 8（类型不符）或 14（标签越界）。非标签类型（Unit/List/Map/Closure）
     * 一律编译错误（§9 附则 13、§11.9）。
     */
    internal static func toStrTag(t: UInt16): ?UInt8 {
        if (t == LocalType.I64) {
            return Some(0u8)
        }
        if (t == LocalType.F64) {
            return Some(1u8)
        }
        if (t == LocalType.BOOL) {
            return Some(2u8)
        }
        if (t == LocalType.STRING) {
            return Some(3u8)
        }
        if (t == LocalType.DECIMAL) {
            return Some(4u8)
        }
        if (t == LocalType.DATETIME) {
            return Some(5u8)
        }
        if (t == LocalType.DURATION) {
            return Some(6u8)
        }
        if (t == LocalType.RANGE) {
            return Some(7u8)
        }
        if (t == LocalType.REGEX) {
            return Some(8u8)
        }
        None
    }

    private func emitToStr(t: UInt16, pos: SourcePos): Unit {
        let ctx = this.requireCtx()
        match (Lowerer.toStrTag(t)) {
            case Some(tag) => ctx.builder.emitU8(Op.TO_STR, tag)
            case None =>
                diagFail(DiagKind.TYPE_MISMATCH, this.src, 0, pos.line, pos.column,
                    '${LocalType.name(t)} 没有文本形式，不能用于插值或字符串拼接')
        }
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
        // m2 §14.8：静态捕获描述符（逐项分类；**不写入 `.fbc`**）。
        let entries = ArrayList<CaptureEntry>()
        for (name in free) {
            match (outer.find(name)) {
                case Some(sym) =>
                    entries.add(CaptureEntry(name, sym.ty, sym.origin))
                case None =>
                    diagFail(DiagKind.UNDEFINED_IDENTIFIER, this.src, 0, lambda.pos.line,
                        lambda.pos.column, '捕获的变量「${name}」不在外层作用域')
            }
        }
        let desc = CaptureDescriptor(lambda.pos, this.escapingDepth > 0, entries.toArray())
        if (desc.escaping && !Lowerer.ALLOW_ESCAPING_HANDLES) {
            let bad = desc.invalidEntries()
            if (bad.size > 0) {
                let b = bad[0]
                diagFail(DiagKind.TYPE_MISMATCH, this.src, 0, lambda.pos.line, lambda.pos.column,
                    '逃逸闭包捕获了「${b.name}」（来源：${CaptureOrigin.name(b.origin)}）；' +
                    '第 0 步白名单只允许值型 / 路径 A 常量捕获（m2 §14.7）')
            }
        }
        this.captureDescs.add(desc)
        outer.builder.emitI64(Op.PUSH_I64, Int64(fnId))
        for (name in free) {
            let sym = this.requireVar(name, lambda.pos)
            outer.builder.emitU16(Op.LOADL, UInt16(sym.slot))
        }
        this.setClosureRetType(fnId, Lowerer.retTypeOf(lambda))
        this.lowerLambda(lambda, fnId, Some(outer), free, lambda.params.size + 1)
        outer.builder.callHelper(HelperCodec.CLOSURE_NEW, UInt8(free.size + 1))
        this.lastClosureFnId = fnId
    }

    private func lowerRecursiveValue(): UInt16 {
        let ctx = this.requireCtx()
        if (ctx.isClosure) {
            ctx.builder.emitU16(Op.LOADL, 0u16)
            this.lastClosureFnId = ctx.fnId
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
        this.lastClosureFnId = adapterId
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

    /** 含成员链 / 方法 / 构造的静态类型（成员访问的接收者与实参校验用）。 */
    private func staticTypeFull(e: AstExpr): UInt16 {
        match (e) {
            case AstExpr.Var(_, _) => this.staticTypeOf(e)
            case AstExpr.MemberName(fieldName, inner, _) =>
                match (this.hostObjectClassOf(inner)) {
                    case Some(cls) =>
                        match (this.view.fieldOf(cls, fieldName)) {
                            case Some(f) => f.`type`
                            case None => LocalType.NONE
                        }
                    case None => LocalType.NONE
                }
            case AstExpr.FieldGet(inner, fieldName, _) =>
                match (this.hostObjectClassOf(inner)) {
                    case Some(cls) =>
                        match (this.view.fieldOf(cls, fieldName)) {
                            case Some(f) => f.`type`
                            case None => LocalType.NONE
                        }
                    case None => LocalType.NONE
                }
            case AstExpr.FieldSet(_, _, _, _) => LocalType.UNIT
            case AstExpr.MethodCall(inner, methodName, _, _) =>
                match (this.hostObjectClassOf(inner)) {
                    case Some(cls) =>
                        match (this.view.methodOf(cls, methodName)) {
                            case Some(m) => m.bind.retType
                            case None => LocalType.NONE
                        }
                    case None => LocalType.NONE
                }
            case AstExpr.CtorCall(className, _, _) =>
                if (this.view.isRegistered(className)) {
                    LocalType.HOST_OBJECT
                } else {
                    LocalType.NONE
                }
            case AstExpr.CastOr(_, t, _, _) => t.code()
            case AstExpr.Call(target, _, _) =>
                match (target) {
                    case AstExpr.Var(cname, _) =>
                        if (this.view.isRegistered(cname)) {
                            LocalType.HOST_OBJECT
                        } else {
                            this.sess.registry.retTypeOf(cname)
                        }
                    case AstExpr.MemberName(methodName, inner, _) =>
                        match (this.hostObjectClassOf(inner)) {
                            case Some(cls) =>
                                match (this.view.methodOf(cls, methodName)) {
                                    case Some(m) => m.bind.retType
                                    case None => LocalType.NONE
                                }
                            case None => LocalType.NONE
                        }
                    case _ => LocalType.NONE
                }
            case _ => Lowerer.staticTypeOfTop(e)
        }
    }

    /**
     * 表达式的捕获来源分类（m2 §14.7）：值型 / 路径 A 常量 / 路径 C 窗口分配。
     *
     * 路径 B（参数）只在符号声明处产生；局部赋值的来源按「严重度只升不降」保守合并。
     */
    private func originOfExpr(e: AstExpr, ty: UInt16): UInt8 {
        if (ty != LocalType.NONE && ty <= LocalType.UNIT) {
            return CaptureOrigin.VALUE
        }
        match (e) {
            case AstExpr.Var(name, _) =>
                match (this.requireCtx().find(name)) {
                    case Some(sym) => sym.origin
                    case None => CaptureOrigin.CONSTANT
                }
            case AstExpr.Lit(t, _) =>
                match (t.kind) {
                    case TokenKind.StrLit | TokenKind.RegexLit | TokenKind.DecLit =>
                        CaptureOrigin.CONSTANT
                    case _ => CaptureOrigin.VALUE
                }
            case AstExpr.ListLit(_, isEmpty, _) =>
                if (isEmpty) { CaptureOrigin.WINDOW } else { CaptureOrigin.CONSTANT }
            case AstExpr.MapLit(_, isEmpty, _) =>
                if (isEmpty) { CaptureOrigin.WINDOW } else { CaptureOrigin.CONSTANT }
            case AstExpr.RegexOp(_, _, _, _, _, _, _) =>
                if (ty != LocalType.NONE && ty <= LocalType.UNIT) {
                    CaptureOrigin.VALUE
                } else {
                    CaptureOrigin.WINDOW
                }
            case AstExpr.IfExpr(_, t, f, _) =>
                Lowerer.worseOrigin(this.originOfExpr(t, ty), this.originOfExpr(f, ty))
            case AstExpr.Index(target, _, _) =>
                if (this.originOfExpr(target, LocalType.NONE) == CaptureOrigin.CONSTANT) {
                    CaptureOrigin.CONSTANT
                } else {
                    CaptureOrigin.WINDOW
                }
            case AstExpr.FieldGet(inner, _, _) =>
                match (inner) {
                    case AstExpr.Var('Duration', _) => CaptureOrigin.CONSTANT
                    case _ => CaptureOrigin.WINDOW
                }
            case AstExpr.MemberName(_, inner, _) =>
                match (inner) {
                    case AstExpr.Var('Duration', _) => CaptureOrigin.CONSTANT
                    case _ => CaptureOrigin.WINDOW
                }
            case AstExpr.FieldSet(_, _, _, _) => CaptureOrigin.VALUE
            case AstExpr.StrAdd(_, _, _) => CaptureOrigin.WINDOW
            case AstExpr.Interp(_, _) => CaptureOrigin.WINDOW
            case AstExpr.Closure(_, _) => CaptureOrigin.WINDOW
            case AstExpr.IIFE(_, _, _) => CaptureOrigin.WINDOW
            case AstExpr.RecursiveValue(_) => CaptureOrigin.WINDOW
            case AstExpr.RangeLit(_, _, _, _, _) => CaptureOrigin.WINDOW
            case AstExpr.Call(_, _, _) => CaptureOrigin.WINDOW
            case AstExpr.MethodCall(_, _, _, _) => CaptureOrigin.WINDOW
            case AstExpr.CtorCall(_, _, _) => CaptureOrigin.WINDOW
            case AstExpr.CastOr(e, _, fb, _) =>
                match (fb) {
                    case Some(v) => Lowerer.worseOrigin(this.originOfExpr(e, ty),
                        this.originOfExpr(v, ty))
                    case None => this.originOfExpr(e, ty)
                }
            case AstExpr.Binary(_, _, _, _) => CaptureOrigin.WINDOW
            case AstExpr.Unary(_, _, _) => CaptureOrigin.WINDOW
            case _ => CaptureOrigin.WINDOW
        }
    }

    private static func worseOrigin(a: UInt8, b: UInt8): UInt8 {
        if (a >= b) { a } else { b }
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
            case AstExpr.CastOr(_, t, _, _) => t.code()
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
            case AstExpr.FieldGet(t, _, _) => Lowerer.scanExpr(t, locals, outer, free)
            case AstExpr.FieldSet(t, _, v, _) =>
                Lowerer.scanExpr(t, locals, outer, free)
                Lowerer.scanExpr(v, locals, outer, free)
            case AstExpr.MethodCall(t, _, args, _) =>
                Lowerer.scanExpr(t, locals, outer, free)
                for (a in args) {
                    Lowerer.scanExpr(a, locals, outer, free)
                }
            case AstExpr.CtorCall(_, args, _) =>
                for (a in args) {
                    Lowerer.scanExpr(a, locals, outer, free)
                }
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
