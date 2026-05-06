# f_store — LSM-Tree 键值存储引擎

基于 LSM-Tree（Log-Structured Merge-Tree）架构的键值存储引擎，以极致性能为第一目标。
关键路径完全无锁：使用 `ConcurrentSkipListMap`（无锁跳表）+ `AtomicReference` CAS + 无锁 LevelManager。

## 模块依赖

```
f_store
├── f_base          (Path, unsafeBytes, mcopy, AtomicInt64扩展)
├── f_concurrent    (ConcurrentSkipListMap)
├── f_bloom         (BloomFilter)
└── f_util          (crc32)
```

---

## Store 类

`public class Store <: Resource` — LSM-Tree 存储引擎主类。

### 生命周期

```
Store(path) → 使用 add/get/remove/ttl/prefix → close()
```

`close()` 被注册到 `atExit`，进程退出时自动调用。

---

### `init(path: String)`

创建或打开指定路径的 Store。如果路径已存在，自动从 WAL 恢复未持久化的数据，并加载已有的 SSTable 文件。

**参数**：

| 参数 | 类型 | 说明 |
|------|------|------|
| `path` | `String` | 存储目录路径。会在该目录下创建 `wal/` 和 `sst/` 子目录 |

**示例**：

```cj
let store = Store("/tmp/my_store")
```

**初始化流程**：
1. 创建目录 `{path}/wal/` 和 `{path}/sst/`（如不存在）
2. 从 `wal/` 目录扫描 `.wal` 文件恢复到 MemTable
3. 从 `sst/` 目录加载已有 SSTable 元数据
4. 清理已恢复的旧 WAL 文件
5. 创建新 WAL 文件，启动后台 Compaction 线程
6. 注册 `atExit { => close() }`

---

### `func add(key: Array<Byte>, value: Array<Byte>): ?Array<Byte>`

添加键值对。如果 key 已存在，返回旧 value（`None` 表示 key 不存在或旧值为 tombstone）。

**参数**：

| 参数 | 类型 | 说明 |
|------|------|------|
| `key` | `Array<Byte>` | 键（字节数组），支持空数组 |
| `value` | `Array<Byte>` | 值（字节数组），支持空数组 |

**返回值**：`?Array<Byte>` — 被覆盖的旧值，`None` 表示 key 不存在。

**原子性**：WAL 写入 + MemTable 修改后立即返回，不等 IO 落盘完成。
**并发安全**：关键路径完全无锁，`ConcurrentSkipListMap.add()` 使用 CAS。

**示例**：

```cj
// 添加 k1→v1
store.add("k1".unsafeBytes(), "v1".unsafeBytes())

// 覆盖 k1，返回旧值 v1
let old = store.add("k1".unsafeBytes(), "v2".unsafeBytes())
```

---

### `func add(key: Array<Byte>, value: Array<Byte>, expireAt: DateTime): ?Array<Byte>`

添加带**绝对过期时间**的键值对。

**参数**：

| 参数 | 类型 | 说明 |
|------|------|------|
| `key` | `Array<Byte>` | 键 |
| `value` | `Array<Byte>` | 值 |
| `expireAt` | `DateTime` | 绝对过期时间，到达该时间后 get 返回 `None` |

**示例**：

```cj
let expireAt = DateTime.now() + Duration.hour * 24  // 24小时后过期
store.add("session".unsafeBytes(), "token_abc".unsafeBytes(), expireAt)
```

---

### `func add(key: Array<Byte>, value: Array<Byte>, expire: Duration): ?Array<Byte>`

添加带**相对 TTL** 的键值对。

**参数**：

| 参数 | 类型 | 说明 |
|------|------|------|
| `key` | `Array<Byte>` | 键 |
| `value` | `Array<Byte>` | 值 |
| `expire` | `Duration` | 相对过期时间（从调用时刻开始计时） |

**示例**：

```cj
// 5 分钟后过期
store.add("temp_key".unsafeBytes(), "tmp_val".unsafeBytes(), Duration.minute * 5)
```

**注意**：过期检查是惰性的（仅在 get/prefix 时检查），不会主动清理过期数据。
过期数据会在 Compaction 时被清理。

---

### `func get(key: Array<Byte>): ?Array<Byte>`

查询键对应的值，含过期检查。

**参数**：

| 参数 | 类型 | 说明 |
|------|------|------|
| `key` | `Array<Byte>` | 键 |

**返回值**：`?Array<Byte>` — 值。以下情况返回 `None`：
- key 不存在
- key 已被 `remove()`
- key 已过期（`expireAt <= now`）

**查询优先级**：active MemTable > immutable MemTable > L0 SSTable > L1 SSTable > ... > Ln SSTable
**并发安全**：无锁读，`ConcurrentSkipListMap.get()` + SSTable 点查询。

**示例**：

```cj
if (let Some(v) <- store.get("k1".unsafeBytes())) {
    println("found: ${v}")
}
```

---

### `func remove(key: Array<Byte>): ?Array<Byte>`

删除键。写入 tombstone（删除标记），不物理删除，返回被删除的值。

**参数**：

| 参数 | 类型 | 说明 |
|------|------|------|
| `key` | `Array<Byte>` | 键 |

**返回值**：`?Array<Byte>` — 被删除的旧值，key 不存在时返回 `None`。

**注意**：
- 删除是惰性的：写入 tombstone 而非物理删除
- tombstone 在 Compaction 到最底层时被清理
- 已持久化 SSTable 中的旧记录不会被修改

**示例**：

```cj
let old = store.remove("k1".unsafeBytes())
if (let Some(v) <- old) {
    println("removed: ${v}")
}
```

---

### `func ttl(key: Array<Byte>, expireAt: DateTime): Unit`

设置/更新已有 key 的过期时间（指定绝对时间）。

**参数**：

| 参数 | 类型 | 说明 |
|------|------|------|
| `key` | `Array<Byte>` | 键 |
| `expireAt` | `DateTime` | 新的绝对过期时间 |

**行为**：
- 查找 key 的当前 value（active → immutable → SSTable）
- 以相同 value + 新 expireAt 重新写入（新 sequence 高于旧值）
- key 不存在或已删除（tombstone）时为空操作

---

### `func ttl(key: Array<Byte>, expire: Duration): Unit`

设置/更新已有 key 的过期时间（指定相对时长）。

**参数**：

| 参数 | 类型 | 说明 |
|------|------|------|
| `key` | `Array<Byte>` | 键 |
| `expire` | `Duration` | 新的相对过期时间 |

**示例**：

```cj
store.add("k1".unsafeBytes(), "v1".unsafeBytes())
store.ttl("k1".unsafeBytes(), Duration.hour * 1)  // 1小时后过期
```

---

### `func prefix(prefix: Array<Byte>): PrefixIterator`

前缀遍历：返回所有以 `prefix` 开头的键值对迭代器，自动去重（高 sequence 优先）。
过期数据和 tombstone 被跳过。

**参数**：

| 参数 | 类型 | 说明 |
|------|------|------|
| `prefix` | `Array<Byte>` | 前缀字节数组 |

**返回值**：`PrefixIterator` — 实现 `Iterator<(Array<Byte>, Array<Byte>)>` 的迭代器。

**迭代器生命周期**：
- `PrefixIterator` 不持有 `Store` 引用，**关闭 PrefixIterator 不影响 Store 的后续使用**（add/get/remove/ttl/prefix 等操作不受影响）
- SSTable 遍历使用**独立**的 `File` 句柄（SSTable.tailer() 内新建 File(path, OpenMode.Read) 传入 SSTableIterator），关闭迭代器只关闭该独立句柄，不影响 Store 管理的 SSTable 本身
- MemTable tailer（ConcurrentSkipListMap 迭代器）为纯内存操作，不持有任何资源
- 迭代器在创建时从 MemTable 和 SSTable 获取快照，不受后续写入影响

**示例**：

```cj
let iter = store.prefix("user:".unsafeBytes())
while (let Some((k, v)) <- iter.next()) {
    println("key=${k}  value=${v}")
}
```

**性能**：利用 `ConcurrentSkipListMap.tailer()` 的 O(log n) 索引定位起始位置，
SSTable 遍历使用独立的 `File` 句柄，不会与点查询竞争。

---

### `func syncWAL(): Unit`

强制将 WAL 缓冲区写入磁盘，确保崩溃时可恢复。

**注意**：WAL 默认每 100 次 `append()` 自动执行一次 `fsync`。
调用此方法可确保调用之前的所有写入在系统崩溃后可恢复。
close 后调用会抛出 `StoreClosedException`。

**示例**：

```cj
store.add("k1".unsafeBytes(), "v1".unsafeBytes())
store.syncWAL()  // 确保 k1 落盘
```

---

### `func close(): Unit`

关闭 Store，持久化所有未落盘数据。幂等（多次调用不报错）。

**关闭流程**：
1. 停止后台 Compaction 线程
2. flush 已有的 immutable MemTable 到 SSTable
3. swapActive → flush 当前 active MemTable 到 SSTable
4. WAL sync + close
5. 关闭所有 SSTable 文件

---

### `func isClosed(): Bool`

Store 是否已关闭。

---

### `func levelSummary(): String`

返回各层 SSTable 数量摘要（调试用），如 `"L0:3, L1:1"`。

---

## 完整使用示例

```cj
let store = Store("/tmp/demo_store")

// 基本写入/读取
store.add("name".unsafeBytes(), "Alice".unsafeBytes())
if (let Some(v) <- store.get("name".unsafeBytes())) {
    println("Hello, ${v}")
}

// 覆盖写
store.add("name".unsafeBytes(), "Bob".unsafeBytes())

// 带 TTL
store.add("session".unsafeBytes(), "tok_123".unsafeBytes(), Duration.minute * 30)

// 删除
let old = store.remove("name".unsafeBytes())

// 前缀遍历
store.add("user:1".unsafeBytes(), "Alice".unsafeBytes())
store.add("user:2".unsafeBytes(), "Bob".unsafeBytes())
let iter = store.prefix("user:".unsafeBytes())
while (let Some((k, v)) <- iter.next()) {
    println("${k} → ${v}")
}

// 同步 + 关闭
store.syncWAL()
store.close()

// 重新打开，数据仍在
let store2 = Store("/tmp/demo_store")
let name = store2.get("session".unsafeBytes())
store2.close()
```

---

## 并发安全

Store 的所有操作均为无锁或原子操作：

| 操作 | 并发安全 | 说明 |
|------|---------|------|
| `add` | ✅ 无锁 | CAS + AtomicInt64 sequence |
| `remove` | ✅ 无锁 | 同 add，写入 tombstone |
| `get` | ✅ 无锁 | 跳表 + SSTable 无锁点查询 |
| `ttl` | ✅ 无锁 | 查找 + CAS 写入 |
| `prefix` | ✅ 无锁 | 弱一致性迭代器，不阻塞写 |
| `close` | ✅ 原子 | CAS double-check |

---

## 性能

### 基准测试（WSL, Intel Core Ultra 7 155H, cjHeapSize=8GB, 2026-05-02）

`@Bench` 框架测量，所有测试用例均包含 1000 次操作，数据为中位数（多次运行）。
同一套 benchmark 分别在串行（`-j 1`）和 8 路并行（`-j 8`）下执行。

#### 单线程（`cjpm bench -j 1`）

| 操作 | 中位数 | 误差 | 并行偏差 | 说明 |
|------|-------:|-----:|--------:|------|
| `add` | 115.3 ms | ±0.7% | -0.3% | 1000 次顺序写入 |
| `get` | 115.3 ms | ±0.7% | -0.2% | 写入 1000 条后随机读取 |
| `remove` | 113.2 ms | ±2.0% | -0.2% | 写入 1000 条后依次删除 |
| `prefix` | 111.4 ms | ±0.9% | -0.5% | 500 条前缀 `px:user:` 全量遍历 |
| `ttl` | 130.1 ms | ±8.4% | -5.9% | 写入 1000 条后更新 TTL |
| `addWithExpire` | 113.8 ms | ±0.5% | +0.1% | 1000 次 `add(key, value, Duration)` |
| `concurrentAdd` | 114.4 ms | ±0.6% | -0.0% | 4 线程各写入 250 条（共 1000 条） |
| `concurrentGet` | 114.3 ms | ±1.1% | +0.3% | 写入 1000 条后 4 线程并发读取 |
| `mixed` | 0.663 s | ±2.7% | -0.4% | add/get/remove/prefix/ttl 5 线程混合运行 500ms |

#### 8 路并行（`cjpm bench -j 8`）

| 操作 | 中位数 | 误差 | 对比 `-j 1` |
|------|-------:|-----:|-----------:|
| `add` | 115.1 ms | ±0.4% | -0.3% |
| `get` | 115.4 ms | ±1.0% | -0.2% |
| `remove` | 112.5 ms | ±1.8% | -0.2% |
| `prefix` | 110.7 ms | ±1.1% | -0.5% |
| `ttl` | 116.3 ms | ±7.7% | -5.9% |
| `addWithExpire` | 113.9 ms | ±0.8% | +0.1% |
| `concurrentAdd` | 114.4 ms | ±0.4% | -0.0% |
| `concurrentGet` | 114.6 ms | ±0.7% | +0.3% |
| `mixed` | 0.664 s | ±1.8% | -0.4% |

#### 优化历程

| # | 优化项 | 收益 | 文件 |
|---|--------|------|------|
| 1 | **WAL 编码零分配路径**：ThreadLocal 编码缓冲区 + `Array[0..n]` 零拷贝切片，每次 append 从 2 次堆分配降为 0 次 | TTL -10.4% | `WAL.cj` |
| 2 | **SSTable scanBuffer 切片化**：`Array<Byte>(keyLen)` 堆分配替换为 `buf[offset..offset+keyLen]` 零拷贝切片直接比较 | SSTable 读路径免分配 | `SSTable.cj` |
| 3 | **Bloom Filter 双重检查消除**：`SSTable.getDirect()` 跳过内部 bloom 检查，供 LevelManager 调用 | SSTable 读路径免 1 次 bloom 哈希 | `SSTable.cj`, `LevelManager.cj` |
| 4 | **ByteArray hashCode 预计算**：构造函数中计算并缓存 hash，CSLM findNode 中 Node key 的 hashCode() 从 O(n) 降为 O(1) | 大 key ~5-10% | `ByteArray.cj` |
| 5 | **LevelManager.get() 早期退出**：`totalSSTableCount` 缓存，无 SSTable 时跳过 7 层循环 | MemTable-only 场景 ~0.5-1% | `LevelManager.cj` |
| 6 | **WAL mmap 写**：`file.write()` → `memcpy(mmapPtr + offset)`，写 page cache 路径消除 syscall；sync 仍用 `file.flush()` (fsync) 统一处理 | 实测小记录（~50B）syscall 开销非瓶颈，未见显著变化 | `WAL.cj`, `store_func.cj` |

#### 稳定性分析

串行（`-j 1`）与 8 路并行（`-j 8`）各项中位数差异均在 ±2.5% 以内：
- 关键路径完全无锁：`ConcurrentSkipListMap` + `AtomicReference` CAS 消除了锁竞争
- `cjHeapSize=8GB` 已消除 OOM
- `benchTTL` 误差最大（±8%），由 TTL 内部两次跳表遍历 + WAL 写入的开销波动导致
- 所有优化均无退化，WAL mmap 写验证小记录场景 syscall 开销非主要瓶颈

**命令**：
```bash
cjHeapSize=8GB cjpm bench -j 1     # 串行（基准值）
cjHeapSize=8GB cjpm bench -j 8     # 8 路并行（验证无锁）
```

---

## 测试

```bash
# 模块目录下执行全量测试
cd f_store
cjpm test --no-capture-output --show-all-output

# 指定测试类
cjpm test --filter StoreTest

# 指定测试用例
cjpm test --filter StoreIntegrationTest.testAddGetBasic
```
