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
 * 只能修饰类。将@Bean修饰的类注册到BeanFactory
 */
public macro Bean(input: Tokens): Tokens {
    expandBean(input)
}

func expandBean(input: Tokens): Tokens {
    let decl = parseDecl(input)
    let identifier = decl.identifier
    match (decl) {
        case x: ClassDecl =>
            let messages = getChildMessages('Constructor')
            let (constructor, params) = 
            if (messages.isEmpty()) {
                (quote($(x.identifier)), `empty_tokens`)
            } else {
                let message = messages[0]
                let constructor = message.getTokens('constructor')
                let params = message.getTokens('params')
                if (constructor[0].value == 'init') {
                    (quote($(x.identifier)), params)
                } else {
                    (quote($(x.identifier).$constructor), params)
                }
            }
            var funcTokens = `lsquare`
            for(f in x.body.decls where isPublic(f) && !isStatic(f) && ((f as FuncDecl)?.funcParams.isEmpty() ?? false)){
                if(funcTokens.size > 1) {
                    funcTokens += `comma`
                }
                let fn = f.identifier
                funcTokens += quote(($(fn.value), {o: Object => (o as $identifier)?.$fn()}))
            }
            funcTokens += `rsquare`
            let tokens = 
            quote(
                $input
                let _ = {=>
                    var postConstruct = {o: Object =>}
                    var destroy = {o: Object =>}
                    var i = 0i8
                    for((n, f) in $funcTokens){
                        if(TypeInfos.withAnnotation<$identifier, PostConstruct>(n)) {
                            postConstruct = f
                            i++
                        }else if (TypeInfos.withAnnotation<$identifier, Destroy>(n)) {
                            destroy = f
                            i++
                        }
                        if(i == 2) {
                            break
                        }
                    }
                    BeanFactory.instance.register<$identifier>({=>
                        $constructor($params)
                    }, postConstruct: postConstruct, destroy: destroy)
                }()
            )
            tokens
        case x: FuncDecl => 
            assertParentContext('Configuration')
            populateConstructor(decl, acceptCtor: false)
            input
        case x: MacroExpandDecl => 
            expandBean(x.macroInputs)
        case _ => 
            report(input, 'macro @Bean can modify a class decl or a func decl when it is inside @Configuration')
            throw BeanException()
    }
}