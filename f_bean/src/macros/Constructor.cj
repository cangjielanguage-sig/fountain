/*
   Copyright (c) [2022] [WuJingrun（吴京润）]
   fountain is licensed under Mulan PSL v2.
   You can use this software according to the terms and conditions of the Mulan PSL v2.
   You may obtain a copy of Mulan PSL v2 at:
            http://license.coscl.org.cn/MulanPSL2
   THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
   See the Mulan PSL v2 for more details.
*/
macro package f_bean.macros

import std.ast.*
import f_macros.*
import f_bean.exception.BeanException

/**
 * 本宏用于为@Bean指示构造器，用于修饰构造bean的构造函数或静态工厂函数
 * 或者用于为@Configuration 指示Bean初始化函数，函数返回值就是bean实例
 */
public macro Constructor(attr: Tokens, input: Tokens){
    assertParentContext("Bean")
    if(attr.size > 0){
        setItem("beanName", attr[0].value)
    }else{
        setItem("beanName", "")
    }
    let decl = parseDecl(input)
    func toThrow(){
        BeanException("macro @Constructor can modify public constructor or public static func, however current is [${input}]")
    }
    if(!isPublic(decl)){
        throw toThrow()
    }
    if(decl is FuncDecl){
        let fn = (decl as FuncDecl).getOrThrow()
        let fnName = fn.identifier.value
        if(!(fnName == "init" || isStatic(fn))){
            throw toThrow()
        }
        setItem("constructor", fnName)
        let args = fn.funcParams.toTokens().toString().trimAscii()
        setItem("args", args)
    }else if(decl is PrimaryCtorDecl){
        setItem("constructor","init")
        let args = (decl as PrimaryCtorDecl).getOrThrow().funcParams.toTokens().toString().trimAscii()
        setItem("args", args)
    }else{
        throw toThrow()
    }
    input
}
