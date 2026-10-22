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

/**
 * AST 结构断言的「形状化」辅助（S3.7 及后续各步测试用）。
 *
 * **为什么在非测试文件**：递归 AST 枚举（`AstExpr` / `AstStmt`，构造器载荷含 `Option<AstExpr>`
 * 等）在 `*_test.cj` 编译单元里做 `match` 会读错载荷——仓颉把模块的 `lib` 与 `$test` 编成两个
 * 编译单元，递归 + `Option` 载荷的枚举在两侧布局不一致（2026-10-17 用 `sameShape=SOME /
 * decl=NONE` 探针定位）。把匹配集中到本文件（lib 单元）后，测试只比较产出的字符串。
 */
internal class AstShape {
    /** 源入口 → 尾表达式的形状文本；无尾表达式 → `<no-ret>`。 */
    internal static func exprOf(src: String): String {
        retShapeOf(Parser(src).parseLambda())
    }

    /** 已解析的 lambda → 尾表达式形状文本；无尾表达式 → `<no-ret>`。 */
    internal static func retShapeOf(l: LambdaAst): String {
        match (l.retExpr) {
            case Some(e) => shapeE(e)
            case None => '<no-ret>'
        }
    }

    /** 源入口 → 尾表达式的（行, 列）；无尾表达式 → (-1, -1)。 */
    internal static func retPosOf(src: String): (Int64, Int64) {
        let l = Parser(src).parseLambda()
        match (l.retExpr) {
            case Some(e) => (e.pos().line, e.pos().column)
            case None => (-1, -1)
        }
    }

    internal static func shapeE(e: AstExpr): String {
        match (e) {
            case AstExpr.Lit(t, _) => 'lit(${t.text})'
            case AstExpr.Var(n, _) => 'var(${n})'
            case AstExpr.Binary(op, l, r, _) =>
                '(${opText(op)} ${shapeE(l)} ${shapeE(r)})'
            case AstExpr.Unary(op, x, _) => '(${opText(op)} ${shapeE(x)})'
            case AstExpr.IfExpr(c, t, f, _) =>
                'ifexpr((${shapeE(c)}) ${shapeE(t)} ${shapeE(f)})'
            case AstExpr.Call(t, args, _) => 'call(${shapeE(t)} [${shapeList(args)}])'
            case AstExpr.Closure(l, _) => 'closure(${shapeL(l)})'
            case AstExpr.IIFE(c, args, _) => 'iife(${shapeE(c)} [${shapeList(args)}])'
            case AstExpr.Interp(parts, _) => 'interp(${shapeList(parts)})'
            case AstExpr.StrAdd(l, r, _) => 'stradd(${shapeE(l)} ${shapeE(r)})'
            case AstExpr.RegexOp(op, re, s, r, n, m, _) =>
                var mod = 'g'
                match (n) {
                    case Some(v) =>
                        match (m) {
                            case Some(w) => mod = 'n=${v} m=${w}'
                            case None => mod = 'n=${v}'
                        }
                    case None => ()
                }
                match (r) {
                    case Some(rr) =>
                        'regexop(${opText(op)} ${shapeE(re)} ${shapeE(s)} ${shapeE(rr)} ${mod})'
                    case None => 'regexop(${opText(op)} ${shapeE(re)} ${shapeE(s)})'
                }
            case AstExpr.RangeLit(a, b, st, closed, _) =>
                let op = if (closed) { '..=' } else { '..' }
                match (st) {
                    case Some(sv) => 'range(${shapeE(a)} ${op} ${shapeE(b)} : ${shapeE(sv)})'
                    case None => 'range(${shapeE(a)} ${op} ${shapeE(b)})'
                }
            case AstExpr.ListLit(elems, isEmpty, _) =>
                if (isEmpty) { 'list[]' } else { 'list[${shapeList(elems)}]' }
            case AstExpr.MapLit(pairs, isEmpty, _) =>
                if (isEmpty) {
                    'map{}'
                } else {
                    var out = ''
                    for (i in 0..pairs.size) {
                        let kv = pairs[i]
                        if (i > 0) {
                            out = out + ','
                        }
                        out = out + shapeE(kv[0]) + ':' + shapeE(kv[1])
                    }
                    'map{${out}}'
                }
            case AstExpr.TupleLit(elems, _) => 'tuple(${shapeList(elems)})'
            case AstExpr.RecursiveValue(_) => 'recursive'
            case AstExpr.Index(t, i, _) => 'index[${shapeE(t)},${shapeE(i)}]'
            case AstExpr.IndexTarget(t, i, _) => 'idxTarget[${shapeE(t)},${shapeE(i)}]'
            case AstExpr.MemberName(n, t, _) => 'member(${shapeE(t)}.${n})'
            case AstExpr.FieldGet(t, f, _) => 'field(${shapeE(t)}.${f})'
            case AstExpr.FieldSet(t, f, v, _) => 'fieldset(${shapeE(t)}.${f} = ${shapeE(v)})'
            case AstExpr.MethodCall(t, m, args, _) =>
                'method(${shapeE(t)}.${m} [${shapeList(args)}])'
            case AstExpr.CtorCall(c, args, _) => 'ctor(${c} [${shapeList(args)}])'
            case AstExpr.CastOr(e, t, f, _) =>
                match (f) {
                    case Some(v) => 'castor(${shapeE(e)} as ${builtinName(t)} ?? ${shapeE(v)})'
                    case None => 'castor(${shapeE(e)} as ${builtinName(t)})'
                }
            case AstExpr.IsType(e, t, _) => 'is(${shapeE(e)} is ${builtinName(t)})'
            case AstExpr.JsonLit(_, code, _) => 'json(${LocalType.name(code)})'
        }
    }

    internal static func shapeS(s: AstStmt): String {
        match (s) {
            case AstStmt.Decl(n, ty, initE, _) =>
                let t = typeText(ty)
                match (initE) {
                    case Some(e) => 'decl(${n}${t} = ${shapeE(e)})'
                    case None => 'decl(${n}${t})'
                }
            case AstStmt.Assign(l, r, _) => 'assign(${shapeE(l)} = ${shapeE(r)})'
            case AstStmt.MultiAssign(ls, rs, _) =>
                'multi((${shapeList(ls)}) = (${shapeList(rs)}))'
            case AstStmt.If(c, t, e, _) =>
                let es = match (e) {
                    case Some(v) => ' else ${shapeS(v)}'
                    case None => ''
                }
                'if ((${shapeE(c)})) ${shapeS(t)}${es}'
            case AstStmt.While(c, b, _) => 'while (${shapeE(c)}) ${shapeS(b)}'
            case AstStmt.ForIn(names, it, w, b, _) =>
                var ns = ''
                for (i in 0..names.size) {
                    if (i > 0) {
                        ns = ns + ','
                    }
                    ns = ns + names[i]
                }
                let ws = match (w) {
                    case Some(c) => ' where ${shapeE(c)}'
                    case None => ''
                }
                'forin(${ns} in ${shapeE(it)}${ws}) ${shapeS(b)}'
            case AstStmt.Return(v, _) =>
                match (v) {
                    case Some(e) => 'return(${shapeE(e)})'
                    case None => 'return()'
                }
            case AstStmt.ExprStmt(e, _) => 'expr(${shapeE(e)})'
            case AstStmt.Block(stmts, _) => 'block([${shapeStmtList(stmts)}])'
            case AstStmt.Break(_) => 'break'
            case AstStmt.Continue(_) => 'continue'
        }
    }

    /** 类型注解文本（只承载 `?TypeRef`，不含递归 AST 的 `Option`）。 */
    internal static func typeText(ty: ?TypeRef): String {
        match (ty) {
            case Some(v) => ' : ${builtinName(v)}'
            case None => ''
        }
    }

    /** 分量显示名：14 用具体类名，其余用 `LocalType.name`。 */
    internal static func componentName(code: UInt16, name: String): String {
        if (code == LocalType.HOST_OBJECT && name != '') {
            name
        } else {
            LocalType.name(code)
        }
    }

    internal static func builtinName(v: TypeRef): String {
        match (v) {
            case TypeRef.Builtin(code) => LocalType.name(code)
            case TypeRef.AnyT => 'Any'
            case TypeRef.ListOf(t) => 'List<${AstShape.builtinName(t)}>'
            case TypeRef.MapOf(k, x) => 'Map<${AstShape.builtinName(k)},${AstShape.builtinName(x)}>'
            case TypeRef.HostClosureT(params, pns, ret, rn) =>
                var ps = ''
                for (i in 0..params.size) {
                    if (i > 0) {
                        ps = ps + ','
                    }
                    ps = ps + AstShape.componentName(params[i], pns[i])
                }
                '(${ps}) -> ${AstShape.componentName(ret, rn)}'
            case TypeRef.HostObjectT(name) => name
        }
    }

    internal static func shapeL(l: LambdaAst): String {
        var ps = ''
        for (i in 0..l.params.size) {
            if (i > 0) {
                ps = ps + ','
            }
            let pa = l.params[i]
            let t = match (pa.typeAnn) {
                case TypeRef.Builtin(code) => LocalType.name(code)
                case TypeRef.AnyT => 'Any'
                case TypeRef.ListOf(_) => 'List'
                case TypeRef.MapOf(_, _) => 'Map'
                case TypeRef.HostClosureT(_, _, _, _) => 'HostClosure'
                case TypeRef.HostObjectT(n) => n
            }
            ps = ps + pa.name + ':' + t
        }
        var es = ''
        match (l.retExpr) {
            case Some(r) => es = ' => ' + shapeE(r)
            case None => ()
        }
        '(${ps})${es}'
    }

    internal static func shapeList(xs: Array<AstExpr>): String {
        var s = ''
        for (i in 0..xs.size) {
            if (i > 0) {
                s = s + ','
            }
            s = s + shapeE(xs[i])
        }
        s
    }

    internal static func shapeStmtList(xs: Array<AstStmt>): String {
        var s = ''
        for (i in 0..xs.size) {
            if (i > 0) {
                s = s + ','
            }
            s = s + shapeS(xs[i])
        }
        s
    }

    /** 运算符 kind → 源码符号文本（与 design §4.3.1 全表同形）。 */
    internal static func opText(k: TokenKind): String {
        match (k) {
            case TokenKind.Plus => '+'
            case TokenKind.Minus => '-'
            case TokenKind.Star => '*'
            case TokenKind.Slash => '/'
            case TokenKind.Percent => '%'
            case TokenKind.EqEq => '=='
            case TokenKind.NotEq => '!='
            case TokenKind.Lt => '<'
            case TokenKind.Le => '<='
            case TokenKind.Gt => '>'
            case TokenKind.Ge => '>='
            case TokenKind.AndAnd => '&&'
            case TokenKind.OrOr => '||'
            case TokenKind.Amp => '&'
            case TokenKind.Pipe => '|'
            case TokenKind.Caret => '^'
            case TokenKind.Shl => '<<'
            case TokenKind.Shr => '>>'
            case TokenKind.Tilde => '~'
            case TokenKind.BangTilde => '!~'
            case TokenKind.Bang => '!'
            case _ => '?'
        }
    }
}
