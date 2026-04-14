## `ValueEqualMapKK, V>` 与 `ValueContainsMap<K, V>`
这是两个接口，所有Map实现和ConcurrentHashMap都可以增加这两个接口的扩展
```cj
public interface Values<V> {
    func values(): Collection<V>
}
public interface ValueContainsMap<K, V> <: Values<V> where K <: Equatable<K> {
    /**
     * 确认当前Map是否包含predicate返回true的值
     */
    func containsValue(predicate: (V) -> Bool): Bool
}
public interface ValueEqualMap<K, V> <: Values<V> where K <: Equatable<K>, V <: Equal<V> {
    /**
     * 确认当前Map是否包含与value相等的值
     */
    func containsValue(value: V): Bool
}
```
