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
import fountain::f_base.UnsafeBytes
import fountain::f_jit.base.LocalType
import fountain::f_jit.base.SourcePos

/**
 * lambda 源入口语法分析（S3.7）——design-m1 §4.3.2 / §4.3.3、规格 §8.0（源入口格式）、
 * §8.5（嵌套闭包与立即调用）、§11.9（优先级与结合性、正则操作符与替换段词法）。
 *
 * **实现形态**：先把源码**整体切成 token 数组**（经 `Lexer.next()` 逐个取出，`nlBefore` 全保留），
 * 解析器在数组上做**带回退的递归下降**。
 *
 * 为什么不是「parser 边调 `next()` 边解析」：`re/s/r/g` 替换段与 `a / b` 除法在**词法层无法区分**
 * （都由 `Slash` 构成），只能靠**前瞻 + 回退**判定（§11.9 替换段词法）。带索引的 token 数组把
 * 「回退」退化为一次整数赋值，比给扫描器加快照 / 复位 API 更不易出错；`Lexer` 的 `next()` 契约
 * 与 fail-fast 语义完全不变（整串切分仍会命中同样的词法错误、同样的位置）。
 *
 * **语句终结（design §4.3.1）**：`;` 或换行等价；一行多条语句必须用 `;`。
 * 因此「换行」必须可判定 ⇒ 由 `Token.nlBefore` 承载。
 */
internal class Parser {
    /** 插值起始序列：直接写进仓颉字面量会被仓颉自身当作插值起点，故经拼接得到。 */
    internal static const INTERP_START: String = '$' + '{'

    private let src: String
    private let ts: Array<Token>
    private var p: Int64 = 0
    /** > 0 时禁止解析替换段 —— 防止 `re/s/r/g` 的内层片段抢走后续斜杠。 */
    private var replaceDepth: Int64 = 0
    /** 类型注解的「已注册类名」判定（M2 §3：内建 → 注册类名 → 未知=编译错误）。 */
    private let registered: (String) -> Bool

    public init(source: String, registered!: (String) -> Bool = { _ => false }) {
        this.src = Lexer.normalizeNewlines(source)
        this.ts = Lexer(this.src).tokenize()
        this.registered = registered
    }

    // ------------------------------------------------------------------
    // 词法游标
    // ------------------------------------------------------------------

    private func peek(): Token {
        this.ts[this.p]
    }

    private func peekAt(k: Int64): Token {
        let i = this.p + k
        if (i < 0 || i >= this.ts.size) {
            this.ts[this.ts.size - 1]
        } else {
            this.ts[i]
        }
    }

    private func take(): Token {
        let t = this.ts[this.p]
        if (t.kind != TokenKind.EOF) {
            this.p = this.p + 1
        }
        t
    }

    private func atKind(k: TokenKind): Bool {
        this.peek().kind == k
    }

    private func advanceIf(k: TokenKind): Bool {
        if (this.atKind(k)) {
            this.take()
            true
        } else {
            false
        }
    }

    private func expect(k: TokenKind, what: String): Token {
        if (!this.atKind(k)) {
            let t = this.peek()
            diagFail(DiagKind.SYNTAX_ERROR, this.src, t.pos, t.line, t.column,
                '期望 ${what}，实际遇到「${Parser.show(t)}」')
        }
        this.take()
    }

    private static func show(t: Token): String {
        if (t.text.isEmpty()) {
            Parser.kindLabel(t.kind)
        } else {
            t.text
        }
    }

    private static func kindLabel(k: TokenKind): String {
        match (k) {
            case TokenKind.EOF => '源码结束'
            case TokenKind.Arrow => '=>'
            case TokenKind.LParen => '('
            case TokenKind.RParen => ')'
            case TokenKind.LBrace => '{'
            case TokenKind.RBrace => '}'
            case TokenKind.LBracket => '['
            case TokenKind.RBracket => ']'
            case TokenKind.Comma => ','
            case TokenKind.Colon => ':'
            case TokenKind.Semi => ';'
            case TokenKind.Assign => '='
            case TokenKind.Underscore => '_'
            case TokenKind.IntLit | TokenKind.DecLit | TokenKind.F64Lit => '数字字面量'
            case TokenKind.StrLit => '字符串字面量'
            case TokenKind.RegexLit => '正则字面量'
            case TokenKind.Ident => '标识符'
            case _ => '运算符'
        }
    }

    /** 语句是否已终止：`}` / EOF / `;` / 换行（`nlBefore`）都算。 */
    private func atTerminator(): Bool {
        let t = this.peek()
        t.kind == TokenKind.RBrace || t.kind == TokenKind.EOF || t.kind == TokenKind.Semi || t.nlBefore
    }

    /** 消费一条语句终结符（`;` 或换行）；`}` 与 EOF 视为块结束，不强求。 */
    private func endStatement(): Unit {
        if (this.atKind(TokenKind.Semi)) {
            this.take()
        }
    }

    // ------------------------------------------------------------------
    // 入口：lambda 源（§8.0）
    // ------------------------------------------------------------------

    /**
     * 解析整个源入口：**必须且只能是单个 lambda 字面量**（§8.0）。
     *
     * 形参：`name: Type` 逗号分隔；**不支持具名参数与参数默认值**（违者 `BadParameterList`）；
     * `=>` **不可省略**（缺失 → `MissingArrow`）；返回值 = 体末表达式（隐式返回）。
     */
    public func parseLambda(): LambdaAst {
        let open = this.expect(TokenKind.LBrace, '{')
        let pos = SourcePos(open.line, open.column)
        let params = this.parseParams()
        if (!this.atKind(TokenKind.Arrow)) {
            let t = this.peek()
            diagFail(DiagKind.MISSING_ARROW, this.src, t.pos, t.line, t.column,
                'lambda 缺 =>（§8.0：箭头不可省略）')
        }
        this.take()
        let body = this.parseBlockBody()
        let close = this.expect(TokenKind.RBrace, '}')
        if (this.peek().kind != TokenKind.EOF) {
            let t = this.peek()
            diagFail(DiagKind.SYNTAX_ERROR, this.src, t.pos, t.line, t.column,
                '源入口必须且只能是一个 lambda 字面量（尾部出现了多余内容）')
        }
        // 体末的表达式语句即返回值（§8.0 隐式返回）
        let split = Parser.splitTailExpr(body)
        LambdaAst(params, split[0], split[1], pos)
    }

    /** token 起点是否为原始串定界符 `#`（原始串 verbatim，§8.8）。 */
    private static func isRawStringToken(src: String, t: Token): Bool {
        let bs = src.unsafeBytes()
        if (t.pos < 0 || t.pos >= bs.size) {
            return false
        }
        bs[t.pos] == 0x23u8
    }

    /** `?TypeRef` 是否为 `Some`。 */
    private static func isSome(t: ?TypeRef): Bool {
        match (t) {
            case Some(_) => true
            case None => false
        }
    }

    /**
     * 拆分「语句序列 + 尾表达式」：体末的表达式语句即返回值（§8.0 隐式返回）。
     * 返回 `(语句序列, ?尾表达式)`。
     */
    private static func splitTailExpr(body: Array<AstStmt>): (Array<AstStmt>, ?AstExpr) {
        var n = body.size
        var ret: ?AstExpr = None
        if (n > 0) {
            match (body[n - 1]) {
                case AstStmt.ExprStmt(e, _) =>
                    n = n - 1
                    ret = Some(e)
                // 尾位置的 `if`：§5「按使用位置判定」——尾返回 = 值用法 ⇒ 表达式形式
                case AstStmt.If(c, t, Some(el), p) =>
                    match ((Parser.tailValueOf(t), Parser.tailValueOf(el))) {
                        case (Some(te), Some(ee)) =>
                            n = n - 1
                            ret = Some(AstExpr.IfExpr(c, te, ee, p))
                        case _ => ()
                    }
                case _ => ()
            }
        }
        var stmts = ArrayList<AstStmt>()
        for (i in 0..n) {
            stmts.add(body[i])
        }
        (stmts.toArray(), ret)
    }

    /**
     * 语句的**值形态**：块末表达式 / 带 else 的 if 递归折算为表达式。
     *
     * 仅用于尾位置（§5 值用法判定）；分支末不是表达式（如赋值）⇒ `None`（语句形式）。
     */
    private static func tailValueOf(s: AstStmt): ?AstExpr {
        match (s) {
            case AstStmt.ExprStmt(e, _) => Some(e)
            case AstStmt.Block(ss, _) =>
                if (ss.size > 0) {
                    Parser.tailValueOf(ss[ss.size - 1])
                } else {
                    None
                }
            case AstStmt.If(c, t, Some(el), p) =>
                match ((Parser.tailValueOf(t), Parser.tailValueOf(el))) {
                    case (Some(te), Some(ee)) => Some(AstExpr.IfExpr(c, te, ee, p))
                    case _ => None
                }
            case _ => None
        }
    }

    /** 形参表：`name: Type`（可空）；不支持具名参数与默认值。 */
    private func parseParams(): Array<ParamAst> {
        var out = ArrayList<ParamAst>()
        if (this.atKind(TokenKind.Arrow)) {
            return out.toArray()
        }
        var slot: Int64 = 0
        while (true) {
            if (!this.atKind(TokenKind.Ident)) {
                let t = this.peek()
                diagFail(DiagKind.BAD_PARAMETER_LIST, this.src, t.pos, t.line, t.column,
                    '形参必须是「名字: 类型」；不支持具名参数与参数默认值（§8.0）')
            }
            let nameTok = this.take()
            if (!this.atKind(TokenKind.Colon)) {
                let bad = this.peek()
                diagFail(DiagKind.BAD_PARAMETER_LIST, this.src, bad.pos, bad.line, bad.column,
                    '形参必须是「名字: 类型」；不支持具名参数（§8.0）')
            }
            this.take()
            let ty = this.parseTypeRef()
            out.add(ParamAst(nameTok.text, ty, slot, SourcePos(nameTok.line, nameTok.column)))
            slot = slot + 1
            if (this.advanceIf(TokenKind.Comma)) {
                continue
            }
            break
        }
        if (this.atKind(TokenKind.Assign)) {
            let t = this.peek()
            diagFail(DiagKind.BAD_PARAMETER_LIST, this.src, t.pos, t.line, t.column,
                '形参不支持默认值（§8.0）')
        }
        out.toArray()
    }

    /**
     * 类型注解 → `TypeRef`（M1：`Builtin`；M2：`HostClosureT` / `HostObjectT`；M3：`AnyT` /
     * `ListOf` / `MapOf` / JSON 谱系码 16–19）。
     *
     * 容器记 `List<T>` / `Map<K, V>` 时**元素/键值类型进 AST**（`ListOf` / `MapOf`）——字节码
     * 类型表仍只记大类 10/11（§11.7），但 m3 §3 的异构容器要求前端知道元素类型，否则第 ④ 类
     * 装箱插入点（元素写入前 `any_box`）无从发射。裸 `List` / `Map`（无实参）仍允许，元素类型
     * 记为未知（`NONE`），行为与 M1 一致。
     *
     * 函数类型 `(T1, T2) -> R` 的 T/R 合法集 = 0–8、10–11、14（m2 §3）与 15（m3 §3）；
     * 9（Regex）与 12/13（函数类型）拒绝；**禁高阶**：分量不得再是函数类型。
     */
    private func parseTypeRef(): TypeRef {
        if (this.atKind(TokenKind.LParen)) {
            return this.parseClosureType()
        }
        if (!this.atKind(TokenKind.Ident)) {
            let t = this.peek()
            diagFail(DiagKind.BAD_PARAMETER_LIST, this.src, t.pos, t.line, t.column, '缺类型名')
        }
        let nameTok = this.take()
        // `Any` 是 M3 的盒类型（LocalType 15）：非泛型，也不接受容器实参。
        if (nameTok.text == 'Any') {
            if (this.atKind(TokenKind.Lt)) {
                let t = this.peek()
                diagFail(DiagKind.BAD_PARAMETER_LIST, this.src, t.pos, t.line, t.column,
                    'Any 不是泛型类型（m3 §3：盒类型不带类型实参）')
            }
            return TypeRef.AnyT
        }
        let code = Parser.builtinTypeOf(nameTok.text)
        if (code == LocalType.NONE) {
            if (this.registered(nameTok.text)) {
                return TypeRef.HostObjectT(nameTok.text)
            }
            diagFail(DiagKind.BAD_PARAMETER_LIST, this.src, nameTok.pos, nameTok.line, nameTok.column,
                '未注册的类名「${nameTok.text}」（M3 类型集：内建类型 / Any / JSON 谱系 16–19 / ' +
                '已注册类名 / (T…) -> R）')
        }
        if (this.atKind(TokenKind.Lt)) {
            this.take()
            let elem = this.parseTypeRef()
            if (code == LocalType.MAP) {
                this.expect(TokenKind.Comma, 'Map 键值类型之间的逗号')
                let value = this.parseTypeRef()
                this.expect(TokenKind.Gt, '容器类型实参的闭合 >')
                return TypeRef.MapOf(elem, value)
            }
            this.expect(TokenKind.Gt, '容器类型实参的闭合 >')
            return TypeRef.ListOf(elem)
        }
        TypeRef.Builtin(code)
    }

    /** `(T1, T2) -> R` / `() -> R`（m2 §3）。`->` 由 `Minus` + `Gt` 两 token 承载。 */
    private func parseClosureType(): TypeRef {
        let open = this.expect(TokenKind.LParen, '函数类型的 (')
        var params = ArrayList<UInt16>()
        var names = ArrayList<String>()
        if (!this.atKind(TokenKind.RParen)) {
            while (true) {
                let (code, cname) = this.parseTypeComponent()
                params.add(code)
                names.add(cname)
                if (this.advanceIf(TokenKind.Comma)) {
                    continue
                }
                break
            }
        }
        this.expect(TokenKind.RParen, '函数类型的闭合 )')
        if (!this.atKind(TokenKind.Minus) || this.peekAt(1).kind != TokenKind.Gt) {
            let t = this.peek()
            diagFail(DiagKind.BAD_PARAMETER_LIST, this.src, t.pos, t.line, t.column,
                'HostClosure 类型记法缺失 `->`（例：`(Int64) -> Bool`，m2 §3）')
        }
        this.take()
        this.take()
        let (ret, retName) = this.parseTypeComponent()
        for (p in params) {
            Parser.checkSignatureComponent(p, open.line, open.column, this.src)
        }
        Parser.checkSignatureComponent(ret, open.line, open.column, this.src)
        TypeRef.HostClosureT(params.toArray(), names.toArray(), ret, retName)
    }

    /** 函数类型的单个分量（T/R）：内建或已注册类名；再出现 `(` 即禁高阶。 */
    /**
     * 函数类型的单个分量（T/R）：返回「类别码 + 类名」。
     *
     * 类名是 14 位置的区分维度：`(User) -> R` 与 `(Order) -> R` 的码相同，签名注册表要按
     * 类名区分（GAP-04/GAP-05）；非 14 位置返回空串。
     */
    private func parseTypeComponent(): (UInt16, String) {
        if (this.atKind(TokenKind.LParen)) {
            let t = this.peek()
            diagFail(DiagKind.BAD_PARAMETER_LIST, this.src, t.pos, t.line, t.column,
                '禁高阶：HostClosure 的 T/R 不得为函数类型（m2 §3）')
        }
        let tr = this.parseTypeRef()
        let cname = match (tr.objectName()) {
            case Some(n) => n
            case None => ''
        }
        (tr.code(), cname)
    }

    /** T/R 合法集：0–8、10–11、14（m2 §3）与 15（m3 §3 的 `Any` 分量）。 */
    private static func checkSignatureComponent(code: UInt16, line: Int64, column: Int64,
        src: String): Unit {
        let ok = (code <= LocalType.RANGE) || (code == LocalType.LIST) || (code == LocalType.MAP) ||
            (code == LocalType.HOST_OBJECT) || (code == LocalType.ANY)
        if (!ok) {
            diagFail(DiagKind.BAD_PARAMETER_LIST, src, 0, line, column,
                'HostClosure 的 T/R 不合法分量：${LocalType.name(code)}（允许 0–8/10–11/14/15；' +
                '9/12/13 与高阶均拒绝，m2 §3 + m3 §3）')
        }
    }

    private static func builtinTypeOf(name: String): UInt16 {
        match (name) {
            case 'Int64' => LocalType.I64
            case 'Float64' => LocalType.F64
            case 'Bool' => LocalType.BOOL
            case 'Unit' => LocalType.UNIT
            case 'String' => LocalType.STRING
            case 'Decimal' => LocalType.DECIMAL
            case 'DateTime' => LocalType.DATETIME
            case 'Duration' => LocalType.DURATION
            case 'Range' => LocalType.RANGE
            case 'Regex' => LocalType.REGEX
            case 'List' => LocalType.LIST
            case 'Map' => LocalType.MAP
            case 'Closure' => LocalType.CLOSURE
            // M3：JSON 谱系内建码（16–19）。`Any` 走 `AnyT`，不在此表（见 parseTypeRef）。
            case 'JsonValue' => LocalType.JSON_VALUE
            case 'JsonObject' => LocalType.JSON_OBJECT
            case 'JsonArray' => LocalType.JSON_ARRAY
            case 'JsonNull' => LocalType.JSON_NULL
            case _ => LocalType.NONE
        }
    }

    // ------------------------------------------------------------------
    // 语句
    // ------------------------------------------------------------------

    /** 解析 `{ … }` 内部（不含外层花括号）的语句序列。 */
    public func parseBlockBody(): Array<AstStmt> {
        var out = ArrayList<AstStmt>()
        while (!this.atKind(TokenKind.RBrace) && !this.atKind(TokenKind.EOF)) {
            out.add(this.parseStatement())
            this.endStatement()
        }
        out.toArray()
    }

    private func parseBlock(): AstStmt {
        let open = this.expect(TokenKind.LBrace, '{')
        let body = this.parseBlockBody()
        this.expect(TokenKind.RBrace, '}')
        AstStmt.Block(body, SourcePos(open.line, open.column))
    }

    private func parseStatement(): AstStmt {
        let t = this.peek()
        let pos = SourcePos(t.line, t.column)
        match (t.kind) {
            case TokenKind.KwLet | TokenKind.KwVar =>
                this.take()
                return this.parseDecl(pos)
            case TokenKind.KwIf =>
                this.take()
                return this.parseIf(pos)
            case TokenKind.KwWhile =>
                this.take()
                return this.parseWhile(pos)
            case TokenKind.KwFor =>
                this.take()
                return this.parseForIn(pos)
            case TokenKind.KwReturn =>
                this.take()
                if (this.atTerminator()) {
                    return AstStmt.Return(None, pos)
                }
                return AstStmt.Return(Some(this.parseExpr()), pos)
            case TokenKind.KwBreak =>
                this.take()
                return AstStmt.Break(pos)
            case TokenKind.KwContinue =>
                this.take()
                return AstStmt.Continue(pos)
            case TokenKind.LBrace =>
                // `{` 三义：闭包（含 `=>`） / 映射字面量（空或含顶层 `:`） / 块语句
                if (Parser.looksLikeClosure(this.ts, this.p) || Parser.looksLikeMapLiteral(this.ts, this.p)) {
                    return AstStmt.ExprStmt(this.parseExpr(), pos)
                }
                return this.parseBlock()
            case TokenKind.LParen | TokenKind.Ident | TokenKind.Underscore =>
                return this.parseAssignOrExprStmt()
            case _ =>
                return AstStmt.ExprStmt(this.parseExpr(), pos)
        }
    }

    /** `let x(: T)? = e` / `var x(: T)? = e`（声明即首写）。 */
    private func parseDecl(pos: SourcePos): AstStmt {
        if (!this.atKind(TokenKind.Ident)) {
            let t = this.peek()
            diagFail(DiagKind.SYNTAX_ERROR, this.src, t.pos, t.line, t.column, '声明缺变量名')
        }
        let nameTok = this.take()
        var ty: ?TypeRef = None
        if (this.advanceIf(TokenKind.Colon)) {
            ty = Some(this.parseTypeRef())
        }
        var initExpr: ?AstExpr = None
        if (this.atKind(TokenKind.Assign)) {
            this.take()
            initExpr = Some(this.parseExpr())
        } else if (!Parser.isSome(ty)) {
            diagFail(DiagKind.SYNTAX_ERROR, this.src, nameTok.pos, nameTok.line, nameTok.column,
                '无初始化的声明必须带类型注解（§11.7 局部类型）')
        }
        AstStmt.Decl(nameTok.text, ty, initExpr, pos)
    }

    /** 从 `from`（标识符）起的 `名[ … ]` 之后是否紧跟 `=`（容器变更判据）。 */
    private static func indexFollowedByAssign(ts: Array<Token>, from: Int64): Bool {
        var depth: Int64 = 0
        var i = from + 1
        if (i >= ts.size || ts[i].kind != TokenKind.LBracket) {
            return false
        }
        while (i < ts.size) {
            let k = ts[i].kind
            if (k == TokenKind.LBracket) {
                depth = depth + 1
            } else if (k == TokenKind.RBracket) {
                depth = depth - 1
                if (depth <= 0) {
                    return i + 1 < ts.size && ts[i + 1].kind == TokenKind.Assign
                }
            } else if (k == TokenKind.EOF) {
                return false
            }
            i = i + 1
        }
        false
    }

    /**
     * 从 `from` 起的 `{ … }` 是否为映射字面量：`{}`（空）或**顶层出现 `:`**
     * ——块语句的语法面不含顶层 `:`，故与块无歧义（§3.3 v0.18 空容器字面值）。
     */
    private static func looksLikeMapLiteral(ts: Array<Token>, from: Int64): Bool {
        if (from + 1 < ts.size && ts[from + 1].kind == TokenKind.RBrace) {
            return true
        }
        var depth: Int64 = 0
        var i = from
        while (i < ts.size) {
            let k = ts[i].kind
            if (k == TokenKind.LBrace || k == TokenKind.LParen || k == TokenKind.LBracket) {
                depth = depth + 1
            } else if (k == TokenKind.RBrace || k == TokenKind.RParen || k == TokenKind.RBracket) {
                depth = depth - 1
                if (depth <= 0) {
                    return false
                }
            } else if (k == TokenKind.Colon && depth == 1) {
                return true
            } else if (k == TokenKind.EOF) {
                return false
            }
            i = i + 1
        }
        false
    }

    /**
     * 语句起首为 `(` / 标识符 / `_` 时的统一分派（**带回退**）：
     * `(名, 名…) =` ⇒ 多重赋值；`名 =` ⇒ 赋值；`名[i] =` ⇒ 容器变更；其余按表达式语句。
     */
    private func parseAssignOrExprStmt(): AstStmt {
        let save = this.p
        if (this.atKind(TokenKind.LParen)) {
            if (!Parser.groupFollowedByAssign(this.ts, this.p)) {
                this.p = save
                return AstStmt.ExprStmt(this.parseExpr(), SourcePos(this.peek().line, this.peek().column))
            }
        }
        if (this.atKind(TokenKind.Underscore) || this.atKind(TokenKind.Ident)) {
            let nxt = this.peekAt(1).kind
            var isAssign = nxt == TokenKind.Assign
            if (nxt == TokenKind.LBracket) {
                isAssign = Parser.indexFollowedByAssign(this.ts, this.p)
            }
            if (!isAssign) {
                this.p = save
                let e = this.parseExpr()
                if (this.atKind(TokenKind.Assign)) {
                    this.take()
                    let rhs = this.parseExpr()
                    return this.assignFrom(e, rhs, SourcePos(this.peek().line, this.peek().column))
                }
                return AstStmt.ExprStmt(e, SourcePos(this.peek().line, this.peek().column))
            }
        }
        this.p = save
        this.parseMaybeMultiAssign()
    }

    /** 后缀形态的赋值目标：局部 / 容器下标 / 宿主字段（`u.f = v`，m2 §12.4）。 */
    private func assignFrom(lhs: AstExpr, rhs: AstExpr, pos: SourcePos): AstStmt {
        match (lhs) {
            case AstExpr.Var(_, _) => AstStmt.Assign(lhs, rhs, pos)
            case AstExpr.Index(t, i, ipos) => AstStmt.Assign(AstExpr.IndexTarget(t, i, ipos), rhs, pos)
            case AstExpr.FieldGet(obj, field, fpos) =>
                AstStmt.ExprStmt(AstExpr.FieldSet(obj, field, rhs, fpos), pos)
            case AstExpr.MemberName(_, _, _) => AstStmt.Assign(lhs, rhs, pos)
            case _ =>
                diagFail(DiagKind.SYNTAX_ERROR, this.src, 0, pos.line, pos.column,
                    '赋值目标只能是局部变量、容器下标或宿主字段')
        }
    }

    /** 从 `from` 起的 `(` … `)` 之后是否紧跟 `=`（多重赋值判据）。 */
    private static func groupFollowedByAssign(ts: Array<Token>, from: Int64): Bool {
        var depth: Int64 = 0
        var i = from
        while (i < ts.size) {
            let k = ts[i].kind
            if (k == TokenKind.LParen || k == TokenKind.LBracket) {
                depth = depth + 1
            } else if (k == TokenKind.RParen || k == TokenKind.RBracket) {
                depth = depth - 1
                if (depth <= 0) {
                    return i + 1 < ts.size && ts[i + 1].kind == TokenKind.Assign
                }
            } else if (k == TokenKind.EOF) {
                return false
            }
            i = i + 1
        }
        false
    }

    /**
     * 赋值：普通 `x = e`、多重 `(a, b) = (b, a)` 与**容器变更 `list[i] = v` / `map[k] = v`**
     * （§9.15：变更是唯一许可的容器副作用，语法上是赋值语句、语义上不是赋值）。
     *
     * LHS 目标：局部变量、`_` 忽略位或下标目标；RHS 仅支持**一维元组字面量**（§5 降低模式）。
     */
    private func parseMaybeMultiAssign(): AstStmt {
        let pos = SourcePos(this.peek().line, this.peek().column)
        var targets = ArrayList<AstExpr>()
        var grouped = false
        if (this.atKind(TokenKind.LParen)) {
            // `(a, b) = …`（多重赋值）；注意 `((a,b) in map)` 不属语句位置
            grouped = true
            this.take()
            while (true) {
                targets.add(this.parseLhsTarget())
                if (this.advanceIf(TokenKind.Comma)) {
                    continue
                }
                break
            }
            this.expect(TokenKind.RParen, '多重赋值 LHS 的闭合 )')
        } else {
            let t = this.parseLhsTarget()
            if (this.atKind(TokenKind.LBracket)) {
                // 下标写：`list[i] = v`
                this.take()
                let idx = this.parseExpr()
                this.expect(TokenKind.RBracket, '下标的闭合 ]')
                this.expect(TokenKind.Assign, '容器变更的赋值号')
                let v = this.parseExpr()
                return AstStmt.Assign(AstExpr.IndexTarget(t, idx, pos), v, pos)
            }
            targets.add(t)
        }
        this.expect(TokenKind.Assign, '赋值号')
        if (grouped || this.atKind(TokenKind.LParen)) {
            // RHS：一维元组字面量（多重赋值）
            this.expect(TokenKind.LParen, '多重赋值 RHS 的元组字面量')
            var rhs = ArrayList<AstExpr>()
            while (true) {
                rhs.add(this.parseExpr())
                if (this.advanceIf(TokenKind.Comma)) {
                    continue
                }
                break
            }
            this.expect(TokenKind.RParen, '多重赋值 RHS 的闭合 )')
            return AstStmt.MultiAssign(targets.toArray(), rhs.toArray(), pos)
        }
        AstStmt.Assign(targets[0], this.parseExpr(), pos)
    }

    /** LHS 目标：标识符或 `_` 忽略位。 */
    private func parseLhsTarget(): AstExpr {
        let t = this.peek()
        let pos = SourcePos(t.line, t.column)
        if (t.kind == TokenKind.Underscore) {
            this.take()
            return AstExpr.Var('_', pos)
        }
        if (t.kind != TokenKind.Ident) {
            diagFail(DiagKind.SYNTAX_ERROR, this.src, t.pos, t.line, t.column,
                '赋值目标只能是局部变量或 `_` 忽略位（M1 无属性赋值）')
        }
        this.take()
        AstExpr.Var(t.text, pos)
    }

    /** `if (c) { … }`（可带 `else { … }` / `else if …`）。 */
    private func parseIf(pos: SourcePos): AstStmt {
        this.expect(TokenKind.LParen, 'if 条件的 (')
        let cond = this.parseExpr()
        this.expect(TokenKind.RParen, 'if 条件的 )')
        let thenS = this.parseBlock()
        var elseS: ?AstStmt = None
        if (this.atKind(TokenKind.KwElse)) {
            this.take()
            if (this.atKind(TokenKind.KwIf)) {
                let inner = this.peek()
                this.take()
                elseS = Some(this.parseIf(SourcePos(inner.line, inner.column)))
            } else {
                elseS = Some(this.parseBlock())
            }
        }
        AstStmt.If(cond, thenS, elseS, pos)
    }

    private func parseWhile(pos: SourcePos): AstStmt {
        this.expect(TokenKind.LParen, 'while 条件的 (')
        let cond = this.parseExpr()
        this.expect(TokenKind.RParen, 'while 条件的 )')
        AstStmt.While(cond, this.parseBlock(), pos)
    }

    /** `for (i in iterable where cond) { … }`；Map 为 `for ((k, v) in map)`。 */
    private func parseForIn(pos: SourcePos): AstStmt {
        this.expect(TokenKind.LParen, 'for 的 (')
        var names = ArrayList<String>()
        if (this.atKind(TokenKind.LParen)) {
            this.take()
            names.add(this.expectIdent())
            this.expect(TokenKind.Comma, 'Map 双绑定的逗号')
            names.add(this.expectIdent())
            this.expect(TokenKind.RParen, 'Map 双绑定的闭合 )')
        } else {
            names.add(this.expectIdent())
        }
        this.expect(TokenKind.KwIn, 'for 的 in')
        let iterable = this.parseExpr()
        var whereCond: ?AstExpr = None
        if (this.atKind(TokenKind.KwWhere)) {
            this.take()
            whereCond = Some(this.parseExpr())
        }
        this.expect(TokenKind.RParen, 'for 的 )')
        AstStmt.ForIn(names.toArray(), iterable, whereCond, this.parseBlock(), pos)
    }

    private func expectIdent(): String {
        if (!this.atKind(TokenKind.Ident)) {
            let t = this.peek()
            diagFail(DiagKind.SYNTAX_ERROR, this.src, t.pos, t.line, t.column, '期望标识符')
        }
        this.take().text
    }

    // ------------------------------------------------------------------
    // 表达式（优先级自低到高）
    // ------------------------------------------------------------------

    public func parseExpr(): AstExpr {
        this.parseCastOr()
    }

    /**
     * 收窄转型 `E as T ?? V` / `E as T`：`as` 与 `??` 都在**最低**结合层（低于 `||`），`??` 右结合。
     *
     * `??` 只作为 `as` 的兜底分隔符存在（单独出现即语法错误）；`?` 单字符仍不合法。
     */
    private func parseCastOr(): AstExpr {
        let left = this.parseOr()
        if (this.atKind(TokenKind.QuestionQuestion)) {
            let t = this.peek()
            diagFail(DiagKind.SYNTAX_ERROR, this.src, t.pos, t.line, t.column,
                '`??` 只能跟在 `as T` 之后（兜底形式为 `E as T ?? V`）')
        }
        if (!this.atKind(TokenKind.KwAs)) {
            return left
        }
        let asTok = this.take()
        let tr = this.parseTypeRef()
        // `?? V` 可缺省：`E as T` 转型失败报错，`E as T ?? V` 失败取 V
        var fallback: ?AstExpr = None
        if (this.atKind(TokenKind.QuestionQuestion)) {
            let _ = this.take()
            fallback = Some(this.parseCastOr())
        }
        AstExpr.CastOr(left, tr, fallback, SourcePos(asTok.line, asTok.column))
    }

    private func parseOr(): AstExpr {
        var left = this.parseAnd()
        while (this.atKind(TokenKind.OrOr)) {
            let opTok = this.take()
            let right = this.parseAnd()
            // 短路：语法层保留二元形态，降低阶段展开为 JZ/JNZ 短路链（§5 / 附 A.3）
            left = AstExpr.Binary(TokenKind.OrOr, left, right, SourcePos(opTok.line, opTok.column))
        }
        left
    }

    private func parseAnd(): AstExpr {
        var left = this.parseCompare()
        while (this.atKind(TokenKind.AndAnd)) {
            let opTok = this.take()
            let right = this.parseCompare()
            left = AstExpr.Binary(TokenKind.AndAnd, left, right, SourcePos(opTok.line, opTok.column))
        }
        left
    }

    private func parseCompare(): AstExpr {
        var left = this.parseBitOr()
        // `E is T`（m3 §3）：类型问答与比较同级，右结合关闭（`a is T is U` 无意义，交给降低期判）。
        while (this.atKind(TokenKind.KwIs)) {
            let isTok = this.take()
            let tr = this.parseTypeRef()
            left = AstExpr.IsType(left, tr, SourcePos(isTok.line, isTok.column))
        }
        while (Parser.isCompareOp(this.peek().kind)) {
            let opTok = this.take()
            let right = this.parseBitOr()
            left = AstExpr.Binary(opTok.kind, left, right, SourcePos(opTok.line, opTok.column))
        }
        left
    }

    /**
     * 位运算三级（与仓颉一致）：`|` < `^` < `&`，均高于比较、低于移位。
     *
     * Bool 上的同名运算由降低阶段分派为 `AND_B/OR_B/XOR_B`（§5）。
     */
    private func parseBitOr(): AstExpr {
        var left = this.parseBitXor()
        while (this.atKind(TokenKind.Pipe)) {
            let opTok = this.take()
            let right = this.parseBitXor()
            left = AstExpr.Binary(opTok.kind, left, right, SourcePos(opTok.line, opTok.column))
        }
        left
    }

    private func parseBitXor(): AstExpr {
        var left = this.parseBitAnd()
        while (this.atKind(TokenKind.Caret)) {
            let opTok = this.take()
            let right = this.parseBitAnd()
            left = AstExpr.Binary(opTok.kind, left, right, SourcePos(opTok.line, opTok.column))
        }
        left
    }

    private func parseBitAnd(): AstExpr {
        var left = this.parseShift()
        while (this.atKind(TokenKind.Amp)) {
            let opTok = this.take()
            let right = this.parseShift()
            left = AstExpr.Binary(opTok.kind, left, right, SourcePos(opTok.line, opTok.column))
        }
        left
    }

    private static func isCompareOp(k: TokenKind): Bool {
        k == TokenKind.EqEq || k == TokenKind.NotEq || k == TokenKind.Lt || k == TokenKind.Le ||
            k == TokenKind.Gt || k == TokenKind.Ge
    }

    /** 移位级：`<<` / `>>`（**低于加法级、高于比较级**，与仓颉一致）。 */
    private func parseShift(): AstExpr {
        var left = this.parseRange()
        while (this.atKind(TokenKind.Shl) || this.atKind(TokenKind.Shr)) {
            let opTok = this.take()
            let right = this.parseRange()
            left = AstExpr.Binary(opTok.kind, left, right, SourcePos(opTok.line, opTok.column))
        }
        left
    }

    /** 区间：`a..b` / `a..=b`，可带 `: step`；**step=0 由降低阶段在编译期拒绝**（§11.9）。 */
    private func parseRange(): AstExpr {
        var left = this.parseAdditive()
        if (this.atKind(TokenKind.DotDot) || this.atKind(TokenKind.DotDotEq)) {
            let opTok = this.take()
            let closed = opTok.kind == TokenKind.DotDotEq
            let right = this.parseAdditive()
            var step: ?AstExpr = None
            if (this.advanceIf(TokenKind.Colon)) {
                step = Some(this.parseAdditive())
            }
            return AstExpr.RangeLit(left, right, step, closed, SourcePos(opTok.line, opTok.column))
        }
        left
    }

    /**
     * 加法级。
     *
     * **String 混合加法（§11.9 v0.18.15）**：任一侧是字符串字面量时解析为 `StrAdd`
     * （静态证据充分）；其余情形留 `Binary(Plus)`，由降低阶段按静态类型判定。
     */
    private func parseAdditive(): AstExpr {
        var left = this.parseRegexOp()
        while (this.atKind(TokenKind.Plus) || this.atKind(TokenKind.Minus)) {
            let opTok = this.take()
            let right = this.parseRegexOp()
            let pos = SourcePos(opTok.line, opTok.column)
            if (opTok.kind == TokenKind.Plus && (Parser.isStringLit(left) || Parser.isStringLit(right))) {
                left = AstExpr.StrAdd(left, right, pos)
            } else {
                left = AstExpr.Binary(opTok.kind, left, right, pos)
            }
        }
        left
    }

    private static func isStringLit(e: AstExpr): Bool {
        match (e) {
            case AstExpr.Lit(t, _) => t.kind == TokenKind.StrLit
            case _ => false
        }
    }

    /**
     * 正则操作符级（§11.9 冻结）：`~` / `!~` / 替换三形。
     *
     * **优先级高于加法级、低于乘法级，左结合**——故本层夹在加法与乘法之间。
     */
    private func parseRegexOp(): AstExpr {
        var left = this.parseMultiplicative()
        while (this.atKind(TokenKind.Tilde) || this.atKind(TokenKind.BangTilde)) {
            let opTok = this.take()
            let right = this.parseMultiplicative()
            left = AstExpr.RegexOp(opTok.kind, left, right, None, None, None,
                SourcePos(opTok.line, opTok.column))
        }
        left
    }

    private func parseMultiplicative(): AstExpr {
        var left = this.parseUnary()
        while (this.atKind(TokenKind.Star) || this.atKind(TokenKind.Slash) || this.atKind(TokenKind.Percent)) {
            // 替换段优先：斜杠既可能是除法也可能是替换段起头（§11.9）——先试替换，失败再当除法
            if (this.atKind(TokenKind.Slash) && this.replaceDepth == 0) {
                match (this.tryParseReplace(left)) {
                    case Some(r) =>
                        left = r
                        continue
                    case None => ()
                }
            }
            // 替换段内部（目标串 / replacement）的斜杠**只**是分隔符，不是运算符
            if (this.atKind(TokenKind.Slash) && this.replaceDepth > 0) {
                break
            }
            let opTok = this.take()
            let right = this.parseUnary()
            left = AstExpr.Binary(opTok.kind, left, right, SourcePos(opTok.line, opTok.column))
        }
        left
    }

    /** 一元：`-x` / `!x` / `~x`（`!~` 是单一 token，不由本层处理）。 */
    private func parseUnary(): AstExpr {
        let t = this.peek()
        if (t.kind == TokenKind.Minus || t.kind == TokenKind.Bang || t.kind == TokenKind.Tilde) {
            this.take()
            let x = this.parseUnary()
            return AstExpr.Unary(t.kind, x, SourcePos(t.line, t.column))
        }
        this.parsePostfix()
    }

    /** 后缀：调用 / 下标 / 正则替换段。 */
    private func parsePostfix(): AstExpr {
        var cur = this.parsePrimary()
        while (true) {
            if (this.atKind(TokenKind.LParen) && !this.atStatementBoundaryForCall()) {
                let openTok = this.take()
                var args = ArrayList<AstExpr>()
                if (!this.atKind(TokenKind.RParen)) {
                    while (true) {
                        args.add(this.parseExpr())
                        if (this.advanceIf(TokenKind.Comma)) {
                            continue
                        }
                        break
                    }
                }
                this.expect(TokenKind.RParen, '实参表的闭合 )')
                let pos = SourcePos(openTok.line, openTok.column)
                // 闭包表达式直接调用 = IIFE（§8.5）；成员/构造/具名调用分别成形（m2 §12.4/§15）
                match (cur) {
                    case AstExpr.Closure(_, _) => cur = AstExpr.IIFE(cur, args.toArray(), pos)
                    case AstExpr.FieldGet(obj, field, mpos) =>
                        cur = AstExpr.MethodCall(obj, field, args.toArray(), mpos)
                    case AstExpr.Var(callee, vpos) =>
                        if (this.registered(callee)) {
                            cur = AstExpr.CtorCall(callee, args.toArray(), pos)
                        } else {
                            cur = AstExpr.Call(cur, args.toArray(), pos)
                        }
                    case _ => cur = AstExpr.Call(cur, args.toArray(), pos)
                }
                continue
            }
            if (this.atKind(TokenKind.Dot)) {
                let dot = this.take()
                let nameTok = this.peek()
                if (nameTok.kind != TokenKind.Ident) {
                    diagFail(DiagKind.SYNTAX_ERROR, this.src, nameTok.pos, nameTok.line, nameTok.column,
                        '成员访问的「.」后必须是标识符')
                }
                this.take()
                cur = AstExpr.FieldGet(cur, nameTok.text, SourcePos(dot.line, dot.column))
                continue
            }
            if (this.atKind(TokenKind.LBracket)) {
                let openTok = this.take()
                let idx = this.parseExpr()
                this.expect(TokenKind.RBracket, '下标的闭合 ]')
                cur = AstExpr.Index(cur, idx, SourcePos(openTok.line, openTok.column))
                continue
            }
            if (this.atKind(TokenKind.Slash) && this.replaceDepth == 0) {
                let rep = this.tryParseReplace(cur)
                match (rep) {
                    case Some(r) =>
                        cur = r
                        continue
                    case None => ()
                }
            }
            break
        }
        cur
    }

    /**
     * 调用与「块起始」消歧：换行之后的 `(` 是**新语句的元组 / 括号**，不是实参表
     * （design §4.3.1 举的 `f` ⏎ `(1)` 反例 ⇒ 必须靠 `nlBefore` 判定）。
     */
    private func atStatementBoundaryForCall(): Bool {
        this.peek().nlBefore
    }

    /**
     * 尝试解析正则替换段 `re/s/r/g` / `re/s/r/n` / `re/s/r/n,m`（§11.9「替换段词法」）。
     *
     * **判定策略（前瞻 + 回退）**：`Slash` 既可能是除法也可能是替换段开头，
     * 唯一可靠的区分是「能否完整解析出替换段形」；失败则整体回退为除法
     * （`Prefix` 位置的 `Slash` 已在 `parseMultiplicative` 消费，此处只处理后缀位置）。
     */
    /**
     * 尝试解析正则替换段 `re/s/r/g` / `re/s/r/n` / `re/s/r/n,m`（§11.9「替换段词法」）。
     *
     * **判定策略（前瞻 + 回退）**：`Slash` 既可能是除法也可能是替换段开头，
     * 唯一可靠的区分是「能否完整解析出替换段形」；失败则整体回退为除法。
     *
     * **禁止嵌套**：解析替换段的目标串与 replacement 期间置位 `replaceDepth`——
     * 否则 `re/s/r/g` 的内层 `s` 会把第二段斜杠当作自己的替换段起头（歧义）
     * （§11.9「分隔 `/` 恒为单个」的兑现）。
     */
    private func tryParseReplace(re: AstExpr): ?AstExpr {
        let save = this.p
        let slashTok = this.take()
        this.replaceDepth = this.replaceDepth + 1
        let s = this.parseExpr()
        var result: ?AstExpr = None
        if (this.atKind(TokenKind.Slash)) {
            this.take()
            let r = this.parseExpr()
            var n: ?Int64 = None
            var m: ?Int64 = None
            var ok = true
            if (this.atKind(TokenKind.Slash)) {
                this.take()
                if (this.atKind(TokenKind.Ident)) {
                    let g = this.take()
                    if (g.text != 'g') {
                        ok = false
                    }
                } else if (this.atKind(TokenKind.IntLit)) {
                    let a = this.take()
                    n = Some(Parser.parseInt(a))
                    if (this.atKind(TokenKind.Comma)) {
                        this.take()
                        let b = this.expect(TokenKind.IntLit, '区间替换的上界 m')
                        m = Some(Parser.parseInt(b))
                    }
                } else {
                    ok = false
                }
            } else {
                // 无修饰符 ⇒ 等价 /0（§11.9「省略 g 等价第 0 个」）
                n = Some(0)
            }
            if (ok) {
                result = Some(AstExpr.RegexOp(TokenKind.Slash, re, s, Some(r), n, m,
                    SourcePos(slashTok.line, slashTok.column)))
            }
        }
        this.replaceDepth = this.replaceDepth - 1
        match (result) {
            case Some(v) => Some(v)
            case None =>
                this.p = save
                None
        }
    }

    private static func parseInt(t: Token): Int64 {
        Parser.parseDigits(t.text)
    }

    private static func parseDigits(s: String): Int64 {
        var v: Int64 = 0
        for (b in s.unsafeBytes()) {
            if (b >= 0x30u8 && b <= 0x39u8) {
                v = v * 10 + Int64(b - 0x30u8)
            }
        }
        v
    }

    // ------------------------------------------------------------------
    // 基本式
    // ------------------------------------------------------------------

    private func parsePrimary(): AstExpr {
        let t = this.peek()
        let pos = SourcePos(t.line, t.column)
        match (t.kind) {
            case TokenKind.IntLit | TokenKind.DecLit | TokenKind.F64Lit =>
                this.take()
                return AstExpr.Lit(t, pos)
            case TokenKind.KwTrue | TokenKind.KwFalse | TokenKind.KwNull =>
                this.take()
                return AstExpr.Lit(t, pos)
            case TokenKind.RegexLit =>
                this.take()
                return AstExpr.Lit(t, pos)
            case TokenKind.StrLit =>
                this.take()
                return this.buildStringExpr(t, pos)
            case TokenKind.JsonLit =>
                this.take()
                return this.buildJsonExpr(t, pos)
            case TokenKind.KwRecursive =>
                this.take()
                return AstExpr.RecursiveValue(pos)
            case TokenKind.Ident =>
                this.take()
                return AstExpr.Var(t.text, pos)
            case TokenKind.LBrace =>
                // `{` 既可能是闭包也可能是映射字面量：闭包必含 `=>`（§8.0「箭头不可省略」），
                // 故以「到闭合 `}` 之前是否出现 `=>`」为判据（§8.0 唯一形态约束）
                if (Parser.looksLikeClosure(this.ts, this.p)) {
                    return AstExpr.Closure(this.parseClosure(), pos)
                }
                return this.parseMapLit(pos)
            case TokenKind.LParen =>
                this.take()
                let inner = this.parseExpr()
                if (this.atKind(TokenKind.Comma)) {
                    // 一维元组字面量（仅多重赋值 RHS 合法；作为值传递时降低阶段拒绝）
                    var elems = ArrayList<AstExpr>()
                    elems.add(inner)
                    while (this.advanceIf(TokenKind.Comma)) {
                        elems.add(this.parseExpr())
                    }
                    this.expect(TokenKind.RParen, '元组的闭合 )')
                    return AstExpr.TupleLit(elems.toArray(), pos)
                }
                this.expect(TokenKind.RParen, '括号表达式的闭合 )')
                return inner
            case TokenKind.LBracket =>
                return this.parseListLit(pos)
            case TokenKind.Minus =>
                this.take()
                return AstExpr.Unary(TokenKind.Minus, this.parseUnary(), pos)
            case TokenKind.KwIf =>
                this.take()
                return this.parseIfExpr(pos)
            case _ =>
                diagFail(DiagKind.SYNTAX_ERROR, this.src, t.pos, t.line, t.column,
                    '表达式位置遇到无法起头的词法单元「${Parser.show(t)}」')
        }
    }

    /**
     * 字符串表达式：无插值 → `Lit`；含插值 → `Interp`（**偶数下标 = 文本片段，奇数下标 = 表达式**）。
     *
     * 切分在**解析期**完成（插值原文由词法保留，§8.8 冻结顺序的最后一步），
     * 片段内的表达式递归解析——位置取片段在原串中的相对行列（由片段起点推算）。
     */
    /**
     * JSON 字面量（m3 §11）：**体首非空白字符**决定静态类型。
     *
     * `{` ⇒ `JsonObject`（17）、`[` ⇒ `JsonArray`（18）；空体与标量顶层（数字 / 字符串 /
     * `true` / `false` / `null`）一律编译错误——标量只作元素（§12-8①），空体也无法定形态。
     * 这里只做**形态判定**；JSON 语法本身在降低阶段解析一遍（非法即源编译错误）。
     */
    private func buildJsonExpr(t: Token, pos: SourcePos): AstExpr {
        let body = t.text
        let bs = body.unsafeBytes()
        var i = 0
        while (i < bs.size && (bs[i] == 0x20u8 || bs[i] == 0x09u8 || bs[i] == 0x0Au8 ||
            bs[i] == 0x0Du8)) {
            i = i + 1
        }
        if (i >= bs.size) {
            diagFail(DiagKind.SYNTAX_ERROR, this.src, t.pos, t.line, t.column,
                'JSON 字面量为空（体必须是对象 `{…}` 或数组 `[…]`，m3 §11）')
        }
        if (bs[i] == 0x7Bu8) {
            return AstExpr.JsonLit(body, LocalType.JSON_OBJECT, pos)
        }
        if (bs[i] == 0x5Bu8) {
            return AstExpr.JsonLit(body, LocalType.JSON_ARRAY, pos)
        }
        diagFail(DiagKind.SYNTAX_ERROR, this.src, t.pos, t.line, t.column,
            'JSON 字面量的体必须以 `{` 或 `[` 开头（标量顶层不开放，m3 §11/§12-8①）')
    }

    private func buildStringExpr(t: Token, pos: SourcePos): AstExpr {
        let raw = t.text
        // 原始串 verbatim（§8.8）：不插值 —— 依 token 起点字符是否为 # 判定
        if (!raw.contains(Parser.INTERP_START) || Parser.isRawStringToken(this.src, t)) {
            return AstExpr.Lit(t, pos)
        }
        var parts = ArrayList<AstExpr>()
        var textBuf = ArrayList<UInt8>()
        var i = 0
        let bs = raw.unsafeBytes()
        var lastLine = t.line
        var lastCol = t.column
        while (i < bs.size) {
            if (bs[i] == 0x24u8 && i + 1 < bs.size && bs[i + 1] == 0x7Bu8) {
                // 先落一个文本片段（可能为空，保证交替关系恒定）
                parts.add(Parser.textPart(textBuf.toArray(), lastLine, lastCol))
                textBuf = ArrayList<UInt8>()
                let start = i + 2
                var depth: Int64 = 1
                var j = start
                while (j < bs.size && depth > 0) {
                    if (bs[j] == 0x7Bu8) {
                        depth = depth + 1
                    } else if (bs[j] == 0x7Du8) {
                        depth = depth - 1
                        if (depth == 0) {
                            break
                        }
                    }
                    j = j + 1
                }
                if (depth != 0) {
                    diagFail(DiagKind.UNTERMINATED_STRING, this.src, t.pos, t.line, t.column,
                        '插值未闭合（词法应与解析同判，此处为防御分支）')
                }
                let innerSrc = Lexer.sliceStr(bs, start, j)
                if (trimAscii(innerSrc).isEmpty()) {
                    diagFail(DiagKind.SYNTAX_ERROR, this.src, t.pos, t.line, t.column,
                        '空插值（附 A：空的表达式片段 → 编译错误）')
                }
                let sub = Parser(innerSrc)
                parts.add(sub.parseExpr())
                lastLine = t.line
                lastCol = t.column + j + 2
                i = j + 1
                continue
            }
            textBuf.add(bs[i])
            i = i + 1
        }
        parts.add(Parser.textPart(textBuf.toArray(), lastLine, lastCol))
        AstExpr.Interp(parts.toArray(), pos)
    }

    /** 文本片段 → 一个 `_StrLit` 形态的 `Lit` 节点（kind 与原文复用，text 换成片段内容）。 */
    private static func textPart(bs: Array<UInt8>, line: Int64, column: Int64): AstExpr {
        let text = String.fromUtf8(bs)
        let tok = Token(TokenKind.StrLit, text, 0, line, column, false)
        AstExpr.Lit(tok, SourcePos(line, column))
    }

    /**
     * **值用法** if（§5 形式判定）：必须有最终 else（仓颉语义：无 else 的 if 不产生值）。
     * 各分支「类型逐位一致、恰留 1 cell」由降低阶段按静态类型校验（§7 校验 9 同口径）。
     */
    private func parseIfExpr(pos: SourcePos): AstExpr {
        this.expect(TokenKind.LParen, 'if 条件的 (')
        let cond = this.parseExpr()
        this.expect(TokenKind.RParen, 'if 条件的 )')
        let thenE = this.parseBracedExpr()
        this.expect(TokenKind.KwElse, '值用法 if 的最终 else')
        var elseE = this.parseBracedExpr()
        // `else if` 链：逐级嵌套为 IfExpr（§5 降低模式）
        while (this.atKind(TokenKind.KwIf)) {
            let innerTok = this.take()
            let innerPos = SourcePos(innerTok.line, innerTok.column)
            let nested = this.parseIfExpr(innerPos)
            elseE = nested
        }
        AstExpr.IfExpr(cond, thenE, elseE, pos)
    }

    /** `{ 单表达式 }`：值用法分支的载体。 */
    private func parseBracedExpr(): AstExpr {
        this.expect(TokenKind.LBrace, '{')
        let e = this.parseExpr()
        this.expect(TokenKind.RBrace, '}')
        e
    }

    /** 嵌套闭包：`{ params => body }` —— 与顶层同一 lambda 语法（§8.5）。 */
    private func parseClosure(): LambdaAst {
        let open = this.expect(TokenKind.LBrace, '{')
        let pos = SourcePos(open.line, open.column)
        let params = this.parseParams()
        if (!this.atKind(TokenKind.Arrow)) {
            let t = this.peek()
            diagFail(DiagKind.MISSING_ARROW, this.src, t.pos, t.line, t.column,
                '闭包缺 =>（§8.0：箭头不可省略）')
        }
        this.take()
        let body = this.parseBlockBody()
        this.expect(TokenKind.RBrace, '}')
        let split = Parser.splitTailExpr(body)
        LambdaAst(params, split[0], split[1], pos)
    }

    /**
     * 从 `from` 起的 `{` 是否为闭包：扫到与之配平的 `}` 为止，途中出现 `=>` 即闭包。
     *
     * 依据：§8.0 的 lambda **必须**有 `=>`；映射字面量的语法面不含 `=>`
     * （值位置只可能是闭包 —— 而闭包值不可作映射元素，§8.6）。
     */
    private static func looksLikeClosure(ts: Array<Token>, from: Int64): Bool {
        var depth: Int64 = 0
        var i = from
        while (i < ts.size) {
            let k = ts[i].kind
            if (k == TokenKind.LBrace || k == TokenKind.LParen || k == TokenKind.LBracket) {
                depth = depth + 1
            } else if (k == TokenKind.RBrace || k == TokenKind.RParen || k == TokenKind.RBracket) {
                depth = depth - 1
                if (depth <= 0) {
                    return false
                }
            } else if (k == TokenKind.Arrow) {
                return true
            } else if (k == TokenKind.EOF) {
                return false
            }
            i = i + 1
        }
        false
    }

    /** 列表字面量：`[]` 为空构造（§3.3 v0.18），`[a, b]` 走常量路径。 */
    private func parseListLit(pos: SourcePos): AstExpr {
        this.expect(TokenKind.LBracket, '[')
        var elems = ArrayList<AstExpr>()
        if (this.atKind(TokenKind.RBracket)) {
            this.take()
            return AstExpr.ListLit(Array<AstExpr>(), true, pos)
        }
        while (true) {
            elems.add(this.parseExpr())
            if (this.advanceIf(TokenKind.Comma)) {
                continue
            }
            break
        }
        this.expect(TokenKind.RBracket, ']')
        AstExpr.ListLit(elems.toArray(), false, pos)
    }

    /** 映射字面量：`{}` 为空构造；`{k: v, …}` 走常量路径。 */
    public func parseMapLit(pos: SourcePos): AstExpr {
        this.expect(TokenKind.LBrace, '{')
        var pairs = ArrayList<(AstExpr, AstExpr)>()
        if (this.atKind(TokenKind.RBrace)) {
            this.take()
            return AstExpr.MapLit(Array<(AstExpr, AstExpr)>(), true, pos)
        }
        while (true) {
            let k = this.parseExpr()
            this.expect(TokenKind.Colon, '映射字面量的键值冒号')
            let v = this.parseExpr()
            pairs.add((k, v))
            if (this.advanceIf(TokenKind.Comma)) {
                continue
            }
            break
        }
        this.expect(TokenKind.RBrace, '}')
        AstExpr.MapLit(pairs.toArray(), false, pos)
    }
}

/** 仅判 ASCII 空白的修剪（避免依赖宿主 `trim` 的 Unicode 口径差异）。 */
private func trimAscii(s: String): String {
    let bs = s.unsafeBytes()
    var lo = 0
    var hi = bs.size
    while (lo < hi && (bs[lo] == 0x20u8 || bs[lo] == 0x09u8 || bs[lo] == 0x0Au8 || bs[lo] == 0x0Du8)) {
        lo = lo + 1
    }
    while (hi > lo && (bs[hi - 1] == 0x20u8 || bs[hi - 1] == 0x09u8 || bs[hi - 1] == 0x0Au8 ||
        bs[hi - 1] == 0x0Du8)) {
        hi = hi - 1
    }
    Lexer.sliceStr(bs, lo, hi)
}
