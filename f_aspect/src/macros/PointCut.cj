/*
    Copyright (c) [2022] [WuJingrun（吴京润）]
    fountain is licensed under Mulan PSL v2.
    You can use this software according to the terms and conditions of the Mulan PSL v2.
    You may obtain a copy of Mulan PSL v2 at:
            http://license.coscl.org.cn/MulanPSL2
    THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
    See the Mulan PSL v2 for more details.
 */
macro package f_aspect.macros

import std.ast.*
import std.collection.*
import std.sync.AtomicUInt64
import f_aspect.*
import f_aspect.exception.AspectException
import f_macros.*

let recursiveSerialGen = AtomicUInt64(1)
/**
 * 可以将切面织入func
 * 被织入的函数返回类型必须明确指定，等有反射api再次尝试是否可以完成类型推断
 * 如果attr最后一个元素是RecursiveSensitive，意思是递归调用切点，切面只在首次调用时执行一次
 */
public macro PointCut(attr: Tokens, input: Tokens): Tokens {
    let decl = parseDecl(input)
    match (decl) {
        case d: CompositeDecl => weaveComposite(d)
        case d: FuncDecl =>
            let recursiveSerial = if (attr.size > 0 && attr[attr.size - 1].value == "RecursiveSensitive" &&
                attr[attr.size - 1].kind == IDENTIFIER) {
                recursiveSerialGen.fetchAdd(1)
            } else {
                0u64
            }
            AssertParentContext("PointCut")
            weaveFunc(d, recursiveSerial)
        case _ => throw AspectException(
            "@PointCut cant modify class struct and func, but current is ${decl.keyword.kind}")
    }
}

func weaveComposite(decl: CompositeDecl) {
    let decls = decl.body.decls
    let identifier = decl.identifier
    let generic = try {
        decl.genericParam.toTokens()
    } catch (e: Exception) {
        `empty_tokens`
    }
    let currentTypeTokens = quote(
        private static let __cUrrEnt_typE_InfO__ = TypeInfos.get<$identifier$generic>()
    )
    let currentTypeInfoDecl = VarDecl(currentTypeTokens)
    decls.prepend(currentTypeInfoDecl)
    decl.toTokens()
}

func weaveFunc(decl: FuncDecl, recursive: UInt64) {
    let body = decl.block
    let nodes = ArrayList<Node>()
    let block = Block()
    block.lBrace = `lcurl`[0]
    block.nodes = nodes
    block.rBrace = `rcurl`[0]
    decl.block = block
    let params = decl.funcParams
    var args = `lsquare`
    var argTypes = `lsquare`
    var i = 0
    while (i < params.size) {
        if (i > 0) {
            args += `comma`
            argTypes += `comma`
        }
        let p = params[i]
        args += p.identifier
        argTypes += quote(TypeInfos.get<$(p.paramType)>())
        i++
    }
    args += `rsquare`
    argTypes += `rsquare`
    nodes.append(parseDecl(quote(
        let args: Array<Any> = $args
    )))
    nodes.append(parseDecl(quote(
        let argsTypes: Array<TypeInfo> = $argTypes
    )))
    nodes.append(parseDecl(quote(
        let fnName = $(decl.identifier.value)
    )))
    nodes.append(parseDecl(quote(
        let route = __cUrrEnt_typE_InfO__.qualifiedName + "." + fnName
    )))
    nodes.append(
        parseDecl(
        quote(
        let returnType = TypeInfos.get<$(decl.declType)>()
    )))
    nodes.append(
        parseExpr(quote(
        AspectProceeder<$(decl.declType)>($recursive, route, args, argTypes, returnType)$(body))))
    decl.toTokens()
}
