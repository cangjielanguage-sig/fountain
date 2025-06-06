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

public func extract(decl: MacroExpandDecl): Decl{
    var d: Decl = decl
    while(let m: MacroExpandDecl <- d){
        d = m.macroInputDecl
    }
    d
}
public func extract(decl: MacroExpandDecl, macroName: String): ?(MacroExpandDecl, Decl) {
    var d: Decl = decl
    var result = None<(MacroExpandDecl, Decl)>
    while(let m: MacroExpandDecl <- d){
        if(m.fullIdentifier.value == macroName){
            result = (m, d)
        }
        d = m.macroInputDecl
    }
    if(let Some((m, _)) <- result){
        result = (m, d)
    }
    result
}
public func extract(expr: MacroExpandExpr): Expr {
    var e: Expr = expr
    while(let m: MacroExpandExpr <- e){
        e = parseExpr(m.macroInputs)
    }
    e
}
public func extract(expr: MacroExpandExpr, macroName: String): ?(MacroExpandExpr, Expr) {
    var e: Expr = expr
    var result = None<(MacroExpandExpr, Expr)>
    while(let m: MacroExpandExpr <- e){
        if(m.identifier.value == macroName){
            result = (m, e)
        }
        e = parseExpr(m.macroInputs)
    }
    if(let Some((m, _)) <- result){
        result = (m, e)
    }
    result
}
public func extract(param: MacroExpandParam): FuncParam {
    var p: FuncParam = param
    while(let m: MacroExpandParam <- param && let pin: FuncParam <- m.macroInputDecl){
        p = pin
    }
    p
}
public func extract(param: MacroExpandParam, macroName: String): ?(MacroExpandParam, FuncParam) {
    var p: FuncParam = param
    var result = None<(MacroExpandParam, FuncParam)>
    while(let m: MacroExpandParam <- param && let pin: FuncParam <- m.macroInputDecl){
        if(m.fullIdentifier.value == macroName){
            result = (m, pin)
        }
        p = pin
    }
    if(let Some((m, _)) <- result){
        result = (m, p)
    }
    result
}