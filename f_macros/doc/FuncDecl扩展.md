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
