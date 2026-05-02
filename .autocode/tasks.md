# 当前任务

## 性能优化：WAL 编码零分配路径

### 背景

当前 `WAL.append()` 中每写入一条记录就有两次堆分配：

1. `computeChecksum()` — 分配 temp buf → 拷贝 header+key+value → `crc32()` → 被 GC
2. `encode()` — 分配 final buf → 拷贝全部字段 → 返回给 `file.write()`

利用 **`Array[0..n]` 零拷贝切片** + **线程局部 Buffer**，将小值记录的热路径降为零堆分配。

### 步骤

#### ✅ 1. `f_util/src/crc32.cj` — 无需修改

`crc32(data: Array<Byte>)` 接收整个数组。调用方传 `scratch[4..totalLen]`（零拷贝切片），`crc32` 自然只看到从 offset=4 开始的内容。

#### ☐ 2. `f_store/src/WAL.cj` — 新增 `encodeDirect` + 线程局部 buffer

**改动内容**：

- 在 `WAL` 类中新增 `private static let encodeBuf = ThreadLocal<Array<Byte>> { => Array<Byte>(4096, repeat: 0u8) }`
- 新增 `WAL.encodeDirect()` 静态方法（见下方伪代码）
- 超大记录（> 4096B）回退到 `WALRecord.encode()`
- 修改 `WAL.append()` 中将 `WALRecord(seq, key, value, expireAt).encode()` 替换为 `encodeDirect(seq, key, value, expireAt)`

**`encodeDirect` 伪代码**：

```
encodeDirect(seq, key, value, expireAt):
    totalLen = 36 + key.size + (value?.size ?? 0)
    scratch = encodeBuf.get()
    if scratch.size < totalLen: fallback to WALRecord.encode()

    # 1. 写入各字段到 scratch（跳过 checksum 4 字节）
    off = 4
    off = writeInt64LE(scratch, off, seq)
    off = writeInt64LE(scratch, off, key.size)
    off = writeInt64LE(scratch, off, valueSize)
    off = writeInt64LE(scratch, off, expireAt ?? 0)
    key.copyTo(scratch, destOffset: off); off += key.size
    value?.copyTo(scratch, destOffset: off)

    # 2. 切片传给 crc32（零拷贝）
    crc = crc32(scratch[4..totalLen])

    # 3. checksum 写回 scratch[0..4]
    writeUInt32LE(scratch, 0, crc)

    # 4. 零拷贝切片返回
    scratch[0..totalLen]
```

#### ☐ 3. `f_store/src/WAL.cj` — 修改 `append()` 使用新路径

将 `WALRecord(seq, key, value, expireAt: expireAt).encode()` 替换为 `encodeDirect(seq, key, value, expireAt)`。

#### ☐ 4. 验证编译 + 运行 benchmark

```
cd f_store && cjpm build -i -j1
cjHeapSize=8GB cjpm bench -j1
```

对比优化前后的 benchmark 中位数：
- 期望：各 case 延迟 ~持平或略好（-3~10%）
- 关键指标：GC Warning 频率降低（减少 2000 次/benchmark 的分配）
