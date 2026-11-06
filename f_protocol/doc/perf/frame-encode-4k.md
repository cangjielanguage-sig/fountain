# 4KB 帧编码对照基准（A/B/C 三阶段）

> 变更：`frame-encode-bench` ｜ 日期：2026-11-06 ｜ 结论：**采纳 B + C**

## 1. 结论

| 阶段 | 改动 | 中位 ns/帧 | 分配字节/帧 | GC 次数 / 50k 帧 | 判定 |
| --- | --- | ---: | ---: | ---: | --- |
| A | 基线（数组列表 + 3 次逐字节拷贝） | 14714 | 14044 | 3 | — |
| B | 单元素直返 + `Array.copyTo` | 10773 | 9591 | 2 | 达标，保留 |
| C | 单缓冲 + 帧头预留 + 原地补帧 | **8214** | **1376** | **1** | 达标，保留 |

- A→B：ns/帧 **-26.8%**，分配 **-31.7%**，GC **-33.3%**。
- A→C：ns/帧 **-44.2%**，分配 **-90.2%**，GC **-66.7%**，p50 **-45.3%**，p99 **-32.9%**。
- B→C：ns/帧 **-23.8%**，分配 **-85.7%**，p50 **-31.7%**。
- 三阶段 `frameBytes=4028`、`frameCrc32=3762771613` 完全一致 ⇒ 帧字节**逐字节相同**。

按 design §7 预登记门槛：B（≥10% ns、≥25% 分配）、C（≥20% vs A、分配 ≤1.5×frame、≥10% vs B）均满足，**B、C 全部采纳**；最终代码 = C（包含 B 的全部改动）。

## 2. 环境与构建（关键前提）

| 项 | 值 |
| --- | --- |
| 平台 | WSL2 Ubuntu-24.04，x86_64 |
| 编译器 | `Cangjie Compiler: 1.3.0-alpha.20261015001050 (cjnative)` |
| 构建 | **`-O2`**（见下） |
| CPU 绑定 | `taskset -c 2`（22 核） |
| 负载 | payload 4018 B，frame 4028 B，n=50_000，warmup=5_000 |
| 轮次 | 每阶段 3 轮，取中位数 |

**必须注意**：`cjc` 默认 `-O0`，而 `cjpm test` 默认也走 `-O0`；生产侧 `fboot` 模板使用 `-O2`。同一个 A 基线：

- `-O0`：约 **602 µs/帧**，GC 129 次 / 50k 帧（逐字节循环 + 边界检查被放大）；
- `-O2`：约 **14.7 µs/帧**，GC 3 次 / 50k 帧。

因此本次测量把 f_protocol 测试依赖链的 `compile-option` 临时追加 `-O2`，**只用于取数，未提交**（测量后已回退各模块 `cjpm.toml`）。任何后续复测都必须确认构建优化级别，否则数字差 40 倍以上。

## 3. 原始数据

### A（基线）

| 轮次 | ns/帧（纯编码） | ns/帧（含 GC） | p50 | p99 | 分配 B/帧 | GC/50k | GC 耗时 µs |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 14841 | 15887 | 11447 | 24394 | 14044 | 3 | 305367 |
| 2 | 14486 | 15739 | 11436 | 24567 | 14044 | 3 | 297316 |
| 3 | 14714 | 15879 | 14377 | 23879 | 14043 | 3 | 321603 |

### B（`copyTo` + 单元素直返）

| 轮次 | ns/帧（纯编码） | ns/帧（含 GC） | p50 | p99 | 分配 B/帧 | GC/50k | GC 耗时 µs |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 10680 | 10894 | 9142 | 19681 | 9591 | 2 | 184026 |
| 2 | 10932 | 10806 | 9631 | 19581 | 9591 | 2 | 193761 |
| 3 | 10773 | 10689 | 9156 | 19570 | 9590 | 2 | 173929 |

### C（单缓冲 + 帧头预留 + 原地补帧）

| 轮次 | ns/帧（纯编码） | ns/帧（含 GC） | p50 | p99 | 分配 B/帧 | GC/50k | GC 耗时 µs |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 8822 | 7548 | 6258 | 16361 | 1376 | 1 | 102657 |
| 2 | 7879 | 7564 | 5949 | 15868 | 1376 | 1 | 101837 |
| 3 | 8214 | 7427 | 6298 | 17354 | 1376 | 2 | 177591 |

`allocBytesPerFrame / frameBytes`：A = 3.49×，B = 2.38×，C = **0.34×**。

## 4. 改了什么

### B（语义不变）

1. `ChainedBytesCopyTo.asBytes()`：单元素直接返回子项视图，去掉一层分配+拷贝；
2. `BytesListOutputStream.asBytes()`：逐字节循环 → `Array.copyTo`（memcpy 级）；
3. `ChainedBytesCopyTo.asBytes()` 多段分支：同上；
4. `EncodedMessage.asOneSmallFrame()`：payload 拷贝 → `copyTo`。

### C（内部结构）

1. `BytesListOutputStream` 由「`ArrayList<Array<Byte>>`」改为单个可增长 `Array<Byte>`：
   - `write` 一次 `copyTo` 写入；`asBytes()` 返回 `[start, start+len)` 视图；
   - `copy(to)` 由「每段一次 write」收敛为**一次 write**；
   - 池项尺寸固定（默认 8192 B）；扩容后的缓冲不再归还池（原池项在扩容时已归还）。
2. `BytesCopyTo` 增加默认方法 `frameBytes(headroom, tail): ?Array<Byte>`（默认 `None`）；
   `BytesListOutputStream` 覆写为返回整帧视图，`ChainedBytesCopyTo` 单元素时透传。
3. `BytesListOutputStream.builder`：`capacity` 改为缓冲字节数（默认 8192），`clearOnReturning` 默认改为 `false`（避免每次归还清 8KB）；新增 `build(timeout!, headroom!)`。
4. `DefaultCodec` 增加 `init(headroom!: Int64)`；`Message.encode()` 传 `FRAME_HEAD_SIZE`，编码从帧头之后开始。
5. `EncodedMessage.asOneSmallFrame()`：命中单缓冲时直接在 `frameBytes` 视图上写 version/cmd/len/CRC，**零组装拷贝**；否则回退旧路径。

## 5. 正确性与回归

- 帧字节一致性：三阶段 `frameBytes` 与整帧 CRC32 完全相同。
- 4KB round-trip / 帧结构（version、cmd、len、CRC 自校验）用例通过。
- 池纪律：连续 2000 帧（超过池预分配 1024）encode→copy 不阻塞、字节数正确。
- 受影响模块全量回归：`f_pool` 69/69、`f_codec` 16/16、`f_protocol` 79/79、`f_rpc` 2/2、`f_mq` 149/149。
  `f_pool` 的 `writeAfterReleaseMustThrow` 已按新契约更新为「新借用方 `byteSize()==0`」；「释放后再写必抛」保持不变。

## 6. 行为与 API 变化

| 变化 | 影响 | 说明 |
| --- | --- | --- |
| `BytesCopyTo` 新增默认方法 `frameBytes(headroom, tail)` | 公开 API（新增，不破坏） | 默认 `None`；单缓冲实现覆写，链式实现在单元素时透传 |
| `BytesListOutputStream` 内部改单缓冲 | 公开签名不变 | `write` 一次 memcpy、`asBytes` 返回视图、`copy` 一次写出 |
| `builder.capacity` 语义 | 由「ArrayList 初始容量」变为「单缓冲字节数」，默认 8192 | 现有调用方不传该参数则无感 |
| `clearOnReturning` 默认值 | `true` → `false` | 避免每次归还 8KB 清零；`len` 隔离，不会暴露脏字节 |
| 池内存 | 1024 × 8192 B ≈ 8 MB（进程级） | 原为 1024 个空 ArrayList；如需收紧可下调 `initSize` |
| 池内复用语义 | 新借用方从 `len=0` 开始（旧实现会看到上次内容） | 更安全；对应测试已更新契约 |

## 7. 复现

```bash
# 1) 临时给依赖链加 -O2（仅测量用，勿提交）
#    f_base f_time f_version f_codec f_data f_exception f_io f_pool f_random f_collection
#    f_concurrent f_log f_macros f_regex f_util f_cache f_config f_protocol
#    compile-option / override-compile-option 追加 " -O2"
cd f_protocol && rm -rf target && cjpm test --filter '*FrameEncodeBench*' --no-progress

# 2) 取数（每阶段 3 轮）
F_PROTOCOL_BENCH=1 F_PROTOCOL_BENCH_STAGE=A taskset -c 2 \
  cjpm test --skip-build --filter '*FrameEncodeBench*' --show-all-output --no-progress

# 3) 预算门槛（TDD）
F_PROTOCOL_BENCH=1 cjpm test --filter '*FrameEncodeBench_test*' --show-all-output
```

## 8. 后续（未做）

- `writev` / 单次 send 合并：需要自有 socket 封装（std.net 不暴露 fd），本变更未涉及。
- 0 拷贝发送（`send_zc`）：4KB 以下收益不足以抵消复杂度。
- 编码器内部每字段一次 `buffer.write([...])` 的小数组分配：C 的 1376 B/帧 主要来自这里（`DefaultCodec` + `ArrayList` + `EncodedMessage`），可作为下一轮优化点。

## 9. 归因基准（2026-11-06）

### 口径

- 同一 harness、`F_PROTOCOL_BENCH=1`、`-O2`；本轮**未绑核**（MT 需要全核，单线程组也同轮跑以便对比）。
- 取数时宿主有另一会话在构建：下面用的是 3 轮 `load average ≈ 2.4`（22 核）的样本；更早一轮 load 19~33 的数据已丢弃（floor 出现 7.5 µs 离群）。
- 每项 3 轮取中位。

### 三组结果（中位）

| 组 | mean ns/帧 | p50 | p99 | 分配 B/帧 |
| --- | ---: | ---: | ---: | ---: |
| C（生产路径，含 CRC） | 6394 | 6430 | 6947 | 1376 |
| floor（copy + CRC + 空 sink） | 3125 | 3135 | 3383 | 0 |
| no-CRC（编码 + 帧头，无 CRC 尾） | 2665 | 2666 | 2854 | 1376 |

### 拆解（估算）

- `C − noCRC = 3764 ns`：CRC + 尾部 + 封装/池的增量。
- `floor = 3135 ns`：4KB `copyTo` + CRC + 写空 sink；按 copy+write ≈ 0.4 µs 估，**CRC ≈ 2.7 µs**。
- 剩余约 `3764 − 2700 ≈ 1.06 µs`：`EncodedMessage` / `payloadSize` / 池借还，以及**缓冲冷缓存**——池在 1024 × 8KB 上轮转，每次 CRC 读的是一个刚从 L3/内存取回的缓冲。
- 占比（p50 6430 ns）：**CRC ≈ 42%**，编码器（noCRC 内除 copy 外）≈ 36%，4KB 拷贝 ≈ 6%，封装/池/冷缓存 ≈ 16%。

### 多线程吞吐（中位）

| 线程 | 吞吐 fps | 每线程 ns/帧 | 相对 1 线程 |
| ---: | ---: | ---: | ---: |
| 1 | 145,234 | 6885 | 1.00× |
| 4 | 330,157 | 12115 | 2.27× |
| 8 | 296,290 | 27000 | 2.04× |
| 16 | 276,635 | 63527 | 1.90× |

4 线程见顶后**回退**，16 线程只有 1.9×。两个叠加因素：共享 `ArrayPool` 的借还竞争；每线程轮转 8MB 缓冲导致 L3 抖动。本轮未做 profile，无法拆分二者占比，但 6 轮（含高负载轮）模式一致，不是单次噪声。

### 对 P0 / P1 / P2 的建议

1. **先做 per-thread / 小工作集池**：每线程可见池项压到 2~4 个，避免 8MB 轮转。预计单线程省 0.5~1 µs，MT 从 1.9× 拉向线性；不改线格式，风险最低。
2. **再做 P0 编码器**：no-CRC 仍有 2.67 µs，去掉每字段小数组、复用 `DefaultCodec`、去虚调用，预计省 1~2 µs。
3. **最后做硬件 CRC**：CRC ≈ 2.7 µs，是单项最大；需要 C 垫片（或 zlib），预计 C 从 6.4 µs 降到 ~3.7 µs。
4. 前两项都不改协议；第三项要先决定“是否给仓库引入 C 构建链”。

## 10. P2 落地：线程本地缓冲池 + P0 编码器（2026-11-06）

### 线程本地池（`localCacheSize`，默认 2）

`BytesListOutputStreamBuilder` 用 `ThreadLocal<LocalBufferCache>` 给每个线程一小批缓冲（默认 2 个）：
借出优先本地栈，归还到**借出方线程**的 cache；不同线程各自一把锁，不再经过共享 `ArrayPool` 的多个互斥量，
也不再在 1024 × 8KB 上轮转。A/B（`F_PROTOCOL_BENCH_LOCAL_CACHE`，-O2，2 轮）：

| localCache | C p50 ns | 1 线程 fps | 4T 扩展 | 8T 扩展 | 16T 扩展 |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 0（关闭） | 6116 | 131k | 2.40× | 2.35× | 2.39× |
| **2** | **3643** | **266k** | **3.42×** | **5.27×** | **8.42×** |
| 4 | 3894 | 252k | 3.59× | 5.70× | 8.01× |
| 8 | 3727 | 216k | 3.76× | 5.59× | 8.84× |

选 **2**：单线程最好、16 线程 8.4×、每线程只占 16KB。相对关闭：C p50 **-40%**，16 线程吞吐 **+251%**（2.39× → 8.42×）。

受限池保护：`maxSize < 64` 时自动关闭本地缓存。否则每线程扣住 2 个缓冲会把小池锁死，
`f_pool` 的 `concurrentBorrowNeverSharesBuffer`（8 线程 × 池 4）就是这种场景；生产默认 `maxSize = 1024` 不受影响。

回归还暴露了一个**既有**生命周期问题：`f_mq` / `fmq` 共 8 处把 `finish().asBytes()` 返回的池缓冲视图在
`release()` 之后继续使用。旧池 1024 项时，下一次编码大概率换一个缓冲，问题被掩盖；本地缓存收紧到 2 项后，
下一次编码立即复用同一缓冲，`MQProtocolTest` 的记录字节被覆盖。已统一改为 `clone()` 后再 `release`，
`f_mq` 149/149 通过。

### P0 编码器（标量写）

`BytesListOutputStream` 增加 `writeByte` / `writeUInt64BE` / `writeUInt32BE`；`DefaultCodec` 的整数、长度前缀
改为直接写缓冲，不再每次 `write([head, b0..b7])` 新建小数组。

- no-CRC p50：903 ns（LC=2，P0 前）→ **643 ns**（-29%）；分配 512 → **384 B/帧**。
- C p50 变化在噪声内（3615 → 3566 ns）：此时 CRC 已占大头，P0 的收益被掩盖，但为后续硬件 CRC 清掉了小对象噪声。
- 编码器复用/去虚调用未做：no-CRC 只剩 0.6 µs，收益不足以抵消 `finish()` 所有权交接的复杂度。

### 最终数据（LC=2 + P0，-O2，2 轮中位）

| 组 | mean ns/帧 | p50 | p99 | 分配 B/帧 |
| --- | ---: | ---: | ---: | ---: |
| C（生产路径） | 3562 | **3566** | 3800 | 384 |
| no-CRC | 615 | 614 | 758 | 384 |
| floor（copy+CRC） | 2853 | 2847 | 2986 | 0 |

MT：1T 277k fps；4T 3.59×；8T 5.59×；**16T 8.46×**。

**新归因**：CRC ≈ 2.5~2.9 µs（**70~80%**），编码器+拷贝 ≈ 0.6 µs（17%），封装/池已降到噪声级。
所以下一步的最大杠杆是硬件 CRC（用户已另有规划）；P0 的剩余项（codec 复用/去虚）优先级降到最低。

### 与上一轮的对比

| 指标 | 上一轮（共享池，无 P0） | 本轮（LC=2 + P0） | 变化 |
| --- | ---: | ---: | ---: |
| C p50 | 6430 ns | **3566 ns** | **-44.5%** |
| no-CRC p50 | 2666 ns | **614 ns** | **-77.0%** |
| 分配/帧 | 1376 B | **384 B** | **-72.1%** |
| 16T 扩展比 | 1.90× | **8.46×** | — |

## 11. 生成式硬件 CRC（Linux x86_64，零第三方）

### 实现

- `CodeBuffer`：`mmap` RW → 写机器码 → `mprotect` RX（W^X）→ `__clear_cache`；失败回退软件。
- CPU 探测：`/proc/cpuinfo` 的 `sse4_2` / `pclmulqdq`；`F_UTIL_CRC_HW=0` 可强制关闭。
- **CRC32C**：SSE4.2 `crc32` 指令（raw，8 字节循环 + 尾字节）。
- **ISO-HDLC**：PCLMULQDQ 16 字节折叠 + Barrett 归约；只处理 16 字节整数倍，尾部由软件补。
- 无第三方库、无 C 垫片；生成失败/非 x86_64 Linux 一律纯软件；CRC 值逐位不变（f_util 9 个生成式用例 + f_protocol 帧 CRC 全绿）。

### 数据（-O2，3 轮中位；宿主 load 11~18，MT 有噪声）

| 组 | mean ns/帧 | p50 | p99 | 分配 B/帧 |
| --- | ---: | ---: | ---: | ---: |
| C（生产路径） | 1384 | **1341** | 1788 | 384 |
| no-CRC | 640 | 627 | 758 | 384 |
| floor（copy+CRC） | 717 | **620** | 1333 | 0 |

MT：1T 777k fps；4T 2.50×；8T 3.03×；16T **3.74×**（绝对 2.78M fps）。

### 与硬件 CRC 前对比

| 指标 | 之前（LC=2 + P0） | 现在（+生成式 CRC） | 变化 |
| --- | ---: | ---: | ---: |
| C p50 | 3566 ns | **1341 ns** | **-62.4%** |
| floor p50 | 2847 ns | **620 ns** | **-78.2%** |
| no-CRC p50 | 614 ns | 627 ns | 噪声内（+2%） |
| 分配/帧 | 384 B | 384 B | 不变 |
| 1T 吞吐 | 277k fps | **777k fps** | +180% |
| 16T 绝对吞吐 | 2.34M fps | **2.78M fps** | +18.8% |
| 16T 扩展比 | 8.46× | 3.74× | 单帧变小后共享分配成为瓶颈；绝对吞吐仍升 |

**新归因**：CRC 从 2.5~2.9 µs 降到 **~0.3~0.5 µs**（约 25~35%）；编码器 + 池 + `EncodedMessage` 成为主要成本（~0.6~0.9 µs）。下一步若要继续降，优先看编码器小对象/编码器复用，而不是 CRC。

**注意**：MT 轮次恰逢宿主有其它构建（load 11~18），绝对扩展比建议在机器空闲时复测；单线程三组数据稳定（C p50 1.21~1.37 µs）。
