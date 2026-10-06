/*
Copyright (c) 2025 WuJingrun（吴京润）

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
macro package fountain::f_aspect.macros

import std.ast.*
import std.collection.*
import fountain::f_aspect.exception.AspectException
import fountain::f_macros.*
import std.reflect.*

public macro Pointcut(input: Tokens): Tokens {
    if (insideParentContext('Pointcut')) {
        return input
    }
    func doPointcut(decl: Decl): Tokens {
        match (decl) {
            case x: FuncDecl => pointcut(x)
            case x: ClassDecl => pointcut(x)
            case x: MacroExpandDecl =>
                var m: MacroExpandDecl = x
                while (let md: MacroExpandDecl <- m.macroInputDecl) {
                    m = md
                }
                m.macroInputDecl = parseDecl(doPointcut(m.macroInputDecl))
                x.toTokens()
            case x =>
                diagReport(ERROR, input, '${x.identifier.value} must be a func decl or a class decl', '')
                throw AspectException()
        }
    }
    let (decl, remainder) = extractFirstDecl(input)
    quote(
        $(doPointcut(decl))
        $remainder
    )
}

func pointcut(decl: FuncDecl, metaName!: ?Token = None): Tokens {
    var tokens = decl.toTokens()
    var funcDecl = quote()
    for (t in tokens) {
        if (t.kind == TokenKind.LCURL) {
            break
        }
        funcDecl += t
    }
    let params = decl.funcParams
    var argVars = quote()
    var args = `lsquare`
    var argTypes = `lsquare`
    for (i in 0..params.size) {
        let param = match (params[i]) {
            case x: MacroExpandParam =>
                var mp: MacroExpandParam = x
                while (let m: MacroExpandParam <- mp.macroInputDecl) {
                    mp = m
                }
                match (mp.macroInputDecl) {
                    case x: FuncParam => x
                    case x: MacroExpandDecl =>
                        var md: MacroExpandDecl = x
                        while (let m: MacroExpandDecl <- md.macroInputDecl) {
                            md = m
                        }
                        match (md.macroInputDecl) {
                            case x: FuncParam => x
                            case x => FuncParam(x.toTokens())
                        }
                    case x => throw AspectException('unexpected decl ${x.toTokens()} ${ClassTypeInfo.of(x)}')
                }
            case x: FuncParam => x
            case x => throw AspectException('unexpected decl ${x.toTokens()} ${ClassTypeInfo.of(x)}')
        }
        let paramName = param.identifier
        argVars += quote(
            let $paramName = (args[$(i)] as $(param.paramType)).getOrThrow()
        ) + `nl`
        if (i > 0) {
            args += `comma`
            argTypes += `comma`
        }
        args += paramName
        argTypes += quote(TypeInfo.of<$(param.paramType)>())
    }
    args += `rsquare`
    argTypes += `rsquare`
    let funcName = decl.identifier.value
    let funcType = try {
        decl.declType.toTokens()
    } catch (_) {
        `empty_tokens`
    }
    let proceed = if (funcType.size == 0) {
        quote(Aspects.proceed(info, callee))
    } else {
        quote(Aspects.proceed<$funcType>(info, callee))
    }
    // ASP-3（§1.14）：类级织入时用「静态元信息」（见 metaTokens）复用 QualifiedFuncInfo，
    // 不再每次调用重建（含反射解析 getInstanceFunction 与哈希）；拿不到静态元信息时
    // （函数级织入、运算符名、函数自身带泛型参数、形参是宏展开声明等）退回原来的每调用构造写法。
    let infoExpr = match (metaName) {
        case Some(m) => quote(InvocationFuncInfo($m, $args))
        case _ => quote(InvocationFuncInfo(TypeInfo.of(this), $funcName, $argTypes, $args))
    }
    tokens = quote(
        $funcDecl {
            func callee(args: Array<Any>){
                $argVars
                $(decl.block.nodes)
            }
            let info = $infoExpr
            $proceed
        }
    )
    tokens
}

private func pointcut(decl: ClassDecl): Tokens {
    let decls = decl.body.decls
    let allowMeta = !isGenericClass(decl)
    let metas = ArrayList<Tokens>()
    let usedNames = HashSet<String>()
    var ord = HashMap<String, Int64>()
    for (i in 0..decls.size) {
        let d = decls[i]
        if (let f: FuncDecl <- d && !isStatic(d) && isPublic(d) && d.identifier.value != 'init') {
            let metaName = if (allowMeta) {
                nextMetaName(f, ord, usedNames)
            } else {
                None<String>
            }
            let (pf, meta) = weaveOne(f, decl.identifier, metaName)
            decls[i] = parseDecl(pf)
            if (let Some(m) <- meta) {
                metas.add(m)
            }
        } else if (let md: MacroExpandDecl <- d) {
            var m: MacroExpandDecl = md
            while (let md: MacroExpandDecl <- m.macroInputDecl) {
                m = md
            }
            if (let f: FuncDecl <- m.macroInputDecl && !isStatic(f) && isPublic(f)) {
                let metaName = if (allowMeta) {
                    nextMetaName(f, ord, usedNames)
                } else {
                    None<String>
                }
                let (pf, meta) = weaveOne(f, decl.identifier, metaName)
                m.macroInputDecl = parseDecl(pf)
                if (let Some(m2) <- meta) {
                    metas.add(m2)
                }
            }
        }
    }
    for (m in metas) {
        decls.add(parseDecl(m))
    }
    decl.toTokens()
}

/**
 * 类级织入的公共半段：改写一个被织入的函数；`metaName` 非空时同时让它复用静态元信息。
 * 返回（改写后的函数 tokens, ?静态元信息声明 tokens）。`@Pointcut` 的类级路径与 `@WeavedBean` 共用。
 */
func weaveOne(f: FuncDecl, classIdent: Token, metaName: ?String): (Tokens, ?Tokens) {
    match (metaName) {
        case Some(name) => match (metaTokens(f, classIdent, name)) {
            case Some(meta) => (pointcut(f, metaName: Token(TokenKind.IDENTIFIER, name)), meta)
            case _ => (pointcut(f), None<Tokens>)
        }
        case _ => (pointcut(f), None<Tokens>)
    }
}

/**
 * 生成 `private static let __pOIntcUt_x = QualifiedFuncInfo(TypeInfo.of<类>(), '函数', [TypeInfo.of<参数类型>…])`。
 * 不适用时返回 None（退回每调用构造）：构造函数、运算符名等非普通标识符、函数自身带泛型参数、形参是宏展开声明。
 */
func metaTokens(f: FuncDecl, classIdent: Token, metaName: String): ?Tokens {
    if (f.identifier.value == 'init' || !isSimpleName(f.identifier) || hasTypeParams(f)) {
        return None
    }
    var argTypes = `lsquare`
    let ps = f.funcParams
    for (i in 0..ps.size) {
        if (i > 0) {
            argTypes += `comma`
        }
        match (ps[i]) {
            case p: FuncParam => argTypes += quote(TypeInfo.of<$(p.paramType)>())
            case _ => return None
        }
    }
    argTypes += `rsquare`
    let funcName = f.identifier.value
    Some(
        quote(
        private static let $(Token(TokenKind.IDENTIFIER, metaName)) = QualifiedFuncInfo(TypeInfo.of<$(classIdent)>(), $(funcName), $argTypes)
    ))
}

/** 静态元信息变量名：首个用 `__pOIntcUt_<名>`，同名重载依次 `_2`、`_3`…；名字已被占用则放弃静态化。 */
func nextMetaName(f: FuncDecl, ord: HashMap<String, Int64>, used: HashSet<String>): ?String {
    let k = (ord.get(f.identifier.value) ?? 0) + 1
    ord[f.identifier.value] = k
    let name = if (k == 1) {
        '__pOIntcUt_${f.identifier.value}'
    } else {
        '__pOIntcUt_${f.identifier.value}_${k}'
    }
    if (used.contains(name)) {
        return None
    }
    used.add(name)
    Some(name)
}

/** 普通标识符（AST 里的 IDENTIFIER）；运算符名等返回 false ⇒ 不做静态化。 */
func isSimpleName(t: Token): Bool {
    t.kind == TokenKind.IDENTIFIER
}

/** 函数自身是否带泛型参数（`func f<T>(…)`）：扫到参数列表的 `(` 之前的 `<` 即为是。 */
func hasTypeParams(f: FuncDecl): Bool {
    for (t in f.toTokens()) {
        if (t.value == '(') {
            return false
        }
        if (t.value == '<') {
            return true
        }
    }
    false
}

/** 泛型类：`class Foo<T>` 类名后紧跟 `<`；`class Foo <: Bar<Int64>` 紧跟 `<:`，不算。 */
func isGenericClass(decl: ClassDecl): Bool {
    let ts = decl.toTokens()
    for (i in 0..ts.size) {
        if (ts[i].value == 'class') {
            if (i + 2 < ts.size && ts[i + 2].value == '<') {
                return true
            }
            return false
        }
    }
    false
}
