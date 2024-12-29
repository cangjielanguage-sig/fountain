/*
    Copyright (c) [2022] [WuJingrun（吴京润）]
    fountain is licensed under Mulan PSL v2.
    You can use this software according to the terms and conditions of the Mulan PSL v2.
    You may obtain a copy of Mulan PSL v2 at:
            http://license.coscl.org.cn/MulanPSL2
    THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
    See the Mulan PSL v2 for more details.  
*/
package f_data.path

import std.ast.{cangjieLex, Tokens, Token, TokenKind}
import std.collection.{ArrayList, LinkedList, HashSet}
import std.collection.concurrent.ConcurrentHashMap
import std.convert.Parsable
import std.reflect.*
import f_cache.HeapCache
import f_base.*
import f_macros.*
import f_data.exception.DataException
public import f_data.*

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
public class DataPath <: DataPathNode {
    private static let solid = ConcurrentHashMap<String, DataPath>()
    private static let cache = HeapCache<DataPath>(maxLife: Duration.day, maxSize: 10000)

    private let nodes = ArrayList<DataPathNode>()

    private init(){}
    public static func compile(path: String, solid!: Bool = false): DataPath {
        if(solid){
            doSolidCompile(path)
        }else{
            doCacheCompile(path)
        }
    }
    private static func doSolidCompile(path: String): DataPath {
        if(let Some(p) <- solid.get(path)){
            p
        }else{
            let p = doCompile(path, true)
            solid[path] = p
            p
        }
    }
    private static func doCacheCompile(path: String): DataPath {
        cache.getOrCompute(path){doCompile(path, false)}
    }
    private static func doCompile(path: String, solid: Bool): DataPath {
        if(!(path.startsWith('$.') || path.startsWith('$['))){
            throw DataException('data path must be starts with "$." or "$[", but it is ${path}')
        }
        doCompile(cangjieLex(path, true), solid)
    }
    private static func extractSubPathInSquares(path: Tokens, index: Int64): (Tokens, Int64) {
        var result = quote()
        let stack = LinkedList<Unit>()
        var end = -1
        for(i in index .. path.size){
            let t = path[i]
            match(t.kind){
                case LSQUARE => stack.append(())
                case RSQUARE => 
                    stack.popLast()
                    if(stack.isEmpty()){
                        end = i
                        break
                    }
                case _ => continue
            }
        }
        if(end < 0){
            throw DataException('squares are not match after ${index} in data path ${path}')
        }
        (path[index + 1 .. end], end)
    }
    private static func compileSubInSquares(sub: Tokens){
        match(sub[0].kind){
            case STRING_LITERAL | IDENTIFIER => SubPathNode(sub[0].value)
            case _ => throw DataException('sub expression in squares can only be string literal or identifier')
        }
    }
    private static func compileIndexInSquares(sub: Tokens){
        let idx = Int64.parse(sub[0].value)
        if(idx < 0){
            throw DataException('sub expression as an index must greater than or equals to zero')
        }
        IndexPathNode(idx)
    }
    private static func compileSubsInSquares(sub: Tokens){
        let names = ArrayList<String>()
        for(t in sub){
            let n =
            match(t.kind){
                case STRING_LITERAL | IDENTIFIER => t.value
                case COMMA => continue
                case _ => throw DataException('sub expression in squares as multi-names can only be string literal, identifier and comma, but current are ${sub}')
            }
            names.append(n)
        }
        MultiSubPathNode(names.toArray())
    }
    private static func compileIndexesInSquares(sub: Tokens): DataPathNode {
        let list = ArrayList<Int64>()
        var range = 0
        var comma = 0
        for(i in 0 .. sub.size){
            let t = sub[i]
            match(t.kind){
                case INT64 => 
                    let idx = Int64.parse(t.value)
                    if(idx < 0){
                        throw DataException('sub expression as an index must greater than or equals to zero')
                    }
                    list.append(idx)
                case COLON => 
                    range++
                    if(range > 2){
                        throw DataException('sub expression in squares as a int range must be int1:int2:int3 or int1:int2')
                    }else if(comma > 0){
                        throw DataException('sub expression in squares cannot be with comma and colon at the same time')
                    }
                case COMMA => 
                    comma++
                    if(range > 0){
                        throw DataException('sub expression in squares cannot be with comma and colon at the same time')
                    }
                case _ => throw DataException('sub expression in squares must be all strings or int64 or int1:int2:int3 or int1:int2')
            }
        }
        match(range){
            case 0 => MultiIndexPathNode(list.toArray())
            case 1 => 
                if(list[0] >= list[1]){
                    throw DataException('sub expression as an int range, range start must be greater than end')
                }
                RangePathNode(list[0] .. list[1])
            case 2 => 
                if(list[0] >= list[1] || list[2] <= 0){
                    throw DataException('sub expression as an int range, range start must be greater than end and step must be greater than zero')
                }
                RangePathNode(list[0] .. list[1]: list[2])
            case _ => throw UnreachableException()
        }
    }
    private static func parseFilterTokens(sub: Tokens, solid: Bool): Tokens {
        var tokens = quote()
        var i = 0
        while(i < sub.size) {
            let t = sub[i]
            match(t.kind){
                case LPAREN => 
                    let stack = LinkedList<Unit>()
                    var end = -1
                    for(e in i .. sub.size){
                        match(sub[e].kind){
                            case LPAREN => stack.append(())
                            case RPAREN => 
                                stack.popLast()
                                if(stack.isEmpty()){
                                    end = e
                                    break
                                }
                            case _ => continue
                        }
                    }
                    if(end <= i){
                        throw DataException('illegal filter expression for data path, ${sub}')
                    }
                    tokens += `lparen` + parseFilterTokens(sub[i .. end], solid) + `rparen`
                case AT => 
                    for(e in i .. sub.size){
                        let t = sub[e]
                        match(t.kind){
                            case EQUAL where sub[e + 1].kind == STRING_LITERAL => 
                                tokens += quote(EqFilter<String>($(sub[i .. e].toString()), $(sub[e + 1].value), $(solid.toString())))
                                i = e + 1
                                break
                            case EQUAL where sub[e + 1].kind == INT64 =>
                                tokens += quote(EqFilter<Int64>($(sub[i .. e].toString()), $(sub[e + 1].value), $(solid.toString())))
                                i = e + 1
                                break
                            case EQUAL where sub[e + 1].kind == FLOAT64 =>
                                tokens += quote(EqFilter<Float64>($(sub[i .. e].toString()), $(sub[e + 1].value), $(solid.toString())))
                                i = e + 1
                                break
                            case EQUAL where sub[e + 1].kind == BOOL_LITERAL =>
                                tokens += quote(EqFilter<Bool>($(sub[i .. e].toString()), $(sub[e + 1].value), $(solid.toString())))
                                i = e + 1
                                break
                            case NOTEQ where sub[e + 1].kind == STRING_LITERAL =>
                                tokens += quote(NotEqFilter<String>($(sub[i .. e].toString()), $(sub[e + 1].value), $(solid.toString())))
                                i = e + 1
                                break
                            case NOTEQ where sub[e + 1].kind == INT64 =>
                                tokens += quote(NotEqFilter<Int64>($(sub[i .. e].toString()), $(sub[e + 1].value), $(solid.toString())))
                                i = e + 1
                                break
                            case NOTEQ where sub[e + 1].kind == FLOAT64 =>
                                tokens += quote(NotEqFilter<Float64>($(sub[i .. e].toString()), $(sub[e + 1].value), $(solid.toString())))
                                i = e + 1
                                break
                            case NOTEQ where sub[e + 1].kind == BOOL_LITERAL =>
                                tokens += quote(NotEqFilter<Bool>($(sub[i .. e].toString()), $(sub[e + 1].value), $(solid.toString())))
                                i = e + 1
                                break
                            case LT where sub[e + 1].kind == STRING_LITERAL =>
                                tokens += quote(CmpFilter<String>($(sub[i .. e].toString()), $(sub[e + 1].value), 'LT', 'false', $(solid.toString())))
                                i = e + 1
                                break
                            case LT where sub[e + 1].kind == INT64 =>
                                tokens += quote(CmpFilter<Int64>($(sub[i .. e].toString()), $(sub[e + 1].value), 'LT', 'false', $(solid.toString())))
                                i = e + 1
                                break
                            case LT where sub[e + 1].kind == FLOAT64 =>
                                tokens += quote(CmpFilter<Float64>($(sub[i .. e].toString()), $(sub[e + 1].value), 'LT', 'false', $(solid.toString())))
                                i = e + 1
                                break
                            case GT where sub[e + 1].kind == STRING_LITERAL =>
                                tokens += quote(CmpFilter<String>($(sub[i .. e].toString()), $(sub[e + 1].value), 'GT', 'false', $(solid.toString())))
                                i = e + 1
                                break
                            case GT where sub[e + 1].kind == INT64 =>
                                tokens += quote(CmpFilter<Int64>($(sub[i .. e].toString()), $(sub[e + 1].value), 'GT', 'false', $(solid.toString())))
                                i = e + 1
                                break
                            case GT where sub[e + 1].kind == FLOAT64 =>
                                tokens += quote(CmpFilter<Float64>($(sub[i .. e].toString()), $(sub[e + 1].value), 'GT', 'false', $(solid.toString())))
                                i = e + 1
                                break
                            case LE where sub[e + 1].kind == STRING_LITERAL =>
                                tokens += quote(CmpFilter<String>($(sub[i .. e].toString()), $(sub[e + 1].value), 'LT', 'false', $(solid.toString())))
                                i = e + 1
                                break
                            case LE where sub[e + 1].kind == INT64 =>
                                tokens += quote(CmpFilter<Int64>($(sub[i .. e].toString()), $(sub[e + 1].value), 'LT', 'false', $(solid.toString())))
                                i = e + 1
                                break
                            case LE where sub[e + 1].kind == FLOAT64 =>
                                tokens += quote(CmpFilter<Float64>($(sub[i .. e].toString()), $(sub[e + 1].value), 'LT', 'false', $(solid.toString())))
                                i = e + 1
                                break
                            case GE where sub[e + 1].kind == STRING_LITERAL =>
                                tokens += quote(CmpFilter<String>($(sub[i .. e].toString()), $(sub[e + 1].value), 'GT', 'false', $(solid.toString())))
                                i = e + 1
                                break
                            case GE where sub[e + 1].kind == INT64 =>
                                tokens += quote(CmpFilter<Int64>($(sub[i .. e].toString()), $(sub[e + 1].value), 'GT', 'false', $(solid.toString())))
                                i = e + 1
                                break
                            case GE where sub[e + 1].kind == FLOAT64 =>
                                tokens += quote(CmpFilter<Float64>($(sub[i .. e].toString()), $(sub[e + 1].value), 'GT', 'false', $(solid.toString())))
                                i = e + 1
                                break
                            case ASSIGN where sub[e + 1].kind == BITNOT && sub[e + 2].kind == DIV => 
                                let rs = e + 2
                                var re = rs + 1
                                for(e in re .. sub.size where sub[e].kind == DIV){
                                    re = e
                                    break
                                }
                                if(rs + 1 == re || sub[re].kind != DIV){
                                    throw DataException('illegal regex in data path filter ${sub}')
                                }
                                if(sub[re + 1].kind == IDENTIFIER && sub[re + 1].value == 'i'){
                                    re++
                                }
                                tokens += quote(RegexFilter($(sub[i .. e].toString()), $(sub[rs ..= re].toString()), $(solid.toString())))
                                i = re
                                break
                            case IN where sub[e + 1].kind == LSQUARE => 
                                let (t, e) = parseSetOp(sub, i, e, quote(InFilter), solid)
                                tokens += t
                                i = e
                            case IDENTIFIER where t.value == 'nin' && sub[e + 1].kind == LSQUARE =>
                                let (t, e) = parseSetOp(sub, i, e, quote(NinFilter), solid)
                                tokens += t
                                i = e
                            case IDENTIFIER where t.value == 'anyof' && sub[e + 1].kind == LSQUARE =>
                                let (t, e) = parseSetOp(sub, i, e, quote(AnyOfFilter), solid)
                                tokens += t
                                i = e
                            case IDENTIFIER where t.value == 'subsetof' && sub[e + 1].kind == LSQUARE =>
                                let (t, e) = parseSetOp(sub, i, e, quote(SubSetOfFilter), solid)
                                tokens += t
                                i = e
                            case IDENTIFIER where t.value == 'nooneof' && sub[e + 1].kind == LSQUARE =>
                                let (t, e) = parseSetOp(sub, i, e, quote(NoOneOfFilter), solid)
                                tokens += t
                                i = e
                            case IDENTIFIER where t.value == 'size' && sub[e + 1].kind == INT64 =>
                                tokens += quote(SizeFilter($(sub[i .. e].toString()), $(sub[e + 1].value), $(solid.toString())))
                                i = e + 1
                                break
                            case _ => throw DataException('filter in data path ${sub} is illegal')
                        }
                    }
                case BITAND where i> 0 => tokens += `bitand`
                case BITOR where i> 0 => tokens += `bitor`
                case _ => throw DataException('filter in data path ${sub} is illegal')
            }
            i++
        }
        tokens
    }
    private static func parseSetOp(sub: Tokens, i: Int64, e: Int64, filter: Tokens, solid: Bool): (Tokens, Int64) {
        let arrs = e + 1
        var arre = arrs + 1
        for(e in arre .. sub.size where sub[e].kind == RSQUARE){
            arre = e
            break
        }
        if(arrs + 1 == arre || sub[arre].kind == RSQUARE){
            throw DataException('illegal array in data path filter ${sub} for in expression')
        }
        let tokens =
        match(sub[arrs + 1].kind){
            case STRING_LITERAL => quote($(filter)<String>($(sub[i .. e].toString()), $(sub[arrs ..= arre].toString()), $(solid.toString())))
            case INT64 => quote($(filter)<Int64>($(sub[i .. e].toString()), $(sub[arrs ..= arre].toString()), $(solid.toString())))
            case FLOAT64 => quote($(filter)<Float64>($(sub[i .. e].toString()), $(sub[arrs ..= arre].toString()), $(solid.toString())))
            case _ => throw DataException('illegal array element type in data path filter ${sub} for in expression')
        }
        (tokens, arre)
    }
    private static func compileFilter(sub: Tokens,  solid: Bool){
        let tokens = parseFilterTokens(sub, solid)
        let expr = parseExpr(tokens)
        DataFilterPathNode(compileFilter(expr))
    }
    private static func compileFilter(expr: Expr): DataFilter {
        //EqFilter<> NotEqFilter<> CmpFilter<> RegexFilter 
        //InFilter<> NinFilter<> AnyOfFilter<> SubSetOfFilter<> NoOneOfFilter<>
        //SizeFilter
        //CallExpr ParenExpr BinaryExpr UnaryExpr
        func arg(args: Tokens, index: Int64){
            args[index].value
        }
        match(expr){
            case x: CallExpr => 
                let tokens = x.toTokens()
                let filter = tokens[0].value
                let generic = tokens[2].value
                let args = tokens[if(filter == 'RegexFilter' || filter == 'SizeFilter'){2}else{5} .. tokens.size - 1]
                match((filter, generic)){
                    case ('EqFilter', 'String') => EqFilter<String>(arg(args, 0), arg(args, 1), arg(args, 2))
                    case ('EqFilter', 'Int64') => EqFilter<Int64>(arg(args, 0), arg(args, 1), arg(args, 2))
                    case ('EqFilter', 'Float64') => EqFilter<Float64>(arg(args, 0), arg(args, 1), arg(args, 2))
                    case ('EqFilter', 'Bool') => EqFilter<Bool>(arg(args, 0), arg(args, 1), arg(args, 2))
                    case ('NotEqFilter', 'String') => NotEqFilter<String>(arg(args, 0), arg(args, 1), arg(args, 2))
                    case ('NotEqFilter', 'Int64') => NotEqFilter<Int64>(arg(args, 0), arg(args, 1), arg(args, 2))
                    case ('NotEqFilter', 'Float64') => NotEqFilter<Float64>(arg(args, 0), arg(args, 1), arg(args, 2))
                    case ('NotEqFilter', 'Bool') => NotEqFilter<Bool>(arg(args, 0), arg(args, 1), arg(args, 2))
                    case ('CmpFilter', 'String') => CmpFilter<String>(arg(args, 0), arg(args, 1), arg(args, 2), arg(args, 3), arg(args, 4))
                    case ('CmpFilter', 'Int64') => CmpFilter<Int64>(arg(args, 0), arg(args, 1), arg(args, 2), arg(args, 3), arg(args, 4))
                    case ('CmpFilter', 'Float64') => CmpFilter<Float64>(arg(args, 0), arg(args, 1), arg(args, 2), arg(args, 3), arg(args, 4))
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
                    case ('SubSetOfFilter', 'Float64') => SubSetOfFilter<Float64>(arg(args, 0), arg(args, 1), arg(args, 2))
                    case ('NoOneOfFilter', 'String') => NoOneOfFilter<String>(arg(args, 0), arg(args, 1), arg(args, 2))
                    case ('NoOneOfFilter', 'Int64') => NoOneOfFilter<Int64>(arg(args, 0), arg(args, 1), arg(args, 2))
                    case ('NoOneOfFilter', 'Float64') => NoOneOfFilter<Float64>(arg(args, 0), arg(args, 1), arg(args, 2))
                    case ('SizeFilter', _) => SizeFilter(arg(args, 0), arg(args, 1), arg(args, 2))
                    case _ => throw DataException('unreachable ${tokens}')
                }
            case x: ParenExpr => compileFilter(x.parenthesizedExpr)
            case x: UnaryExpr where x.op.kind == NOT => 
                !compileFilter(x.expr)
            case x: BinaryExpr where x.op.kind == BITAND => 
                compileFilter(x.leftExpr) & compileFilter(x.rightExpr)
            case x: BinaryExpr where x.op.kind == BITOR => 
                compileFilter(x.leftExpr) | compileFilter(x.rightExpr)
            case _ => throw DataException('unreachable ${expr.toTokens()}')
        }
    }
    private static func compileInSquares(sub: Tokens, dp: DataPath, solid: Bool) {
        if(sub.size == 1 && sub[0].kind == STRING_LITERAL){
            compileSubInSquares(sub)
        }else if(sub.size == 1 && sub[0].kind == INT64){
            compileIndexInSquares(sub)
        }else if(sub.size > 1 && sub[0].kind == STRING_LITERAL){
            compileSubsInSquares(sub)
        }else if(sub.size > 1 && sub[0].kind == INT64){
            compileIndexesInSquares(sub)
        }else if(sub.size > 1 && sub[0].kind == QUEST && sub[1].kind == LPAREN && sub[sub.size - 1].kind == RPAREN){
            compileFilter(sub[2 .. sub.size - 1], solid)
        }else{
            throw DataException('sub path ${sub} is illegal')
        }
    }
    private static func doCompile(path: Tokens, solid: Bool): DataPath {
        let dp = DataPath()
        var i = 0
        while(i < path.size){
            let node = 
            if (i == 0 && path[i].kind == DOLLAR) {
                RootPathNode.instance
            } else if(path[i].kind == DOT && path[i + 1].kind == IDENTIFIER) {
                i++
                SubPathNode(path[i].value)
            } else if(path[i].kind == DOT && path[i + 1].kind == DOT) {
                RecursiveDescentPathNode.instance
            } else if(path[i].kind == DOT && path[i + 1].kind == LSQUARE && path[i - 1].kind == DOT) {
                let (sub, index) = extractSubPathInSquares(path, i + 1)
                i = index
                compileInSquares(sub, dp, solid)
            } else if(path[i].kind == LSQUARE && (path[i - 1].kind == IDENTIFIER || path[i - 1].kind == DOLLAR || path[i - 1].kind == AT || path[i - 1].kind == RSQUARE)) {
                let (subPath, index) = extractSubPathInSquares(path, i)
                i = index
                compileInSquares(sub, dp, solid)
            } else if (i == 0 && path[i].kind == AT) {
                CurrentPathNode.instance
            } else if (path[i].kind == DOT && path[i + 1].kind == IDENTIFIER && path[i + 2].kind == LPAREN && path[i + 3].kind == RPAREN) {
                let node: DataPathNode =
                match(path[i + 1].value){
                    case 'min' => MinPathNode.instance
                    case 'max' => MaxPathNode.instance
                    case 'avg' => AvgPathNode.instance
                    case 'length' => LengthPathNode.instance
                    case _ => throw DataException('data path is illegal at index ${i}, path: ${path}, unsupported function call')
                }
                i += 3
                node
            } else {
                throw DataException('data path is illegal at index ${i}, path: ${path}')
            }
            dp.nodes.append(node)
            i++
        }
        dp
    }
    public func get(data: Data): Iterator<Data> {
        var itr: Iterator<Data> = nodes[0].get(data)
        for(i in 1 .. nodes.size){
            itr = itr.flatMap<Data>{d => nodes[i].get(d)}
        }
        itr
    }
}
private interface DataPathNode {
    func get(data: Data): Iterator<Data>
}
private class RootPathNode <: DataPathNode {
    private init(){}
    static let instance = RootPathNode()
    public func get(data: Data): Iterator<Data> {
        SingleIterable<Data>(data).iterator()
    }
}
private class CurrentPathNode <: DataPathNode {
    static let instance = CurrentPathNode()
    private init(){}
    public func get(data: Data): Iterator<Data> {
        SingleIterable<Data>(data).iterator()
    }
}
private class SubPathNode <: DataPathNode {
    SubPathNode(private let name: String){}
    public func get(data: Data): Iterator<Data> {
        match(data){
            case x: StringKeyMapTuples => OptionIterator<Data>(x.get(name))
            case _ => 
                let info = TypeInfo.of(data)
                if(info.qualifiedName.startsWith('f_data.DataObject') && 
                   let Some(fn) <- TypeMemberInfos.instanceFunction(info, 'getData', [TypeInfos.get<String>()]) && 
                   let d: ?Data <- fn.apply(data, [name])){
                    OptionIterator<Data>(d)
                }else{
                    OptionIterator<Data>.NONE
                }
        }
    }
}
private class IndexPathNode <: DataPathNode {
    IndexPathNode(private let index: Int64){}
    public func get(data: Data): Iterator<Data> {
        match(data){
            case x: DataSequence => OptionIterator<Data>(x.get(index))
            case _ => OptionIterator<Data>.NONE
        }
    }
}
private class MultiSubPathNode <: DataPathNode {
    MultiSubPathNode(private let names: Array<String>){}
    public func get(data: Data): Iterator<Data> {
        names.iterator().map{n => SubPathNode(n)}.flatMap{n => n.get(data).iterator()}
    }
}
private class MultiIndexPathNode <: DataPathNode {
    MultiIndexPathNode(private let indexes: Array<Int64>){}
    public func get(data: Data): Iterator<Data> {
        indexes.iterator().map{i => IndexPathNode(i)}.flatMap{n => n.get(data).iterator()}
    }
}
private class RangePathNode <: DataPathNode {
    RangePathNode(private let range: Range<Int64>){}
    public func get(data: Data): Iterator<Data>{
        range.iterator().map{i => IndexPathNode(i)}.flatMap{n => n.get(data).iterator()}
    }
}
private class AnySubPathNode <: DataPathNode {
    init(){}
    public func get(data: Data): Iterator<Data> {
        match(data){
            case x: StringKeyMapTuples => x.iterator().map{tpl => tpl.value}
            case x: DataSequence => x.iterator()
            case _ => 
                let info = TypeInfo.of(data)
                if(info.qualifiedName.startsWith('f_data.DataObject') && 
                   let Some(fn) <- TypeMemberInfos.instanceFunction(info, 'iterator') && 
                   let tuples: Iterator<(String, Data)> <- fn.apply(data)){
                    tuples.map{f => f[1]}
                }else{
                    SingleIterator<Data>(data)
                }
        }
    }
}
private class RecursiveDescentPathNode <: DataPathNode{
    static let instance = RecursiveDescentPathNode()
    private init(){}
    public func get(data: Data): Iterator<Data> {
        RecursiveDescentIterator(data)
    }
}
private class RecursiveDescentIterator <: Iterator<Data> {
    private let list = LinkedList<Iterator<Data>>()
    private var itr: Iterator<Data> = EmptyIterator<Data>.INSTANCE
    init(data: Data){
        append(data)
    }
    private func append(data: Data){
        list.append(AnySubPathNode().get(data))
    }
    public func next(): ?Data {
        if(let Some(x) <- itr.next()){
            if(!(itr is SingleIterable<Data>)){
                append(x)
            }
            x
        }else if(let Some(i) <- list.popFirst()){
            itr = i.iterator()
            next()
        }else{
            None
        }
    }
}
private class MinPathNode <: DataPathNode {
    static let instance = MinPathNode()
    private init(){}
    public func get(data: Data): Iterator<Data> {
        match(data){
            case x: DataSequence => 
                var r = None<Data>
                for(v in x){
                    if(r.isNone()){
                        r = v
                        continue
                    }
                    r = 
                    match((v, r)){
                        case (x: DataDateTime, y: DataDateTime) where x < y => x
                        case (x: DataDuration, y: DataDuration) where x < y => x
                        case (x: DataReal, y: DataReal) where x < y => x
                        case (x: DataString, y: DataString) where x < y => x
                        case _ => continue
                    }
                }
                OptionIterator<Data>(r)
            case _ => OptionIterator<Data>.NONE                
        }
    }
}
private class MaxPathNode <: DataPathNode {
    static let instance = MaxPathNode()
    private init(){}
    public func get(data: Data): Iterator<Data> {
        match(data){
            case x: DataSequence => 
                var r = None<Data>
                for(v in x){
                    if(r.isNone()){
                        r = v
                        continue
                    }
                    r = 
                    match((v, r)){
                        case (x: DataDateTime, y: DataDateTime) where x > y => x
                        case (x: DataDuration, y: DataDuration) where x > y => x
                        case (x: DataReal, y: DataReal) where x > y => x
                        case (x: DataString, y: DataString) where x > y => x
                        case _ => return OptionIterator<Data>.NONE
                    }
                }
                OptionIterator<Data>(r)
            case _ => OptionIterator<Data>.NONE
        }
    }
}
private class AvgPathNode <: DataPathNode {
    static let instance = AvgPathNode()
    private init(){}
    public func get(data: Data): Iterator<Data> {
        match(data){
            case x: DataSequence => 
                var r = Decimal.ZERO
                var c = 0
                for(v in x){
                    match(v){
                        case x: DataReal => 
                            c++
                            r += x.data
                        case _ => return OptionIterator<Data>.NONE
                    }
                }
                OptionIterator<Data>((r/Decimal(BigInt(c))).toData())
            case _ => OptionIterator<Data>.NONE                
        }
    }
}
private class LengthPathNode <: DataPathNode {
    static let instance = LengthPathNode()
    private init(){}
    public func get(data: Data): Iterator<Data>{
        match(data){
            case x: DataSequence => SingleIterator<Data>(x.size.toData())
            case x: StringKeyMapTuples => SingleIterator<Data>(x.size.toData())
            case x: DataString => SingleIterator<Data>(x.data.size.toData())
            case _ => OptionIterator<Data>.NONE
        }
    }
}
private class DataFilterPathNode <: DataPathNode{
    DataFilterPathNode(private let filter: DataFilter){}
    public func get(data: Data): Iterator<Data>{
        SingleIterator<Data>(data).filter{d => filter.check(d)}
    }
}
private interface DataFilter {
    func check(data: Data): Bool

    operator func &(right: DataFilter): DataFilter {
        AndFilter(this, right)
    }
    operator func |(right: DataFilter): DataFilter {
        OrFilter(this, right)
    }
    operator func !(): DataFilter {
        NotFilter(this)
    }
    static func parse<T>(value: String): T {
        let t = TypeInfos.get<T>()
        let any: Any = 
        if(t == TypeInfos.get<String>()){
            value
        }else if(t == TypeInfos.get<Int64>()){
            Int64.parse(value)
        }else if(t == TypeInfos.get<Float64>()){
            Float64.parse(value)
        }else if(t == TypeInfos.get<Bool>()){
            Bool.parse(value)
        }else {
            throw DataException('unsupported for comparing type ${t}')
        }
        (any as T).getOrThrow()
    }
    static func parseArrayList<T>(value: String): ArrayList<T> {
        let list = ArrayList<T>()
        for(t in cangjieLex(value, true)){
            match(t.kind){
                case COMMA => continue
                case STRING_LITERAL | INT64 | FLOAT64 | BOOL_LITERAL => list.append(parse<T>(t.value))
                case _ => throw DataException('illegal token for set filter ${value}')
            }
        }
        list
    }
    static func parseHashSet<T>(value: String): HashSet<T> where T <: Hashable & Equatable<T> {
        let set = HashSet<T>()
        for(t in cangjieLex(value, true)){
            match(t.kind){
                case COMMA => continue
                case STRING_LITERAL | INT64 | FLOAT64 | BOOL_LITERAL => set.put(parse<T>(t.value))
                case _ => throw DataException('illegal token for set filter ${value}')
            }
        }
        set
    }
}

private class CmpFilter<T> <: DataFilter where T <: Comparable<T> {
    CmpFilter(private let left: DataPath, private let right: T, private let ordering: Ordering, private let eq: Bool){}
    init(left: String, right: String, orderingStr: String, eqStr: String, solid: String){
        this(DataPath.compile(left, solid: Bool.parse(solid)), parse<T>(right), match(orderingStr){
            case 'LT' => LT
            case 'GT' => GT
            case 'EQ' => EQ
            case _ => throw DataException('illegal Ordering string')
        }, Bool.parse(eqStr))
    }

    public func check(data: Data): Bool {
        let d = match(left.get(data).next()){
            case Some(x) => x
            case _ => return false
        }
        match(d){
            case x: DataDateTime => match(x.data){
                case x: T => 
                    let cmp = x.compare(right)
                    cmp == ordering || (eq && cmp == EQ)
                case _ => false
            }
            case x: DataDuration => match(x.data){
                case x: T => 
                    let cmp = x.compare(right)
                    cmp == ordering || (eq && cmp == EQ)
                case _ => false
            }
            case x: DataReal => match(x.data){
                case x: T => 
                    let cmp = x.compare(right)
                    cmp == ordering || (eq && cmp == EQ)
                case _ => false
            }
            case x: DataString => match(x.data){
                case x: T => 
                    let cmp = x.compare(right)
                    cmp == ordering || (eq && cmp == EQ)
                case _ => false
            }
            case _ => false
        }
    }
}
private class EqFilter<T> <: DataFilter where T <: Equatable<T> {
    EqFilter(private let left: DataPath, private let right: T){}
    init(left: String, right: String, solid: String){
        this(DataPath.compile(left, solid: Bool.parse(solid)), parse<T>(right))
    }
    public func check(data: Data): Bool {
        let d = match(left.get(data).next()){
            case Some(x) => x
            case _ => return false
        }
        match(d){
            case x: DataDateTime => match(x.data){
                case x: T => x == right
                case _ => false
            }
            case x: DataDuration => match(x.data){
                case x: T => x == right
                case _ => false
            }
            case x: DataReal => match(x.data){
                case x: T => x == right
                case _ => false
            }
            case x: DataString => match(x.data){
                case x: T => x == right
                case _ => false
            }
            case x: DataBool => match(x.data){
                case x: T => x == right
                case _ => false
            }
            case _ => false
        }
    }
}
private class NotEqFilter<T> <: DataFilter where T <: Equatable<T> {
    private let eqFilter: EqFilter<T>
    init(left: DataPath, right: T){
        eqFilter = EqFilter<T>(left, right)
    }
    init(left: String, right: String, solid: String){
        this(DataPath.compile(left, solid: Bool.parse(solid)), parse<T>(right))
    }
    public func check(data: Data): Bool {
        !eqFilter.check(data)
    }
}
private class RegexFilter <: DataFilter {
    private let regex: Regex
    private let left: DataPath
    init(left: DataPath, regex: String){
        this.left = left
        this.regex = parseRegex(regex)
    }
    init(left: String, regex: String, solid: String){
        this(DataPath.compile(left, solid: Bool.parse(solid)), regex)
    }
    private static func parseRegex(regex: String){
        if(!regex.startsWith('/')){
            throw DataException('illegal regex ${regex}, regex must be format as /<REGEX>/ or /<REGEX>/i')
        }
        if(regex.endsWith('/')){
            regex[1 .. regex.size - 1].regex()
        }else if(regex.endsWith('/i')){
            regex[1 .. regex.size - 1].regex(option: RegexOption().ignoreCase())
        }else{
            throw DataException('illegal regex ${regex}, regex must be format as /<REGEX>/ or /<REGEX>/i')
        }
    }
    public func check(data: Data){
        let d = match(left.get(data).next()){
            case Some(x) => x
            case _ => return false
        }
        match(d){
            case x: DataString => regex.matched(x.data)
            case _ => false
        }
    }
}
private class InFilter<T> <: DataFilter where T <: Hashable & Equatable<T> {
    InFilter(private let left: DataPath, private let right: HashSet<T>){}
    init(left: String, right: String, solid: String){
        this(DataPath.compile(left, solid: Bool.parse(solid)), parseHashSet<T>(right))
    }
    public func check(data: Data): Bool {
        let d = match(left.get(data).next()){
            case Some(x) => x
            case _ => return false
        }
        match(d){
            case x: DataDateTime => match(x.data){
                case x: T => right.contains(x)
                case _ => false
            }
            case x: DataDuration => match(x.data){
                case x: T => right.contains(x)
                case _ => false
            }
            case x: DataReal => match(x.data){
                case x: T => right.contains(x)
                case _ => false
            }
            case x: DataString => match(x.data){
                case x: T => right.contains(x)
                case _ => false
            }
            case x: DataBool => match(x.data){
                case x: T => right.contains(x)
                case _ => false
            }
            case _ => false
        }
    }
}
private class NinFilter<T> <: DataFilter where T <: Hashable & Equatable<T> {
    private let filter: InFilter<T>
    init(left: DataPath, right: HashSet<T>){
        filter = InFilter<T>(left, right)
    }
    init(left: String, right: String, solid: String){
        this(DataPath.compile(left, solid: Bool.parse(solid)), parseHashSet<T>(right))
    }
    public func check(data: Data): Bool {
        !filter.check(data)
    }
}
private abstract class Subset<T> where T <: ToString & DataFields<T> {
    protected let left: DataPath
    private let right = HashSet<String>()
    init(left: DataPath, right: ArrayList<T>){
        for(v in right){
            this.right.put(v.toData().toString())
        }
        this.left = left
    }
    func subset(data: Data): Int64 {
        var subsetSize = 0
        let d = match(left.get(data).next()){
            case Some(x) => x
            case _ => return subsetSize
        }
        match(d){
            case x: DataSequence => 
                for(v in x where right.contains(v.toString())){
                    subsetSize++
                }
            case x: StringKeyMapTuples =>
                for(v in x where right.contains(v.key.toString())){
                    subsetSize++
                }
            case _ => 
                let info = TypeInfo.of(left)
                if(info.qualifiedName.startsWith('f_data.DataObject') && 
                   let Some(fn) <- TypeMemberInfos.instanceFunction(info, 'iterator') && 
                   let tuples: Iterator<(String, Data)> <- fn.apply(left)){
                    for((k, _) in tuples where right.contains(k)){
                        subsetSize++
                    }
                }
        }
        subsetSize
    }
}
private class AnyOfFilter<T> <: Subset<T> & DataFilter where T <: ToString & DataFields<T> {
    init(left: DataPath, right: ArrayList<T>){
        super(left, right)
    }
    init(left: String, right: String, solid: String){
        this(DataPath.compile(left, solid: Bool.parse(solid)), parseArrayList<T>(right))
    }
    public func check(data: Data): Bool {
        subset(data) > 0
    }
}
private class SubSetOfFilter<T> <: Subset<T> & DataFilter where T <: ToString & DataFields<T> {
    init(left: DataPath, right: ArrayList<T>){
        super(left, right)
    }
    init(left: String, right: String, solid: String){
        this(DataPath.compile(left, solid: Bool.parse(solid)), parseArrayList<T>(right))
    }
    public func check(data: Data): Bool {
        let d = match(left.get(data).next()){
            case Some(x) => x
            case _ => return false
        }
        let size = match(d){
            case x: DataSequence => x.size
            case x: StringKeyMapTuples => x.size
            case _ =>
                var size = -1
                let info = TypeInfo.of(left)
                if(info.qualifiedName.startsWith('f_data.DataObject') && 
                   let Some(fn) <- TypeMemberInfos.instanceFunction(info, 'fields') && 
                   let fields: Iterator<ReadableField> <- fn.apply(left)){
                    size = 0
                    for(_ in fields){
                        size++
                    }
                }
                size
        }
        subset(data) == size
    }
}
private class NoOneOfFilter<T> <: Subset<T> & DataFilter where T <: ToString & DataFields<T> {
    init(left: DataPath, right: ArrayList<T>){
        super(left, right)
    }
    init(left: String, right: String, solid: String){
        this(DataPath.compile(left, solid: Bool.parse(solid)), parseArrayList<T>(right))
    }
    public func check(left: Data): Bool {
        subset(left) == 0
    }
}
private class SizeFilter <: DataFilter {
    SizeFilter(private let left: DataPath, private let right: Int64){}
    init(left: String, right: String, solid: String){
        this(DataPath.compile(left, solid: Bool.parse(solid)), Int64.parse(right))
    }
    public func check(data: Data): Bool {
        let d = match(left.get(data).next()){
            case Some(x) => x
            case _ => return false
        }
        match(d){
            case x: DataSequence => x.size
            case x: StringKeyMapTuples => x.size
            case x: DataTuples => x.size
            case x: DataString => 
                var s = 0
                for(_ in x.data.runes()){
                    s++
                }
                s
            case _ => 
                var size = -1
                let info = TypeInfo.of(left)
                if(info.qualifiedName.startsWith('f_data.DataObject') && 
                   let Some(fn) <- TypeMemberInfos.instanceFunction(info, 'fields') && 
                   let fields: Iterator<ReadableField> <- fn.apply(left)){
                    size = 0
                    for(_ in fields){
                        size++
                    }
                }
                size
        } == right
    }
}
private class AndFilter <: DataFilter {
    AndFilter(private let left: DataFilter, private let right: DataFilter){}

    public func check(data: Data): Bool {
        left.check(data) && right.check(data)
    }
}
private class OrFilter <: DataFilter {
    OrFilter(private let left: DataFilter, private let right: DataFilter){}

    public func check(data: Data): Bool {
        left.check(data) || right.check(data)
    }
}
private class NotFilter <: DataFilter {
    NotFilter(private let op: DataFilter){}
    public func check(data: Data): Bool {
        !(op.check(data))
    }
}