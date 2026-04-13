方便宏编程的模块

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
```cj
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

