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

**迭代器生命周期**：迭代器在创建时从 MemTable 和 SSTable 获取快照，不受后续写入影响。
使用完后不需要显式关闭（不持有文件句柄）。

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

详细并发安全分析见 [并发安全审查](#) 章节。

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
