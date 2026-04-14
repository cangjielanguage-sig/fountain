## LinkedHashMap
```cj
/**
 * 按最近访问顺序遍历的HashMap
 */
public class LinkedHashMap<K, V> <: Map<K, V> where K <: Hashable & Equatable<K> {
    /**
     * 不设置最大容量
     */
    public init()
    /**
     * size是初始容量；max如果是true，size也是初始容量
     */
    public init(size: Int64, max: Bool)
    /**
     * 将c的元素添加到新的LinkedHashMap
     */
    public init(c: Collection<(K, V)>)
    /**
     * 将c的元素添加到新的LinkedHashMap
     * size是初始容量；max如果是true，size也是初始容量
     */
    public init(c: Collection<(K, V)>, size: Int64, max: Bool)
    /**
     * size是初始容量；max如果是true，size也是初始容量
     * 用initElement的返回值填充新的LinkedHashMap，参数取值范围是0..size
     */
    public init(size: Int64, initElement: (Int64) -> (K, V))
}
```
