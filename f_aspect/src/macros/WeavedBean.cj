/*
Copyright (c) 2025 WuJingrun（吴京润）

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
 */
macro package fountain::f_aspect.macros

import std.ast.*
import std.collection.*
import fountain::f_macros.*
import fountain::f_aspect.exception.*
public import fountain::f_bean.macros.*

public macro WeavedBean(input: Tokens): Tokens {
    let (decl, remainder) = extractFirstDecl(input)
    let tokens = quote(
        @Bean
        $(weave(decl))
        $remainder
    )
    tokens
}

public macro WeavedBean(attr: Tokens, input: Tokens): Tokens {
    let (decl, remainder) = extractFirstDecl(input)
    quote(
        @Bean[$attr]
        $(weave(decl))
        $remainder
    )
}

private func weave(input: Decl): Tokens {
    match (input) {
        case x: ClassDecl =>
            let decls = x.body.decls
            // ASP-3（§1.14）：可用时为每个被织入函数生成静态元信息（private static let __pOIntcUt_…），
            // 函数体里复用它，不再每次调用重建 QualifiedFuncInfo；不适用时退回原来的每调用构造。
            let allowMeta = !isGenericClass(x)
            let metas = ArrayList<Tokens>()
            let usedNames = HashSet<String>()
            var ord = HashMap<String, Int64>()
            for (i in 0..decls.size) {
                decls[i] = match (decls[i]) {
                    case f: FuncDecl where f.isPublic() && !f.isStatic() =>
                        let metaName = if (allowMeta) {
                            nextMetaName(f, ord, usedNames)
                        } else {
                            None<String>
                        }
                        let (pf, meta) = weaveOne(f, x.identifier, metaName)
                        if (let Some(m) <- meta) {
                            metas.add(m)
                        }
                        parseDecl(pf)
                    case me: MacroExpandDecl =>
                        var md = me
                        while (let m: MacroExpandDecl <- md.macroInputDecl) {
                            md = m
                        }
                        if (let f: FuncDecl <- md.macroInputDecl && f.isPublic() && !f.isStatic()) {
                            let metaName = if (allowMeta) {
                                nextMetaName(f, ord, usedNames)
                            } else {
                                None<String>
                            }
                            let (pf, meta) = weaveOne(f, x.identifier, metaName)
                            md.macroInputDecl = parseDecl(pf)
                            if (let Some(m2) <- meta) {
                                metas.add(m2)
                            }
                        }
                        me
                    case _ => continue
                }
            }
            for (m in metas) {
                decls.add(parseDecl(m))
            }
            x.toTokens()
        case x: MacroExpandDecl =>
            var md = x
            while (let x: MacroExpandDecl <- md.macroInputDecl) {
                md = x
            }
            let tokens = weave(md.macroInputDecl)
            md.macroInputDecl = parseDecl(tokens)
            x.toTokens()
        case _ =>
            diagReport(ERROR, input.toTokens(), 'input must be a class decl', '')
            throw AspectException()
    }
}
