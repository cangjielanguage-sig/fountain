## HashBuilder
```cj
/* 此类一般只作为局部变量使用，不会发生逃逸
   仓颉已支持类实例的逃逸分析和栈上分配
   按照HashBuilder_test的简单性能测试。
   每个append函数参数会尽量参与哈希计算，参数实现了Hashable的会调用参数的hashCode()再用这个哈希值执行哈希公式
 */
public class HashBuilder

/**
 * 调用一次，本类的实例回到初始状态
 */
public func build(): Int64
@OverflowWrapping
public func append(arg: Int64): This
public func append<T>(arg: T): This where T <: Hashable
//遍历参数的每个元素，逐个元素调用append函数
public func append<T, I>(args: I): This where T <: Hashable, I <: Iterable<T>
//遍历区间，每个区间值调用append函数
public func append<T>(args: Range<T>): This where T <: Hashable & Countable<T> & Comparable<T> & Equatable<T>
//调用参数的toString()函数，用这个字符串调用append
public func append(arg: StringGenerator): This
/**
 * 遍历参数，如果键和值实现了Hashable，则使用它们的哈希值分别调用append函数，
 * 如果实现了ToString则先调用toString()再调用append，都没有实现的用'_'调用append函数。
 */
public func append<K, V>(value: ConcurrentHashMap<K, V>): This where K <: Hashable & Equatable<K>
/**
 * 如果value实现了Hashable，使用参数的哈希值调用append函数，
 * 如果value实现了ToString，用参数的toString()结果调用append
 */
public func append(value: Any): This
/**
 * 如果参数扩展了Hashable，则用参数的哈希值调用append。
 * 否则遍历参数，每个键和值如果实现了Hashable，则分别用哈希值调用append，
 * 如果实现了ToString则用toString()的结果调用append
 */
private func append<K, V>(value: Map<K, V>): This where K <: Equatable<K>
```
