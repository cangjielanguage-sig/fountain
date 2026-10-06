# f_bloom

`fountain::f_bloom` 提供布隆过滤器（Bloom Filter）实现

---

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
| `m` | 位数组大小（自动计算，`bitCount`） |
| `k` | 哈希函数数量（自动计算，`seeds` 的个数） |

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

// 持久化：种子随数据一起序列化
let bytes = filter.serialize()
let restored = BloomFilter.deserialize(bytes)
```

公开成员：`n`、`p`（记录值）、`bitCount`（位数组长度）、`seeds`（哈希种子迭代器）、`new(n, p)`、`new(n, p, seeds)`、`add`/`mightContain` 的4个重载、`serialize()`、`deserialize(bytes)`。

### 注意事项

- 布隆过滤器不支持删除操作
- 误判率越低，所需内存空间越大
- 元素数量超过预期时，误判率会升高
- **`new(n, p)`的种子是随机生成的**：需要多实例判定一致或跨进程一致时，必须用`new(n, p, seeds)`或`deserialize`（`seeds` 会随序列化数据带回来）。
- **`deserialize`对脏数据静默兜底**：数据长度不足或位数组越界时返回`BloomFilter.new(1, 0.01)`，不抛异常。
- **不同重载的判定口径不同**：`Hashable`重载只按8字节`hashCode()`建/查，与`String`/`ToString`/`Array<Byte>`重载不互通，同一逻辑元素不要混用重载。
- `f_store`用它抑制SSTable/L0的读放大。
