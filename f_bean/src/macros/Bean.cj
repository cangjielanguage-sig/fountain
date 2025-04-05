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
    let decl = parseDecl(input)
    let identifier = decl.identifier
    let (constructor, params) = match (decl) {
        case x: ClassDecl =>
            let messages = getChildMessages('Constructor')
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
        case _ => report(input, 'macro @Bean accept a class decl')
    }
    quote(
        
      $input

      let _ = BeanFactory.instance.register<$identifier>{
         $constructor($params)
      }
   )
}
