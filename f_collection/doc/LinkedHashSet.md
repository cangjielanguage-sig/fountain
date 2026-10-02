## LinkedHashSet
```cj
/**
 * 按最近访问顺序遍历的HashSet
 */
public class LinkedHashSet<T> <: Set<T> where T <: Hashable & Equatable<T> {
    /**
     * 默认初始化的空集合
     */
    public init() 
    /**
     * 使用elements填充新的LinkedHashSet
     */
    public init(elements: Collection<T>) 
    /**
     * 使用elements填充新的LinkedHashSet
     */
    public init(elements: Array<T>) 
    /**
     * 新LinkedHashSet初始容量是size，
     * initElement的返回值用来填充LinkedHashSet，参数范围是0..size
     */
    public init(size: Int64, initElement: (Int64) -> T) 
}
```
