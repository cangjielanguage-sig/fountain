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

import f_base.*

public func extractProps(decls: ArrayList<Decl>, extractPublic!: Bool = true): Array<PropDecl> {
    let list = ArrayList<PropDecl>()
    for (decl in decls where decl is PropDecl && (!extractPublic || isPublic(decl))) {
        list.add((decl as PropDecl).getOrThrow())
    }
    list.toArray()
}

public func extractMutProps(decls: ArrayList<Decl>, extractPublic!: Bool = true, extractStatic!: Bool = false): Array<PropDecl> {
    let list = ArrayList<PropDecl>()
    for (decl in decls where decl is PropDecl && (!extractPublic || isPublic(decl)) && (!extractStatic || isStatic(decl)) &&
        isMut(decl)) {
        let propDecl = (decl as PropDecl).getOrThrow()
        list.add(propDecl)
    }
    list.toArray()
}

public func extractReadOnlyProps(decls: ArrayList<Decl>, extractPublic!: Bool = true): Array<PropDecl> {
    let list = ArrayList<PropDecl>()
    for (decl in decls where decl is PropDecl && (!extractPublic || isPublic(decl)) && !isMut(decl)) {
        let propDecl = (decl as PropDecl).getOrThrow()
        list.add(propDecl)
    }
    list.toArray()
}
