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

public interface ExtendVarDecl <: ExtendMember {
    func isVar(): Bool
    func isStatic(): Bool
}

extend VarDecl <: ExtendVarDecl {
    public func isVar(): Bool {
        match (this.keyword.kind) {
            case VAR => true
            case _ => false
        }
    }
    public func isPublic(): Bool {
        isPublic(this)
    }
    public func isProtected(): Bool {
        isProtected(this)
    }
    public func isPrivate(): Bool {
        isPrivate(this)
    }
    public func isStatic(): Bool {
        isStatic(this)
    }
}
