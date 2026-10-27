# 任务：新建 f_zip 模块（TDD）

> 每个任务都是「先写失败用例（红）→ 最小实现（绿）→ 重构」。用例与被测文件同目录、同名加 `_test` 后缀。
> **DoD（每个任务）**：① 对应用例全绿；② `cjpm build` 无新增 warning；③ `specs/*/spec.md` 中对应的 Scenario 有用例覆盖（用例名里引用场景标题）；④ 与 `f_zip/doc/f_zip模块设计.md` 出现偏差时**同提交改文档**；⑤ 提交前统一 LF。
> **顺序理由**：先能写出被外部工具认可的普通 ZIP（阶段 6），再加 descriptor（阶段 8）、ZIP64（阶段 9）。一次只引入一类"读端可能不认"的风险，出问题能立刻定位到新加的那层。

## 1. 模块骨架与仓库登记

- [ ] 1.1 建 `f_zip/` 目录：`cjpm.toml`、`src/`、`doc/`、`README.md`、`README_en.md`
- [ ] 1.2 `f_zip/cjpm.toml` 依赖：`fountain::f_util`、`fountain::f_io`、`fountain::f_log`、`cangjie_tpc::charset4cj`；`output-type = "dynamic"`；`include = ["src"]`；target 段与 `f_util/cjpm.toml` 对齐（含 `CANGJIE_STDX_DYNAMIC_PATH`）
- [ ] 1.3 根 `cjpm.toml` 的 `[dependencies]` 增加 `"fountain::f_zip" = {path = "./f_zip"}`
- [ ] 1.4 `.modules` 的 `[include]` 增加 `f_zip`
- [ ] 1.5 红：`src/f_zip_test.cj` 平凡用例（断言 `ZipException("x").message == "x"`），证明 `cjpm test` 可跑
- [ ] 1.6 绿：`src/f_zip.cj` 放 `package fountain::f_zip`，`ZipException <: BaseException` 最小实现
- [ ] 1.7 验收：`f_zip` 下 `cjpm build` / `cjpm test` 通过；根工程 `cjpm build` 不受影响

## 2. P0：容器原语（CRC + 小端读写）

- [ ] 2.1 红：`LeBytes_test.cj` —— `readU16LE`/`readU32LE`/`readU64LE` 越界返回 `None` **且 `readOffset` 不位移**；底层 `read` 返回短读时不补零；`writeU32LE(0x04034b50)` 产出 `50 4B 03 04`；失败读之后继续读仍正确
- [ ] 2.2 绿：`LeBytes.cj` —— `readU16LE` / `readU32LE` / `readU64LE` / `writeU16LE` / `writeU32LE` / `writeU64LE` / `readBytes` / `skip`，实现 D12 的四条硬约定
- [ ] 2.3 红：`ZipLayout_test.cj` —— 三个签名常量、各 header 固定长度、ZIP64 extra ID `0x0001`、descriptor 签名 `0x08074b50` / `0x07064b50` / `0x06064b50` 的数值与字节序
- [ ] 2.4 绿：`ZipLayout.cj` —— 常量表 + `CompressionMethod` 枚举（`Stored = 0` / `Deflate = 8`）
- [ ] 2.5 红：`ZipTime_test.cj` —— `2026-10-24 13:45:30` 往返相等；`13:45:31` 解码为 `13:45:30`
- [ ] 2.6 绿：`ZipTime.cj` —— DOS 时间双向转换
- [ ] 2.7 红：CRC 用例 —— `crc32("123456789") == 0xCBF43926`；确认复用 `f_util.crc32` 而非自建表
- [ ] 2.8 绿：在写入侧接线 `f_util.crc32`，并加注释说明"CRC 对未压缩数据计算"

> **门禁**：阶段 2 全绿前不开工解析与写入，否则后面每一处越界错误都会伪装成"格式不兼容"。

## 3. P1：`ZipReader(input)` —— EOCD → 中央目录 → 条目列表

- [ ] 3.1 红：`EntrySource_test.cj` —— `BufferSource` 的 `size` / `readAt` / `openRange` / `close`；`openRange` 只返回指定窗口
- [ ] 3.2 绿：`EntrySource.cj` —— 接口 + `BufferSource`
- [ ] 3.3 红：`Eocd_test.cj` —— 空 ZIP（0 条目）；注释内嵌 `0x06054b50` 时仍定位到真 EOCD；尾部窗口扫不到时报 `不是有效的 ZIP 文件（未找到中央目录）`；CD 偏移越界报 `中央目录偏移 ${off} 超出文件长度 ${len}`
- [ ] 3.4 绿：`Eocd.cj` —— 尾部窗口扫描 + 自洽校验（`22 + commentLen == size - offset`），扫不到直接失败
- [ ] 3.5 红：`CentralHeader_test.cj` —— 46 字节头 20 个字段往返；带 file comment 时正确跳到下一条
- [ ] 3.6 绿：`CentralHeader.cj` —— 读/写 + `RawEntry`（含 externalAttributes、flag、extra 原片）
- [ ] 3.7 红：`NameCodec_test.cj` —— bit 11 置位按 UTF-8；未置位的合法 UTF-8；未置位的合法 GBK；两者都非法走 Latin-1；写入侧中文置位、纯 ASCII 不置位
- [ ] 3.8 绿：`NameCodec.cj` —— 回退链 `UTF-8 → GBK → Latin-1` + 写入判定
- [ ] 3.9 红：`ZipReader_test.cj` —— `entries()` 顺序等于中央目录顺序；同名条目全部保留；每次返回独立列表
- [ ] 3.10 绿：`ZipReader.cj` —— `init(input)`、`entries()`、`contains()`、`close()`（幂等、关闭后调用报错）
- [ ] 3.11 验收：用 `docs/f_zip模块设计.md §9` 的外部样本（Linux `zip` 产出）列出全部条目

> **门禁**：能列出外部 ZIP 的全部条目，才进入解压。

## 4. P2：解压（Stored + Deflate）+ CRC 校验

- [ ] 4.1 红：`BoundedStream_test.cj` —— 限长 `InputStream` 到 EOF 返回 -1；`Crc32InputStream` 统计原始字节数与 CRC
- [ ] 4.2 绿：`BoundedStream.cj` —— 限长流 + CRC 计数流（`read` 语义与 `std.io.InputStream` 一致）
- [ ] 4.3 红：解压用例 —— Stored 直接返回原字节；Deflate 走 `CompressInputStream(DeflateFormat)`；空条目；CRC 不匹配报 `CRC 校验失败：期望 ${exp}，实际 ${act}（${name}）`；`uncompressedSize` 不符报错；截断流报错
- [ ] 4.4 绿：`ZipReader.read(name)` / `readAll(name)` —— 以中央目录为准（bit 3 置位时不信 local header），解压后校验大小与 CRC，失败不返回部分数据
- [ ] 4.5 红：不支持方法用例 —— method 12 / 93 报 `不支持压缩方法 ${method}（${name}）`；加密 bit 0 / bit 6 报 `不支持加密 ZIP（${name}）`
- [ ] 4.6 绿：方法白名单 + 加密检查接线
- [ ] 4.7 红：`open(name)` 用例 —— 读到 EOF 才校验 CRC；不存在返回 `None`；并发开 4 个条目不串数据（`BufferSource` 用独立游标）
- [ ] 4.8 绿：`ZipReader.open(name): ?InputStream`
- [ ] 4.9 验收：`unzip` 出来的文件与源逐字节一致（先手写脚本比对，阶段 12 再补 `unzip`）

## 5. P2.5：`ZipReader(path)` —— `File.seek` 窗口读

- [ ] 5.1 红：`FileSource_test.cj` —— `size` 正确；`readAt` 指定偏移读；`openRange` 每次另开句柄（两个 `openRange` 交替读互不干扰）；`close` 释放
- [ ] 5.2 绿：`EntrySource.cj` 增加 `FileSource`
- [ ] 5.3 红：`ZipReader_path_test.cj` —— 路径构造能列出与流构造完全相同的条目；CD 一次读入；尾部窗口不超过 `min(len, 22 + 65535)`
- [ ] 5.4 绿：`ZipReader.init(path)` 接线，解析逻辑保持同一份
- [ ] 5.5 验收（脚本）：解压 1 GB 样本，`/proc/self/status` 的 `VmRSS` 增量远小于文件大小

> 该阶段只影响"怎么读到字节"，与解析逻辑正交；提前做完能让后续所有大文件测试都用上流式读取。

## 6. P3：`ZipWriter.add` + 中央目录 + EOCD（关键里程碑）

- [ ] 6.1 红：`LocalHeader_test.cj` —— 30 字节头往返；bit 3 为 0 时写真实值
- [ ] 6.2 绿：`LocalHeader.cj` —— 写/读（ZIP64 extra 先留接口，阶段 9 补）
- [ ] 6.3 红：`CentralEntry` 累加器用例 —— 写完一条后名字/flag/method/时间/crc/大小/偏移全部就位
- [ ] 6.4 绿：`CentralEntry` 累加器 + `close()` 写 CD 与 EOCD（先只支持非 ZIP64）
- [ ] 6.5 红：`ZipWriter_test.cj` —— 单文件 Stored / Deflate 往返；空数据条目（大小 0、CRC 0）；空包（不写条目直接 `close()` 产出合法 ZIP）；`close()` 幂等；未 `close()` 的产物不可读
- [ ] 6.6 绿：`ZipWriter` 内存路径（先算 CRC 与压缩后大小，再写 header，不写 descriptor）
- [ ] 6.7 验收（外部工具，独立步骤）：写出的 ZIP 通过 `unzip -t`、`7z t`、Python `zipfile.testzip()`

> **P3 是关键里程碑**：能让外部工具认可"最简单的 ZIP"，才算真正跑通格式理解。此步不过，后面的 descriptor / ZIP64 一律不开工。

## 7. P4：多条目 + 目录 + 中文名

- [ ] 7.1 红：多条目用例 —— 5 个文件 + 2 个目录，中央目录条数与顺序正确
- [ ] 7.2 绿：多条目写入（复用阶段 6 的累加器）
- [ ] 7.3 红：目录条目用例 —— `addDirectory("sub")` 返回 `sub/`；两个大小为 0、method 0、crc 0、external attributes 高位为目录 mode；`unzip -l` 显示为目录
- [ ] 7.4 绿：`addDirectory` + external attributes 目录位
- [ ] 7.5 红：中文名用例 —— `中文/文件.txt` 往返；bit 11 为 1；字节为 UTF-8
- [ ] 7.6 验收（外部工具）：中文名在 `unzip -l` / 7-Zip / Windows 资源管理器中都不乱码

## 8. P4.5：`addFileStream` + data descriptor

- [ ] 8.1 红：`addFileStream` 用例 —— local header bit 3 = 1、`version needed` = 45、extra 含 `0x0001` 且两个 8 字节值为 0；descriptor 固定 24 字节；10 字节内容也用 24 字节形式；中央目录记录真实值
- [ ] 8.2 红：包装流顺序用例 —— CRC 等于对**原始**字节的 `f_util.crc32`；`compressedSize < uncompressedSize`（可压缩数据）；随机字节解压后逐字节一致
- [ ] 8.3 绿：`addFileStream` —— `Crc32InputStream → CompressOutputStream(DeflateFormat) → CountingOutputStream → output`，descriptor 24 字节
- [ ] 8.4 红：混合样本用例 —— `add` 与 `addFileStream` 交替三条，自身读回正确；bit 3 分别为 0/1/0
- [ ] 8.5 红：`addFile(name, path)` 用例 —— 1 MB 文件往返；符号链接被跟随；路径不存在抛 `ZipException`
- [ ] 8.6 绿：`addFile`
- [ ] 8.7 红：失败与脏状态用例 —— 输入流中途抛错后 `close()` 抛 `条目 ${name} 写入中断，ZIP 结构不完整`；脏状态下 `add` 也抛
- [ ] 8.8 绿：脏状态标记与拦截
- [ ] 8.9 验收（外部工具，独立步骤）：混合样本与纯流式样本各跑 `unzip -t` / `7z t` / `zipfile.testzip()`。若某工具不认 ZIP64 descriptor，登记进 `f_zip/doc/兼容性例外.md`，**不改回 4 字节**

## 9. P4.6：ZIP64 写入（extra + EOCD64 + 自动升级）

- [ ] 9.1 红：ZIP64 extra 用例 —— 只有 `uncompressedSize` 越界时 extra 只含 `originalSize(8)`；两个字段越界时按 `originalSize → compressedSize` 顺序；构造出的 extra 满足"只放越界项"
- [ ] 9.2 绿：`LocalHeader` / `CentralHeader` 的 ZIP64 extra 构造与解析（按哨兵个数决定读几个 8 字节；长度不足报 `ZIP64 extra 长度不足：需要 ${need}，实际 ${got}（${name}）`）
- [ ] 9.3 红：EOCD64 用例 —— 条目数 > `0xFFFF` 时写 EOCD64 + 定位器，普通 EOCD 填 `0xFFFF`；不越界时输出中不存在 `0x06064b50` / `0x07064b50`，普通 EOCD 是真实值
- [ ] 9.4 绿：`close()` 的 ZIP64 分支
- [ ] 9.5 红：读取侧 ZIP64 用例 —— 普通 EOCD 无哨兵时不读 EOCD64；有哨兵时读定位器与 EOCD64；定位器签名不匹配报错
- [ ] 9.6 绿：`Eocd.cj` 的 ZIP64 读取链
- [ ] 9.7 红（慢用例）：单条目 > 4 GB（稀疏文件 / 重复数据构造）往返；条目数 > 65535 往返
- [ ] 9.8 验收（外部工具）：两个慢样本 `unzip -l` 计数与大小正确、`7z t` 通过

## 10. P5：安全校验（Zip Slip / ZipLimits / 炸弹 / 符号链接）

- [ ] 10.1 红：`ZipLimits` 用例 —— 单条目超限报 `解压体积超过上限 ${limit}（${name}）`；累计超限；条目数在**解析期**拒绝（不构造满列表）；高压缩比只告警；上限可按实例覆盖；两个实例各自计数；同实例跨 `read` / `open` 累计；计数不采信 header
- [ ] 10.2 绿：`ZipLimits.cj` + `ZipReader` 接线（实际字节累计、解析期条目数检查、warning 日志）
- [ ] 10.3 红：`Unzip_security_test.cj` —— `../../etc/passwd` 拒绝；`/abs/path.txt` 拒绝；`a/../../b.txt` 拒绝；非法条目**不创建任何中间目录**；前两条合法、第三条非法时的部分成功语义
- [ ] 10.4 绿：`Unzip.cj` —— 路径四条校验（绝对路径 / `..` 段 / 规范化前缀 / 校验先于落盘）
- [ ] 10.5 红：符号链接用例 —— 解压遇 `S_IFLNK` 跳过并 warning；`zip()` 跳文件链接、跳过目录链接整棵子树（不能无限递归）；`read("link")` 返回目标字符串；`addFile` 跟随
- [ ] 10.6 绿：符号链接判别 `(mode & 0xF000) == 0xA000` + 两处策略接线
- [ ] 10.7 红：恶意样本 —— 高压缩比炸弹（10 MB → 1 GB）、截断 ZIP、注释内嵌 EOCD 签名
- [ ] 10.8 验收：八类负例（相对穿越 / 绝对路径 / 深层穿越 / 符号链接条目 / 目录符号链接 / 炸弹 / 条目数超限 / 加密）各有至少一条用例，且都断言消息含关键字段

## 11. P6：同名消解 + `position` + 落盘 + 平台阈值

- [ ] 11.1 红：`EntryNameTable_test.cj` —— 全表覆盖 `a.txt → a_2.txt → a_3.txt`、`a_2.txt → a_2_2.txt`、`a_2_2.txt → a_2_2_2.txt`、`a → a_2`、`dir.d/file → dir.d/file_2`、`.gitignore → .gitignore_2`、`a. → a_2.`
- [ ] 11.2 绿：`EntryNameTable.cj` —— `allocate` + `insertSuffix`
- [ ] 11.3 红：目录合并用例 —— 连续两次 `addDirectory("d")` 都返回 `d/`，ZIP 中只有一条
- [ ] 11.4 绿：`ZipWriter` 接入名字分配（所有 `add*` 返回实际名字）
- [ ] 11.5 红：`position` 用例 —— 三次写入后读数严格递增；`close()` 前不含 CD（小于最终总字节数）
- [ ] 11.6 绿：`CountingOutputStream` 包在最外层，暴露 `position`
- [ ] 11.7 红：`spilling` 用例 —— 另一线程轮询时落盘阶段读到 `true` 且 `position` 不增长；`addFileStream` 期间恒为 `false`；落盘结束复位；底层必须是 `AtomicBool`
- [ ] 11.8 绿：`spilling`（`std.sync.AtomicBool`）
- [ ] 11.9 红：`@When` 用例 —— Linux 默认 `67108864`；非 Linux 默认 `16777216`；任一平台上同名函数只有一份定义
- [ ] 11.10 绿：`ZipWriterOptions.cj` —— 两份互补 `@When` 的 `defaultMemoryEntryThreshold()`（各带 `// 与另一份保持同步`）+ `forServer()` / `forLowMemory()` 静态工厂（每次返回新实例）
- [ ] 11.11 红：`TempSpill_test.cj` —— 超过阈值走流式（bit 3 = 1、24 字节 descriptor、读回一致）；未超阈值全程不建临时文件；`tempDir` 优先于 `TMPDIR`；四级全失败抛 `无法创建临时文件，且条目大小 ${size} 超过内存路径阈值 ${threshold}`；落盘分支打 debug 日志（默认级别不输出）
- [ ] 11.12 绿：`TempSpill.cj` —— 四级目录解析 + `.fountain_tmp/` 自动创建 + `Log.debug` + 写完删临时文件
- [ ] 11.13 红：资源用例 —— `add` 一条 100 MB 不可压缩数据，Linux 峰值 < 110 MB
- [ ] 11.14 绿：`add()` 接线落盘分支（`spilling` 置位、`position` 不增长的窗口符合预期）

## 12. 便捷函数

- [ ] 12.1 红：`zip` 用例 —— 两层子目录 5 个文件返回 `5`，解压还原一致；空目录返回 `0` 且仍有目录条目；符号链接被跳过；总大小 2 GB 时 RSS 不线性增长
- [ ] 12.2 绿：`Zip.cj` —— `zip(output, dir, options!)` 递归 + `addFileStream`
- [ ] 12.3 红：`unzip` 用例 —— 含 3 文件 2 目录的包返回 `3`；`a/b/c.txt` 自动建目录；`empty/` 被创建；同名覆盖；`unzip(path, dir)` 不爆内存
- [ ] 12.4 绿：`Unzip.cj` —— `unzip(input, dir, limits!)` 与 `unzip(path, dir, limits!)`
- [ ] 12.5 验收：`zip` 产物 → `unzip` 还原 → 与原目录逐文件比对一致

## 13. 外部工具交叉验证（独立验收，不算进"单测全绿"）

- [ ] 13.1 反向：`unzip -t` / `unzip -l` 跑普通 / 流式 / ZIP64 / 混合四类样本
- [ ] 13.2 反向：`7z t` 跑同样四类样本
- [ ] 13.3 反向：Python `zipfile.testzip()` 跑同样四类样本（重点看 bit 3 + ZIP64 extra 组合）
- [ ] 13.4 正向：读 Linux `zip` 产出（标准 deflate、UTF-8 名）
- [ ] 13.5 正向：读 Windows 资源管理器产出（可能 GBK 名、bit 11 未置位）
- [ ] 13.6 正向：读 7-Zip 产出（可能含 ZIP64）
- [ ] 13.7 正向：读 macOS 归档工具产出（含 `__MACOSX/` 与 `._` 资源叉）
- [ ] 13.8 正向：读 Python `zipfile` 产出（各种边界）
- [ ] 13.9 把与 APPNOTE 不一致的真实样本登记进 `f_zip/doc/兼容性例外.md`（样本来源 / 现象 / APPNOTE 位置 / 我们的处理），**不改代码迁就**

## 14. 文档、登记与收尾

- [ ] 14.1 `f_zip/doc/f_zip模块设计.md` —— 落位 v0.7 设计稿，并回写两处与实现的差异：① 依赖表增加 `f_log`（`§1`）；② `ZipWriter` 构造增加 `options!` 参数（`§3.2`）
- [ ] 14.2 `f_zip/doc/api.md` —— 九个公开名字的速查；显式写明 `maxTotalSize` 是**每实例累计**、`ZipWriter` 非线程安全、`spilling` 与 `position` 不保证原子一致
- [ ] 14.3 `f_zip/doc/兼容性例外.md` —— 建表（初始为空），表头按 `§8.1`
- [ ] 14.4 `f_zip/README.md` / `README_en.md` —— 能力清单、依赖、快速开始（`zip` / `unzip` / `addFileStream`）、安全默认值
- [ ] 14.5 根 `README.md` 的模块清单与依赖矩阵（若有自动生成脚本则按流程重跑）
- [ ] 14.6 全量 `cjpm test` 与 `cjpm build` 无新增 warning；慢用例单独跑一次并留档
- [ ] 14.7 提交（功能分支 `feature/f_zip`），每个阶段一次提交；完成后按仓库流程 `--no-ff` 合并回 master

## 15. 与 `f_excel` 的交接确认

- [ ] 15.1 在 `f_zip/doc/api.md` 标注"拉模式"约束：`addFileStream` 由 f_zip 主动从 `input` 读，`f_excel` 需把行迭代器包成惰性 `InputStream`（对接 `docs/f_excel模块设计.md:462`）
- [ ] 15.2 确认 `f_excel` 需要的两个构造（`ZipReader(input)` / `ZipReader(path)`）与 `open(name)` 均已可用；无需 `openEntry` 推模式
