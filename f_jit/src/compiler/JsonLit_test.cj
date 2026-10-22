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

import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_jit.base.DummyDiagnosticsSink
import fountain::f_jit.base.LocalType
import fountain::f_jit.base.SourceCompileException
import fountain::f_jit.base.Version
import fountain::f_jit.bytecode.FbcReader
import fountain::f_jit.bytecode.LoadedUnit
import fountain::f_jit.test.TCase

/**
 * M3 R3.6–R3.8：JSON 字面量的词法、`{`/`[` 原义、静态类型与发射（m3 §11 / D4）。
 *
 * 口径：字面量只有**反引号**一种形态；`{`/`[` 保持 M1 原义（闭包 / 空 Map / 列表 / 下标），
 * 与 JSON **没有消歧**；体首字符定静态类型（17/18），非空 → 常量 kind 11，空 → H83。
 */
@Test
public class JsonLit_test {

    // ------------------------------------------------------------------
    // R3.6 词法：反引号取界与段内保护
    // ------------------------------------------------------------------

    /** `{"a":"}"}`：串内的 `}` 不干扰取界。 */
    @TestCase
    public func takesBoundaryWithBraceInString(): Unit {
        let t = JsonLit_test.firstToken('`{"a":"}"}`')
        @Assert(t.kind, TokenKind.JsonLit)
        @Assert(t.text, '{"a":"}"}')
        @Assert(TCase.hit('T41/json-boundary-brace', t.text == '{"a":"}"}'), true)
    }

    /** `["]"]`：串内的 `]` 不干扰取界。 */
    @TestCase
    public func takesBoundaryWithBracketInString(): Unit {
        @Assert(JsonLit_test.firstToken('`["]"]`').text, '["]"]')
    }

    /** 嵌套 `[{"k":[]}]`：整体一次取界。 */
    @TestCase
    public func takesNestedBoundary(): Unit {
        @Assert(JsonLit_test.firstToken('`[{"k":[]}]`').text, '[{"k":[]}]')
    }

    /** 段内 `//` 与块注释样式的内容**原样保留**（不被当源码注释剥离）。 */
    @TestCase
    public func keepsCommentLikeContent(): Unit {
        @Assert(JsonLit_test.firstToken('`{"url":"http://x"}`').text, '{"url":"http://x"}')
        @Assert(JsonLit_test.firstToken('`{"p":"/* n */"}`').text, '{"p":"/* n */"}')
        @Assert(TCase.hit('T41/json-comments-kept',
            JsonLit_test.firstToken('`{"url":"http://x"}`').text.contains('//')), true)
    }

    /** 跨行字面量：CRLF / CR 规范化为 `\n`（payload 跨平台逐字节一致）。 */
    @TestCase
    public func normalizesNewlinesInJson(): Unit {
        let t = JsonLit_test.firstToken("`{\r\n\"a\":1}`")
        @Assert(t.text, '{\n"a":1}')
        let t2 = JsonLit_test.firstToken("`{\r\"a\":1}`")
        @Assert(t2.text, '{\n"a":1}')
    }

    /** 缺闭合反引号 → 词法错误（不是把它当普通字符）。 */
    @TestCase
    public func rejectsUnterminatedJson(): Unit {
        var kind = ''
        try {
            let _ = Lexer('`{"a":1}').tokenize()
        } catch (e: SourceCompileException) {
            kind = e.kind
        }
        @Assert(kind, DiagKind.UNTERMINATED_STRING)
    }

    /** 反引号段后的普通 token 正常接续（词法游标不前移过多）。 */
    @TestCase
    public func continuesAfterJsonToken(): Unit {
        let ts = Lexer('`{}` + 1').tokenize()
        @Assert(ts[0].kind, TokenKind.JsonLit)
        @Assert(ts[1].kind, TokenKind.Plus)
        @Assert(ts[2].kind, TokenKind.IntLit)
    }

    // ------------------------------------------------------------------
    // R3.7 `{` / `[` 保持 M1 原义（无消歧）
    // ------------------------------------------------------------------

    /** `{ args => … }` 仍是闭包、`{}` 仍是空 Map、`[…]` 仍是列表、`xs[0]` 仍是下标。 */
    @TestCase
    public func bracesKeepM1Meaning(): Unit {
        let cl = AstShape.retShapeOf(Parser('{ => { x: Int64 => x } }').parseLambda())
        @Assert(cl.startsWith('closure('), true)
        let m = AstShape.retShapeOf(Parser('{ => {} }').parseLambda())
        @Assert(m, 'map{}')
        let l = AstShape.retShapeOf(Parser('{ => [1, 2] }').parseLambda())
        @Assert(l, 'list[lit(1),lit(2)]')
        let i = AstShape.retShapeOf(Parser('{ xs: List<Int64> => xs[0] }').parseLambda())
        @Assert(i.startsWith('index['), true)
        @Assert(TCase.hit('T41/no-disambiguation', cl.startsWith('closure(') && m == 'map{}'), true)
    }

    /**
     * `{ "a" : 1 }` 是 **M1 的映射字面量**，不是 JSON 对象——JSON 只能经反引号书写。
     *
     * 这是「不存在消歧」的负向面：同一段花括号文本落在 M1 语义里就是 Map，绝不会被解释成
     * `JsonObject`；要 JSON 必须写 `` `{"a":1}` ``。
     */
    @TestCase
    public func braceObjectStaysMapLiteral(): Unit {
        let s = AstShape.retShapeOf(Parser('{ => { "a" : 1 } }').parseLambda())
        @Assert(s.startsWith('map{'), true)
        @Assert(s.contains('json('), false)
    }

    // ------------------------------------------------------------------
    // R3.8 静态类型与发射
    // ------------------------------------------------------------------

    /** 体首 `{` ⇒ `JsonObject`(17)；非空 ⇒ 常量 kind 11（`PUSH_KH`）。 */
    @TestCase
    public func objectLiteralBecomesJsonObjectConstant(): Unit {
        let unit = JsonLit_test.compileM3('{ => `{"a":1}` }')
        @Assert(Int64(unit.dir.at(0).retType), Int64(LocalType.JSON_OBJECT))
        let d = JsonLit_test.dumpOf(unit)
        @Assert(d.contains('PUSH_KH'), true)
        @Assert(d.contains('CALL_HELPER 83'), false)
        @Assert(TCase.hit('T41/json-object-const', d.contains('PUSH_KH')), true)
    }

    /** 体首 `[` ⇒ `JsonArray`(18)。 */
    @TestCase
    public func arrayLiteralBecomesJsonArrayConstant(): Unit {
        let unit = JsonLit_test.compileM3('{ => `[1,2]` }')
        @Assert(Int64(unit.dir.at(0).retType), Int64(LocalType.JSON_ARRAY))
        @Assert(JsonLit_test.dumpOf(unit).contains('PUSH_KH'), true)
    }

    /** 空 `{}` ⇒ H83 `json_new`（世界内构造，可变、非常量）。 */
    @TestCase
    public func emptyObjectUsesJsonNew(): Unit {
        let unit = JsonLit_test.compileM3('{ => `{}` }')
        let d = JsonLit_test.dumpOf(unit)
        @Assert(d.contains('CALL_HELPER 83,1'), true)
        @Assert(d.contains('PUSH_KH'), false)
        @Assert(Int64(unit.dir.at(0).retType), Int64(LocalType.JSON_OBJECT))
        @Assert(TCase.hit('T41/json-empty-new', d.contains('CALL_HELPER 83,1')), true)
    }

    /** 空 `[]` ⇒ H83，模式 1（数组）。 */
    @TestCase
    public func emptyArrayUsesJsonNew(): Unit {
        let unit = JsonLit_test.compileM3('{ => `[]` }')
        let d = JsonLit_test.dumpOf(unit)
        @Assert(d.contains('CALL_HELPER 83,1'), true)
        @Assert(Int64(unit.dir.at(0).retType), Int64(LocalType.JSON_ARRAY))
    }

    /** 空体带空白仍是空（`` `{  }` `` ⇒ H83）。 */
    @TestCase
    public func emptyWithWhitespaceStillUsesJsonNew(): Unit {
        @Assert(JsonLit_test.dumpOf(JsonLit_test.compileM3('{ => `{  }` }'))
            .contains('CALL_HELPER 83,1'), true)
    }

    /** 标量顶层（数字 / 字符串 / true / null）→ 编译错误（§12-8①）。 */
    @TestCase
    public func rejectsScalarTopLevel(): Unit {
        @Assert(JsonLit_test.errKind('{ => `123` }'), DiagKind.SYNTAX_ERROR)
        @Assert(JsonLit_test.errKind('{ => `"s"` }'), DiagKind.SYNTAX_ERROR)
        @Assert(JsonLit_test.errKind('{ => `true` }'), DiagKind.SYNTAX_ERROR)
        @Assert(JsonLit_test.errKind('{ => `null` }'), DiagKind.SYNTAX_ERROR)
        @Assert(JsonLit_test.errKind('{ => `  ` }'), DiagKind.SYNTAX_ERROR)
    }

    /**
     * 非法 JSON（语法坏）→ 编译错误，消息含 JSON 语义描述。
     *
     * 注：`f_data` 的解析器对**尾逗号**是宽松的（`{"a":1,}` 可解析），故负向样本用「缺冒号」
     * 这类结构错误；严格性口径最终以 `f_data.json` 为准（m3 §11「加载期/编译期双层拒绝」）。
     */
    @TestCase
    public func rejectsInvalidJson(): Unit {
        @Assert(JsonLit_test.errKind('{ => `{"a":}` }'), DiagKind.SYNTAX_ERROR)
        @Assert(JsonLit_test.errKind('{ => `{"a" 1}` }'), DiagKind.SYNTAX_ERROR)
        @Assert(JsonLit_test.errText('{ => `{"a":}` }').contains('JSON'), true)
        @Assert(TCase.hit('T41/json-invalid', true), true)
    }

    /** 静态类型标注：`JsonObject` 之间可赋值、收进 `JsonValue` 合法；反向与兄弟类型拒绝。 */
    @TestCase
    public func jsonStaticTypeAnnotation(): Unit {
        @Assert(JsonLit_test.errKind('{ => let o: JsonObject = `{}`\n 0 }'), '')
        @Assert(JsonLit_test.errKind('{ => let v: JsonValue = `{"a":1}`\n 0 }'), '')
        @Assert(JsonLit_test.errKind('{ => let a: JsonArray = `{"a":1}`\n 0 }'),
            DiagKind.TYPE_MISMATCH)
        @Assert(JsonLit_test.errKind('{ => let o: JsonObject = `[]`\n 0 }'),
            DiagKind.TYPE_MISMATCH)
    }

    // ------------------------------------------------------------------
    // 工具
    // ------------------------------------------------------------------

    private static func firstToken(src: String): Token {
        Lexer(src).next()
    }

    private static func compileM3(src: String): LoadedUnit {
        let sc = SourceCompiler(PredefinedSnapshot.empty(), DummyDiagnosticsSink(),
            verMajor: Version.M3_MAJOR)
        FbcReader.load(sc.compile(src).raw)
    }

    private static func dumpOf(unit: LoadedUnit): String {
        CodeDump.dump(LowererM2_test.entryBytes(unit))
    }

    private static func errKind(src: String): String {
        var got = ''
        try {
            let _ = JsonLit_test.compileM3(src)
        } catch (e: SourceCompileException) {
            got = e.kind
        }
        got
    }

    private static func errText(src: String): String {
        var got = ''
        try {
            let _ = JsonLit_test.compileM3(src)
        } catch (e: SourceCompileException) {
            got = e.message
        }
        got
    }
}
