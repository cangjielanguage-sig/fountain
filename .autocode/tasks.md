# SegmentedLog 模块抽象 — 开发计划

## 背景

f_store 的 WAL 使用 mmap 实现零 syscall 写入（`memcpy` 替代 `file.write()`），约 140 行通用 I/O 逻辑（mmap 初始化、轮转、同步、并发保护）与约 100 行 f_store 业务编码逻辑（记录格式、CRC、expireAt）同在一个类中。

同时，f_io 模块已有 mmap 封装（`MMapFile`、`mmap_native` 的 FFI 绑定），但存在逻辑缺陷，且 `MMapFile` 设计为通用 IOStream（支持随机读写），不适合 WAL/MQ 等纯顺序追加场景。

此外，f_log 模块也直接依赖了 f_io 的 mmap 封装（`RotatableMMapFile`），应清理为纯 file I/O。

**目标**：在 f_io 中实现 `SegmentedLog`，统一接管 mmap 文件 I/O + 轮转 + 同步，供 f_store WAL 和未来 MQ 模块复用。

---

## Step 1：确认并修复 f_io 现有 mmap 代码的问题

### 1.1 问题列表

#### P1 — `ToMMap.mmap()` 默认 flag 为 `Private`

**文件**: `f_io/src/MMapFile.cj`，第 291 行

```cj
public func mmap(offset: Int64, mapLength: Int64, flag!: MMapFlag = MMapFlag.Private): MMapFile {
```

**问题**：当前 WAL 需要 `MAP_SHARED` 才能将写入同步到磁盘。`Private` 默认值对 WAL 场景不正确。

**影响**：SegmentedLog 不受影响（它自己传 `Shared`），但未来 `File.mmap()` 的新使用者容易误用。建议将默认值改为 `Shared` 以匹配常见文件映射场景。

#### P2 — `mmap_native.cj` 缺少 `ftruncate`/`fallocate` FFI 绑定

`ftruncate` 和 `fallocate` 在 `MMapFile` 中未使用（`MMapFile` 用 `File.setLength()` 替代），但 SegmentedLog 需要直接操作 fd 来做 `ftruncate + fallocate + mmap`。需在 `mmap_native.cj` 中补充。

> `memcpy` 需求：SegmentedLog 中直接使用 `fountain::f_base.mcopy`（已有公开 FFI 封装），`mmap_native.cj` 不新增 `memcpy` FFI。

`ftruncate` 和 `fallocate` 在 `MMapFile` 中未使用（`MMapFile` 用 `File.setLength()` 替代），但 SegmentedLog 需要直接操作 fd 来做 `ftruncate + fallocate + mmap`。需在 `mmap_native.cj` 中补充。

### 1.2 修复项汇总

| 优先级 | 文件 | 修改内容 | 性质 |
|--------|------|---------|------|
| P1 | `MMapFile.cj` 第 291 行 | `Private` → `Shared` 默认 flag | 默认值修正 |
| P2 | `mmap_native.cj` 第 66-74 行 | 新增 `ftruncate`/`fallocate` FFI 绑定（`memcpy` 使用 `f_base.mcopy`） | 补充 |

---

## Step 2：在 f_io 中实现 `SegmentedLog`

### 2.1 设计目标

- **纯顺序追加**，不支持随机写/重写
- **固定大小分段**（轮转日志模式）
- **Linux mmap** 零 syscall 写入，**非 Linux** 回退 `file.write()`
- **线程安全**（`appendLock` Mutex 保护临界区）
- **最小 API**，不引入 `IOStream` 等通用接口

### 2.2 类设计

**包路径**: `fountain::f_io`

```cj
public struct LogPosition {
    // segment 序号（文件名中的 sequence）
    seq: Int64
    // segment 文件中的偏移量
    offset: Int64
}
```

```cj
public struct LogConfig {
    // 日志目录
    dir: String
    // 文件名前缀，如 "wal" → 生成 "wal_1.log", "wal_2.log"...
    filePrefix: String
    // 每个 segment 文件的最大大小（bytes）
    maxFileSize: Int64
    // 自动 fsync 间隔（append 次数），<= 0 表示每次 append 都 sync
    syncInterval: Int64
    // 起始 sequence 号
    startSeq: Int64 = 1
    // 文件扩展名（含点），默认 ".log"
    fileExt: String = ".log"
}
```

```cj
@When[os == "Linux"]
public class SegmentedLog <: Resource {
    // ===== 公共 API =====

    init(config: LogConfig)

    /** 追加数据到当前 segment。返回写入的实际字节数 */
    func append(data: Array<Byte>): LogPosition

    /** 强制 fsync 当前 segment */
    func sync(): Unit

    /** 主动轮转：关闭当前 segment，创建新 segment（用于 checkpoint 后清理） */
    func rotate(): Unit

    /** 关闭所有资源 */
    public func close(): Unit
    public func isClosed(): Bool

    /** 获取已轮转的旧文件路径列表（外部负责删除清理），并清空内部列表 */
    func takeOldFiles(): ArrayList<String>

    /** 当前写入位置（累积字节数，所有 segment 累计） */
    prop writeOffset: Int64

    // ===== 内部实现 =====

    // @When[os == "Linux"]
    // init: ftruncate(fd, maxFileSize) → fallocate(fd, 0, 0, maxFileSize) → mmap(...)
    // append: synchronized(appendLock) { check closed → rotate if full → memcpy(mmapPtr + wPos, data) → currentPos += size → periodic sync }
    // sync: file.flush() (fsync, not msync)
    // rotate: sync → munmap → close file → oldFiles.add(path) → open new File → ftruncate+fallocate+mmap
    // close: CAS closed → synchronized(appendLock) { sync → munmap → close file }

    // @When[os != "Linux"]
    // append: synchronized(appendLock) { file.write(data) }
    // (rest is same, just no mmap)
}
```

### 2.3 与 `MMapFile` 的差异

| 维度 | `MMapFile` | `SegmentedLog` |
|------|-----------|---------------|
| 写方式 | `BytePointerStream.write()`（抽象流） | 裸 `memcpy(mmapPtr + offset, data)` |
| 同步 | `msync(MSYNC_FLAG)` | `file.flush()` (fsync) |
| 文件准备 | 调用者负责 | 内置 `ftruncate + fallocate` |
| 轮转 | 不支持（`remap` 是重映射） | 内置 `rotate()` |
| 并发安全 | ❌ 无锁 | ✅ `appendLock` Mutex |
| `@When` 非 Linux | ❌ 不支持（仅 Linux） | ✅ `file.write()` 回退 |
| API 风格 | 通用 `IOStream`（read/write/seek） | 专用 `append-only` |

### 2.4 文件组织

```
f_io/src/
├── SegmentedLog.cj          # 新文件：SegmentedLog 主类
├── LogConfig.cj              # 新文件：LogConfig struct（可内联进 SegmentedLog.cj）
└── mmap_native.cj            # 修改：新增 memcpy/ftruncate/fallocate FFI
```

### 2.5 涉及的现有 import

SegmentedLog 需要：
- `f_io::mmap_native.*` — `MMapProt`, `MMapFlag`, `mmap()`, `munmap()`, `msync()`
- `f_base::memcpy` / `f_base::mcopy` — 零 syscall 写入（或 f_io 自建 FFI）
- `std.sync.Mutex` — appendLock
- `std.fs.*` — File, Directory, exists, OpenMode
- `std.sync.AtomicInt64`, `std.sync.AtomicBool`
- `std.core.Resource`

### 2.6 非 Linux 回退

`@When[os != "Linux"]` 版本的 SegmentedLog 不使用 mmap，全部使用 `file.write()`。这种写法已有 WAL 的先例（`writeRecord()` 的 `@When` 双版本模式）。

---

## Step 3：清除 f_log 对 f_io mmap 封装的依赖

### 3.1 背景

f_log 中以下文件直接使用 f_io 的 mmap 封装：

| 文件 | 依赖 |
|------|------|
| `f_log/src/output/RotatableMMapFile.cj` | `import fountain::f_io.*` → `MMapFile` |
| `f_log/src/output/RotatableFile.cj` | `import fountain::f_io.*` → `MMapFile`, `File.mmap()` |
| `f_log/src/impl/FileLoggerAppender.cj` | 配置 `mmap` flag，条件性调用 `rf.mmap()` |

### 3.2 清理方案

| 文件 | 操作 | 原因 |
|------|------|------|
| `RotatableMMapFile.cj` | **删除整个文件** | mmap 在日志场景不适合（文件增长管理复杂） |
| `RotatableFile.cj` | 移除 `@When[os == "Linux"]` 的 `mmapf` 字段、`mmap()` 方法、`close()` 中的 mmap 分支、`rotate()` 中的 mmap 重映射 | 统一走纯 file I/O |
| `FileLoggerAppender.cj` | 多处改动：<br>① `toPath()` 中移除 `case x: RotatableMMapFile => x.path`（第 35 行）<br>② `FileLoggerParams` 移除 `protected let mmap: Bool` 字段（第 57 行）<br>③ `HashBuilder` 中移除 `mmap`（第 60 行）<br>④ `==` 操作符中移除 `mmap` 比较（第 64 行）<br>⑤ `newParams()` 中移除 `let mmap = LoggerConfig.getLogFileMMap(appender)`（第 86 行）<br>⑥ `newParams()` 的 `FileLoggerParams(...)` 调用中移除 `mmap` 参数（第 88 行）<br>⑦ `newAppender()` 中移除 `@When[os == "Linux"]` 条件 mmap 分支（第 96-101 行） | 不再需要 mmap 配置 |
| `LoggerConfig.cj` | 移除 `getLogFileMMap()` 整个方法（第 89-91 行），即删除 "mmap" 配置键的读取 | 不再需要 mmap 配置 |
| `f_log/cjpm.toml` | **移除 `fountain::f_io` 依赖**（如果不再有其他 f_io 引用） | 但 `DummyOutputStream` 在`AsyncLogger`/`LoggerAppenderFacade`/`LoggerWrapper`/`NoneLogAppender` 4 处仍有使用，**不能移除 f_io 依赖** |

### 3.3 影响的代码量

| 操作 | 增加(+) / 删除(-) 行数 |
|------|-----------------------|
| 删除 `RotatableMMapFile.cj` | -61 行 |
| `RotatableFile.cj` mmap 相关移除 | ~-30 行 |
| `FileLoggerAppender.cj` mmap 移除 | ~-15 行 |
| `LoggerConfig.cj` `getLogFileMMap` 移除 | ~-5 行 |
| **合计** | **~-111 行** |

---

## Step 4：改造 f_store WAL 依赖 `SegmentedLog`

### 4.1 当前 WAL 结构

```
WAL (240 行)
├── 通用 I/O (可抽象进 SegmentedLog)  ~140 行
│   ├── mmap 初始化/关闭
│   ├── 文件增长 & 轮转
│   ├── 同步策略
│   ├── 并发保护 (appendLock + closed CAS)
│   └── Resource 生命周期
│
└── f_store 特定编码逻辑              ~100 行
    ├── encodeDirect()
    ├── WALRecord / 记录格式
    ├── CRC32
    └── expireAt 逻辑
```

### 4.2 改造后的 WAL

```cj
class WAL <: Resource {
    // 持有的 SegmentedLog（mmap + 轮转 + 同步的通用层）
    private let segmentLog: SegmentedLog

    // f_store 特有的逻辑保留
    private let sequence: AtomicInt64
    private let encodeBuf = ThreadLocal<Array<Byte>>()

    init(path: String, startSequence!: Int64 = 0, maxFileSize!: Int64 = 64 * 1024 * 1024) {
        // 解析 dir + filePrefix
        // 初始化 SegmentedLog
        // 初始化 sequence
    }

    func append(key, value, expireAt): Int64 {
        // 1. 自增 sequence
        let seq = sequence.incrFetch()
        // 2. 零分配编码（encodeDirect，f_store 逻辑）
        let encoded = encodeDirect(seq, key, value, expireAt)
        // 3. 委托给 SegmentedLog.append()
        segmentLog.append(encoded)
        seq
    }

    func sync(): Unit { segmentLog.sync() }
    func takeOldFiles(): ArrayList<String> { segmentLog.takeOldFiles() }

    public func close(): Unit {
        if (!closed.compareAndSwap(false, true)) { return }
        segmentLog.close()
    }

    // encodeDirect() / WALRecord 逻辑保留不动
    private static func encodeDirect(...): Array<Byte> { ... }
}
```

### 4.3 需要调整的事项

| 事项 | 当前 | 改造后 |
|------|------|--------|
| WAL 文件路径 | `walDir/wal_${seq}.wal` | 由 SegmentedLog 内部管理（`dir/filePrefix_seq.ext`） |
| `currentFileSize` | WAL 的 `AtomicInt64` 字段 | SegmentedLog 内部维护 |
| `appendLock` | WAL 的 `Mutex` | SegmentedLog 内部持有 |
| `oldFiles` | WAL 的 `ArrayList<String>` + `oldFilesLock` | SegmentedLog 的 `takeOldFiles()` |
| `syncInterval` | WAL 硬编码 `100` | 通过 `LogConfig.syncInterval` 传入 |
| `mmapPtr` | WAL 的 `CPointer<Byte>` | SegmentedLog 内部持有 |

### 4.4 f_store 依赖变更

**f_store/cjpm.toml**：新增依赖

```toml
"fountain::f_io" = { path = "../f_io" }
```

### 4.5 清理 f_store 重复 FFI 绑定

f_store 当前在 `store_func.cj` 第 96-121 行有自己独立的 mmap FFI 绑定（`mmap`/`munmap`/`msync`/`ftruncate`/`fallocate`/`memcpy`）。

SegmentedLog 实现在 f_io 中后，这些绑定不再需要。一并清理：

| 文件 | 行号 | 操作 |
|------|------|------|
| `f_store/src/store_func.cj` | 94-122 | 删除整段 os == "Linux" 的 `const` + `foreign` 绑定 |

注意：`store_func.cj` 中 `pread` 和 `positionedRead`（第 77-92 行）属于 SSTable 读取逻辑，**保留不动**。

### 4.6 改造涉及代码量

| 操作 | 增加/删除行数 |
|------|--------------|
| WAL: 新增 `segmentLog` 字段 + 构造传参 | +3 行 |
| WAL: `append()` 中 `writeRecord` → `segmentLog.append` | -10 行 |
| WAL: `syncRecords()` → `segmentLog.sync()` | -7 行 |
| WAL: `rotate()` → `segmentLog.rotate()` | -20 行 |
| WAL: 移除 `mmapPtr`, `currentFileSize`, `appendLock`, `oldFiles`, `oldFilesLock`, `closed` 等字段 | -8 行 |
| WAL: `close()` 简化 | -10 行 |
| WAL: 移除 `writeRecord()` + `mmapFile()` + `unmapFile()` 共 6 个 `@When` 函数 | -36 行 |
| f_store/cjpm.toml 加 f_io 依赖 | +1 行 |
| store_func.cj 删除 mmap FFI | -28 行 |
| **WAL 净减少** | **~-88 行** |

---

## 执行顺序

```
Step 1 (f_io 修Bug + 补FFI)
    → 确认修复后 cjpm build 通过
Step 2 (实现 SegmentedLog)
    → 编译通过 + 单元测试
Step 3 (清理 f_log 的 mmap 依赖)
    → 编译通过 + f_log 测试通过
Step 4 (改造 f_store WAL)
    → 编译通过 + f_store 测试通过（benchmark 不退化）
```

---

## 影响模块关系图

```
当前：
f_io ──mmap──→ f_log
  │
  └──(无 SegmentedLog)

f_store ──(独自 mmap FFI)──→ WAL (240行混合)

改造后：
f_io ──DummyOutputStream──→ f_log (mmap 已移除)
  │
  └─ SegmentedLog ──→ f_store::WAL (152行, 净减88行)
                     ──→ (未来) f_mq::MQLog
```
