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
macro package fountain::f_jit.macros

import std.ast.*
import std.collection.HashSet
import fountain::f_macros.*

/**
 * `@JitBind`（M2.1 / 接口扩展）：修饰**类或接口**，把公共成员一次性展开成类型化绑定。
 *
 * ```
 * @JitBind
 * public class ReflectUser { public var name: String; public func greet(s: String): String }
 *
 * c.registerType<ReflectUser>()   // 不传 bindings，自动取用包初始化期的登记
 * ```
 *
 * 展开结果 = 「原类 + 一个包级 `let jitBindEnroll_<类名> = enrollOf<类名>(JitBindings(…))`」，
 * **不往类里插任何声明，也不生成中间函数**。
 *
 * 覆盖面（按性能立项，不按稳定性）：
 * - **实例方法** → `PublicMethod`；
 * - **实例字段**（`var`/`let`）→ `JitFieldBinding`（getter；`var` 另带 setter）；
 * - **实例属性**（`prop`/`mut prop`）→ 两条 `PublicMethod`（getter 用属性名，setter 用 `set<Name>`）；
 * - **构造器**（`init`）→ 每条一个 `PublicCtor`（重载按形参码区分）；
 * - **静态函数 / 静态只读字段 / 只读静态属性** → `PredefinedFunction`（进 `statics`，
 *   注册时按名替换 `auto` 表里的反射包装）。
 *
 * 每条绑定体都是「`as` 成声明类型后静态调用」，不经 `InstanceVariableInfo.getValue` /
 * `InstanceFunctionInfo.apply` / `ConstructorInfo.apply` 的 MCC 路径。
 * 私有成员、泛型方法不展开（泛型发 WARNING）；`static var` 与 `static mut prop`
 * 属注册面的「永久排除」（`§12.5` 附 B），宏只发 WARNING、不生成。
 */
public macro JitBind(input: Tokens): Tokens {
    let klass: CompositeDecl = match (parseDecl(input)) {
        case c: ClassDecl => c
        case i: InterfaceDecl => i
        case _ =>
            diagReport(ERROR, input, '@JitBind 只能修饰类或接口', '')
            return input
    }
    let isIface = klass is InterfaceDecl
    let clsName = klass.identifier
    var methods = quote()
    var fields = quote()
    var ctors = quote()
    var statics = quote()
    var hasMethod = false
    var hasField = false
    var hasCtor = false
    var hasStatic = false
    var skippedGeneric = 0

    // 子宏 `@IgnoreJitBinding` 先展开并投递成员名；这里按名字跳过（D10）。
    let ignored = HashSet<String>()
    for (msg in getChildMessages('IgnoreJitBinding')) {
        ignored.add(msg.getString('member'))
    }

    for (d in klass.body.decls) {
        match (unwrapMemberMacro(d)) {
            case f: FuncDecl where (isPublic(f) || isIface) && !isStatic(f) =>
                if (f.identifier.value == 'init') {
                    if (hasCtor) {
                        ctors += Token(TokenKind.COMMA, ',').toTokens()
                    }
                    ctors += buildCtor(f, clsName)
                    hasCtor = true
                } else if (ignored.contains(f.identifier.value)) {
                    ()
                } else if (f.isGenericDecl) {
                    skippedGeneric = skippedGeneric + 1
                } else {
                    if (hasMethod) {
                        methods += Token(TokenKind.COMMA, ',').toTokens()
                    }
                    methods += buildMethod(f, clsName)
                    hasMethod = true
                }
            case f: FuncDecl where isPublic(f) && isStatic(f) && !isIface &&
                !ignored.contains(f.identifier.value) =>
                if (f.isGenericDecl) {
                    skippedGeneric = skippedGeneric + 1
                } else {
                    if (hasStatic) {
                        statics += Token(TokenKind.COMMA, ',').toTokens()
                    }
                    statics += buildStaticFunc(f, clsName)
                    hasStatic = true
                }
            case v: VarDecl where isPublic(v) && isStatic(v) && !isIface &&
                !ignored.contains(v.identifier.value) =>
                if (v.isVar()) {
                    diagReport(WARNING, input,
                        '${clsName.value}.${v.identifier.value}：static var 未纳入注册面（附 B），不生成绑定', '')
                } else {
                    if (hasStatic) {
                        statics += Token(TokenKind.COMMA, ',').toTokens()
                    }
                    statics += buildStaticValue(v.identifier, v.declType, clsName, true)
                    hasStatic = true
                }
            case p: PropDecl where isPublic(p) && isStatic(p) && !isIface &&
                !ignored.contains(p.identifier.value) =>
                if (isMut(p)) {
                    diagReport(WARNING, input,
                        '${clsName.value}.${p.identifier.value}：static mut prop 未纳入注册面（附 B），不生成绑定', '')
                } else {
                    if (hasStatic) {
                        statics += Token(TokenKind.COMMA, ',').toTokens()
                    }
                    statics += buildStaticValue(p.identifier, p.declType, clsName, false)
                    hasStatic = true
                }
            case v: VarDecl where isPublic(v) && !isStatic(v) && !isIface &&
                !ignored.contains(v.identifier.value) =>
                if (hasField) {
                    fields += Token(TokenKind.COMMA, ',').toTokens()
                }
                fields += buildField(v, clsName)
                hasField = true
            case p: PropDecl where (isPublic(p) || isIface) && !isStatic(p) &&
                !ignored.contains(p.identifier.value) =>
                if (hasMethod) {
                    methods += Token(TokenKind.COMMA, ',').toTokens()
                }
                methods += buildPropGetter(p, clsName)
                hasMethod = true
                if (isMut(p)) {
                    methods += Token(TokenKind.COMMA, ',').toTokens()
                    methods += buildPropSetter(p, clsName)
                }
            case _ => ()
        }
    }
    if (skippedGeneric > 0) {
        diagReport(WARNING, input,
            '${clsName.value}：${skippedGeneric} 个泛型方法未生成绑定（无法静态确定类型）', '')
    }

    let enrollName = Token(TokenKind.IDENTIFIER, 'jitBindEnroll_' + clsName.value)
    // 忽略名单随登记表一起下发：反射注册侧据此跳过自动包装（D10 的第二层）。
    var ignoredNames = quote()
    var hasIgnored = false
    for (name in ignored) {
        if (hasIgnored) {
            ignoredNames += Token(TokenKind.COMMA, ',').toTokens()
        }
        ignoredNames += Token(TokenKind.STRING_LITERAL, name).toTokens()
        hasIgnored = true
    }
    if (isIface) {
        var parents = quote()
        var hasParent = false
        for (t in klass.superTypes) {
            if (hasParent) {
                parents += Token(TokenKind.COMMA, ',').toTokens()
            }
            parents += Token(TokenKind.STRING_LITERAL, typeNameOf(t)).toTokens()
            hasParent = true
        }
        return quote(
            $input
            let $enrollName = JitBindSupport.enrollInterfaceOf<$clsName>(
                JitBindings(methods: [$methods], parents: [$parents], ignored: [$ignoredNames]),
                { o: Object => o is $clsName }
            )
        )
    }
    quote(
        $input
        let $enrollName = JitBindSupport.enrollOf<$clsName>(
            JitBindings(
                methods: [$methods],
                fields: [$fields],
                ctors: [$ctors],
                statics: [$statics],
                ignored: [$ignoredNames]
            )
        )
    )
}

/** 成员上仍挂着未展开的成员宏时，向下穿透到真实声明；是否忽略由父宏消息决定。 */
private func unwrapMemberMacro(d: Decl): Decl {
    match (d) {
        case m: MacroExpandDecl =>
            var inner: Decl = m.macroInputDecl
            while (let md: MacroExpandDecl <- inner) {
                inner = md.macroInputDecl
            }
            inner
        case _ => d
    }
}

/** 类型节点的首 token 名（接口父类型只需名字，不走 `codeOf` 的 14 判定）。 */
private func typeNameOf(t: TypeNode): String {
    let ts = t.toTokens()
    if (ts.size == 0) {
        ''
    } else {
        ts[0].value
    }
}

// ---- 方法 ----

private func buildMethod(f: FuncDecl, clsName: Token): Tokens {
    let nameTok = f.identifier
    let nameStr = Token(TokenKind.STRING_LITERAL, nameTok.value)
    let params = f.funcParams

    var codes: Tokens = Token(TokenKind.LSQUARE, '[').toTokens()
    codes += Token(TokenKind.INTEGER_LITERAL, '14').toTokens()
    var prelude = quote()
    var callArgs = quote()
    for (i in 0..params.size) {
        let p = params[i]
        let pTok = p.identifier
        let pType = p.paramType
        codes += Token(TokenKind.COMMA, ',').toTokens()
        codes += codeToken(pType)
        prelude += quote(
            let $pTok = match (args[$(i + 1)] as $pType) {
                case Some(v) => v
                case None => JitBindSupport.typeMismatch()
            }
        ) + Token(TokenKind.NL, '\n').toTokens()
        if (i > 0) {
            callArgs += Token(TokenKind.COMMA, ',').toTokens()
        }
        callArgs += pTok.toTokens()
    }
    codes += Token(TokenKind.RSQUARE, ']').toTokens()

    let retCode = try {
        codeToken(f.declType)
    } catch (_) {
        Token(TokenKind.INTEGER_LITERAL, '3').toTokens()
    }
    let retNameStr = try {
        Token(TokenKind.STRING_LITERAL, classNameOf(f.declType))
    } catch (_) {
        Token(TokenKind.STRING_LITERAL, '')
    }

    quote(
        PublicMethod(
            name: $nameStr,
            bind: PredefinedFunction(
                JitBindSupport.bindNameOf<$clsName>($nameStr),
                $codes,
                $retCode,
                { args =>
                    let __self = match (args[0] as $clsName) {
                        case Some(v) => v
                        case None => JitBindSupport.typeMismatch()
                    }
                    $prelude
                    __self.$nameTok($callArgs)
                },
                retName: $retNameStr
            )
        )
    )
}

// ---- 字段 ----

private func buildField(v: VarDecl, clsName: Token): Tokens {
    let nameTok = v.identifier
    let nameStr = Token(TokenKind.STRING_LITERAL, nameTok.value)
    let vType = v.declType
    let setter = if (v.isVar()) {
        quote(
            set: Some({ o, x =>
                match (o as $clsName) {
                    case Some(self) => match (x as $vType) {
                        case Some(v) => self.$nameTok = v
                        case None => JitBindSupport.typeMismatch()
                    }
                    case None => JitBindSupport.typeMismatch()
                }
            })
        )
    } else {
        quote(set: None)
    }
    quote(
        JitFieldBinding(
            name: $nameStr,
            get: { o =>
                match (o as $clsName) {
                    case Some(self) =>
                        let r: Any = self.$nameTok
                        r
                    case None => JitBindSupport.typeMismatch()
                }
            },
            $setter
        )
    )
}

// ---- 属性 ----

private func buildPropGetter(p: PropDecl, clsName: Token): Tokens {
    let nameTok = p.identifier
    let nameStr = Token(TokenKind.STRING_LITERAL, nameTok.value)
    let pType = p.declType
    let c14 = Token(TokenKind.INTEGER_LITERAL, '14').toTokens()
    let pcode = codeToken(pType)
    let pRetName = Token(TokenKind.STRING_LITERAL, classNameOf(pType))
    quote(
        PublicMethod(
            name: $nameStr,
            bind: PredefinedFunction(
                JitBindSupport.bindNameOf<$clsName>($nameStr),
                [$c14],
                $pcode,
                { args =>
                    match (args[0] as $clsName) {
                        case Some(self) =>
                            let r: Any = self.$nameTok
                            r
                        case None => JitBindSupport.typeMismatch()
                    }
                },
                retName: $pRetName
            )
        )
    )
}

private func buildPropSetter(p: PropDecl, clsName: Token): Tokens {
    let nameTok = p.identifier
    let setNameStr = Token(TokenKind.STRING_LITERAL, 'set' + capitalize(nameTok.value))
    let pType = p.declType
    let c14 = Token(TokenKind.INTEGER_LITERAL, '14').toTokens()
    let pcode = codeToken(pType)
    let unitCode = Token(TokenKind.INTEGER_LITERAL, '3').toTokens()
    quote(
        PublicMethod(
            name: $setNameStr,
            bind: PredefinedFunction(
                JitBindSupport.bindNameOf<$clsName>($setNameStr),
                [$c14, $pcode],
                $unitCode,
                { args =>
                    let __self = match (args[0] as $clsName) {
                        case Some(v) => v
                        case None => JitBindSupport.typeMismatch()
                    }
                    let __v = match (args[1] as $pType) {
                        case Some(v) => v
                        case None => JitBindSupport.typeMismatch()
                    }
                    __self.$nameTok = __v
                }
            )
        )
    )
}

private func capitalize(s: String): String {
    if (s.size == 0) {
        return s
    }
    s[0..1].toAsciiUpper() + s[1..]
}

// ---- 构造器 ----

private func buildCtor(f: FuncDecl, clsName: Token): Tokens {
    let params = f.funcParams
    var codes: Tokens = Token(TokenKind.LSQUARE, '[').toTokens()
    var prelude = quote()
    var callArgs = quote()
    for (i in 0..params.size) {
        let p = params[i]
        let pTok = p.identifier
        let pType = p.paramType
        if (i > 0) {
            codes += Token(TokenKind.COMMA, ',').toTokens()
            callArgs += Token(TokenKind.COMMA, ',').toTokens()
        }
        codes += codeToken(pType)
        prelude += quote(
            let $pTok = match (args[$(i)] as $pType) {
                case Some(v) => v
                case None => JitBindSupport.typeMismatch()
            }
        ) + Token(TokenKind.NL, '\n').toTokens()
        callArgs += pTok.toTokens()
    }
    codes += Token(TokenKind.RSQUARE, ']').toTokens()
    quote(
        PublicCtor(
            params: $codes,
            adapter: { args =>
                $prelude
                $clsName($callArgs)
            }
        )
    )
}


/** 源码类型 → `LocalType` 码（编译期决定，避免运行期反射）。 */
private func codeToken(t: TypeNode): Tokens {
    Token(TokenKind.INTEGER_LITERAL, codeOf(t).toString()).toTokens()
}

/** 源码类型 → `LocalType` 码（宏内编译期映射；非内建一律按注册类 14 处理）。 */
private func codeOf(t: TypeNode): Int64 {
    let ts = t.toTokens()
    var name = ''
    if (ts.size > 0) {
        name = ts[0].value
    }
    match (name) {
        case 'Int64' => 0
        case 'Float64' => 1
        case 'Bool' => 2
        case 'Unit' => 3
        case 'String' => 4
        case 'Decimal' => 5
        case 'DateTime' => 6
        case 'Duration' => 7
        case 'Range' => 8
        case 'Regex' => 9
        case 'ArrayList' => 10
        case 'HashMap' => 11
        case _ => 14
    }
}

/** 源码类型 → 返回类名（仅 14 非空）；`PredefinedFunction.retName` 的编译期来源。 */
private func classNameOf(t: TypeNode): String {
    let ts = t.toTokens()
    if (ts.size == 0 || codeOf(t) != 14) {
        return ''
    }
    ts[0].value
}

// ---- 静态成员（无接收者，直接进 auto 函数表）----

private func buildStaticFunc(f: FuncDecl, clsName: Token): Tokens {
    let nameTok = f.identifier
    let nameStr = Token(TokenKind.STRING_LITERAL, nameTok.value)
    let params = f.funcParams
    var codes: Tokens = Token(TokenKind.LSQUARE, '[').toTokens()
    var prelude = quote()
    var callArgs = quote()
    for (i in 0..params.size) {
        let p = params[i]
        let pTok = p.identifier
        let pType = p.paramType
        if (i > 0) {
            codes += Token(TokenKind.COMMA, ',').toTokens()
            callArgs += Token(TokenKind.COMMA, ',').toTokens()
        }
        codes += codeToken(pType)
        prelude += quote(
            let $pTok = match (args[$(i)] as $pType) {
                case Some(v) => v
                case None => JitBindSupport.typeMismatch()
            }
        ) + Token(TokenKind.NL, '\n').toTokens()
        callArgs += pTok.toTokens()
    }
    codes += Token(TokenKind.RSQUARE, ']').toTokens()
    let retCode = try {
        codeToken(f.declType)
    } catch (_) {
        Token(TokenKind.INTEGER_LITERAL, '3').toTokens()
    }
    let sRetName = try {
        Token(TokenKind.STRING_LITERAL, classNameOf(f.declType))
    } catch (_) {
        Token(TokenKind.STRING_LITERAL, '')
    }
    quote(
        PredefinedFunction(
            $nameStr,
            $codes,
            $retCode,
            { args =>
                $prelude
                $clsName.$nameTok($callArgs)
            },
            retName: $sRetName
        )
    )
}

private func buildStaticValue(ident: Token, t: TypeNode, clsName: Token,
    fromVar: Bool): Tokens {
    let nameStr = Token(TokenKind.STRING_LITERAL, ident.value)
    let emptyCodes = Token(TokenKind.LSQUARE, '[').toTokens() +
        Token(TokenKind.RSQUARE, ']').toTokens()
    let pcode = codeToken(t)
    let vRetName = Token(TokenKind.STRING_LITERAL, classNameOf(t))
    quote(
        PredefinedFunction(
            $nameStr,
            $emptyCodes,
            $pcode,
            { _ =>
                let r: Any = $clsName.$ident
                r
            },
            retName: $vRetName
        )
    )
}
