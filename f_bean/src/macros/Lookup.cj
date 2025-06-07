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

public macro Lookup(input: Tokens): Tokens {
    quote(
        @Lookup[]
        $input
    )
}
public macro Lookup(attr: Tokens, input: Tokens): Tokens{
    let beanName = if(attr.size == 0){
        `empty_tokens`
    }else{
        attr
    }
    var tokens = `empty_tokens`
    for(i in 0 .. input.size){
        let t = input[i]
        if(t.kind == LCURL){
            break
        }
        tokens += t
    }
    let beanType = FuncDecl(input).declType
    let body = genAutowiredMessage(beanName, '', beanType, None)[1]
    quote(
        $tokens {
            $body
        }
    )
}