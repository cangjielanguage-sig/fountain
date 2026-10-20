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
 * `@JitBind`（M2.1）：修饰**类**，把它的公共实例方法一次性展开成 `overrides`。
 *
 * ```
 * @JitBind
 * public class ReflectUser { public func greet(s: String): String { … } }
 *
 * c.registerType<ReflectUser>(overrides: jitOverrides_ReflectUser())
 * ```
 *
 * 展开结果 = 「原类 + 一个顶层函数 `jitOverrides_<类名>(): Array<PublicMethod>`」。
 * 每条绑定的函数体是**类型化嵌套调用**：逐参 `as` 成声明类型后静态调用目标方法，
 * 不再经 `InstanceFunctionInfo.apply` 的 MCC 路径（GAP-13 的根治形态）。
 *
 * 覆盖范围与边界：
 * - **公共实例方法**会被展开；`init`、静态方法、泛型方法、带宏展开的成员跳过；
 * - **字段（var/let）不展开**：字段访问走 H64/H65 的字段表，`PublicField` 没有 override 通道，
 *   宏无从替换——这是注册面的结构限制，不是宏的取舍；
 * - **属性（prop）暂未展开**：值型属性走反射已实测稳定（GAP-13 不涉及），需要时可后续补；
 * - 类型码经 `JitBindSupport.code<T>()` 在**注册期**算出，映射不到即报 3（CALL_CONTRACT）。
 */
public macro JitBind(input: Tokens): Tokens {
    let klass = match (parseDecl(input)) {
        case c: ClassDecl => c
        case _ =>
            diagReport(ERROR, input, '@JitBind 只能修饰类', '')
            return input
    }
    let clsName = klass.identifier
    var items = quote()
    var first = true
    var skippedGeneric = 0
    for (d in klass.body.decls) {
        match (d) {
            case f: FuncDecl where isPublic(f) && !isStatic(f) && f.identifier.value != 'init' =>
                if (f.isGenericDecl) {
                    skippedGeneric = skippedGeneric + 1
                    continue
                }
                if (!first) {
                    items += Token(TokenKind.COMMA, ',').toTokens()
                }
                items += buildItem(f, clsName)
                first = false
            case _ => ()
        }
    }
    if (skippedGeneric > 0) {
        diagReport(WARNING, input,
            '${clsName.value}：${skippedGeneric} 个泛型方法未生成绑定（无法静态确定类型）', '')
    }
    let fnName = Token(TokenKind.IDENTIFIER, 'jitOverrides_' + clsName.value)
    quote(
        $input
        public func $fnName(): Array<PublicMethod> {
            [$items]
        }
    )
}

private func buildItem(f: FuncDecl, clsName: Token): Tokens {
    let nameTok = f.identifier
    let nameStr = Token(TokenKind.STRING_LITERAL, nameTok.value)
    let params = f.funcParams

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
        let rt = f.declType
        quote(JitBindSupport.code<$rt>())
    } catch (_) {
        quote(JitBindSupport.UNIT_CODE)
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
