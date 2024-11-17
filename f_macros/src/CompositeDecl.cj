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

public interface CompositeDecl <: ToTokens {
    mut prop annotations: ArrayList<Annotation>
    mut prop modifiers: ArrayList<Modifier>
    mut prop keyword: Token
    mut prop identifier: Token
    mut prop genericParam: GenericParam
    mut prop genericConstraint: ArrayList<GenericConstraint>
    func getAttrs(): Tokens
    func hasAttr(attr: String): Bool
    mut prop upperBound: Token
    mut prop superTypes: ArrayList<TypeNode>
    mut prop body: Body
    func isPublic(): Bool 
    func isProtected(): Bool 
    func isPrivate(): Bool 
    func isInternal(): Bool {
        !(isPublic() || isProtected() || isPrivate())
    }
}
extend ClassDecl <: CompositeDecl{
    public func isPublic(): Bool {
        isPublic(this)
    }
    public func isProtected(): Bool {
        isProtected(this)
    }
    public func isPrivate(): Bool {
        isPrivate(this)
    }
}
extend StructDecl <: CompositeDecl{
    public func isPublic(): Bool {
        isPublic(this)
    }
    public func isProtected(): Bool {
        isProtected(this)
    }
    public func isPrivate(): Bool {
        isPrivate(this)
    }
}
