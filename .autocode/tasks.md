# 当前任务

## WAL mmap 改造（进行中）

### 方案简述

将 WAL 写入从 `file.write()` (syscall) 改为 **mmap + memcpy** (零 syscall 写 page cache)，
消除每次 append 的 write syscall 开销（~50-80µs → ~1-2µs）。

### 文件变更

| 文件 | 变更 |
|------|------|
| `store_func.cj` | 新增 mmap/munmap/msync/fallocate/memcpy FFI 绑定（`@When[os == "Linux"]`） |
| `WAL.cj` | mmap 字段 + init/append/sync/rotate/close 的 mmap 路径 |

### 架构设计

```
现状（非 Linux 保持不变）:
  append → encodeDirect → file.write(encoded)      [1 syscall]
  sync   → file.flush()                              [1 syscall]

mmap 路径（Linux）:
  append → encodeDirect → memcpy(mmapPtr + off, encoded)  [0 syscall]
  sync   → msync(mmapPtr, size, MS_SYNC)                   [1 syscall/100次]
```

### 步骤

#### ☐ 1. `store_func.cj` — 新增 FFI 绑定

Linux 上声明：

```cj
@When[os == "Linux"]
foreign func mmap(addr: CPointer<Byte>, length: Int64, prot: Int32, flags: Int32, fd: Int32, offset: Int64): CPointer<Byte>

@When[os == "Linux"]
foreign func munmap(addr: CPointer<Byte>, length: Int64): Int32

@When[os == "Linux"]
foreign func msync(addr: CPointer<Byte>, length: Int64, flags: Int32): Int32

@When[os == "Linux"]
foreign func ftruncate(fd: Int32, length: Int64): Int32

@When[os == "Linux"]
foreign func fallocate(fd: Int32, mode: Int32, offset: Int64, length: Int64): Int32

@When[os == "Linux"]
foreign func memcpy(dest: CPointer<Byte>, src: CPointer<Byte>, n: Int64): CPointer<Byte>
```

常量：
```cj
const PROT_READ: Int32 = 1
const PROT_WRITE: Int32 = 2
const MAP_SHARED: Int32 = 1
const MS_SYNC: Int32 = 4
const FALLOC_FL_KEEP_SIZE: Int32 = 0
```

#### ☐ 2. `WAL.cj` — 新增 mmap 字段

```cj
@When[os == "Linux"]
private var mmapPtr: CPointer<Byte>

@When[os == "Linux"]
private var mmapSize: Int64 = 0  // 实际 mmap 的大小 = maxFileSize
```

#### ☐ 3. `WAL.cj` — init() mmap 初始化

创建文件后，Linux 上执行：
1. `ftruncate(fd, maxFileSize)` — 设置文件大小
2. `fallocate(fd, 0, 0, maxFileSize)` — 预分配物理空间（防 SIGBUS）
3. `mmap(NULL, maxFileSize, PROT_READ|PROT_WRITE, MAP_SHARED, fd, 0)`
4. 保存 mmapPtr

#### ☐ 4. `WAL.cj` — append() mmap 写

```cj
synchronized (appendLock) {
    if (closed.load()) { throw StoreClosedException() }
    let writePos = currentFileSize.load()
    if (writePos + Int64(encoded.size) > maxFileSize) {
        rotate()
        writePos = 0
    }
    // mmap: 直接 memcpy 到 page cache（零 syscall）
    unsafe {
        let srcHdl = acquireArrayRawData<Byte>(encoded)
        memcpy(mmapPtr + writePos, srcHdl.pointer, encoded.size)
        releaseArrayRawData(srcHdl)
    }
    currentFileSize.fetchAdd(Int64(encoded.size))
    // 每 syncInterval 次 msync（替代 file.flush）
    if (appendCount.incrFetch() % syncInterval == 0) {
        msync(mmapPtr, currentFileSize.load(), MS_SYNC)
    }
}
```

非 Linux 路径维持 `file.write(encoded)` + `file.flush()` 不变。

#### ☐ 5. `WAL.cj` — sync() mmap 版

```cj
synchronized (appendLock) {
    if (!closed.load()) {
        @When[os == "Linux"]
        msync(mmapPtr, currentFileSize.load(), MS_SYNC)
        @When[os != "Linux"]
        file.flush()
    }
}
```

#### ☐ 6. `WAL.cj` — rotate() + close() mmap 版

rotate: `munmap` 旧文件 → `close()` 旧文件 → 创建新文件 → mmap 新文件
close: `munmap` → `close()` 文件

#### ☐ 7. 验证编译 + benchmark

```bash
cd f_store && cjpm build -i -j1
cjHeapSize=8GB cjpm bench -j1
cjHeapSize=8GB cjpm bench -j8
```

期望：add/remove/ttl 延迟显著降低（消除 file.write syscall）。
