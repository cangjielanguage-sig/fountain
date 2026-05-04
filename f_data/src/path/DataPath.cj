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
    private static let IJSON_MIN: Int64 = -9007199254740991
    private static let IJSON_MAX: Int64 = 9007199254740991
    private let nodes = ArrayList<DataPathNode>()
    // Side channel for pre-compiled sub-filters used in nested function expressions
    private let subFilters = ArrayList<DataFilter>()

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
            case INTEGER_LITERAL =>
                let val = Int64.parse(t.value)
                validateIJSON(val)
                val
            case SUB where i + 1 < sub.size && sub[i + 1].kind == INTEGER_LITERAL =>
                let val = -Int64.parse(sub[i + 1].value)
                validateIJSON(val)
                val
            case _ => throw DataException('sub expression as an index must be an integer')
        }
    }
    private static func validateIJSON(val: Int64) {
        if (val < IJSON_MIN || val > IJSON_MAX) {
            throw DataException('integer ${val} is outside I-JSON range [-(2^53)+1, (2^53)-1]')
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
                    let val = Int64.parse(t.value)
                    validateIJSON(val)
                    list.add(val)
                case SUB where i + 1 < sub.size && sub[i + 1].kind == INTEGER_LITERAL =>
                    let val = -Int64.parse(sub[i + 1].value)
                    validateIJSON(val)
                    list.add(val)
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
                    let raw = Int64.parse(t.value)
                    validateIJSON(raw)
                    if (phase == 0) { start = raw
                    } else if (phase == 1) { end = raw
                    } else { step = raw }
                case SUB where i + 1 < sub.size && sub[i + 1].kind == INTEGER_LITERAL =>
                    let val = -Int64.parse(sub[i + 1].value)
                    validateIJSON(val)
                    if (phase == 0) { start = val
                    } else if (phase == 1) { end = val
                    } else { step = val }
                    i++
                case COLON => phase++
                case DOUBLE_COLON =>
                    // :: is two colons: skip start and end phases, go to step
                    if (phase < 2) { phase = 2 }
                case SUB => throw DataException('illegal SUB token in slice: i=${i} i+1=${i+1} sub.size=${sub.size} next=${if (i+1<sub.size) { sub[i+1].kind.toString() } else { "N/A" }}')
                case _ => throw DataException('illegal slice expression ${sub}: unexpected token kind=${t.kind} at i=${i}')
            }
            i++
        }
        RangePathNode(start, end, step)
    }
    private func parseFilterTokens(sub: Tokens, solid: Bool): Tokens {
        var tokens = quote()
        var i = 0
        
        // Helper: find RPAREN matching LPAREN at i+1
        func findFuncRParen(): Int64 {
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
            rparenIdx
        }
        // Helper: depth-aware argument splitting by COMMA at nesting depth 0
        func splitArgsDepthAware(args: Tokens): ArrayList<Tokens> {
            let parts = ArrayList<Tokens>()
            var start = 0
            var depth = 0
            for (i in 0..args.size) {
                match (args[i].kind) {
                    case LPAREN | LSQUARE | LCURL => depth++
                    case RPAREN | RSQUARE | RCURL => depth--
                    case COMMA where depth == 0 =>
                        parts.add(args[start..i])
                        start = i + 1
                    case _ => continue
                }
            }
            if (start < args.size) {
                parts.add(args[start..args.size])
            }
            parts
        }
        // Helper: recursively compile a sub-expression (for nested function calls),
        // store in subFilters, return index as string.
        func compileSubFilter(tokens: Tokens): String {
            let inner = parseFilterTokens(tokens, solid)
            let expr = parseExpr(inner)
            let filter = compileFilter(expr)
            let idx = subFilters.size
            subFilters.add(filter)
            idx.toString()
        }
        // Helper: extract the single path argument from function call
        func extractOneArg(rparenIdx: Int64): String {
            concatTokenValues(sub[i + 2 .. rparenIdx])
        }
        // Helper: extract two arguments (path, regex) separated by COMMA
        func extractTwoArgs(rparenIdx: Int64): (String, String) {
            let parts = splitArgsDepthAware(sub[i + 2 .. rparenIdx])
            if (parts.size < 2) { throw DataException('function call requires 2 arguments') }
            let path = concatTokenValues(parts[0])
            let rawRegex = concatTokenValues(parts[1])
            let regex = if (rawRegex.size >= 2 && (rawRegex[0] == 0x27u8 || rawRegex[0] == 0x22u8)) {
                rawRegex[1..rawRegex.size - 1]
            } else { rawRegex }
            (path, regex)
        }
        // Helper: find RSQUARE matching LSQUARE at startIdx
        func findMatchingRSQUARE(startIdx: Int64): Int64 {
            var depth = 0
            for (e in startIdx..sub.size) {
                match (sub[e].kind) {
                    case LSQUARE => depth++
                    case RSQUARE =>
                        depth--
                        if (depth == 0) { return e }
                    case _ => continue
                }
            }
            throw DataException('unclosed bracket in array literal')
        }
        // Helper: find RCURL matching LCURL at startIdx
        func findMatchingRCURL(startIdx: Int64): Int64 {
            var depth = 0
            for (e in startIdx..sub.size) {
                match (sub[e].kind) {
                    case LCURL => depth++
                    case RCURL =>
                        depth--
                        if (depth == 0) { return e }
                    case _ => continue
                }
            }
            throw DataException('unclosed brace in object literal')
        }
        // Helper: emit a comparison filter for count()/value() + OP + value
        func emitCmpFilter(path: String, startIdx: Int64, fnType: String): (Tokens, Int64) {
            let opToken = sub[startIdx]
            let opKind = opToken.kind
            let valueIdx = startIdx + 1
            if (valueIdx >= sub.size) { throw DataException('missing value after comparison operator') }
            let valueToken = sub[valueIdx]
            let valueStr = valueToken.value
            let (result, nextIdx) = if (fnType == 'count') {
                let r = if (opKind == TokenKind.GT) {
                    quote(CountCmpFilter($(path), $(valueStr), "GT", "false", "false"))
                } else if (opKind == TokenKind.LT) {
                    quote(CountCmpFilter($(path), $(valueStr), "LT", "false", "false"))
                } else if (opKind == TokenKind.GE) {
                    quote(CountCmpFilter($(path), $(valueStr), "GT", "true", "false"))
                } else if (opKind == TokenKind.LE) {
                    quote(CountCmpFilter($(path), $(valueStr), "LT", "true", "false"))
                } else if (opKind == TokenKind.EQUAL) {
                    quote(CountCmpFilter($(path), $(valueStr), "EQ", "true", "false"))
                } else if (opKind == TokenKind.NOTEQ) {
                    quote(CountCmpFilter($(path), $(valueStr), "EQ", "false", "false"))
                } else {
                    throw DataException('unsupported operator for count/value comparison')
                }
                (r, valueIdx)
            } else if (fnType == 'length') {
                let r = if (opKind == TokenKind.GT) {
                    quote(LengthCmpFilter($(path), $(valueStr), "GT", "false", "false"))
                } else if (opKind == TokenKind.LT) {
                    quote(LengthCmpFilter($(path), $(valueStr), "LT", "false", "false"))
                } else if (opKind == TokenKind.GE) {
                    quote(LengthCmpFilter($(path), $(valueStr), "GT", "true", "false"))
                } else if (opKind == TokenKind.LE) {
                    quote(LengthCmpFilter($(path), $(valueStr), "LT", "true", "false"))
                } else if (opKind == TokenKind.EQUAL) {
                    quote(LengthCmpFilter($(path), $(valueStr), "EQ", "true", "false"))
                } else if (opKind == TokenKind.NOTEQ) {
                    quote(LengthCmpFilter($(path), $(valueStr), "EQ", "false", "false"))
                } else {
                    throw DataException('unsupported operator for length comparison')
                }
                (r, valueIdx)
            } else if (fnType == 'count_filter') {
                // path argument is actually a filter index (from subFilters)
                let r = if (opKind == TokenKind.GT) {
                    quote(CountFilterResult($(path), $(valueStr), "GT", "false"))
                } else if (opKind == TokenKind.LT) {
                    quote(CountFilterResult($(path), $(valueStr), "LT", "false"))
                } else if (opKind == TokenKind.GE) {
                    quote(CountFilterResult($(path), $(valueStr), "GT", "true"))
                } else if (opKind == TokenKind.LE) {
                    quote(CountFilterResult($(path), $(valueStr), "LT", "true"))
                } else if (opKind == TokenKind.EQUAL) {
                    quote(CountFilterResult($(path), $(valueStr), "EQ", "true"))
                } else if (opKind == TokenKind.NOTEQ) {
                    quote(CountFilterResult($(path), $(valueStr), "EQ", "false"))
                } else {
                    throw DataException('unsupported operator for count_filter comparison')
                }
                (r, valueIdx)
            } else if (fnType == 'value_filter') {
                if (opKind != TokenKind.EQUAL && opKind != TokenKind.NOTEQ) {
                    throw DataException('value_filter only supports == and != comparisons')
                }
                let isEq = opKind == TokenKind.EQUAL
                let r = quote(ValueFilterResult($(path), $(valueStr), $(if (isEq) { "true" } else { "false" })))
                (r, valueIdx)
            } else {
                if (opKind != TokenKind.EQUAL && opKind != TokenKind.NOTEQ) {
                    throw DataException('value() only supports == and != comparisons')
                }
                let r = quote(ValueCmpFilter($(path), $(valueStr), "false"))
                (r, valueIdx)
            }
            (result, nextIdx)
        }
        
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
                            validateIJSON(Int64.parse(sub[e + 1].value))
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
                            validateIJSON(Int64.parse(sub[e + 1].value))
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
                        case EQUAL where sub[e + 1].kind == LSQUARE =>
                            // Array literal comparison: @.items == [1, 2, 3]
                            let arrEnd = findMatchingRSQUARE(e + 1)
                            let arrContent = concatTokenValues(sub[e + 1 .. arrEnd + 1])
                            tokens += quote(StructEqFilter($(sub[i .. e].toString()), $(Token(STRING_LITERAL, arrContent)), 'false', 'true'))
                            i = arrEnd
                            break
                        case NOTEQ where sub[e + 1].kind == LSQUARE =>
                            let arrEnd = findMatchingRSQUARE(e + 1)
                            let arrContent = concatTokenValues(sub[e + 1 .. arrEnd + 1])
                            tokens += quote(StructEqFilter($(sub[i .. e].toString()), $(Token(STRING_LITERAL, arrContent)), 'false', 'false'))
                            i = arrEnd
                            break
                        case EQUAL where sub[e + 1].kind == LCURL =>
                            // Object literal comparison: @.obj == {"key": "val"}
                            let objEnd = findMatchingRCURL(e + 1)
                            let objContent = concatTokenValues(sub[e + 1 .. objEnd + 1])
                            tokens += quote(ObjectEqFilter($(sub[i .. e].toString()), $(Token(STRING_LITERAL, objContent)), 'false', 'true'))
                            i = objEnd
                            break
                        case NOTEQ where sub[e + 1].kind == LCURL =>
                            let objEnd = findMatchingRCURL(e + 1)
                            let objContent = concatTokenValues(sub[e + 1 .. objEnd + 1])
                            tokens += quote(ObjectEqFilter($(sub[i .. e].toString()), $(Token(STRING_LITERAL, objContent)), 'false', 'false'))
                            i = objEnd
                            break
                        case LT where sub[e + 1].kind == STRING_LITERAL || sub[e + 1].kind ==SINGLE_QUOTED_STRING_LITERAL =>
                            tokens += quote(CmpFilter<String>($(sub[i .. e].toString()), $(sub[e + 1].value), 'LT', 'false', 'false'))
                            i = e + 1
                            break
                        case LT where sub[e + 1].kind == INTEGER_LITERAL =>
                            validateIJSON(Int64.parse(sub[e + 1].value))
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
                            validateIJSON(Int64.parse(sub[e + 1].value))
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
                            validateIJSON(Int64.parse(sub[e + 1].value))
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
                            validateIJSON(Int64.parse(sub[e + 1].value))
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
                            validateIJSON(Int64.parse(sub[e + 1].value))
                            tokens += quote(SizeFilter($(sub[i .. e].toString()), $(sub[e + 1].value), 'false'))
                            i = e + 1
                            break
                        case DOT | IDENTIFIER | MUL => continue
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
                    if (t.value == 'search') {
                        let rp = findFuncRParen()
                        let args = splitArgsDepthAware(sub[i + 2 .. rp])
                        if (args.size < 2) { throw DataException('search() requires 2 arguments') }
                        let pathStr = concatTokenValues(args[0])
                        if (args[1].size > 0 && (args[1][0].kind == AT || args[1][0].kind == DOLLAR)) {
                            let regexPath = concatTokenValues(args[1])
                            tokens += quote(DeferredSearchFilter($(pathStr), $(regexPath), 'false'))
                        } else {
                            let rawRegex = concatTokenValues(args[1])
                            let regex = if (rawRegex.size >= 2 && (rawRegex[0] == 0x27u8 || rawRegex[0] == 0x22u8)) {
                                rawRegex[1..rawRegex.size - 1]
                            } else { rawRegex }
                            tokens += quote(SearchFilter($(pathStr), $(regex), 'false'))
                        }
                        i = rp
                    } else if (t.value == 'count') {
                        let rp = findFuncRParen()
                        let innerArgs = sub[i + 2 .. rp]
                        // Check if argument is a function call (starts with IDENTIFIER or MATCH keyword)
                        if (innerArgs.size > 0 && (innerArgs[0].kind == IDENTIFIER || innerArgs[0].kind == MATCH)) {
                            let filterIdx = compileSubFilter(innerArgs)
                            let idx = rp + 1
                            if (idx < sub.size) {
                                let cmpResult = emitCmpFilter(filterIdx, idx, 'count_filter')
                                tokens += cmpResult[0]
                                i = cmpResult[1]
                            } else {
                                tokens += quote(CountFilterResult($(filterIdx), '0', 'GT', 'false'))
                                i = rp
                            }
                        } else {
                            let path = extractOneArg(rp)
                            let idx = rp + 1
                            if (idx < sub.size) {
                                let cmpResult = emitCmpFilter(path, idx, 'count')
                                tokens += cmpResult[0]
                                i = cmpResult[1]
                            } else {
                                tokens += quote(CountCmpFilter($(path), '0', 'GT', 'false', 'false'))
                                i = rp
                            }
                        }
                    } else if (t.value == 'value') {
                        let rp = findFuncRParen()
                        let innerArgs = sub[i + 2 .. rp]
                        if (innerArgs.size > 0 && (innerArgs[0].kind == IDENTIFIER || innerArgs[0].kind == MATCH)) {
                            let filterIdx = compileSubFilter(innerArgs)
                            let idx = rp + 1
                            if (idx < sub.size) {
                                let cmpResult = emitCmpFilter(filterIdx, idx, 'value_filter')
                                tokens += cmpResult[0]
                                i = cmpResult[1]
                            } else {
                                tokens += quote(ValueFilterResult($(filterIdx), 'true', 'false'))
                                i = rp
                            }
                        } else {
                            let path = extractOneArg(rp)
                            let idx = rp + 1
                            if (idx < sub.size) {
                                let cmpResult = emitCmpFilter(path, idx, 'value')
                                tokens += cmpResult[0]
                                i = cmpResult[1]
                            } else {
                                tokens += quote(ValueCmpFilter($(path), 'true', 'false'))
                                i = rp
                            }
                        }
                    } else if (t.value == 'length') {
                        let rp = findFuncRParen()
                        let path = extractOneArg(rp)
                        let idx = rp + 1
                        if (idx < sub.size) {
                            let cmpResult = emitCmpFilter(path, idx, 'length')
                            tokens += cmpResult[0]
                            i = cmpResult[1]
                        } else {
                            tokens += quote(LengthCmpFilter($(path), '0', 'GT', 'false', 'false'))
                            i = rp
                        }
                    } else {
                        throw DataException('filter in data path ${sub} is illegal')
                    }
                case MATCH =>
                    let rp = findFuncRParen()
                    let args = splitArgsDepthAware(sub[i + 2 .. rp])
                    if (args.size < 2) { throw DataException('match() requires 2 arguments') }
                    let pathStr = concatTokenValues(args[0])
                    // Detect if second argument is a path expression (starts with @/$)
                    if (args[1].size > 0 && (args[1][0].kind == AT || args[1][0].kind == DOLLAR)) {
                        let regexPath = concatTokenValues(args[1])
                        tokens += quote(DeferredMatchFilter($(pathStr), $(regexPath), 'false'))
                    } else {
                        let rawRegex = concatTokenValues(args[1])
                        let regex = if (rawRegex.size >= 2 && (rawRegex[0] == 0x27u8 || rawRegex[0] == 0x22u8)) {
                            rawRegex[1..rawRegex.size - 1]
                        } else { rawRegex }
                        tokens += quote(MatchFilter($(pathStr), $(regex), 'false'))
                    }
                    i = rp
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
            case IDENTIFIER where sub[arrs + 1].value == 'null' =>
                // null element: scan for first non-null element to infer type, default to String
                var inferredType = "String"
                for (scanIdx in arrs + 2..arre) {
                    if (sub[scanIdx].kind == INTEGER_LITERAL) { inferredType = "Int64"; break }
                    else if (sub[scanIdx].kind == FLOAT_LITERAL) { inferredType = "Float64"; break }
                    else if (sub[scanIdx].kind == STRING_LITERAL || sub[scanIdx].kind == SINGLE_QUOTED_STRING_LITERAL) { inferredType = "String"; break }
                }
                match (inferredType) {
                    case "Int64" => quote($(filter)<Int64>($(sub[i .. e].toString()), $(sub[arrs + 1 .. arre].toString()), 'false'))
                    case "Float64" => quote($(filter)<Float64>($(sub[i .. e].toString()), $(sub[arrs + 1 .. arre].toString()), 'false'))
                    case _ => quote($(filter)<String>($(sub[i .. e].toString()), $(sub[arrs + 1 .. arre].toString()), 'false'))
                }
            case _ => throw DataException('illegal array element type in data path filter ${sub} for in expression')
        }
        (tokens, arre)
    }
    private func compileFilter(sub: Tokens, solid: Bool) {
        subFilters.clear()
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
                let args = tokens[if (filter == 'RegexFilter' || filter == 'SizeFilter' || filter == 'ExistsFilter' || filter == 'NullFilter' || filter == 'MatchFilter' || filter == 'SearchFilter' || filter == 'CountCmpFilter' || filter == 'ValueCmpFilter' || filter == 'LengthCmpFilter' || filter == 'StructEqFilter' || filter == 'ObjectEqFilter' || filter == 'DeferredMatchFilter' || filter == 'DeferredSearchFilter' || filter == 'ValueFilterResult' || filter == 'CountFilterResult') {
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
                    case ('CountCmpFilter', _) => CountCmpFilter(arg(args, 0), arg(args, 1), arg(args, 2), arg(args, 3), arg(args, 4))
                    case ('ValueCmpFilter', _) => ValueCmpFilter(arg(args, 0), arg(args, 1), arg(args, 2))
                    case ('LengthCmpFilter', _) => LengthCmpFilter(arg(args, 0), arg(args, 1), arg(args, 2), arg(args, 3), arg(args, 4))
                    case ('StructEqFilter', _) => StructEqFilter(arg(args, 0), arg(args, 1), arg(args, 2), arg(args, 3))
                    case ('ObjectEqFilter', _) => ObjectEqFilter(arg(args, 0), arg(args, 1), arg(args, 2), arg(args, 3))
                    case ('DeferredMatchFilter', _) => DeferredMatchFilter(arg(args, 0), arg(args, 1), arg(args, 2))
                    case ('DeferredSearchFilter', _) => DeferredSearchFilter(arg(args, 0), arg(args, 1), arg(args, 2))
                    case ('CountFilterResult', _) =>
                        let idx = Int64.parse(arg(args, 0))
                        CountFilterResult(subFilters[idx], Int64.parse(arg(args, 1)), arg(args, 2), arg(args, 3))
                    case ('ValueFilterResult', _) =>
                        let idx = Int64.parse(arg(args, 0))
                        ValueFilterResult(subFilters[idx], arg(args, 1), arg(args, 2))
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
