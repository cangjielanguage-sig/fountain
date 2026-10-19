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

/**
 * 词法单元（S3.1）——design-m1 §4.3.1「`Token`（只读 struct，6 字段）」+ §4.3.9 `DiagKind`。
 *
 * **为什么做成本包 `internal`**：design §4.2「本包没有任何 `public` 声明」——用户面 API 一律
 * 由根包再导出；词法/语法/AST 只在前端包内使用（同章可见性规则逐条）。
 *
 * **`TokenKind` 58 个构造器**（design §4.3.1 全表，无载荷 enum：拼写差异由 `Token.text` 承载，
 * 解析器做穷尽 `match`）：
 *
 * | 类别 | 个数 | 构造器 |
 * |---|---|---|
 * | 字面量 | 5 | `IntLit` `DecLit` `F64Lit` `StrLit` `RegexLit` |
 * | 标识符 / 关键字 | 16 | `Ident` + `recursive/let/var/if/else/while/for/in/where/break/continue/return/true/false/null` |
 * | 标点 | 12 | `(` `)` `{` `}` `[` `]` `,` `:` `=>` `.` `_` `;` |
 * | 运算符 | 24 | `+ - * / % = == != < <= > >= && \|\| ! & \| ^ << >> ~ !~ .. ..=` |
 * | 终止 | 1 | `EOF` |
 *
 * **没有 error token**（design §4.3.1「词法错误策略」）：本模块是单次编译（非 IDE/LSP），
 * `TokenKind` 只描述**合法**词法单元；非法输入由 `Lexer.next()` 直接抛 `SourceCompileException`
 * （fail-fast、不续跑、不做错误恢复 / 多错报告）。若设 `Error` kind，每条语法规则都得处理它，
 * 成本远大于收益；且能保持「编译期错误只有一个出口」（`DiagnosticsSink` 不承担错误通道）。
 */

/** 词法单元类别（无载荷 enum，58 个构造器；穷尽 `match` 由 `Parser` 保证）。 */
internal enum TokenKind <: Equatable<TokenKind> {
    // ---- 字面量（5）----
    /** 整数字面量：`text` 为数字原文——**超 Int64 域是合法输入**（§11.9：降级为 Decimal 常量）。 */
    | IntLit
    /** 小数 / 指数形式 numeral：`1.5`、`3e2`、`1e-3`（§11.9：精确构造 Decimal，不经 Float64）。 */
    | DecLit
    /** 显式浮点 suffix 形态：`1.5f64`、`2f64`（§11.9「显式标注的字面值」）。 */
    | F64Lit
    /** 字符串字面量（三形态归一；`text` = 锚定 + 转义解码之后的串体，`${…}` 仍为原文）。 */
    | StrLit
    /** 正则字面量 `/pattern/flags`（`text` = pattern，flags 单独由 `Lexer` 归一进位域→写进 token 尾部）。 */
    | RegexLit

    // ---- 标识符 / 关键字（16）----
    | Ident
    | KwRecursive
    | KwLet
    | KwVar
    | KwIf
    | KwElse
    | KwWhile
    | KwFor
    | KwIn
    | KwWhere
    | KwBreak
    | KwContinue
    | KwReturn
    | KwTrue
    | KwFalse
    | KwNull

    // ---- 标点（12）----
    | LParen
    | RParen
    | LBrace
    | RBrace
    | LBracket
    | RBracket
    | Comma
    | Colon
    | Arrow
    | Dot
    | Underscore
    | Semi

    // ---- 运算符（24）----
    | Plus
    | Minus
    | Star
    | Slash
    | Percent
    | Assign
    | EqEq
    | NotEq
    | Lt
    | Le
    | Gt
    | Ge
    | AndAnd
    | OrOr
    | Bang
    | Amp
    | Pipe
    | Caret
    | Shl
    | Shr
    | Tilde
    /** `!~`（**单一 token**，优先于一元 `!` 识别，避免 `!` + `~` 歧义；§11.9）。 */
    | BangTilde
    | DotDot
    | DotDotEq

    // ---- 终止（1）----
    | EOF

    /**
     * 相等判定经**构造器序号**（见下）：58 项两两比对写成 match 需 58×58 项，
     * 唯一能长期维护的形态是「序号 + 数值比较」——序号表本身同时是**全表清单**，
     * 写漏任何一项都会在 `Lexer_test.allFiftyEightKindsAreConstructible` 暴露（design §4.3.1）。
     */
    public operator func ==(other: TokenKind): Bool {
        TokenKind.ordinal(this) == TokenKind.ordinal(other)
    }

    /** 构造器序号：按 design §4.3.1 全表的声明序，5 字面量 → 16 标识符/关键字 → 12 标点 → 24 运算符 → EOF。 */
    public static func ordinal(k: TokenKind): Int64 {
        match (k) {
            case IntLit => 0
            case DecLit => 1
            case F64Lit => 2
            case StrLit => 3
            case RegexLit => 4
            case Ident => 5
            case KwRecursive => 6
            case KwLet => 7
            case KwVar => 8
            case KwIf => 9
            case KwElse => 10
            case KwWhile => 11
            case KwFor => 12
            case KwIn => 13
            case KwWhere => 14
            case KwBreak => 15
            case KwContinue => 16
            case KwReturn => 17
            case KwTrue => 18
            case KwFalse => 19
            case KwNull => 20
            case LParen => 21
            case RParen => 22
            case LBrace => 23
            case RBrace => 24
            case LBracket => 25
            case RBracket => 26
            case Comma => 27
            case Colon => 28
            case Arrow => 29
            case Dot => 30
            case Underscore => 31
            case Semi => 32
            case Plus => 33
            case Minus => 34
            case Star => 35
            case Slash => 36
            case Percent => 37
            case Assign => 38
            case EqEq => 39
            case NotEq => 40
            case Lt => 41
            case Le => 42
            case Gt => 43
            case Ge => 44
            case AndAnd => 45
            case OrOr => 46
            case Bang => 47
            case Amp => 48
            case Pipe => 49
            case Caret => 50
            case Shl => 51
            case Shr => 52
            case Tilde => 53
            case BangTilde => 54
            case DotDot => 55
            case DotDotEq => 56
            case EOF => 57
        }
    }
}

/**
 * 词法单元（只读 struct，6 字段，值语义；design §4.3.1）。
 *
 * **`nlBefore` 而不是 `NewLine` kind**（design §4.3.1「为什么不设 NewLine kind」）：
 * 换行不是词法单元而是**语句终结信号**；且多行串内部的换行是**字面内容**不该产 token。
 * **用 `nlBefore` 而不是比较 `line`**：`"""…"""` 这类跨行 token 结束之后同行紧跟 `-` 时，
 * 两个 token 的 `line` 相同却跨过换行，只有词法阶段记录才可靠（同法支撑 `>|` 的行首判定）。
 */
internal struct Token {
    /** 类别。 */
    public let kind: TokenKind
    /** 归一化后的字面文本 / 原文拼写。 */
    /**
     * 归一化后的字面文本 / 原文拼写：
     *
     * - 标识符 / 关键字 / 标点 / 运算符：原文拼写；
     * - `IntLit` / `DecLit`：数字原文（`F64Lit` 不含 `f64` 后缀）；
     * - `StrLit`：串体（已换行规范化 → 锚定截取 → 转义解码；**插值原文保留**，S3.12 再切分）；
     * - `RegexLit`：两个斜杠之间的 pattern（flags 归一为位域，经 `Lexer.lastRegexFlags()` 取出）。
     */
    public let text: String
    /** 源码字节位置（token 起点，基于换行规范化之后的源码）。 */
    public let pos: Int64
    /** 1 起。 */
    public let line: Int64
    /** 1 起，按 **Unicode 码点**计（design §4.3.1「多字节码点列号」）。 */
    public let column: Int64
    /** 本 token 之前（跳过空白与注释时）**跨过了换行**。 */
    public let nlBefore: Bool
    /**
     * `RegexLit` 的 flags 位域（bit0=i bit1=m bit2=u）；其余 kind 恒 0。
     *
     * 加这个字段的原因：`text` 只放 pattern（`Lexer_test` 与设计均按此断言），而降低阶段
     * 需要把 flags 写进正则常量（§11.5 kind 10）；`Lexer.lastRegexFlags()` 只在「刚取完
     * 该 token」时有意义，`Parser` 预先批量取词后已无法回读。
     */
    public let flags: UInt8

    public init(kind: TokenKind, text: String, pos: Int64, line: Int64, column: Int64, nlBefore: Bool,
        flags!: UInt8 = 0u8) {
        this.kind = kind
        this.text = text
        this.pos = pos
        this.line = line
        this.column = column
        this.nlBefore = nlBefore
        this.flags = flags
    }
}

/**
 * 编译期错误分类常量（design §4.3.9；测试按 kind 断言，**词法族逐 kind 一条用例**）。
 *
 * **词法族**（fail-fast，design §4.3.1）：非法字符 / 未闭合字符串 / 非法转义 / 畸形数字 /
 * 未闭合正则 / 未闭合注释 / 多行头部有内容 / 未闭合多行串 / 未闭合原始串。
 * **解析 / 名字 / 校验族**：未注册函数 / 未定义标识符 / 坏形参表 / 缺箭头 / 重名注册 / 未实现特性。
 *
 * 「编译期错误只有一个出口」：`SourceCompileException` 不占用 §2 运行期错误码（§8.4）。
 */
internal class DiagKind {
    // ---- 词法族（design §4.3.1 策略 ①–⑥ + §8.8 三错）----
    /** 不属于任何合法词法单元的字符——`@`、插值外的 `$`、反引号等。 */
    public static const ILLEGAL_CHARACTER: String = "IllegalCharacter"
    /** 单行串或 `${…}` 未闭合。 */
    public static const UNTERMINATED_STRING: String = "UnterminatedString"
    /** 非法转义；多行串中单独 `\`（§8.8「内容可含除单独 `\` 外的任意字符」）。 */
    public static const BAD_ESCAPE: String = "BadEscape"
    /** 数字字形畸形（`1.2.3`、`3e`）——**超 Int64 域是合法输入**，不属本类（§11.9）。 */
    public static const BAD_NUMBER: String = "BadNumber"
    /** 正则段缺闭合 `/`。 */
    public static const UNTERMINATED_REGEX: String = "UnterminatedRegex"
    /** `/* */` 嵌套未配平至源码结束（§8.5）。 */
    public static const UNTERMINATED_COMMENT: String = "UnterminatedComment"
    /** 多行串开头三引号同行出现非空白内容（§8.8）。 */
    public static const MULTILINE_HEAD_CONTENT: String = "MultilineHeadContent"
    /** 多行串未闭合（§8.8）。 */
    public static const UNTERMINATED_MULTILINE_STRING: String = "UnterminatedMultilineString"
    /** 原始串未闭合（§8.8）。 */
    public static const UNTERMINATED_RAW_STRING: String = "UnterminatedRawString"

    // ---- 解析 / 名字 / 校验族 ----
    /** 调用点了未注册的预定义函数（§8.4 需求 4）。 */
    public static const UNREGISTERED_FUNCTION: String = "UnregisteredFunction"
    /** 非调用位置的未定义标识符（§8.4 需求 4）。 */
    public static const UNDEFINED_IDENTIFIER: String = "UndefinedIdentifier"
    /** 形参表非法：具名参数 / 参数默认值 / 缺类型注解（§8.0）。 */
    public static const BAD_PARAMETER_LIST: String = "BadParameterList"
    /** lambda 缺 `=>`（§8.0「`=>` 不可省略」）。 */
    public static const MISSING_ARROW: String = "MissingArrow"
    /** 预定义函数重名注册（S6.2；常量在本包登记，供§4.3.9 清单完整）。 */
    public static const DUPLICATE_REGISTRATION: String = "DuplicateRegistration"
    /** 未实现特性：§7 校验 2/8/11（0xA9–AA、0xC0–FF、CALL_HOST、变更型 + deopt 源）的编译期呈现。 */
    public static const NOT_IMPL: String = "NotImpl"
    /** 明确赋值违规：读未赋值局部 / `PUSH_NULL` 直存句柄型槽（§7 校验 10）。 */
    public static const NOT_ASSIGNED: String = "NotAssigned"
    /** 类型不一致（值用法 if 分支类型不一致、调用实参类型不符等，§11.9 前端义务）。 */
    public static const TYPE_MISMATCH: String = "TypeMismatch"
    /** 语法错误（无法归入上述细类的解析期错误）。 */
    public static const SYNTAX_ERROR: String = "SyntaxError"
    /**
     * 代码生成期的**内部不变量**被破坏（未回填的标签、分支汇合栈深不等、发射了 RSVD/FORBID 区等）。
     *
     * 触发面**不可由用户源码直接构造**：发生即意味着 `Lowerer` / `BytecodeBuilder` 自身的缺陷
     * （正常路径在下层已被 diag 拦住）；它与源语言无关，故独占一个 kind 以便快速定位。
     */
    public static const CODE_GEN: String = "CodeGen"
}
