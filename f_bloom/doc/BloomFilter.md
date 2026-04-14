## BloomFilter

布隆过滤器（Bloom Filter）是一种空间效率高的概率型数据结构，用于判断一个元素是否可能存在于集合中。

### 特性

- **空间效率高**：使用位数组存储，内存占用远低于传统集合
- **可能存在误判**：如果元素不存在，一定返回 false；如果存在，可能返回 true（假阳性）
- **无锁并发安全**：使用 `AtomicUInt64` 实现无锁写入，多线程安全
- **自动优化参数**：根据预期元素数量和误判率自动计算最优的位数组大小和哈希函数数量

### 核心参数

| 参数 | 说明 |
|------|------|
| `n` | 预期元素数量 |
| `p` | 期望误判率 (0 < p < 1) |
| `m` | 位数组大小（自动计算） |
| `k` | 哈希函数数量（自动计算） |

### 构造函数

```cj
// 使用随机种子创建
let filter = BloomFilter.new(1000000, 0.01) // 预期100万元素，1%误判率

// 使用自定义种子创建（用于持久化或分布式场景）
let seeds = Array<UInt64>(k){i => ... }
let filter = BloomFilter.new(1000000, 0.01, seeds)
```

### 主要方法

```cj
// 添加元素
filter.add("hello")          // 添加 String
filter.add(someByteArray)    // 添加 Array<Byte>
filter.add(someToString)     // 添加实现了 ToString 的对象
filter.add(someHashable)     // 添加实现了 Hashable 的对象

// 查询元素
let exists = filter.mightContain("hello")  // 返回 Bool
```

### 注意事项

- 布隆过滤器不支持删除操作
- 误判率越低，所需内存空间越大
- 元素数量超过预期时，误判率会升高
