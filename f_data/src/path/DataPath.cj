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
package fountain::f_data.path

import std.ast.{cangjieLex, Tokens, Token, TokenKind}
import std.collection.{ArrayList, LinkedList, HashSet}
import std.convert.Parsable
import std.reflect.*
import fountain::f_base.*
import fountain::f_macros.*
import fountain::f_data.exception.DataException
internal import fountain::f_data.base.*

/**
 * $                根元素
 * @                当前元素
 * .                子元素
 * ..               递归下降，
 * *                当前节点的所有元素
 * []               大于等于1个子元素，可以是数组索引或对象元素名
 * [,]              多个子元素用,分隔
 * [start:end:step] 数组区间，step可省略，step默认是1
 * ?()              过滤表达式
 *
 * min()            数组最小值
 * max()            数组最大值
 * avg()            数组平均值
 * stddev()         数组标准差，未实现
 * length()         数组长度
 *
 * ==               相等
 * !=               不相等
 * <                小于
 * <=               小于等于
 * >                大于
 * >=               大于等于
 * =~               左侧是否匹配右侧的正则
 * in               左侧是否存在于右侧的数组、左侧的字符串是不是右侧对象的key或属性名
 * nin              in的相反运算
 * anyof            左侧与右侧的交集数是否大于零，左侧是单值是认为是只有一个值的集合。
 *                  如果左侧是字符串，右侧是map或对象则判断左侧是否右侧key的子集或是否右侧对象属性的子集
 * subsetof         左侧与右侧的交集数是否等于左侧数
 * nooneof          左侧与右侧的交集数是否等于零
 * size             左侧集合长度或字符串长度或map大小或对象属性数是否等于右侧指定的整数
 *
 * && || !          逻辑与、逻辑或、逻辑非
 * [?(@.age =~ /\d+/)]
 */
abstract sealed class DataPath <: DataPathNode {
    private let nodes = ArrayList<DataPathNode>()

    init() {}
    public static func solid(path: String): DataPath {
        SolidDataPath.compile(path)
    }
    public static func cache(path: String): DataPath {
        CacheDataPath.compile(path)
    }
    func doCompile(path: String, solid: Bool): DataPath {
        if (!(path == '$' || path == '@' || path.startsWith('$.') || path.startsWith('$[') || path.startsWith('@.') || path.startsWith('@['))) {
            throw DataException('data path must be "$" or starts with "$." or "$[", but it is ${path}')
        }
        doCompile(cangjieLex(path, true), solid)
    }
    private func extractSubPathInSquares(path: Tokens, index: Int64): (Tokens, Int64) {
        var parens = 0
        var end = -1
        for (i in index..path.size) {
            let t = path[i]
            match (t.kind) {
                case LSQUARE => parens++
                case RSQUARE =>
                    parens--
                    if (parens == 0) {
                        end = i
                        break
                    }
                case _ => continue
            }
        }
        if (end < 0) {
            throw DataException('squares are not match after ${index} in data path ${path}')
        }
        (path[index + 1..end], end)
    }
    private func compileSubInSquares(sub: Tokens) {
        match (sub[0].kind) {
            case STRING_LITERAL | SINGLE_QUOTED_STRING_LITERAL | IDENTIFIER => SubPathNode(sub[0].value)
            case _ => throw DataException('sub expression in squares can only be string literal or identifier')
        }
    }
    private func compileIndexInSquares(sub: Tokens) {
        let idx = parseIndexToken(sub[0], sub, 0)
        IndexPathNode(idx)
    }
    private func compileSubsInSquares(sub: Tokens) {
        let names = ArrayList<String>()
        for (t in sub) {
            let n = match (t.kind) {
                case STRING_LITERAL | SINGLE_QUOTED_STRING_LITERAL | IDENTIFIER => t.value
                case COMMA => continue
                case _ => throw DataException(
                    'sub expression in squares as multi-names can only be string literal, identifier and comma, but current are ${sub}')
            }
            names.add(n)
        }
        MultiSubPathNode(names.unsafeData())
    }
    private func parseIndexToken(t: Token, sub: Tokens, i: Int64): Int64 {
        match (t.kind) {
            case INTEGER_LITERAL => Int64.parse(t.value)
            case SUB where i + 1 < sub.size && sub[i + 1].kind == INTEGER_LITERAL => -Int64.parse(sub[i + 1].value)
            case _ => throw DataException('sub expression as an index must be an integer')
        }
    }
    private func compileIndexesInSquares(sub: Tokens): DataPathNode {
        // Check if this is a slice (contains colon)
        for (t in sub) {
            if (t.kind == COLON) {
                return compileSliceInSquares(sub)
            }
        }
        let list = ArrayList<Int64>()
        var i = 0
        while (i < sub.size) {
            let t = sub[i]
            match (t.kind) {
                case INTEGER_LITERAL =>
                    list.add(Int64.parse(t.value))
                case SUB where i + 1 < sub.size && sub[i + 1].kind == INTEGER_LITERAL =>
                    list.add(-Int64.parse(sub[i + 1].value))
                    i++
                case COMMA => ()
                case _ => throw DataException(
                    'sub expression in squares must be all strings or int64 or int1:int2:int3 or int1:int2')
            }
            i++
        }
        MultiIndexPathNode(list.toArray())
    }
    private func compileSliceInSquares(sub: Tokens): RangePathNode {
        // Parse [start:end:step] with all parts optional
        var start = Int64.Max  // UNSET sentinel
        var end = Int64.Max
        var step = 1i64
        var phase = 0  // 0=start, 1=end, 2=step
        var i = 0
        while (i < sub.size) {
            let t = sub[i]
            match (t.kind) {
                case INTEGER_LITERAL =>
                    if (phase == 0) { start = Int64.parse(t.value)
                    } else if (phase == 1) { end = Int64.parse(t.value)
                    } else { step = Int64.parse(t.value) }
                case SUB where i + 1 < sub.size && sub[i + 1].kind == INTEGER_LITERAL =>
                    let val = -Int64.parse(sub[i + 1].value)
                    if (phase == 0) { start = val
                    } else if (phase == 1) { end = val
                    } else { step = val }
                    i++
                case COLON => phase++
                case _ => throw DataException('illegal slice expression ${sub}')
            }
            i++
        }
        RangePathNode(start, end, step)
    }
    private func parseFilterTokens(sub: Tokens, solid: Bool): Tokens {
        var tokens = quote()
        var i = 0
        while (i < sub.size) {
            let t = sub[i]
            match (t.kind) {
                case LPAREN =>
                    var parens = 0
                    var end = -1
                    for (e in i..sub.size) {
                        match (sub[e].kind) {
                            case LPAREN => parens++
                            case RPAREN =>
                                parens--
                                if (parens == 0) {
                                    end = e
                                    break
                                }
                            case _ => continue
                        }
                    }
                    if (end <= i) {
                        throw DataException('illegal filter expression for data path, ${sub}')
                    }
                    tokens += `lparen` + parseFilterTokens(sub[i + 1..end], solid) + `rparen`
                    i = end
                case AT =>
                    let savedI = i
                    var pathEnd = sub.size
                    for (e in i + 1..sub.size) {
                        let t = sub[e]
                        match (t.kind) {
                        case EQUAL where sub[e + 1].kind == STRING_LITERAL || sub[e + 1].kind == SINGLE_QUOTED_STRING_LITERAL =>
                            tokens += quote(EqFilter<String>($(sub[i .. e].toString()), $(sub[e + 1].value), $(if (solid) { "true" } else { "false" })))
                            i = e + 1
                            break
                        case EQUAL where sub[e + 1].kind == INTEGER_LITERAL =>
                            tokens += quote(EqFilter<Int64>($(sub[i .. e].toString()), $(sub[e + 1].value), $(if (solid) { "true" } else { "false" })))
                            i = e + 1
                            break
                        case EQUAL where sub[e + 1].kind == FLOAT_LITERAL =>
                            tokens += quote(EqFilter<Float64>($(sub[i .. e].toString()), $(sub[e + 1].value), 'false'))
                            i = e + 1
                            break
                        case EQUAL where sub[e + 1].kind == BOOL_LITERAL =>
                            tokens += quote(EqFilter<Bool>($(sub[i .. e].toString()), $(sub[e + 1].value), 'false'))
                            i = e + 1
                            break
                        case NOTEQ where sub[e + 1].kind == STRING_LITERAL || sub[e + 1].kind == SINGLE_QUOTED_STRING_LITERAL =>
                            tokens += quote(NotEqFilter<String>($(sub[i .. e].toString()), $(sub[e + 1].value), 'false'))
                            i = e + 1
                            break
                        case NOTEQ where sub[e + 1].kind == INTEGER_LITERAL =>
                            tokens += quote(NotEqFilter<Int64>($(sub[i .. e].toString()), $(sub[e + 1].value), 'false'))
                            i = e + 1
                            break
                        case NOTEQ where sub[e + 1].kind == FLOAT_LITERAL =>
                            tokens += quote(NotEqFilter<Float64>($(sub[i .. e].toString()), $(sub[e + 1].value), 'false'))
                            i = e + 1
                            break
                        case NOTEQ where sub[e + 1].kind == BOOL_LITERAL =>
                            tokens += quote(NotEqFilter<Bool>($(sub[i .. e].toString()), $(sub[e + 1].value), 'false'))
                            i = e + 1
                            break
                        case EQUAL where sub[e + 1].kind == IDENTIFIER && sub[e + 1].value == 'null' =>
                            tokens += quote(NullFilter($(sub[i .. e].toString()), 'false', 'true'))
                            i = e + 1
                            break
                        case NOTEQ where sub[e + 1].kind == IDENTIFIER && sub[e + 1].value == 'null' =>
                            tokens += quote(NullFilter($(sub[i .. e].toString()), 'false', 'false'))
                            i = e + 1
                            break
                        case LT where sub[e + 1].kind == STRING_LITERAL || sub[e + 1].kind ==SINGLE_QUOTED_STRING_LITERAL =>
                            tokens += quote(CmpFilter<String>($(sub[i .. e].toString()), $(sub[e + 1].value), 'LT', 'false', 'false'))
                            i = e + 1
                            break
                        case LT where sub[e + 1].kind == INTEGER_LITERAL =>
                            tokens += quote(CmpFilter<Int64>($(sub[i .. e].toString()), $(sub[e + 1].value), 'LT', 'false', 'false'))
                            i = e + 1
                            break
                        case LT where sub[e + 1].kind == FLOAT_LITERAL =>
                            tokens += quote(CmpFilter<Float64>($(sub[i .. e].toString()), $(sub[e + 1].value), 'LT', 'false', 'false'))
                            i = e + 1
                            break
                        case GT where sub[e + 1].kind == STRING_LITERAL || sub[e + 1].kind == SINGLE_QUOTED_STRING_LITERAL =>
                            tokens += quote(CmpFilter<String>($(sub[i .. e].toString()), $(sub[e + 1].value), 'GT', 'false', 'false'))
                            i = e + 1
                            break
                        case GT where sub[e + 1].kind == INTEGER_LITERAL =>
                            tokens += quote(CmpFilter<Int64>($(sub[i .. e].toString()), $(sub[e + 1].value), 'GT', 'false', 'false'))
                            i = e + 1
                            break
                        case GT where sub[e + 1].kind == FLOAT_LITERAL =>
                            tokens += quote(CmpFilter<Float64>($(sub[i .. e].toString()), $(sub[e + 1].value), 'GT', 'false', 'false'))
                            i = e + 1
                            break
                        case LE where sub[e + 1].kind == STRING_LITERAL || sub[e + 1].kind == SINGLE_QUOTED_STRING_LITERAL =>
                            tokens += quote(CmpFilter<String>($(sub[i .. e].toString()), $(sub[e + 1].value), 'LT', 'true', 'false'))
                            i = e + 1
                            break
                        case LE where sub[e + 1].kind == INTEGER_LITERAL =>
                            tokens += quote(CmpFilter<Int64>($(sub[i .. e].toString()), $(sub[e + 1].value), 'LT', 'true', 'false'))
                            i = e + 1
                            break
                        case LE where sub[e + 1].kind == FLOAT_LITERAL =>
                            tokens += quote(CmpFilter<Float64>($(sub[i .. e].toString()), $(sub[e + 1].value), 'LT', 'true', 'false'))
                            i = e + 1
                            break
                        case GE where sub[e + 1].kind == STRING_LITERAL || sub[e + 1].kind == SINGLE_QUOTED_STRING_LITERAL =>
                            tokens += quote(CmpFilter<String>($(sub[i .. e].toString()), $(sub[e + 1].value), 'GT', 'true', 'false'))
                            i = e + 1
                            break
                        case GE where sub[e + 1].kind == INTEGER_LITERAL =>
                            tokens += quote(CmpFilter<Int64>($(sub[i .. e].toString()), $(sub[e + 1].value), 'GT', 'true', 'false'))
                            i = e + 1
                            break
                        case GE where sub[e + 1].kind == FLOAT_LITERAL =>
                            tokens += quote(CmpFilter<Float64>($(sub[i .. e].toString()), $(sub[e + 1].value), 'GT', 'true', 'false'))
                            i = e + 1
                            break
                        case ASSIGN where sub[e + 1].kind == BITNOT && sub[e + 2].kind == DIV =>
                            let rs = e + 2
                            var re = rs + 1
                            let pathPrefixEnd = e
                            for (e in re..sub.size where sub[e].kind == DIV) {
                                re = e
                                break
                            }
                            if (rs + 1 == re || sub[re].kind != DIV) {
                                throw DataException('illegal regex in data path filter ${sub}')
                            }
                            if (re + 1 < sub.size && sub[re + 1].kind == IDENTIFIER && sub[re + 1].value == 'i') {
                                re++
                            }
                            tokens += quote(RegexFilter($(sub[i .. pathPrefixEnd].toString()), $(concatTokenValues(sub[rs ..= re])), 'false'))
                            i = re
                            break
                        case IN where sub[e + 1].kind == LSQUARE =>
                            let (t, e) = parseSetOp(sub, i, e, quote(InFilter), solid)
                            tokens += t
                            i = e
                            break
                        case IDENTIFIER where t.value == 'in' && sub[e + 1].kind == LSQUARE =>
                            let (t, e) = parseSetOp(sub, i, e, quote(InFilter), solid)
                            tokens += t
                            i = e
                            break
                        case IDENTIFIER where t.value == 'nin' && sub[e + 1].kind == LSQUARE =>
                            let (t, e) = parseSetOp(sub, i, e, quote(NinFilter), solid)
                            tokens += t
                            i = e
                            break
                        case IDENTIFIER where t.value == 'anyof' && sub[e + 1].kind == LSQUARE =>
                            let (t, e) = parseSetOp(sub, i, e, quote(AnyOfFilter), solid)
                            tokens += t
                            i = e
                            break
                        case IDENTIFIER where t.value == 'subsetof' && sub[e + 1].kind == LSQUARE =>
                            let (t, e) = parseSetOp(sub, i, e, quote(SubSetOfFilter), solid)
                            tokens += t
                            i = e
                            break
                        case IDENTIFIER where t.value == 'nooneof' && sub[e + 1].kind == LSQUARE =>
                            let (t, e) = parseSetOp(sub, i, e, quote(NoOneOfFilter), solid)
                            tokens += t
                            i = e
                            break
                        case IDENTIFIER where t.value == 'size' && sub[e + 1].kind == INTEGER_LITERAL =>
                            tokens += quote(SizeFilter($(sub[i .. e].toString()), $(sub[e + 1].value), 'false'))
                            i = e + 1
                            break
                        case DOT | IDENTIFIER => continue
                        case _ =>
                            pathEnd = e
                            break
                    }
                }
                if (i == savedI) {
                    // RFC 9535 existence test: @.path without operator
                    tokens += quote(ExistsFilter($(concatTokenValues(sub[i .. pathEnd])), 'false'))
                    i = pathEnd - 1
                }
                case NOT => tokens += quote(!)
                case AND where i > 0 => tokens += quote(&&)
                case OR where i > 0 => tokens += quote(||)
                case IDENTIFIER =>
                    if (t.value != 'search') {
                        throw DataException('filter in data path ${sub} is illegal')
                    }
                    // Find matching RPAREN (for search)
                    var parens = 0
                    var rparenIdx = -1
                    for (e in i + 1..sub.size) {
                        match (sub[e].kind) {
                            case LPAREN => parens++
                            case RPAREN =>
                                parens--
                                if (parens == 0) { rparenIdx = e; break }
                            case _ => continue
                        }
                    }
                    if (rparenIdx < 0) { throw DataException('unclosed paren in function call ${sub}') }
                    let args = sub[i + 2 .. rparenIdx]
                    var commaIdx = -1
                    for (e in 0..args.size) {
                        if (args[e].kind == COMMA) { commaIdx = e; break }
                    }
                    if (commaIdx < 0) { throw DataException('function call search requires 2 arguments') }
                    let pathTokens = sub[i + 2 .. i + 2 + commaIdx]
                    let regexTokens = sub[i + 2 + commaIdx + 1 .. rparenIdx]
                    let path = concatTokenValues(pathTokens)
                    let rawRegex = concatTokenValues(regexTokens)
                    let regex = if (rawRegex.size >= 2 && (rawRegex[0] == 0x27u8 || rawRegex[0] == 0x22u8)) {
                        rawRegex[1..rawRegex.size - 1]
                    } else { rawRegex }
                    tokens += quote(SearchFilter($(path), $(regex), 'false'))
                    i = rparenIdx
                case MATCH =>
                    // Find matching RPAREN (for match)
                    var parens2 = 0
                    var rparenIdx2 = -1
                    for (e in i + 1..sub.size) {
                        match (sub[e].kind) {
                            case LPAREN => parens2++
                            case RPAREN =>
                                parens2--
                                if (parens2 == 0) { rparenIdx2 = e; break }
                            case _ => continue
                        }
                    }
                    if (rparenIdx2 < 0) { throw DataException('unclosed paren in function call ${sub}') }
                    let args2 = sub[i + 2 .. rparenIdx2]
                    var commaIdx2 = -1
                    for (e in 0..args2.size) {
                        if (args2[e].kind == COMMA) { commaIdx2 = e; break }
                    }
                    if (commaIdx2 < 0) { throw DataException('function call match requires 2 arguments') }
                    let pathTokens2 = sub[i + 2 .. i + 2 + commaIdx2]
                    let regexTokens2 = sub[i + 2 + commaIdx2 + 1 .. rparenIdx2]
                    let path2 = concatTokenValues(pathTokens2)
                    let rawRegex2 = concatTokenValues(regexTokens2)
                    let regex2 = if (rawRegex2.size >= 2 && (rawRegex2[0] == 0x27u8 || rawRegex2[0] == 0x22u8)) {
                        rawRegex2[1..rawRegex2.size - 1]
                    } else { rawRegex2 }
                    tokens += quote(MatchFilter($(path2), $(regex2), 'false'))
                    i = rparenIdx2
                case _ => throw DataException('filter in data path ${sub} is illegal')
            }
            i++
        }
        tokens
    }
    private func parseSetOp(sub: Tokens, i: Int64, e: Int64, filter: Tokens, solid: Bool): (Tokens, Int64) {
        let arrs = e + 1
        var arre = arrs + 1
        for (e in arre..sub.size where sub[e].kind == RSQUARE) {
            arre = e
            break
        }
        if (arrs + 1 == arre) {
            throw DataException('illegal empty array in data path filter ${sub} for in expression')
        }
            let tokens = match (sub[arrs + 1].kind) {
            case STRING_LITERAL | SINGLE_QUOTED_STRING_LITERAL => quote($(filter)<String>($(sub[i .. e].toString()), $(sub[arrs + 1 .. arre].toString()), 'false'))
            case INTEGER_LITERAL => quote($(filter)<Int64>($(sub[i .. e].toString()), $(sub[arrs + 1 .. arre].toString()), 'false'))
            case FLOAT_LITERAL => quote($(filter)<Float64>($(sub[i .. e].toString()), $(sub[arrs + 1 .. arre].toString()), 'false'))
            case _ => throw DataException('illegal array element type in data path filter ${sub} for in expression')
        }
        (tokens, arre)
    }
    private func compileFilter(sub: Tokens, solid: Bool) {
        let tokens = parseFilterTokens(sub, solid)
        let expr = parseExpr(tokens)
        DataFilterPathNode(compileFilter(expr))
    }
    private func compileFilter(expr: Expr): DataFilter {
        //EqFilter<> NotEqFilter<> CmpFilter<> RegexFilter 
        //InFilter<> NinFilter<> AnyOfFilter<> SubSetOfFilter<> NoOneOfFilter<>
        //SizeFilter
        //CallExpr ParenExpr BinaryExpr UnaryExpr
        func arg(args: Tokens, index: Int64) {
            // Args include COMMA tokens between values, skip them
            let actualIndex = index * 2
            if (actualIndex >= args.size) {
                throw DataException('missing argument at index ${index} in filter ${args}')
            }
            let v = args[actualIndex].value
            if (v.size >= 2 && (v[0] == 0x27u8 || v[0] == 0x22u8)) {
                v[1..v.size - 1]
            } else {
                v
            }
        }
        match (expr) {
            case x: CallExpr =>
                let tokens = x.toTokens()
                let filter = tokens[0].value
                let generic = tokens[2].value
                let args = tokens[if (filter == 'RegexFilter' || filter == 'SizeFilter' || filter == 'ExistsFilter' || filter == 'NullFilter' || filter == 'MatchFilter' || filter == 'SearchFilter') {
                        2
                    } else {
                        5
                    }..tokens.size - 1]
                match ((filter, generic)) {
                    case ('EqFilter', 'String') => EqFilter<String>(arg(args, 0), arg(args, 1), arg(args, 2))
                    case ('EqFilter', 'Int64') => EqFilter<Int64>(arg(args, 0), arg(args, 1), arg(args, 2))
                    case ('EqFilter', 'Float64') => EqFilter<Float64>(arg(args, 0), arg(args, 1), arg(args, 2))
                    case ('EqFilter', 'Bool') => EqFilter<Bool>(arg(args, 0), arg(args, 1), arg(args, 2))
                    case ('NotEqFilter', 'String') => NotEqFilter<String>(arg(args, 0), arg(args, 1), arg(args, 2))
                    case ('NotEqFilter', 'Int64') => NotEqFilter<Int64>(arg(args, 0), arg(args, 1), arg(args, 2))
                    case ('NotEqFilter', 'Float64') => NotEqFilter<Float64>(arg(args, 0), arg(args, 1), arg(args, 2))
                    case ('NotEqFilter', 'Bool') => NotEqFilter<Bool>(arg(args, 0), arg(args, 1), arg(args, 2))
                    case ('CmpFilter', 'String') => CmpFilter<String>(arg(args, 0), arg(args, 1), arg(args, 2),
                        arg(args, 3), arg(args, 4))
                    case ('CmpFilter', 'Int64') => CmpFilter<Int64>(arg(args, 0), arg(args, 1), arg(args, 2),
                        arg(args, 3), arg(args, 4))
                    case ('CmpFilter', 'Float64') => CmpFilter<Float64>(arg(args, 0), arg(args, 1), arg(args, 2),
                        arg(args, 3), arg(args, 4))
                    case ('RegexFilter', _) => RegexFilter(arg(args, 0), arg(args, 1), arg(args, 2))
                    case ('InFilter', 'String') => InFilter<String>(arg(args, 0), arg(args, 1), arg(args, 2))
                    case ('InFilter', 'Int64') => InFilter<Int64>(arg(args, 0), arg(args, 1), arg(args, 2))
                    case ('InFilter', 'Float64') => InFilter<Float64>(arg(args, 0), arg(args, 1), arg(args, 2))
                    case ('NinFilter', 'String') => NinFilter<String>(arg(args, 0), arg(args, 1), arg(args, 2))
                    case ('NinFilter', 'Int64') => NinFilter<Int64>(arg(args, 0), arg(args, 1), arg(args, 2))
                    case ('NinFilter', 'Float64') => NinFilter<Float64>(arg(args, 0), arg(args, 1), arg(args, 2))
                    case ('AnyOfFilter', 'String') => AnyOfFilter<String>(arg(args, 0), arg(args, 1), arg(args, 2))
                    case ('AnyOfFilter', 'Int64') => AnyOfFilter<Int64>(arg(args, 0), arg(args, 1), arg(args, 2))
                    case ('AnyOfFilter', 'Float64') => AnyOfFilter<Float64>(arg(args, 0), arg(args, 1), arg(args, 2))
                    case ('SubSetOfFilter', 'String') => SubSetOfFilter<String>(arg(args, 0), arg(args, 1), arg(args, 2))
                    case ('SubSetOfFilter', 'Int64') => SubSetOfFilter<Int64>(arg(args, 0), arg(args, 1), arg(args, 2))
                    case ('SubSetOfFilter', 'Float64') => SubSetOfFilter<Float64>(arg(args, 0), arg(args, 1),
                        arg(args, 2))
                    case ('NoOneOfFilter', 'String') => NoOneOfFilter<String>(arg(args, 0), arg(args, 1), arg(args, 2))
                    case ('NoOneOfFilter', 'Int64') => NoOneOfFilter<Int64>(arg(args, 0), arg(args, 1), arg(args, 2))
                    case ('NoOneOfFilter', 'Float64') => NoOneOfFilter<Float64>(arg(args, 0), arg(args, 1), arg(args, 2))
                    case ('SizeFilter', _) => SizeFilter(arg(args, 0), arg(args, 1), arg(args, 2))
                    case ('ExistsFilter', _) => ExistsFilter(arg(args, 0), arg(args, 1))
                    case ('NullFilter', _) => NullFilter(arg(args, 0), arg(args, 1), arg(args, 2))
                    case ('MatchFilter', _) => MatchFilter(arg(args, 0), arg(args, 1), arg(args, 2))
                    case ('SearchFilter', _) => SearchFilter(arg(args, 0), arg(args, 1), arg(args, 2))
                    case _ => throw DataException('unreachable ${tokens}')
                }
            case x: ParenExpr => compileFilter(x.parenthesizedExpr)
            case x: UnaryExpr where x.op.kind == NOT => !compileFilter(x.expr)
            case x: BinaryExpr where x.op.kind == AND => compileFilter(x.leftExpr) & compileFilter(x.rightExpr)
            case x: BinaryExpr where x.op.kind == OR => compileFilter(x.leftExpr) | compileFilter(x.rightExpr)
            case _ => throw DataException('unreachable ${expr.toTokens()}')
        }
    }
    private func hasColon(sub: Tokens): Bool {
        for (t in sub) {
            if (t.kind == COLON) {
                return true
            }
        }
        false
    }
    private static func concatTokenValues(toks: Tokens): String {
        let s = StringGenerator()
        for (t in toks) {
            s.append(t.value)
        }
        s.toString()
    }
    private func compileInSquares(sub: Tokens, solid: Bool): DataPathNode {
        if (sub.size == 1 && (sub[0].kind == STRING_LITERAL || sub[0].kind == SINGLE_QUOTED_STRING_LITERAL)) {
            compileSubInSquares(sub)
        } else if (sub.size == 1 && sub[0].kind == INTEGER_LITERAL) {
            compileIndexInSquares(sub)
        } else if (sub.size == 1 && sub[0].kind == MUL) {
            AnySubPathNode.instance
        } else if (sub.size == 2 && sub[0].kind == SUB && sub[1].kind == INTEGER_LITERAL) {
            compileIndexInSquares(sub)
        } else if (sub.size > 1 && (sub[0].kind == STRING_LITERAL || sub[0].kind == SINGLE_QUOTED_STRING_LITERAL)) {
            compileSubsInSquares(sub)
        } else if (sub.size > 1 && (sub[0].kind == INTEGER_LITERAL || (sub[0].kind == SUB && sub[1].kind == INTEGER_LITERAL))) {
            compileIndexesInSquares(sub)
        } else if (sub.size > 1 && sub[0].kind == QUEST && sub[1].kind == LPAREN && sub[sub.size - 1].kind == RPAREN) {
            compileFilter(sub[2..sub.size - 1], solid)
        } else {
            compileSliceInSquares(sub)
        }
    }
    private func doCompile(path: Tokens, solid: Bool): DataPath {
        var i = 0
        while (i < path.size) {
            let node = if (i == 0 && path[i].kind == DOLLAR) {
                RootPathNode.instance
            } else if (path[i].kind == DOT && i + 3 < path.size && path[i + 1].kind == IDENTIFIER && path[i + 2].kind == LPAREN &&
                path[i + 3].kind == RPAREN) {
                let node: DataPathNode = match (path[i + 1].value) {
                    case 'min' => MinPathNode.instance
                    case 'max' => MaxPathNode.instance
                    case 'avg' => AvgPathNode.instance
                    case 'length' => LengthPathNode.instance
                    case 'count' => CountPathNode.instance
                    case 'value' => ValuePathNode.instance
                    case _ => throw DataException(
                        'data path is illegal at index ${i}, path: ${path}, unsupported function call')
                }
                i += 3
                node
            } else if (path[i].kind == DOT && path[i + 1].kind == IDENTIFIER) {
                i++
                SubPathNode(path[i].value)
            } else if (path[i].kind == DOT && path[i + 1].kind == MUL) {
                i++
                AnySubPathNode.instance
            } else if (path[i].kind == DOT && path[i + 1].kind == DOT) {
                // Skip optional MUL after .. (..* means all descendants)
                if (i + 2 < path.size && path[i + 2].kind == MUL) {
                    i++
                }
                RecursiveDescentPathNode.instance
            } else if (path[i].kind == RANGEOP) {
                // Skip optional MUL after .. (..* with RANGEOP token)
                if (i + 1 < path.size && path[i + 1].kind == MUL) {
                    i++
                }
                RecursiveDescentPathNode.instance
            } else if (path[i].kind == IDENTIFIER && i > 0 && (path[i - 1].kind == RANGEOP || path[i - 1].kind == DOT)) {
                SubPathNode(path[i].value)
            } else if (path[i].kind == DOT && path[i + 1].kind == LSQUARE && path[i - 1].kind == DOT) {
                let (sub, index) = extractSubPathInSquares(path, i + 1)
                i = index
                compileInSquares(sub, solid)
            } else if (path[i].kind == LSQUARE && (path[i - 1].kind == IDENTIFIER || path[i - 1].kind == DOLLAR ||
                path[i - 1].kind == AT || path[i - 1].kind == RSQUARE || path[i - 1].kind == RANGEOP || path[i - 1].kind == DOT)) {
                let (subPath, index) = extractSubPathInSquares(path, i)
                i = index
                compileInSquares(subPath, solid)
            } else if (i == 0 && path[i].kind == AT) {
                CurrentPathNode.instance
            } else {
                throw DataException('data path is illegal at index ${i}, path: ${path}')
            }
            nodes.add(node)
            i++
        }
        this
    }
    public func get(data: Data): Iterator<Data> {
        var itr: Iterator<Data> = nodes[0].get(data)
        for (i in 1..nodes.size) {
            itr = itr.flatMap<Data> {d => nodes[i].get(d)}
        }
        itr
    }
}
