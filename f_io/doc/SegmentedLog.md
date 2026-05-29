# SegmentedLog

固定大小分段、纯顺序追加的写日志。通用层，接管文件 I/O + 轮转 + 同步。供 `f_store::WAL` 和未来 MQ 模块复用。

---

## API 使用说明

### 配置

```cj
let config = LogConfig(
    dir: "/tmp/mylog",          // 日志目录
    filePrefix: "wal",          // 文件名前缀，生成 "wal_1.log", "wal_2.log", ...
    maxFileSize: 64 * 1024 * 1024, // 每个 segment 最大字节数
    syncInterval: 10,           // 每 10 次 append 自动 fsync；<= 0 表示每次都 sync
    startSeq!: 1,               // (命名参数，默认 1) 起始 sequence 号
    fileExt!: ".log"            // (命名参数，默认 ".log") 文件扩展名
)
```

### 创建实例

```cj
// 方式一：自动生成初始文件名 "{dir}/{filePrefix}_{startSeq}{fileExt}"
let log = SegmentedLog(config)

// 方式二：指定初始文件路径。rotate() 时仍使用 config 生成后续文件名
let log = SegmentedLog(config, initPath: "/tmp/custom/path_1.log")
```

### 追加数据

```cj
let data: Array<Byte> = ...
let pos: LogPosition = log.append(data)
// pos.seq   — segment 序号
// pos.offset — 段内偏移（该 segment 文件中的起始字节位置）
```

返回的 `LogPosition` 可用作写入位置的持久化凭证，用于崩溃恢复时的确认点追踪。

### 强制刷盘

```cj
log.sync()  // fsync 当前 segment
```

### 主动轮转

```cj
log.rotate()  // 关闭当前 segment 并创建新 segment
```

通常在 checkpoint 后调用，配合 `takeOldFiles()` 清理旧文件。

### 获取已轮转的文件

```cj
let oldFiles = log.takeOldFiles()
// 返回 ArrayList<String>，包含所有已轮转的旧文件路径
// 调用后内部列表被清空
```

外部负责对返回的旧文件执行删除或归档操作。

### 关闭日志

```cj
log.close()  // 实现 Resource 接口，可用 try-with-resource
```

---

## 实现思想与技术原理

### 设计目标

SegmentedLog 的核心需求：

1. **顺序追加** — 只写不读，写入即落盘，不提供读取 API
2. **固定大小分段** — 单文件不无限增长，到达阈值后自动轮转
3. **高性能** — 最小化用户态到内核态的切换次数
4. **跨平台** — Linux 用 mmap 零拷贝写入，非 Linux 回退 `file.write()`

### 架构概览

```
SegmentedLog
 ├─ LogConfig        // 配置参数（目录、前缀、大小、sync 间隔等）
 ├─ File (当前)       // 当前写入的文件句柄
 ├─ mmapPtr          // Linux: mmap 映射地址；非 Linux: null
 ├─ 状态变量
 │   ├─ seq          // 当前 segment 序号（AtomicInt64）
 │   ├─ currentSize  // 当前 segment 已写入字节数（AtomicInt64）
 │   ├─ appendCount  // 累计 append 次数，用于周期性 sync（AtomicInt64）
 │   └─ closed       // 关闭标志（AtomicBool）
 ├─ oldFiles         // 已轮转的旧文件路径列表（ArrayList<String>）
 ├─ appendLock       // Mutex，保护 append + rotate 临界区
 └─ oldFilesLock     // Mutex，保护 oldFiles 并发访问
```

### 写入路径（Linux）

```
用户调用 append(data)
  │
  ├─ closed 检查 → 已关闭则抛 LogClosedException
  │
  ├─ synchronized(appendLock) {
  │     ├─ (双层检查) closed 重检
  │     ├─ 超限检查: currentSize + data.size > maxFileSize → 自动 rotate
  │     ├─ mcopy(mmapPtr + pos, data)    ← 零 syscall，直接写 page cache
  │     ├─ currentSize += data.size
  │     └─ 周期性 sync → file.flush()    ← fsync 刷盘
  │   }
  │
  └─ 返回 LogPosition(seq, pos)
```

核心优化在于 `memcpy` 到 `mmap` 区域这一操作：它不触发任何系统调用，数据直接写入操作系统的 page cache，内核在后台异步将脏页回写到磁盘。这种"零 syscall 写入"是 SegmentedLog 高性能的基础。

非 Linux 平台回退到 `file.write(data)`，每次写入都会经过 `write()` 系统调用。

### 轮转机制（rotate）

当 `currentSize + data.size > maxFileSize` 时自动触发，也可手动调用：

```
doRotate()
  ├─ syncImpl()                          // 刷盘当前 segment
  ├─ munmap(mmapPtr, maxFileSize)        // 解除映射（Linux）
  ├─ file.close()                        // 关闭当前文件
  ├─ oldFiles.add(curPath)               // 记录旧路径
  ├─ seq += 1
  ├─ File(newPath, ReadWrite)            // 创建新文件
  ├─ ftruncate + fallocate + mmap        // 映射新文件（Linux）
  └─ currentSize = 0, appendCount = 0
```

`startSeq` 默认从 1 开始，文件名格式为 `{prefix}_{seq}.{ext}`，如 `wal_1.log`、`wal_2.log`。

### 刷盘策略

`syncInterval` 参数控制自动 fsync 的频率：

- **syncInterval <= 0**：每次 `append` 后都执行 `file.flush()`，最大程度保证数据安全
- **syncInterval > 0**：每 N 次 append 执行一次 `file.flush()`。例如 `syncInterval = 10` 表示第 1、11、21...次 append 后刷盘

`syncImpl()` 统一调用 `file.flush()`，在 Linux 下等价于 `msync()` + `fsync()`，将 mmap 脏页写回磁盘。

### 线程安全

SegmentedLog 是线程安全的，通过以下机制实现：

| 场景 | 保护机制 |
|------|----------|
| append + rotate 互斥 | `appendLock`（Mutex）保护整个临界区，包括超限检查、写入、sync |
| oldFiles 并发访问 | `oldFilesLock`（Mutex）保护 `takeOldFiles()` 和 `doRotate()` 中的 add |
| close 与 append 的竞态 | `closed` 标志位用 `AtomicBool` 的 CAS 确保仅首次生效，`synchronized(appendLock)` 等待正在进行的 append 完成 |
| 状态变量的可见性 | `seq`、`currentSize`、`appendCount` 均使用 `AtomicInt64`，`Mutex` 提供 acquire/release 语义 |

### 关闭协议

```cj
public func close(): Unit {
    if (!closed.compareAndSwap(false, true)) { return }
    synchronized (appendLock) {
        syncImpl()
        unmapFile(mmapPtr, maxFileSize)   // Linux
        if (!file.isClosed()) { file.close() }
    }
}
```

双保险设计：

1. **CAS** `closed` 标志 — 确保 `close()` 只执行一次，后续调用立即返回
2. **synchronized(appendLock)** — 确保没有正在进行的 `append()`，防止 close 与写入并发
3. 在锁内执行最后的 sync + 解除映射 + 关闭文件

### 跨平台条件编译

| 方法 | Linux 行为 | 非 Linux 行为 |
|------|-----------|--------------|
| `initFileMapping` | `ftruncate + fallocate + mmap(MAP_SHARED)` | 返回 `CPointer<Byte>()`（null） |
| `unmapFile` | `munmap(ptr, size)` | 空操作 |
| `writeImpl` | `memcpy(mmapPtr + pos, data)` — 零 syscall | `file.write(data)` |
| `syncImpl` | `file.flush()` — 实际触发 `msync + fsync` | `file.flush()` |

### 与 WAL 的关系

SegmentedLog 最初是为 `f_store::WAL`（Write-Ahead Log）提取的通用层。WAL 的核心约束与 SegmentedLog 的设计完全吻合：

- **顺序追加** — WAL 只追加不修改
- **分段管理** — 固定大小文件便于旧 segment 的 checkpoint 后删除
- **可配置 fsync 频率** — WAL 可在性能与持久性之间权衡
- **崩溃恢复** — `LogPosition` 可作为确认点，记录已写入的 segment 和偏移

### 使用模式

典型生命周期：

```
1. 创建 SegmentedLog
2. 循环 append(data) ← 自动 rotate
3. 定期 checkpoint
4. takeOldFiles() → 删除已 checkpoint 的旧文件
5. close()
```

不提供读取 API，读取由上层模块（如 WAL 的 recovery）自行按文件名规则遍历旧文件执行 `pread`。
