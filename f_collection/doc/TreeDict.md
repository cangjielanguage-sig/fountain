## TreeDict
```cj
/**按指定比较函数比较的排序树字典*/
public class LinkedHashDict<K, V> <: Dict<K, V> {
    /**
     * 用指定比较函数实例化字典
     */
    public TreeDict(private let cmp: (K, K) -> Ordering)
    /**
     * 用elements作为初始元素和指定的比较函数实例化字典
     */
    public init(elements: Array<(K, V)>, cmp: (K, K) -> Ordering)
    /**
     * 用elements作为初始元素和指定的比较函数实例化字典
     */
    public init(elements: Collection<(K, V)>, cmp: (K, K) -> Ordering)
    /**
     * 用指定的比较函数实例化字典，初始容量是size，initElement用来返回初始化的键值对，传入的参数范围是0 .. size
     */
    public init(size: Int64, initElement: (Int64) -> (K, V), cmp: (K, K) -> Ordering)
}
```
