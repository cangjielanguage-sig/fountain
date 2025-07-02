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

public func extractAllVars(decls: Array<Decl>): Array<VarDecl> {
    let list = ArrayList<VarDecl>()
    for (decl in decls where decl is VarDecl) {
        list.add((decl as VarDecl).getOrThrow())
    }
    list.toArray()
}

public func extractVars(decls: ArrayList<Decl>, extractPublic!: Bool = true, extractVar!: Bool = true,
    extractStatic!: Bool = false): Array<VarDecl> {
    let list = ArrayList<VarDecl>()
    for (decl in decls where decl is VarDecl && (!extractPublic || isPublic(decl)) && (!extractStatic || isStatic(decl))) {
        let varDecl = (decl as VarDecl).getOrThrow()
        if (!extractVar || varDecl.isVar()) {
            list.add(varDecl)
        }
    }
    list.toArray()
}
