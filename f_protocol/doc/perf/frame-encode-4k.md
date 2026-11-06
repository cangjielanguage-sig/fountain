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
