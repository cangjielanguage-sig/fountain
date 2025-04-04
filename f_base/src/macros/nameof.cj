/*
   Copyright (c) [2022] [WuJingrun（吴京润）]
   fountain is licensed under Mulan PSL v2.
   You can use this software according to the terms and conditions of the Mulan PSL v2.
   You may obtain a copy of Mulan PSL v2 at:
            http://license.coscl.org.cn/MulanPSL2
   THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
   See the Mulan PSL v2 for more details.  
*/
macro package f_base.macros

import std.ast.*
/**
 * @nameof(name) 展开是'name'
 * @nameof(object.name) 展开是'name'
 */
public macro nameof(input: Tokens): Tokens {
    quote(@nameValue($input)[0])
}
/**
 * @nameValueOf(name) 展开是元组('name', /*name变量的值*/)
 * @nameValueOf(object.name) 展开是元组('name', /*object.name的值*/)
 */
public macro nameValueOf(input: Tokens): Tokens {
    if(input.size == 0) {
        diagReport(ERROR, input, 'macro nameof do not accept empty input', '')
        throw IllegalArgumentException()
    }
    let last = input[input.size - 1]
    let identifier = 
    match(last.kind){
        case IDENTIFIER where input.size == 1 || input[input.size - 2].kind == DOT => last.value
        case _ => 
            diagReport(ERROR, input, 'the kind of last token in parameter of macro nameof must be IDENTIFIER', '')
            throw IllegalArgumentException()
    }
    quote(($identifier, $input))
}