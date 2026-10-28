# Change: 新建 f_zip 模块（ZIP 容器读写）

## Why

1. **fountain 目前没有任何 ZIP 能力。** `f_excel` 的 OOXML 包（xlsx 本质是 ZIP）已把 `fountain::f_zip` 写成硬前置（`docs/f_excel模块设计.md:6`、`:2404` 的 P-1），`f_zip` 不落地，`f_excel` 就无从开工；向量知识库等场景也需要"打包/解包"这一层。
2. **设计已冻结，可直接施工。** `f_zip/doc/f_zip模块设计.md` v0.7 已把 21 项决策全部拍板（`§12.1`），无阻塞项（`§12.2`），逐节给出 API、字节布局、实施顺序（P0–P6）与验收口径。本次变更就是把这 21 条落成代码。
3. **容器层必须自己写，且这是长期约束。** v0.7 `§1` 明确：ZIP 容器（local header / 中央目录 / EOCD / ZIP64 / CRC 编排）永久不引入第三方 ZIP 实现；deflate 数据流复用 `stdx.compress.zlib`（`WrapType.DeflateFormat`）是有意为之，不算例外。理由是边角行为（中文名编码、ZIP64 覆盖范围、descriptor 有无、目录属性位）必须由本项目决定，且避免给底层模块引入 FFI/native 依赖传导风险。
4. **现有实现路径已被验证可行。** `stdx.compress.zlib` 在仓库内已有使用（`f_log/src/output/RotatableFile.cj:25`），`f_util.crc32` 已有（`f_util/src/crc32.cj:114`），`f_io.ByteBuffer` 的 `seekReading` / `bytes()` 正合随机访问需要（`f_io/src/ByteBuffer.cj:22`）——没有新的外部前置任务。
5. **`9.7b` 的卡点不在 `f_zip`，在 `f_util` 的 CRC 吞吐，且它正在堵住本变更的验收。** 融合侧实测 `f_util.crc32` 约 **4.2 MB/s**（`CrcEngine.update` 用 `for (b in data)` 逐字节查表；同机 C 版表驱动 175 MB/s）：4.4 GB 单条目一次往返要算两遍 CRC ≈ 35 分钟，超出本机单条命令 10 分钟的上限；写 100 MB 条目光 CRC 就要 ~25 s，两个资源用例（509 s / 551 s）的耗时也几乎全在这一处。多线程/换机器只是缓解，`9.7b` 会长期挂着。用户已决定**在本变更内修**，不另开 change。

## What Changes

- **新建 `f_zip` 模块骨架**：`f_zip/cjpm.toml`、`f_zip/src/`、`f_zip/doc/`、中英 README；登记进根 `cjpm.toml` 与 `.modules` 的 `[include]`。
- **容器层（P0）**：f_zip 内部的小端读写原语（`readU16LE`/`readU32LE`/`readU64LE` 与对应写函数，越界返回 `None` 且回滚游标、校验实际读到的字节数）、Local File Header（30 字节）、Central Directory Header（46 字节）、EOCD（22 字节）的语义化编解码、DOS 时间、签名常量表；CRC32 复用 `f_util.crc32`（对**未压缩**数据计算）。
- **读取（P1–P2、P2.5）**：`ZipReader(input)` 全量缓冲 + `ZipReader(path)` 走 `File.seek` 窗口读；EOCD 尾部窗口扫描（`min(len, 22 + 65535)`，校验 `22 + 注释长度 == 到文件尾距离`）；ZIP64 读取链（哨兵 → EOCD64 定位器 → EOCD64 → extra `0x0001` 按顺序只含越界项）；`entries()` / `read(name)` / `readAll(name)` / `open(name)` / `contains(name)` / `close()`；`open(name)` 每次另开 `File` 句柄以支持并发解压；解压后校验 CRC32 与 `uncompressedSize`；压缩方法白名单（0 Stored / 8 Deflate），其余报**具体方法名**。
- **写入（P3–P4.6、P6）**：`ZipWriter.add(name, data)` 内存路径（先算 CRC 与压缩后大小，再写真实值 header，不写 descriptor）；`addFileStream(name, input)` 流式路径（header 全 0 + bit 3 = 1 + `version needed = 45` + ZIP64 extra 占位，数据后写 **24 字节 ZIP64 形式** data descriptor）；`addFile(name, path)` / `addDirectory(name)` / `close()`；包装流顺序固定为 `input → CRC 计数 → CompressOutputStream(DeflateFormat) → 压缩后计数 → output`；`position: Int64`（单调递增、`close()` 前不含中央目录）与 `spilling: Bool`（`AtomicBool`，仅 `add()` 落盘阶段为真，与 `position` **不保证原子一致**）；ZIP64 写入仅在越界时启用（单条目 ≥ `0xFFFFFFFF`、偏移 ≥ `0xFFFFFFFF`、条目数 > `0xFFFF`），否则不写；同名条目写入侧消解（目录合并、文件 `_2` `_3`… 后缀插在 stem 上）。
- **大条目落盘（P6）**：`add()` 的 `data` 超过 `ZipWriterOptions.memoryEntryThreshold` 自动写临时文件后走流式路径；阈值按 `os` **编译期分档**（Linux 64 MB / 其他 16 MB，两份 `@When` 声明互斥）；临时目录四级解析（`tempDir` → `TMPDIR` → 系统临时目录 → `./.fountain_tmp/`），全失败直接抛错**不降级回内存**；进入该分支打一条 debug 日志。
- **安全（P5）**：Zip Slip 四条规则（拒绝绝对路径、拒绝 `..` 段、规范化后必须以目标目录为前缀、符号链接条目跳过）；符号链接**无条件跳过**（`unzip` 与 `zip()` 跳过，`addFile()` 跟随单个文件）；`ZipLimits`（单条 512 MB / 累计 2 GB / 条目数 65535 / 压缩比 1000 告警）可覆盖，`maxEntries` **只服务读取**；加密 ZIP（bit 0 / bit 6）直接报错。
- **便捷函数**：`unzip(input|path, dir, limits!)` 与 `zip(output, dir, options!)`，逐条走流式路径，不整包进内存。
- **`f_util` 的 CRC32 吞吐优化（范围扩展）**：`CrcEngine.update` 的内层循环从 `for (b in data)` 改为**索引遍历**，并对「**反射 + 位宽 32**」的变体启用 **slicing-by-4**（由现有 `t0` 逐级 `>> 8` 再查表生成 `t1..t3`，一次消费 4 字节；`< 4` 字节的尾巴仍走索引路径）；其余变体只做索引遍历。多项式、寄存器初值、输入/输出反射、`xorout`、位宽与 11 个变体的标准检查值**全部不变**，`CrcEngine` / `Crc32` / 顶层 `crc32*` 的公开签名**零变化**。目标吞吐 ≥ 60 MB/s（1 MiB 门禁用例的保守下限取 30 MB/s），把 `9.7b` 拉进可跑范围。
- **测试**：模块内 `cjpm test` 单元测试（构造性、流式/ZIP64 专项、安全负例），加外部工具交叉验证（`7z t` 与 Python `zipfile.testzip()` 为必做，`unzip -t` 仅在环境具备时补跑）作为独立验收步骤；`f_util` 侧另有 CRC 等价性用例（以测试内逐字节参考实现为第二基准）与吞吐用例（`F_UTIL_PERF=1` 门控，默认 SKIP）。

## Capabilities

### New Capabilities

- `f-zip-container`: ZIP 容器层的静态格式能力——小端读写原语与越界语义、三类 header 的编解码、EOCD 自洽定位、ZIP64 读写规则、压缩方法白名单、文件名编码判定链、DOS 时间、CRC 归属。
- `f-zip-reader`: 读取侧能力——两种构造（内存缓冲 / `File.seek` 窗口）、条目枚举、按名读取与流式打开、CRC 与大小校验、`ZipLimits` 上限语义、`unzip` 便捷解压。
- `f-zip-writer`: 写入侧能力——内存路径与流式路径、data descriptor、ZIP64 自动升级、同名消解、目录条目、`position`/`spilling` 进度语义、平台分档阈值与临时文件落盘、`zip` 便捷打包。
- `f-zip-security`: 安全能力——Zip Slip 拒绝、符号链接跳过、ZIP 炸弹上限、加密 ZIP 拒绝、可诊断的错误信息。

### Modified Capabilities

- `f-util-crc`: **`f_util` 既有 CRC 引擎的吞吐改进**（不是 API 变更）。约束三件事：① 全变体检查值不变、增量接口与一次算完等价；② 切片路径与逐字节路径对任意长度输入**结果逐位一致**；③ 1 MiB 吞吐下限（保守 30 MB/s，目标 60+）。同时钉住「切片只对反射 + 32 位启用」，其余变体保持原算法（可改索引遍历）。
  > 本次不修改任何既有模块的**公开 API**；根 `cjpm.toml` / `.modules` 仍只做登记性新增。
  > **delta 形态说明**：`openspec/specs/` 目前没有任何基线 spec，`f_util` 的 CRC 从未被规格化过，因此该 capability 的规格文件以 `## ADDED Requirements` 落地（等于给既有实现补一份规格并约束其不变式），语义上仍是一次"改进既有能力"。

## Impact

- **新增代码**：`f_zip/cjpm.toml`、`f_zip/src/**`、`f_zip/doc/**`、`f_zip/README.md`、`f_zip/README_en.md`。
- **修改代码（范围扩展）**：`f_util/src/CrcEngine.cj` —— `update` 内层循环改索引遍历（`f_util/src/CrcEngine.cj:99`）+ 反射 32 位变体的 3 张切片表构造；`f_util/src/crc32.cj` 只可能补注释。`CrcEngine` / `Crc32` / `crc32*` 的签名、变体列表、检查值全部不动。
- **影响面（CRC 优化）**：所有调用 CRC32 的模块——`f_protocol` 帧校验（`f_protocol/src/default/Message.cj:95` / `:128` / `:297`，用增量接口）、`f_store` WAL 校验（`f_store/src/WAL.cj:125`、`f_store/src/WALRecordCodec.cj:39`）、`f_zip` 条目 CRC（`Crc32InputStream` 与 `ZipWriter`）。**只改性能不改语义**，回归口径 = `f_util` 全量 `cjpm test`（含 `crc_check_test` 的 11 个变体）+ 上述三个模块各自的 CRC 相关用例。
- **静态内存**：反射 32 位变体共 6 个（`isoHdlc` / `jamcrc` / `crc32c` / `koopman` / `base91D` / `autosar`），按现有 `Array<UInt64>` 表口径各多 3×256 项 ≈ 6 KB，合计 **+36 KB**（若切片表用 `UInt32` 则合计 +18 KB），一次性静态分配，构造期多 768 次查表。
- **修改配置**：根 `cjpm.toml` 的 `[dependencies]` 增加 `"fountain::f_zip" = {path = "./f_zip"}`；`.modules` 的 `[include]` 增加 `f_zip`。
- **模块依赖**（方向单一，无环）：`f_zip` → `fountain::f_base`（`BaseException`）、`fountain::f_util`（`crc32`）、`fountain::f_io`（`ByteBuffer`）、`fountain::f_log`（落盘 debug 日志）、`cangjie_tpc::charset4cj`（GBK 回退解码）、`stdx.compress.zlib`、`std.fs` / `std.io` / `std.time` / `std.sync`。
  > 与 v0.7 `§0` 依赖表的两处差异：① `§3.4.3` 要求落盘时打 debug 日志，因此必须依赖 `f_log`；② `ZipException` 继承 `f_base.BaseException`（与仓库其它模块一致），因此必须依赖 `f_base`。两者都是仓库内模块，不属于"第三方 ZIP 实现"，长期约束不受影响；两处差异在 `design.md` D11 记录。
- **下游影响**：`f_excel` 的 P-1 前置解除；`f_zip` 为新增模块，无已上线实现，不存在破坏性变更与迁移成本。
- **发布**：随 fountain 版本发布，`f_zip` 为动态库模块，无独立版本号。

## Out of Scope

- 压缩方法扩展（Deflate64 / BZIP2 / LZMA / Zstandard / XZ / PPMd）——只报错，不实现（v0.7 `§6.3`）。
- 加密 ZIP 的任何部分支持（含 AES / ZipCrypto）——直接报错。
- 分卷 / 多磁盘 ZIP（`disk number start` 非 0）——不实现，读到即报错。
- 推模式写入（`openEntry(name): OutputStream`）——`f_excel` 已确认改为拉模式适配（`docs/f_excel模块设计.md:2464`），本次不扩接口。
- 容器内内存探测（cgroup limit）与 `forContainer(memoryLimit)`——v0.7 明确不做（`§12.1` 第 13、21 条）。
- `f_io.ByteBuffer` 的小端/多字符集增强——2026-10-24 已决定不实施，改由 f_zip 内部私有函数承担（v0.7 `§1.2`）。
- `f_zip` 层自身的性能调优（`CompressLevel`、`bufLen`、buffer 大小、并行压缩）：不设提速门禁，性能数字按 `§10` 观察。本次唯一的性能类改动是 `f_util` 的 CRC32 吞吐（见上），它不改 `f_zip` 的任何参数。
- **`f_util` 侧明确不做**：不改多项式 / 不改支持的变体集合 / 不改 8、16、24、40、64 位变体与全部非反射变体的算法路径（它们只享受索引遍历）/ 不改 `finish` 与 `initRegister` 的收尾语义 / 不引 FFI 与硬件指令（CRC32C 的 SSE4.2、ARMv8 `crc32` 指令另议）/ 不新增 `update(ptr, len)` 之类重载。
