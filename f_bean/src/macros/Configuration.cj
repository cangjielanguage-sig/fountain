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

/**
 * 将@Configuration修饰的类里被@Constructor修饰的函数作为bean初始化函数。被@Configuration修饰的类不会注册到BeanFactory.
 */
public macro Configuration(input: Tokens): Tokens {
    let decl = parseDecl(input)
    let identifier = decl.identifier
    let staticConstructors = ArrayList<(Tokens, Tokens)>()
    let instanceConstructors = ArrayList<(Tokens, Tokens)>()
    var configurationConstructor = None<(Tokens, Tokens)>
    match (decl) {
        case x: ClassDecl =>
            var tokens = `empty_tokens`
            for (message in getChildMessages('Bean')) {
                var constructor = message.getTokens('constructor')
                let params = message.getTokens('params')
                if (constructor[0].value == 'init') {
                    if (configurationConstructor.isNone()) {
                        configurationConstructor = (quote($(x.identifier)), params)
                    } else {
                        report(input,
                            '@Constructor can modify one constructor in which decl is modified by @Configuration')
                    }
                } else if (message.getBool('static')) {
                    staticConstructors.add((quote($(x.identifier).$constructor), params))
                } else {
                    instanceConstructors.add((quote(configuration.$constructor), params))
                }
            }
            tokens
        case _ => report(input, 'macro @Configuration accept a class decl or')
    }
    func genCtorApply(tokens: Option<(Tokens, Tokens)>) {
        if (let Some((constructor, params)) <- tokens) {
            quote($constructor($params))
        } else {
            quote($(decl.identifier)())
        }
    }
    func genCtorApply(tokens: ArrayList<(Tokens, Tokens)>) {
        var beans = `empty_tokens`
        for (ct in tokens) {
            if (beans.size > 0) {
                beans += `nl`
            }
            beans += quote(BeanFactory.instance.register{
            $(genCtorApply(ct))
         })
        }
        beans
    }
    let beans = `nl` + genCtorApply(staticConstructors) + `nl` + genCtorApply(instanceConstructors)
    quote(
        
      $input
      
      let _ = {=> 
         let configuration = $(genCtorApply(configurationConstructor))
         $beans
      }
   )
}
