## `HashDict<K, V> <: Dict<K, V>
```cj
//哈希字典
public class HashDict<K, V> <: Dict<K, V> {
    /**
     * hasher用来计算K的哈希，equals用来比较两个K是否相等
     */
    public init(hasher: (K) -> Int64, equals: (K, K) -> Bool)
    /**
     * hasher用来计算K的哈希，equals用来比较两个K是否相等
     * elements用来初始化填充HashDict
     */
    public init(elements: Array<(K, V)>, hasher: (K) -> Int64, equals: (K, K) -> Bool)
    public init(elements: Collection<(K, V)>, hasher: (K) -> Int64, equals: (K, K) -> Bool)
    /**
     * hasher用来计算K的哈希，equals用来比较两个K是否相等
     * 初始容量是size
     */
    public init(size: Int64, hasher: (K) -> Int64, equals: (K, K) -> Bool)
    /**
     * hasher用来计算K的哈希，equals用来比较两个K是否相等
     * 初始容量是size，
     * initElement用来返回初始化的键值对，传入的参数范围是0 .. size
     */
    public init(size: Int64, initElement: (Int64) -> (K, V), hasher: (K) -> Int64, equals: (K, K) -> Bool) 
}
```
