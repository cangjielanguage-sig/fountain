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
import std.collection.ArrayList
import f_bean.exception.BeanException
import f_macros.*
/**
   @Configuration本宏只能修饰类或结构体
   被修饰的类型必须有一个public或包内可访问的无参构造器
   被修饰类型内被@Constructor修饰的函数返回值会被注册到bean.BeanFactory
 */
public macro Configuration(input: Tokens): Tokens {
    let decl = parseDecl(input)
    let (name, composite): (Token, CompositeDecl) = if (decl is StructDecl) {
        let structDecl = (decl as StructDecl).getOrThrow()
        (structDecl.identifier, structDecl)
    } else if (decl is ClassDecl) {
        let classDecl = (decl as ClassDecl).getOrThrow()
        (classDecl.identifier, classDecl)
    } else {
        throw BeanException("@Configuration can modify class or struct only")
    }
    input + `nl` + generateConstructors(name)
}

func generateConstructors(name: Token){
    var fnMetas = `lsquare`
    var i = 0
    for (message in getChildMessages("Constructor")) {
        let beanName = message.getString("beanName")
        let isStatic = message.getBool("static")
        let fnName = message.getString("fnName")
        let argTypeNames = message.getString("args").split("|")
        if (i > 0) {
            fnMetas += `comma`
        }
        var argTypes = `lsquare`
        var j = 0
        while(j < argTypeNames.size) {
            if(j > 0){
                argTypes += `comma`
            }
            let typeTokens = cangjieLex(argTypeNames[j])
            argTypes += quote(TypeInfos<$typeTokens>.instance)
            j++
        }
        argTypes += `rsquare`
        fnMetas += quote(($beanName, $isStatic, $fnName, $argTypes))
        i++
    }
    fnMetas += `rsquare`
    quote(
        let _ = {=>
            let fnMetas = $fnMetas
            for(fnMeta in fnMetas){
                let beanName = fnMeta[0]
                let isStatic = fnMeta[1]
                let fnName = fnMeta[2]
                let args = fnMeta[3]
                let meta = BeanMeta.create<$name>($name(), beanName, isStatic, fnName, args)
                App.beanFactory.register(meta)
            }
        }()
    )
}
