布隆过滤器
===

```cj
public class BloomFilter {
    public  let size: Int64
    /**
     * 初始化过滤器
     * @param n 预期元素数量
     * @param p 期望误判率
     */
    public static func new(n: Int64, p: Float64): BloomFilter
    /**
     * 初始化过滤器
     * @param n 预期元素数量
     * @param p 期望误判率
     * @param seeds 随机数种子，使用这些种子生成相同数量的哈希函数
     */
    public static func new(n: Int64, p: Float64, seeds: Array<UInt64>): BloomFilter
    public prop seeds: Iterator<UInt64> 
    /**
     * 添加元素 (无锁并发安全)
     */
    public func add(element: Array<Byte>): Unit 
    /**
     * 添加元素，使用字符串的UTF8字节数组计算哈希
     */
    public func add(element: String): Unit 
    /**
     * 添加元素，把参数转为字符串，再使用字符串的UTF8字节数组计算哈希
     */ 
    public func add(element: ToString): Unit 
    /**
     * 添加元素，参数的哈希值转成的字节数组计算哈希
     */
    public func add(element: Hashable): Unit 
    /**
     * 查询元素 (无锁并发安全)
     */
    public func mightContain(element: Array<Byte>): Bool 
    /**
     * 查询元素，使用参数的UTF8字节数组计算哈希
     */
    public func mightContain(element: String): Bool 
    /**
     * 查询元素，使用参数的哈希值转成的字节数组计算哈希
     */
    public func mightContain(element: Hashable): Bool 
    /**
     * 查询元素，使用参数转成的字符串的UTF8字节数组计算哈希
     */
    public func mightContain(element: ToString): Bool 
}
```