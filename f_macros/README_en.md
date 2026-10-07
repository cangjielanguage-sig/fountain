# f_macros


## Decl extension

Decl extends this interface
```cj
public interface ExtendDecl {
    /**
     * Returns the generic parameters of the Decl, or empty Tokens when there are none
     */
    prop genericParamTokens: Tokens
}
```


## FuncDecl extension

public interface ExtendFuncDecl <: ExtendMember {
    /**
     * Whether it is a mut function
     */
    func isMut(): Bool
    /**
     * Whether it is an open function
     */
    func isOpen(): Bool
    /**
     * Whether it is a static function
     */
    func isStatic(): Bool
}
```


## Type member extension

VarDecl, FuncDecl, PrimaryCtorDecl and PropDecl all implement this interface extension
```cj
public interface ExtendMember {
    /**
     * Whether it is a public member
     */
    func isPublic(): Bool
    /**
     * Whether it is a protected member
     */
    func isProtected(): Bool
    /**
     * Whether it is a private member
     */
    func isPrivate(): Bool
    /**
     * Whether it is an internal member
     */
    func isInternal(): Bool {
        !(isPublic() || isProtected() || isPrivate())
    }
}
```

### Property extension
```cj
public interface ExtendPropDecl <: ExtendMember {
    /**
     * Whether it is a mut property
     */
    func isMut(): Bool
    /**
     * Whether it is an open property
     */
    func isOpen(): Bool
    /**
     * Whether it is a static property
     */
    func isStatic(): Bool
}
```


## Variable extension

VarDecl implements this interface extension
```cj
public interface ExtendVarDecl <: ExtendMember {
    /**
     * Whether it is a var
     */
    func isVar(): Bool
    /**
     * Whether it is static
     */
    func isStatic(): Bool
}
```


## Modifier checks (`src/isModifier.cj`)

Checks modifiers on `Tokens` or `Decl`; most of them provide two overloads at the same time:

`isStatic`, `isAbstract`, `isSealed`, `isPublic`, `isPrivate`, `isProtected`, `isInternal`, `isMut`, `isOpen`, `isOverride`, `isRedef`, plus `isVar(param: FuncParam)`, which checks whether a function parameter is a `var`.

## Declaration extraction

| Function | Purpose |
|---|---|
| `extractFuncs(decls: Array<Decl>, extractPublic!: Bool = true): Array<FuncDecl>` | Get all function declarations |
| `extractProps` / `extractMutProps` / `extractReadOnlyProps` | Get property declarations (all/mutable/read-only) |
| `extractAllVars` / `extractVars(decls, extractPublic!, extractVar!, ...)` | Get variable declarations |
| `extractFirstDecl(input: Tokens): (Decl, Tokens)` | Take out the first declaration and the remaining tokens |
| `extractFirstTokenToStringLiteral(tokens, default!)` / `extractFirstTokenToIdentifier(tokens)` | Take the first token and turn it into a string literal/identifier |
| `extract(decl/expr/param)` and `extractIfOneOf(...)` | Unwrap macro expansion nodes, optionally filtering by macro name or a set of macro names |
| `replaceMacroInputDecl(...)` | Replace a declaration in the macro input |
| `withAnnotation<T>(decl)` / `withMacro(decl, macroName)` | Check whether a declaration carries the given annotation/macro |
| `primaryCtorParam(input: Tokens): FuncParam` | Get the parameters of the primary constructor |

## Others

- `topMacroAnonymousClosure(tokens: Tokens): Tokens`: wraps tokens into an anonymous closure, commonly used by top-level macros.
- The `Extend*` interfaces such as `ExtendToken` and `ExtendVarDecl`; the exception `MacroFragmentException`.
