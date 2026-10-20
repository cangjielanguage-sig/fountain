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
import std.collection.ArrayList

/**
 * `@JitSignatures[(T1, T2) -> R, (T3) -> R2, …]` —— **闭包形参的类型化 adapter 自动登记**（M2.3）。
 *
 * 与 `@JitBind` 对类成员做的事完全同构：`@JitBind` 让「类成员」的每次访问变成静态调用，
 * 本宏让「闭包形参」的每次回调变成静态调用——两者都靠**宿主编译期**生成类型化闭包，
 * 运行期只按签名查表，不穿 `FunctionTypeInfo.apply`。
 *
 * 用法（标注在任意一个 `func` 上；宏不改动它，只在**包初始化**时把签名登记进
 * `SignatureRegistry`）：
 *
 * ```cangjie
 * import fountain::f_jit.JitHost
 * import fountain::f_jit.macros.*
 *
 * @JitSignatures[(Int64) -> Int64, (String) -> Bool]
 * public func jitSignatures(): Unit {}
 * ```
 *
 * 生成物 = 每个签名一个包级 `let`（名字 `__jitSig_<函数名>_<序号>`）。
 *
 * **边界**：
 * - 只支持**扁平**签名（形参是单个类型名，允许 `()`）；高阶函数类型由 `HostClosure` 规则本就禁止。
 * - 14 位置必须写**注册类名**，宏按名字记住 `paramNames` / `retName`（与反射注册同一口径）。
 * - 生成代码用短名 `JitHost`，所以标注文件需要 `import fountain::f_jit.JitHost`。
 * - 未登记签名的调用点仍走 M2 的反射路径（行为不变）。
 */
public macro JitSignatures(attr: Tokens, input: Tokens): Tokens {
    expandSignatures(attr, input)
}

/** `@JitSignatures` 无属性形式：没有签名可登记，原样返回并告警。 */
public macro JitSignatures(input: Tokens): Tokens {
    diagReport(WARNING, input, '@JitSignatures 缺少签名列表：写作 @JitSignatures[(T) -> R]', '')
    input
}

private func expandSignatures(attr: Tokens, input: Tokens): Tokens {
    let owner = funcNameOf(input)
    let groups = splitTopLevel(attr)
    var body = quote()
    for (g in groups) {
        body += buildStmt(parseSignature(g, attr))
    }
    // 生成 ① 一个**公开**登记函数（包初始化时由 ② 调用一次；用例可 `resetForTest` 后再调它复原）
    // ② 一个包级 `let`——保证「只要该包被初始化过，签名就已在表里」。
    let fnTok = Token(TokenKind.IDENTIFIER, '__jitSigRegister_' + owner)
    let letTok = Token(TokenKind.IDENTIFIER, '__jitSigApply_' + owner)
    quote(
        public func $fnTok(): Unit {
            $body
        }
        private let $letTok = $fnTok()
        $input
    )
}

// ---------------------------------------------------------------------------
// 解析
// ---------------------------------------------------------------------------

/** 一个扁平函数签名：形参类型 token 序列 + 返回类型 token（保留原 kind）。 */
private class FunSig {
    public let params: Array<Token>
    public let ret: Token

    public init(params: Array<Token>, ret: Token) {
        this.params = params
        this.ret = ret
    }

    /** `(Int64, String) -> Bool` 形态的展示文本。 */
    public func display(): String {
        var out = '('
        var i = 0
        while (i < this.params.size) {
            if (i > 0) {
                out = out + ', '
            }
            out = out + this.params[i].value
            i = i + 1
        }
        out + ') -> ' + this.ret.value
    }
}

/** 包级 `let` 名的来源：标注声明里的函数名（找不到就用 `sig`）。 */
private func funcNameOf(input: Tokens): String {
    var i = 0
    while (i + 1 < input.size) {
        if (input[i].value == 'func' && input[i + 1].kind == TokenKind.IDENTIFIER) {
            return input[i + 1].value
        }
        i = i + 1
    }
    'sig'
}

/** 顶层逗号切分（括号深度为 0 处）。 */
private func splitTopLevel(ts: Tokens): Array<Tokens> {
    var out = ArrayList<Tokens>()
    var cur = quote()
    var depth = 0
    var i = 0
    while (i < ts.size) {
        let t = ts[i]
        if (t.kind == TokenKind.LPAREN) {
            depth = depth + 1
        } else if (t.kind == TokenKind.RPAREN) {
            depth = depth - 1
        }
        if (t.kind == TokenKind.COMMA && depth == 0) {
            out.add(cur)
            cur = quote()
        } else {
            cur += t.toTokens()
        }
        i = i + 1
    }
    if (cur.size > 0) {
        out.add(cur)
    }
    out.toArray()
}

/** `( T1, T2 ) -> R` → `FunSig`。类型 token 只要求「非标点」（`Int64` 等有专用 kind）。 */
private func parseSignature(g: Tokens, whole: Tokens): FunSig {
    if (g.size == 0 || g[0].kind != TokenKind.LPAREN) {
        diagReport(ERROR, whole, '@JitSignatures：签名必须写成 `(T1, T2) -> R`', '')
        throw Exception('@JitSignatures 签名格式错误')
    }
    var i = 1
    var params = ArrayList<Token>()
    var expectParam = true
    while (i < g.size && g[i].kind != TokenKind.RPAREN) {
        let t = g[i]
        if (t.kind == TokenKind.COMMA) {
            expectParam = true
            i = i + 1
            continue
        }
        if (!expectParam) {
            diagReport(ERROR, whole, '@JitSignatures：形参之间缺逗号', '')
            throw Exception('@JitSignatures 形参格式错误')
        }
        if (t.kind == TokenKind.LPAREN) {
            diagReport(ERROR, whole, '@JitSignatures：形参只支持单个类型名（禁高阶）', '')
            throw Exception('@JitSignatures 形参类型错误')
        }
        params.add(t)
        expectParam = false
        i = i + 1
    }
    if (i >= g.size) {
        diagReport(ERROR, whole, '@JitSignatures：缺少 `)`', '')
        throw Exception('@JitSignatures 括号未闭合')
    }
    i = i + 1
    // std.ast 把 `->` 词法成单个 ARROW；兼容被拆成 SUB + GT 的情形
    if (i < g.size && g[i].kind == TokenKind.ARROW) {
        i = i + 1
    } else if (i + 1 < g.size && g[i].kind == TokenKind.SUB && g[i + 1].kind == TokenKind.GT) {
        i = i + 2
    } else {
        diagReport(ERROR, whole, '@JitSignatures：缺少 `->`', '')
        throw Exception('@JitSignatures 缺 ->')
    }
    if (i >= g.size || g[i].kind == TokenKind.LPAREN) {
        diagReport(ERROR, whole, '@JitSignatures：返回类型只支持单个类型名', '')
        throw Exception('@JitSignatures 返回类型错误')
    }
    FunSig(params.toArray(), g[i])
}

// ---------------------------------------------------------------------------
// 生成
// ---------------------------------------------------------------------------

private func buildStmt(s: FunSig): Tokens {
    var fnType = tk(TokenKind.LPAREN, '(')
    var codes = tk(TokenKind.LSQUARE, '[')
    var names = tk(TokenKind.LSQUARE, '[')
    var unpack = quote()
    var callArgs = quote()
    var i = 0
    while (i < s.params.size) {
        let pTok = s.params[i]
        let pName = pTok.value
        if (i > 0) {
            fnType += tk(TokenKind.COMMA, ',')
            codes += tk(TokenKind.COMMA, ',')
            names += tk(TokenKind.COMMA, ',')
            callArgs += tk(TokenKind.COMMA, ',')
        }
        fnType += pTok.toTokens()
        let code = codeOf(pName)
        codes += tk(TokenKind.INTEGER_LITERAL, code.toString())
        names += tk(TokenKind.STRING_LITERAL, classNameOf(pName, code))
        let aTok = Token(TokenKind.IDENTIFIER, '__a' + i.toString())
        let badMsg = tk(TokenKind.STRING_LITERAL,
            '@JitSignatures：实参 ' + i.toString() + ' 与签名不符')
        unpack += quote(
            let $aTok = match (a[$(i)] as $pTok) {
                case Some(v) => v
                case None => throw Exception($badMsg)
            }
        ) + tk(TokenKind.NL, '\n')
        callArgs += aTok.toTokens()
        i = i + 1
    }
    fnType += tk(TokenKind.RPAREN, ')')
    fnType += tk(TokenKind.ARROW, '->')
    fnType += s.ret.toTokens()
    codes += tk(TokenKind.RSQUARE, ']')
    names += tk(TokenKind.RSQUARE, ']')

    let retCode = codeOf(s.ret.value)
    let disp = tk(TokenKind.STRING_LITERAL, s.display())
    let retName = tk(TokenKind.STRING_LITERAL, classNameOf(s.ret.value, retCode))
    let retCodeTok = tk(TokenKind.INTEGER_LITERAL, retCode.toString())
    let gTok = Token(TokenKind.IDENTIFIER, '__g')
    let notSig = tk(TokenKind.STRING_LITERAL, '@JitSignatures：宿主函数与声明签名不符')

    quote(
        let _ = JitHost.registerSignature<$fnType>(
            display: $disp,
            params: $codes,
            paramNames: $names,
            ret: $retCodeTok,
            retName: $retName,
            adapter: { f, a =>
                match (f) {
                    case $gTok: $fnType =>
                        $unpack
                        $gTok($callArgs)
                    case _ => throw Exception($notSig)
                }
            }
        )
    ) + tk(TokenKind.NL, '\n')
}

/** 单 token → Tokens（`` `LPAREN` `` 这类字面量在独立宏包里不可用，只能显式构造）。 */
private func tk(k: TokenKind, text: String): Tokens {
    Token(k, text).toTokens()
}

/** 类型名 → `LocalType` 码（与反射注册、`@JitBind` 同一张表）。 */
private func codeOf(name: String): Int64 {
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

private func classNameOf(name: String, code: Int64): String {
    if (code == 14) {
        name
    } else {
        ''
    }
}

