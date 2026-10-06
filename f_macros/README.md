# f_macros


## Decl扩展

Decl扩展此接口
```cj
public interface ExtendDecl {
    /**
     * 返回Decl的泛型参数，如果没有泛型则返回空的Tokens
     */
    prop genericParamTokens: Tokens
}
```


## FuncDecl扩展

public interface ExtendFuncDecl <: ExtendMember {
    /**
     * 是否mut函数
     */
    func isMut(): Bool
    /**
     * 是否open函数
     */
    func isOpen(): Bool
    /**
     * 是否static函数
     */
    func isStatic(): Bool
}
```


## 类型成员扩展

VarDecl FuncDecl PrimaryCtorDecl PropDecl FuncDecl都实现此接口扩展
```cj
public interface ExtendMember {
    /**
     * 是否public成员
     */
    func isPublic(): Bool
    /**
     * 是否protected成员
     */
    func isProtected(): Bool
    /**
     * 是否private成员
     */
    func isPrivate(): Bool
    /**
     * 是否internal成员
     */
    func isInternal(): Bool {
        !(isPublic() || isProtected() || isPrivate())
    }
}
```

### 属性扩展
```cj
public interface ExtendPropDecl <: ExtendMember {
    /**
     * 是否mut属性
     */
    func isMut(): Bool
    /**
     * 是否open属性
     */
    func isOpen(): Bool
    /**
     * 是否static属性
     */
    func isStatic(): Bool
}
```


## 变量扩展

VarDecl实现此接口扩展
```cj
public interface ExtendVarDecl <: ExtendMember {
    /**
     * 是否var
     */
    func isVar(): Bool
    /**
     * 是否static
     */
    func isStatic(): Bool
}
```


## 修饰符判定（`src/isModifier.cj`）

对`Tokens`或`Decl`判定修饰符，多数同时提供两个重载：

`isStatic`、`isAbstract`、`isSealed`、`isPublic`、`isPrivate`、`isProtected`、`isInternal`、`isMut`、`isOpen`、`isOverride`、`isRedef`，以及判定函数参数是否`var`的`isVar(param: FuncParam)`。

## 声明提取

| 函数 | 作用 |
|---|---|
| `extractFuncs(decls: Array<Decl>, extractPublic!: Bool = true): Array<FuncDecl>` | 取全部函数声明 |
| `extractProps` / `extractMutProps` / `extractReadOnlyProps` | 取属性声明（全部/可变/只读） |
| `extractAllVars` / `extractVars(decls, extractPublic!, extractVar!, ...)` | 取变量声明 |
| `extractFirstDecl(input: Tokens): (Decl, Tokens)` | 取出第一个声明及其剩余tokens |
| `extractFirstTokenToStringLiteral(tokens, default!)` / `extractFirstTokenToIdentifier(tokens)` | 取第一个token并转成字符串字面量/标识符 |
| `extract(decl/expr/param)` 与 `extractIfOneOf(...)` | 解包宏展开节点，可按宏名或宏名集合过滤 |
| `replaceMacroInputDecl(...)` | 替换宏输入里的声明 |
| `withAnnotation<T>(decl)` / `withMacro(decl, macroName)` | 判断声明是否带指定注解/宏 |
| `primaryCtorParam(input: Tokens): FuncParam` | 取主构造函数的参数 |

## 其他

- `topMacroAnonymousClosure(tokens: Tokens): Tokens`：把tokens包成匿名闭包，顶层宏常用。
- `ExtendToken`、`ExtendVarDecl`等`Extend*`接口；异常`MacroFragmentException`。

