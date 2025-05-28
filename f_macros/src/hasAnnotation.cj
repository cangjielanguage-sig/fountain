/*
    Copyright (c) [2022] [WuJingrun（吴京润）]
    fountain is licensed under Mulan PSL v2.
    You can use this software according to the terms and conditions of the Mulan PSL v2.
    You may obtain a copy of Mulan PSL v2 at:
            http://license.coscl.org.cn/MulanPSL2
    THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
    See the Mulan PSL v2 for more details.  
*/
package f_macros

import f_base
public func withAnnotation<T>(decl: Decl): Bool where T <: Annotation {
    match(decl){
        case d: MacroExpandDecl => f_base.TypeInfos.get<T>().qualifiedName.endsWith('.${d.fullIdentifier.value}')
        case _ => false
    }
}
public func withAnnotation<T, A>(funcName: String, argTypes: Array<TypeInfo>): Bool where A <: Annotation {
    f_base.TypeInfos.get<T>().getInstanceFunction(funcName, argTypes).findAnnotation<A>().isSome()
}
public func withMacro(decl: Decl, macroName: String): Bool {
    match(decl){
        case d: MacroExpandDecl => d.fullIdentifier.value == macroName
        case _ => false
    }
}