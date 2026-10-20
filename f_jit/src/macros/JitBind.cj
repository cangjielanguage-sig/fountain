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

/**
 * `@JitBind[ClassName]`（M2.1）：把实例方法展开成「原方法 + 类型化绑定构造器」。
 *
 * 生成后可在注册处直接取用：
 * ```
 * c.registerType<ReflectUser>(overrides: [ReflectUser.jitBind_greet()])
 * ```
 * 绑定体是**嵌套闭包调用**——逐参 `as` 成声明类型后静态调用，不再经 `InstanceFunctionInfo.apply`
 * 的 MCC 路径（GAP-13 的根治形态）。
 *
 * 约束（宏的固有边界）：
 * - 只能修饰**实例方法**，且必须用 `@JitBind[类名]` 显式给出所属类（宏看不到外层类声明）；
 * - 类的成员清单不在宏可见范围内，故**不能**一次展开整个类，只能逐方法标注；
 * - 参数/返回类型走 `JitBindSupport.code<T>()` 映射，映射不到的类型在**运行期注册时**报 CALL_CONTRACT。
 */
public macro JitBind(attr: Tokens, input: Tokens): Tokens {
    let decl = match (parseDecl(input)) {
        case f: FuncDecl => f
        case _ =>
            diagReport(ERROR, input, '@JitBind 只能修饰实例方法', '')
            return input
    }
    let nameTok = decl.identifier
    let name = nameTok.value
    let params = decl.funcParams

    var codes: Tokens = Token(TokenKind.LSQUARE, '[').toTokens()
    codes += quote(JitBindSupport.HOST_OBJECT_CODE)
    var prelude = quote()
    var callArgs = quote()
    for (i in 0..params.size) {
        let p = params[i]
        let pTok = p.identifier
        let pType = p.paramType
        codes += Token(TokenKind.COMMA, ',').toTokens()
        codes += quote(JitBindSupport.code<$pType>())
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
        let rt = decl.declType
        quote(JitBindSupport.code<$rt>())
    } catch (_) {
        quote(JitBindSupport.UNIT_CODE)
    }

    let bindFnTok = Token(TokenKind.IDENTIFIER, 'jitBind_' + name)
    let nameStr = Token(TokenKind.STRING_LITERAL, name)
    quote(
        $input
        public static func $bindFnTok(): PublicMethod {
            PublicMethod(
                name: $nameStr,
                bind: PredefinedFunction(
                    JitBindSupport.bindNameOf<$attr>($nameStr),
                    $codes,
                    $retCode,
                    { args =>
                        let __self = match (args[0] as $attr) {
                            case Some(v) => v
                            case None => JitBindSupport.typeMismatch()
                        }
                        $prelude
                        __self.$nameTok($callArgs)
                    }
                )
            )
        }
    )
}
