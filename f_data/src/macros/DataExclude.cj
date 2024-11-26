/*
   Copyright (c) [2022] [WuJingrun（吴京润）]
   fountain is licensed under Mulan PSL v2.
   You can use this software according to the terms and conditions of the Mulan PSL v2.
   You may obtain a copy of Mulan PSL v2 at:
            http://license.coscl.org.cn/MulanPSL2
   THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
   See the Mulan PSL v2 for more details.  
*/
macro package f_data.macros

import std.ast.*
import f_macros.*

/**
 * attrs取值可以是prop hash equal compare tostring field或Prop Hash Equal Compare ToString toString Field
 */
public macro DataExclude(attrs: Tokens, input: Tokens): Tokens {
    assertParentContext('DataAssist')
    let decl = parseDecl(input)
    match(decl){
        case d: VarDecl where !d.isStatic() => 
            for(attr in attrs){
                let tag = attr.value.toAsciiLower()
                if(tag == 'field' && !d.isPublic()){
                    diagReport(ERROR, extractDeclSignature(d) , 'input must be non-static public prop/public mut prop for @DataExclude[field]', '')
                }
                setItem(tag, d.identifier.value)
            }
        case d: PropDecl where !d.isStatic() && d.isPublic() => 
            for(attr in attrs){
                let tag = attr.value.toAsciiLower()
                if(tag == 'field'){
                    setItem(tag, d.identifier.value)
                }else{
                    diagReport(WARNING, extractDeclSignature(d), 'only @DataExclude[field] can only modify public prop or public mut prop', '')
                }
            }
        case _ => 
            diagReport(ERROR, extractDeclSignature(decl), 'input must be non-static var decleration for prop hash equal compare tostring or non-static public var/public prop/public mut prop for field', '')
    }
    input
}
func extractDeclSignature(decl: Decl){
    quote($(decl.modifiers) $(decl.keyword) $(decl.identifier)) 
}