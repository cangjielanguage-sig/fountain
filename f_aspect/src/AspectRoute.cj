/*
    Copyright (c) [2022] [WuJingrun（吴京润）]
    fountain is licensed under Mulan PSL v2.
    You can use this software according to the terms and conditions of the Mulan PSL v2.
    You may obtain a copy of Mulan PSL v2 at:
            http://license.coscl.org.cn/MulanPSL2
    THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
    See the Mulan PSL v2 for more details.
 */
package f_aspect

public import std.reflect.*
import std.ast.*
import f_base.*
import f_aspect.exception.AspectException
import f_regex.*

/**
 * 用来修饰切面也就是Aspect的实现类
 */
@Annotation[target: [Type]]
public class AspectRoute <: RouteRule {
    public const AspectRoute(public let route: Route) {}
    public func isAspect<T>(): Bool {
        TypeInfos.get<T>().isSubtypeOf(TypeInfos.get<Aspect>())
    }
    public func matched(qualifiedFunc: String): Bool {
        route.matched(qualifiedFunc)
    }
}
public sealed interface RouteRule {
    func matched(qualifiedFunc: String): Bool
}
public enum Route <: RouteRule {
    /**
     * *\/..*.*(#): *
     */
    | Execution(String)
    /**
     * 匹配类型全限定名
     */
    | Within(String)
    /**
     * 匹配参数，各参数全限定名用|分害
     */
    | Args(String)
    /**
     * 第一个参数函数参数类型全限定名，各参数类型用|分割，第二个参数是函数返回类型全限定名
     */
    | FuncType(String, String)
    /**
     * 注解全限定名
     */
    | WithAnnotation(String)
    /**
     * 与
     */
    | And(Route, Route)
    /**
     * 或
     */
    | Or(Route, Route)
    /**
     * 非
     */
    | Not(Route)
      

    public func matched(qualifiedFunc: String): Bool {
        match (this) {
            case Execution(route) => doExecutionMatch(route, qualifiedFunc)
            case Within(route) => doExecutionMatch("${route}.*(#): *", qualifiedFunc)
            case Args(route) => doExecutionMatch("*/..*.*(${route.replace("|",",")}): *", qualifiedFunc)
            case WithAnnotation(annotation) => doWithAnnotation(TypeInfos.get(annotation), qualifiedFunc)
            case FuncType(args, returnType) =>
                let argArray = args.split("|")
                let argTypes = Array<TypeInfo>(argArray.size){i =>
                    TypeInfos.get(argArray[i])
                }
                let returnTypeInfo = TypeInfos.get(returnType)
                doFuncTypeMatch(argTypes, returnTypeInfo, qualifiedFunc)
            case And(a, b) => a.matched(qualifiedFunc) && b.matched(qualifiedFunc)
            case Or(a, b) => a.matched(qualifiedFunc) || b.matched(qualifiedFunc)
            case Not(a) => !a.matched(qualifiedFunc)
        }
    }
    private func doExecutionMatch(route: String, qualifiedFunc: String): Bool {
        func withinRegex(within: String) {
            within.replace("..", #"[\w\.]*"#).replace("*", #"\w*"#).replace(".", #"\."#)
        }
        let lparen = route.indexOf("(") ?? -1
        let rparen = route.lastIndexOf(")") ?? -1
        let within = withinRegex(route[0..lparen].trimAscii())
        let args = withinRegex(route[lparen + 1..rparen].replace("#", #"[\w,:\.<>]*"#).replace(" ", ""))
        let colon = route.lastIndexOf(":")
        let returnType = if (let Some(ridx) <- colon) {
            withinRegex(route[ridx + 1..].trimAscii())
        } else {
            ".*"
        }
        "${within}(${args}):${returnType}".regex().matched(qualifiedFunc)
    }
    private func doWithAnnotation(annotationType: TypeInfo, qualifiedFunc: String): Bool {
        var qualified = qualifiedFunc[0..(qualifiedFunc.indexOf("(") ?? -1)]
        qualified = qualified[0..(qualified.lastIndexOf(".") ?? -1)]
        for (annotation in TypeInfos.get(qualified).annotations where TypeInfo.of(annotation) == annotationType) {
            return true
        }
        return false
    }
    private func doFuncTypeMatch(args: Array<TypeInfo>, returnType: TypeInfo, qualifiedFunc: String): Bool {
        let argStart = (qualifiedFunc.indexOf("(") ?? -1)
        let argEnd = qualifiedFunc.lastIndexOf(")") ?? -1
        var qualified = qualifiedFunc[0 .. argStart]
        let funcStart = qualified.lastIndexOf(".") ?? -1
        qualified = qualified[0 .. funcStart].trimAscii()
        let typeInfo = TypeInfos.get(qualified)
        let argStr = qualifiedFunc[argStart + 1 .. argEnd]
        let funcTmp = """
            func fn(${argStr}){()}
"""
        let funcTokens = cangjieLex(funcTmp)
        let funcParams = (parseDecl(funcTokens) as FuncDecl).getOrThrow().funcParams
        let argTypes = Array<TypeInfo>(funcParams.size){i =>
            TypeInfos.get(funcParams[i].paramType.toTokens().toString().replace(" ", ""))
        }
        let fn = typeInfo.getInstanceFunction(qualifiedFunc[funcStart + 1 .. argStart], argTypes)
        var argidx = 0
        for (param in fn.parameters) {
            if (param.typeInfo != args[argidx]) {
                return false
            }
            argidx++
        }
        returnType == fn.returnType
    }
}
