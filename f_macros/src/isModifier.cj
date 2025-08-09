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
package f_macros

public func isStatic(tokens: Tokens): Bool {
    isStatic(parseDecl(tokens))
}

public func isStatic(decl: Decl): Bool {
    (decl is PropDecl && isStatic((decl as PropDecl).getOrThrow())) || (decl is FuncDecl && isStatic(
        (decl as FuncDecl).getOrThrow())) || (decl is VarDecl && isStatic((decl as VarDecl).getOrThrow()))
}

public func isStatic(decl: PropDecl) {
    let modifiers = decl.modifiers
    let size = modifiers.size
    (size > 0 && isStatic(modifiers, 0)) || (size > 1 && isStatic(modifiers, 1)) || (size > 2 && isStatic(modifiers, 2)) ||
        (size > 3 && isStatic(modifiers, 3)) || (size > 4 && isStatic(modifiers, 4))
}

public func isStatic(decl: FuncDecl) {
    let modifiers = decl.modifiers
    let size = modifiers.size
    (size > 0 && isStatic(modifiers, 0)) || (size > 1 && isStatic(modifiers, 1)) || (size > 2 && isStatic(modifiers, 2)) ||
        (size > 3 && isStatic(modifiers, 3)) || (size > 4 && isStatic(modifiers, 4))
}

public func isStatic(decl: VarDecl) {
    let modifiers = decl.modifiers
    let size = modifiers.size
    (size > 0 && isStatic(modifiers, 0)) || (size > 1 && isStatic(modifiers, 1)) || (size > 2 && isStatic(modifiers, 2)) ||
        (size > 3 && isStatic(modifiers, 3)) || (size > 4 && isStatic(modifiers, 4))
}

func isStatic(modifiers: ArrayList<Modifier>, index: Int64): Bool {
    isModifier(modifiers, index, STATIC)
}

public func isAbstract(tokens: Tokens): Bool {
    isAbstract(parseDecl(tokens))
}

public func isAbstract(decl: Decl): Bool {
    decl is ClassDecl && isAbstract((decl as ClassDecl).getOrThrow())
}

public func isAbstract(decl: ClassDecl): Bool {
    let modifiers = decl.modifiers
    let size = modifiers.size
    (size > 0 && isAbstract(modifiers, 0)) || (size > 1 && isAbstract(modifiers, 1))
}

func isAbstract(modifiers: ArrayList<Modifier>, index: Int64): Bool {
    isModifier(modifiers, index, ABSTRACT)
}

public func isPublic(tokens: Tokens): Bool {
    isPublic(parseDecl(tokens))
}

public func isPublic(decl: Decl): Bool {
    (decl is PropDecl && isPublic((decl as PropDecl).getOrThrow())) || (decl is FuncDecl && isPublic(
        (decl as FuncDecl).getOrThrow())) || (decl is VarDecl && isPublic((decl as VarDecl).getOrThrow())) || (decl is ClassDecl &&
        isPublic((decl as ClassDecl).getOrThrow())) || (decl is StructDecl && isPublic(
        (decl as StructDecl).getOrThrow())) || (decl is EnumDecl && isPublic((decl as EnumDecl).getOrThrow())) ||
        (decl is PrimaryCtorDecl) && isPublic((decl as PrimaryCtorDecl).getOrThrow())
}

public func isPrivate(decl: PrimaryCtorDecl) {
    match (decl.toTokens()[0].kind) {
        case PRIVATE => true
        case _ => false
    }
}

public func isProtected(decl: PrimaryCtorDecl) {
    match (decl.toTokens()[0].kind) {
        case PROTECTED => true
        case _ => false
    }
}

public func isPublic(decl: PrimaryCtorDecl) {
    match (decl.toTokens()[0].kind) {
        case PUBLIC => true
        case _ => false
    }
}

public func isPublic(decl: ClassDecl): Bool {
    let modifiers = decl.modifiers
    let size = modifiers.size
    (size > 0 && isPublic(modifiers, 0)) || (size > 1 && isPublic(modifiers, 1))
}

public func isPublic(decl: StructDecl): Bool {
    let modifiers = decl.modifiers
    let size = modifiers.size
    (size > 0 && isPublic(modifiers, 0))
}

public func isPublic(decl: EnumDecl): Bool {
    let modifiers = decl.modifiers
    let size = modifiers.size
    (size > 0 && isPublic(modifiers, 0))
}

public func isPublic(decl: PropDecl) {
    let modifiers = decl.modifiers
    let size = modifiers.size
    (size > 0 && isPublic(modifiers, 0)) || (size > 1 && isPublic(modifiers, 1)) || (size > 2 && isPublic(modifiers, 2)) ||
        (size > 3 && isPublic(modifiers, 3)) || (size > 4 && isPublic(modifiers, 4))
}

public func isPublic(decl: FuncDecl) {
    let modifiers = decl.modifiers
    let size = modifiers.size
    (size > 0 && isPublic(modifiers, 0)) || (size > 1 && isPublic(modifiers, 1)) || (size > 2 && isPublic(modifiers, 2)) ||
        (size > 3 && isPublic(modifiers, 3)) || (size > 4 && isPublic(modifiers, 4))
}

public func isPublic(decl: VarDecl) {
    let modifiers = decl.modifiers
    let size = modifiers.size
    (size > 0 && isPublic(modifiers, 0)) || (size > 1 && isPublic(modifiers, 1)) || (size > 2 && isPublic(modifiers, 2)) ||
        (size > 3 && isPublic(modifiers, 3)) || (size > 4 && isPublic(modifiers, 4))
}

func isPublic(modifiers: ArrayList<Modifier>, index: Int64): Bool {
    isModifier(modifiers, index, PUBLIC)
}

public func isPrivate(tokens: Tokens): Bool {
    isPrivate(parseDecl(tokens))
}

public func isPrivate(decl: Decl): Bool {
    (decl is PropDecl && isPrivate((decl as PropDecl).getOrThrow())) || (decl is FuncDecl && isPrivate(
        (decl as FuncDecl).getOrThrow())) || (decl is VarDecl && isPrivate((decl as VarDecl).getOrThrow())) ||
        (decl is PrimaryCtorDecl) && isPublic((decl as PrimaryCtorDecl).getOrThrow())
}

public func isPrivate(decl: PropDecl) {
    let modifiers = decl.modifiers
    let size = modifiers.size
    (size > 0 && isPrivate(modifiers, 0)) || (size > 1 && isPrivate(modifiers, 1)) || (size > 2 && isPrivate(modifiers,
        2)) || (size > 3 && isPrivate(modifiers, 3)) || (size > 4 && isPrivate(modifiers, 4))
}

public func isPrivate(decl: FuncDecl) {
    let modifiers = decl.modifiers
    let size = modifiers.size
    (size > 0 && isPrivate(modifiers, 0)) || (size > 1 && isPrivate(modifiers, 1)) || (size > 2 && isPrivate(modifiers,
        2)) || (size > 3 && isPrivate(modifiers, 3)) || (size > 4 && isPrivate(modifiers, 4))
}

public func isPrivate(decl: VarDecl) {
    let modifiers = decl.modifiers
    let size = modifiers.size
    (size > 0 && isPrivate(modifiers, 0)) || (size > 1 && isPrivate(modifiers, 1)) || (size > 2 && isPrivate(modifiers,
        2)) || (size > 3 && isPrivate(modifiers, 3)) || (size > 4 && isPrivate(modifiers, 4))
}

func isPrivate(modifiers: ArrayList<Modifier>, index: Int64): Bool {
    isModifier(modifiers, index, PRIVATE)
}

public func isProtected(tokens: Tokens): Bool {
    isProtected(parseDecl(tokens))
}

public func isProtected(decl: Decl): Bool {
    (decl is PropDecl && isProtected((decl as PropDecl).getOrThrow())) || (decl is FuncDecl && isProtected(
        (decl as FuncDecl).getOrThrow())) || (decl is VarDecl && isProtected((decl as VarDecl).getOrThrow())) ||
        (decl is PrimaryCtorDecl) && isPublic((decl as PrimaryCtorDecl).getOrThrow())
}

public func isProtected(decl: PropDecl) {
    let modifiers = decl.modifiers
    let size = modifiers.size
    (size > 0 && isProtected(modifiers, 0)) || (size > 1 && isProtected(modifiers, 1)) || (size > 2 && isProtected(
        modifiers, 2)) || (size > 3 && isProtected(modifiers, 3)) || (size > 4 && isProtected(modifiers, 4))
}

public func isProtected(decl: FuncDecl) {
    let modifiers = decl.modifiers
    let size = modifiers.size
    (size > 0 && isProtected(modifiers, 0)) || (size > 1 && isProtected(modifiers, 1)) || (size > 2 && isProtected(
        modifiers, 2)) || (size > 3 && isProtected(modifiers, 3)) || (size > 4 && isProtected(modifiers, 4))
}

public func isProtected(decl: VarDecl) {
    let modifiers = decl.modifiers
    let size = modifiers.size
    (size > 0 && isProtected(modifiers, 0)) || (size > 1 && isProtected(modifiers, 1)) || (size > 2 && isProtected(
        modifiers, 2)) || (size > 3 && isProtected(modifiers, 3)) || (size > 4 && isProtected(modifiers, 4))
}

func isProtected(modifiers: ArrayList<Modifier>, index: Int64): Bool {
    isModifier(modifiers, index, PROTECTED)
}

public func isMut(tokens: Tokens): Bool {
    isMut(parseDecl(tokens))
}

public func isMut(decl: Decl): Bool {
    (decl is PropDecl && isMut((decl as PropDecl).getOrThrow())) || (decl is FuncDecl && isMut(
        (decl as FuncDecl).getOrThrow())) || (decl is VarDecl && isMut((decl as VarDecl).getOrThrow()))
}

public func isMut(decl: PropDecl) {
    let modifiers = decl.modifiers
    let size = modifiers.size
    (size > 0 && isMut(modifiers, 0)) || (size > 1 && isMut(modifiers, 1)) || (size > 2 && isMut(modifiers, 2))
}

public func isMut(decl: FuncDecl) {
    let modifiers = decl.modifiers
    let size = modifiers.size
    (size > 0 && isMut(modifiers, 0)) || (size > 1 && isMut(modifiers, 1)) || (size > 2 && isMut(modifiers, 2)) || (size >
        3 && isMut(modifiers, 3)) || (size > 4 && isMut(modifiers, 4))
}

public func isMut(decl: VarDecl) {
    let modifiers = decl.modifiers
    let size = modifiers.size
    (size > 0 && isMut(modifiers, 0)) || (size > 1 && isMut(modifiers, 1)) || (size > 2 && isMut(modifiers, 2)) || (size >
        3 && isMut(modifiers, 3)) || (size > 4 && isMut(modifiers, 4))
}

func isMut(modifiers: ArrayList<Modifier>, index: Int64): Bool {
    isModifier(modifiers, index, MUT)
}

public func isOpen(tokens: Tokens): Bool {
    isOpen(parseDecl(tokens))
}

public func isOpen(decl: Decl): Bool {
    (decl is PropDecl && isOpen((decl as PropDecl).getOrThrow())) || (decl is FuncDecl && isOpen(
        (decl as FuncDecl).getOrThrow())) || (decl is VarDecl && isOpen((decl as VarDecl).getOrThrow()))
}

public func isOpen(decl: PropDecl) {
    let modifiers = decl.modifiers
    let size = modifiers.size
    (size > 0 && isOpen(modifiers, 0)) || (size > 1 && isOpen(modifiers, 1)) || (size > 2 && isOpen(modifiers, 2)) || (size >
        3 && isOpen(modifiers, 3)) || (size > 4 && isOpen(modifiers, 4))
}

public func isOpen(decl: FuncDecl) {
    let modifiers = decl.modifiers
    let size = modifiers.size
    (size > 0 && isOpen(modifiers, 0)) || (size > 1 && isOpen(modifiers, 1)) || (size > 2 && isOpen(modifiers, 2)) || (size >
        3 && isOpen(modifiers, 3)) || (size > 4 && isOpen(modifiers, 4))
}

public func isOpen(decl: VarDecl) {
    let modifiers = decl.modifiers
    let size = modifiers.size
    (size > 0 && isOpen(modifiers, 0)) || (size > 1 && isOpen(modifiers, 1)) || (size > 2 && isOpen(modifiers, 2)) || (size >
        3 && isOpen(modifiers, 3)) || (size > 4 && isOpen(modifiers, 4))
}

func isOpen(modifiers: ArrayList<Modifier>, index: Int64): Bool {
    isModifier(modifiers, index, OPEN)
}

public func isOverride(tokens: Tokens): Bool {
    isOverride(parseDecl(tokens))
}

public func isOverride(decl: Decl): Bool {
    (decl is PropDecl && isOverride((decl as PropDecl).getOrThrow())) || (decl is FuncDecl && isOverride(
        (decl as FuncDecl).getOrThrow())) || (decl is VarDecl && isOverride((decl as VarDecl).getOrThrow()))
}

public func isOverride(decl: PropDecl) {
    let modifiers = decl.modifiers
    let size = modifiers.size
    (size > 0 && isOverride(modifiers, 0)) || (size > 1 && isOverride(modifiers, 1)) || (size > 2 && isOverride(
        modifiers, 2)) || (size > 3 && isOverride(modifiers, 3)) || (size > 4 && isOverride(modifiers, 4))
}

public func isOverride(decl: FuncDecl) {
    let modifiers = decl.modifiers
    let size = modifiers.size
    (size > 0 && isOverride(modifiers, 0)) || (size > 1 && isOverride(modifiers, 1)) || (size > 2 && isOverride(
        modifiers, 2)) || (size > 3 && isOverride(modifiers, 3)) || (size > 4 && isOverride(modifiers, 4))
}

public func isOverride(decl: VarDecl) {
    let modifiers = decl.modifiers
    let size = modifiers.size
    (size > 0 && isOverride(modifiers, 0)) || (size > 1 && isOverride(modifiers, 1)) || (size > 2 && isOverride(
        modifiers, 2)) || (size > 3 && isOverride(modifiers, 3)) || (size > 4 && isOverride(modifiers, 4))
}

func isOverride(modifiers: ArrayList<Modifier>, index: Int64): Bool {
    isModifier(modifiers, index, OVERRIDE)
}

public func isRedef(tokens: Tokens): Bool {
    isRedef(parseDecl(tokens))
}

public func isRedef(decl: Decl): Bool {
    (decl is PropDecl && isRedef((decl as PropDecl).getOrThrow())) || (decl is FuncDecl && isRedef(
        (decl as FuncDecl).getOrThrow())) || (decl is VarDecl && isRedef((decl as VarDecl).getOrThrow()))
}

public func isRedef(decl: PropDecl) {
    let modifiers = decl.modifiers
    let size = modifiers.size
    (size > 0 && isRedef(modifiers, 0)) || (size > 1 && isRedef(modifiers, 1)) || (size > 2 && isRedef(modifiers, 2)) ||
        (size > 3 && isRedef(modifiers, 3)) || (size > 4 && isRedef(modifiers, 4))
}

public func isRedef(decl: FuncDecl) {
    let modifiers = decl.modifiers
    let size = modifiers.size
    (size > 0 && isRedef(modifiers, 0)) || (size > 1 && isRedef(modifiers, 1)) || (size > 2 && isRedef(modifiers, 2)) ||
        (size > 3 && isRedef(modifiers, 3)) || (size > 4 && isRedef(modifiers, 4))
}

public func isRedef(decl: VarDecl) {
    let modifiers = decl.modifiers
    let size = modifiers.size
    (size > 0 && isRedef(modifiers, 0)) || (size > 1 && isRedef(modifiers, 1)) || (size > 2 && isRedef(modifiers, 2)) ||
        (size > 3 && isRedef(modifiers, 3)) || (size > 4 && isRedef(modifiers, 4))
}

func isRedef(modifiers: ArrayList<Modifier>, index: Int64): Bool {
    isModifier(modifiers, index, REDEF)
}

func isModifier(modifiers: ArrayList<Modifier>, index: Int64, kind: TokenKind): Bool {
    match ((modifiers[index].keyword.kind, kind)) {
        case (PUBLIC, PUBLIC) | (PRIVATE, PRIVATE) | (PROTECTED, PROTECTED) | (STATIC, STATIC) | (MUT, MUT)
            | (OPEN, OPEN) | (OVERRIDE, OVERRIDE) | (REDEF, REDEF) => true
        case _ => false
    }
}
