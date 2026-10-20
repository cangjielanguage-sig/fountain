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
import fountain::f_macros.*

/**
 * `@JitBind`（M2.1）：修饰**类**，把它的公共成员一次性展开成类型化绑定。
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
 * - **构造器**（`init`）→ `PublicCtor`。
 *
 * 每条绑定体都是「`as` 成声明类型后静态调用」，不经 `InstanceVariableInfo.getValue` /
 * `InstanceFunctionInfo.apply` / `ConstructorInfo.apply` 的 MCC 路径。
 * 静态成员、私有成员、泛型方法不展开（泛型发 WARNING）。
 */
public macro JitBind(input: Tokens): Tokens {
    let klass = match (parseDecl(input)) {
        case c: ClassDecl => c
        case _ =>
            diagReport(ERROR, input, '@JitBind 只能修饰类', '')
            return input
    }
    let clsName = klass.identifier
    var methods = quote()
    var fields = quote()
    var ctors = quote()
    var hasMethod = false
    var hasField = false
    var hasCtor = false
    var skippedGeneric = 0

    for (d in klass.body.decls) {
        match (d) {
            case f: FuncDecl where isPublic(f) && !isStatic(f) =>
                if (f.identifier.value == 'init') {
                    if (!hasCtor) {
                        ctors += buildCtor(f, clsName)
                        hasCtor = true
                    } else {
                        diagReport(WARNING, input,
                            '${clsName.value}：多构造器只展开第一个，其余走反射', '')
                    }
                } else if (f.isGenericDecl) {
                    skippedGeneric = skippedGeneric + 1
                } else {
                    if (hasMethod) {
                        methods += Token(TokenKind.COMMA, ',').toTokens()
                    }
                    methods += buildMethod(f, clsName)
                    hasMethod = true
                }
            case v: VarDecl where isPublic(v) && !isStatic(v) =>
                if (hasField) {
                    fields += Token(TokenKind.COMMA, ',').toTokens()
                }
                fields += buildField(v, clsName)
                hasField = true
            case p: PropDecl where isPublic(p) && !isStatic(p) =>
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
    quote(
        $input
        let $enrollName = JitBindSupport.enrollOf<$clsName>(
            JitBindings(
                methods: [$methods],
                fields: [$fields],
                ctors: [$ctors]
            )
        )
    )
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
                }
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
                }
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
    let ts = t.toTokens()
    var name = ''
    if (ts.size > 0) {
        name = ts[0].value
    }
    let c = match (name) {
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
    Token(TokenKind.INTEGER_LITERAL, c.toString()).toTokens()
}
