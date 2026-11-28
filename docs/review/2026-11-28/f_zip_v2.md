# f_zip 模块审查报告

- **审查日期**：2026-11-28
- **模块路径**：`f_zip`（55 个文件：42 个 .cj + 13 个 .md）
- **基线**：工作区快照（sts/1.3.x 工作区，master 同提交 120fd2542，无分支差异）
- **审查重点**：见 scope.md（正确性、死代码、重复逻辑、空实现、栈溢出、OOM、热点、并发与锁、存量 BUG、内存/CPU 优化空间、local mode 可行性、README 覆盖）
- **报告版本**：v1（由 4 个分部分报告合并：`parts/f_zip.part1..4.md`）

## 发现

<!-- 第 1 部分 -->

### [一般][存量] 「f_zip 对外只抛 ZipException / 唯一异常类型」不成立

- **位置**：`f_zip/README.md:235`、`f_zip/README_en.md:256`、`f_zip/doc/api.md:13`、`f_zip/doc/f_zip模块设计.md:1125-1143`
- **来源**：存量（`git log -- f_zip/doc/api.md` 最后为 `bc44964e4`；README 该句为 `935606dac`，均早于后续代码）
- **判据**：review-checklist §13（文档承诺与实现相反）/ §11（契约与实现不符）
- **证据**：静态确定 —— `ZipReader(path)` 直接 `File(path, OpenMode.Read)`，无包装（`f_zip/src/EntrySource.cj:77-81`）；`unzip(path, dir)` 走同一构造（`f_zip/src/Unzip.cj:47`）；`unzipInto` 的 `Directory.create` 与 `writeEntryToFile` 的 `File(...)`/`file.write` 也未包装（`Unzip.cj:82-86`、`:142-166`）；`ZipWriter.add` / `addFileStream` 的 `catch (e: Exception) { markDirty(...); throw e }` 原样重抛（`ZipWriter.cj:113-119`、`:189-192`）；`addFile` 的 `File(path.toString(), OpenMode.Read)` 同样直接抛（`ZipWriter.cj:312-325`）。
- **描述**：文档写「对外只抛 `ZipException`」「唯一异常类型」，调用方按此只 `catch (ZipException)` 时，路径不存在、权限不足、磁盘写满、stdx zlib 异常都会漏网。设计稿 §8 只列了 11 条 `ZipException` 消息，进一步强化了这个误解。
- **建议**：二选一并同步三处文档：① 所有公共入口把 fs / zlib 异常包装成 `ZipException`（保留 cause 文案）；② 改成「ZIP 结构与安全类错误抛 `ZipException`，IO / 压缩器异常按原类型透传」，并在 `api.md` 列出会透传的类别。

### [一般][存量] 推模式 `openEntry` 未回写 `api.md` 与变更规格；「九个公开名字」已过期

- **位置**：`f_zip/doc/api.md:3`、`:43-55`、`:113-118`、`f_zip/README.md:249`、`f_zip/doc/spec/add-f-zip-module/design.md:41-44`、`f_zip/doc/spec/add-f-zip-module/proposal.md:55`
- **来源**：存量（`api.md` 最后为 `bc44964e4`；`openEntry` 由 `00ca5ed91`「新增 openEntry 推模式流式条目与按句柄解压流」引入，该提交未改 `api.md` / spec）
- **判据**：review-checklist §13（API 与源码不符）/ §14.2（公开 API 未文档化）
- **证据**：静态确定 —— 模块顶层 `public` 类型/函数按名字计 10 个：`ZipReader`、`ZipWriter`、`ZipEntry`、`ZipLimits`、`ZipWriterOptions`、`CompressionMethod`、`ZipException`、`ZipEntryOutputStream`（`f_zip/src/ZipEntryOutputStream.cj:31`）、`zip`、`unzip`；`api.md:3` 与 `README.md:249` 仍写「九个名字」，`api.md:116` 还写「不需要 f_zip 提供推模式（`openEntry(name): OutputStream`）」，而 `ZipWriter.cj:216` 已提供、`README.md:143/154` 已宣传。
- **描述**：同一份发布物里 README 说有推模式、api.md 说没有、变更规格把它列为 Non-Goals；用户按 `doc/` 选型会得到相反结论，按 `api.md` 写代码会漏掉 `ZipEntryOutputStream`。README 也未写推模式最容易踩的独占约束：条目流未 `close()` 前，其它 `add*` / `openEntry` / `close()` 抛异常（`ZipWriter.cj:214`、`:385-387`、`:453-462`）。
- **建议**：① `api.md` 补第 10 个名字与 `openEntry` 小节；② 归档规格的 Non-Goals / Out of Scope 标注「后续已实现（`00ca5ed91`）」；③ README 的 `openEntry` 行补独占约束与「关闭条目后才登记中央目录」。

### [一般][存量] 「写入仅在越界时升级、小文件不产生任何 ZIP64 字节」对流式条目为假

- **位置**：`f_zip/README.md:31`、`f_zip/README_en.md:37-38`、`f_zip/doc/spec/add-f-zip-module/specs/f-zip-container/spec.md:114-118`
- **来源**：存量（快照无基线；README 两句均为模块首提 `66d934e7`）
- **判据**：review-checklist §13（文档承诺与实现相反）
- **证据**：静态确定 —— `writeLocalHeader` 的流式分支**无条件**写 `version needed = 45` 与 extra `0x0001`（两个 8 字节 0 占位）：`f_zip/src/LocalHeader.cj:201-207`；`addFileStream` / `openEntry` 都置 `header.streaming = true`（`ZipWriter.cj:160`、`:234`），数据后固定写 24 字节 descriptor（`ZipWriter.cj:185-188`、`ZipEntryOutputStream.cj:135-153`）。
- **描述**：该承诺只对 `add()` / `addDirectory()` 的内存路径成立。流式条目即使内容 1 字节，也带 version 45、extra `0x0001`（16 字节）与 ZIP64 形式 descriptor；`specs/f-zip-container/spec.md` 场景「所有 header 的 extra 里没有 `0x0001`」在流式样本上必然失败。设计稿 §5.2「流式条目一律用 ZIP64 形式」才是正确口径。
- **建议**：README 中英两处限定为「非流式条目」；container spec 的小文件场景补「流式条目除外，见 §5.2」。

### [一般][存量] ZIP64 条目数边界在两份变更文档里写成 `> 0xFFFF`，与设计稿 / 规格 / 实现的 `≥` 相反

- **位置**：`f_zip/doc/spec/add-f-zip-module/design.md:90`（D5）、`f_zip/doc/spec/add-f-zip-module/proposal.md:16`
- **来源**：存量（两份文档均 `66d934e7` 入库）
- **判据**：review-checklist §13（规格与实现漂移）/ §11（边界差一）
- **证据**：静态确定 —— 实现为 `Int64(entries.size) >= ZipLayout.ZIP64_MAX_U16`（`f_zip/src/ZipWriter.cj:396-398`），`ZipLayout.cj:99-106` 注释说明「0xFFFF 本身在读取侧是哨兵」；模块设计稿 `doc/f_zip模块设计.md:342-345`、`:1071-1076` 与 `specs/f-zip-container/spec.md:112` 都写 `≥`。
- **描述**：D5 与 proposal 的「条目数 > `0xFFFF` 才升级」正是设计稿点名警告的边界错误：恰好 65535 条时普通 EOCD 会写入真实值 `0xFFFF`，自家 reader 按哨兵去找不存在的 EOCD64 定位器，产出的包读不回来。实现目前是对的，但规范自相矛盾，后续按 D5 改写或重写会重新引入。
- **建议**：两处统一为 `≥ 0xFFFF`，并在 D5 引用 `Zip64EntryCount_test.exactly65535EntriesWritesZip64` 作为钉子。

### [一般][存量] README「其他公开 API」把 30+ 个 `internal` 类型成员列为对外 API

- **位置**：`f_zip/README.md:254-258`、`f_zip/README_en.md:277-281`
- **来源**：存量（`f624bf2fa`「各模块按最新代码补『其他公开 API』小节」，2026-11-11）
- **判据**：review-checklist §14.2（公开 API 覆盖写反）/ §13（文档与实现不符）；硬原则二（非公共顶级声明里的 `public` 成员对外不可达）
- **证据**：静态确定 —— 列表中 `cdOffset` / `cdSize` / `entryCount` / `eocdOffset` / `eocd64Offset` 属于 `internal struct EocdInfo`（`Eocd.cj:21`）；`versionMadeBy` / `internalAttributes` / `externalAttributes` / `nameBytes` / `comment` / `crc` / `flags` / `dosTime` / `dosDate` 属于 `internal class CentralEntry`（`CentralHeader.cj:25`）；`originalSize` / `compressedSize` / `localHeaderOffset` / `diskStart` 属于 `internal struct Zip64ExtraValues`（`LocalHeader.cj:30`）；`streaming` / `dataOffset` 属于 `internal class LocalHeader`（`:177`）；`allocate` / `allocateDirectory` / `insertSuffix` / `size` 属于 `internal class EntryNameTable`（`EntryNameTable.cj:30`）；`candidates` / `createFile` / `createIn` / `fallbackDirectory` 属于 `internal class TempSpill`（`TempSpill.cj:35`）；`readAt` / `openRange` / `left` / `checksum` / `closeQuietly` / `empty` 分属 `internal` 的 `EntrySource` / `BoundedInputStream` / `Crc32InputStream` / `Zip64ExtraValues`。
- **描述**：这些名字在包外不可见，下游 `import fountain::f_zip.*` 后无法引用；README 却称「以下声明未在上文展开……完整语义见 `src/`」，与 `api.md:3` 的「对外只有九个名字」直接冲突。按文档写代码会全部编译失败，也会诱导使用者误判模块的稳定 API 面。列表中至少 `dataOffset`（只写不读，`LocalHeader.cj:190` + `ZipReader.cj:236`）、`left`、`size()`、`eocd64Offset` 在仓内没有读取方，更说明它们是内部实现细节而非 API。
- **建议**：删除该小节，或改成「以下为 `internal` 实现，不对外」；另起一节只列 10 个真正公开的名字。

### [轻微][存量] 设计稿承诺 bit 13（掩盖 local header）报错，实现没有这道检查

- **位置**：`f_zip/doc/f_zip模块设计.md:303-310`（§2.2 表 bit 13「报错」）
- **来源**：存量（`66d934e7`）
- **判据**：review-checklist §14.1（承诺了但没实现）/ §13（文档与实现不符）
- **证据**：静态确定 —— `ZipLayout` 只有 `FLAG_ENCRYPTED` / `FLAG_DATA_DESCRIPTOR` / `FLAG_STRONG_ENCRYPTION` / `FLAG_UTF8_NAME` 四个 flag 常量（`ZipLayout.cj:85-88`），没有 bit 13（`0x2000`）；`checkEntryReadable` 只判 bit 0 与 bit 6（`ZipReader.cj:202-216`）；全仓 `0x2000` 无生产代码命中。
- **描述**：APPNOTE 的 bit 13 与加密位（bit 0 / bit 6）同现时，本实现会先按「不支持加密 ZIP」拒绝，所以正常样本不会走到「用被掩码的 local header 长度定位数据」这一步；本条的实际影响是**设计表承诺的可诊断错误不存在**，对手工构造的「只置 bit 13、不置加密位」畸形包会按普通 header 解析，失败信息退化为 CRC/大小不符。
- **建议**：二选一并两侧同步——① 补 `FLAG_MASKED_LOCAL_HEADER = 0x2000`，`checkEntryReadable` 命中即抛 `ZipException("不支持掩盖 local header 的 ZIP（${name}）")`；② 从 §2.2 删除该行，注明「不识别 bit 13，按普通 header 解析，由 CRC/大小校验兜底」。

### [轻微][存量] 两份设计稿把 `ZipException` 的基类写成 `Exception`，与实现和同节另一处相反

- **位置**：`f_zip/doc/f_zip模块设计.md:1125`、`f_zip/doc/spec/add-f-zip-module/design.md:184`
- **来源**：存量（`66d934e7`）
- **判据**：review-checklist §13（API 与源码不符）
- **证据**：静态确定 —— 实现 `public class ZipException <: BaseException`（`f_zip/src/ZipException.cj:38`）；同一份文档的 §8/D14 后文又写「继承 `f_base.BaseException`」（`doc/f_zip模块设计.md:198`、`spec/.../design.md:198`），README:230 亦然。
- **描述**：`Exception` 与 `BaseException` 的 catch 覆盖面不同，照设计稿写 `catch (e: Exception)` 的调用方可能接不住 `ZipException`，属于会误导错误处理的类型声明错误（README 与 api.md 是对的，风险仅在读设计稿的人）。
- **建议**：两处代码块改为 `<: BaseException`，并补一句「与仓库其它模块一致，继承 `f_base.BaseException`」。

### [轻微][存量] §9 仍写「9.7b 暂未跑通」，与 §10 已回填的 200 s 实测矛盾

- **位置**：`f_zip/doc/f_zip模块设计.md:1178`
- **来源**：存量（`a0ee9a80d` 在 §10 回填实测，漏改 §9）
- **判据**：review-checklist §13（文档过期）
- **证据**：静态确定 —— 同文件 §10 `:1259` 写「`9.7b`（单条目 4 GiB + 4096 字节的 Stored 往返）**200 s**（写出 94 s、读回 105 s）」；`doc/spec/add-f-zip-module/tasks.md:325-326` 已勾选「2026-10-28 通过」。
- **描述**：读者按 §9 会以为 4 GB 条目仍未验收，与 §10 和 tasks 的结论冲突。
- **建议**：§9 该行改为「已跑通，200 s，见 §10 与 `Zip64BigEntry_test`」。

### [轻微][存量] 设计稿 API / 伪代码与实现漂移（7 处）

- **位置**：`f_zip/doc/f_zip模块设计.md:580-585`、`:646-654`、`:716-717`、`:796`、`:1092`、`:1338`、`:134`、`:817`；`f_zip/doc/spec/add-f-zip-module/design.md:70`
- **来源**：存量（`66d934e7`；§10 由 `1026bb21d` 局部更新）
- **判据**：review-checklist §13（规格与实现漂移）
- **证据**：静态确定 ——
  1. `insertSuffix` 伪代码用 `if (dot <= slash)`（`:583`），会把 `.gitignore` 判成有扩展名（得到 `_2.gitignore`），与同节边界表 `:596-597`（`.gitignore → .gitignore_2`）和实现 `EntryNameTable.cj:80`（`dot <= slash + 1`）都相反。
  2. `ZipWriterOptions` 片段（`:646-654`）用字段默认值 `public var memoryEntryThreshold: Int64 = defaultMemoryEntryThreshold()`，实现是构造函数命名参数默认值（`ZipWriterOptions.cj:59-67`）。
  3. 两处写「四份声明」（`:716-717`、`:1338`），实际只有 `defaultMemoryEntryThreshold` 两份 `@When` 声明（`ZipWriterOptions.cj:36-45`）。
  4. `close()` 伪代码要求「无条目需要 ZIP64」才写普通 EOCD（`:1092`），实现只判条目数 / CD 大小 / CD 偏移（`ZipWriter.cj:396-400`）；单条目越界由各 header 自己的 extra 承担，不会触发 EOCD64。
  5. `zip` 签名写作 `zip(output: OutputStream, dir: Path)`（`:796`），实现与 README 都有 `options!`（`Zip.cj:35`、`README.md:79-80`）。
  6. 依赖树与读取流程把解压流写成 `CompressInputStream`（`:134`、`:817`），同文件 `:149` 又强调「解压用的是 `DecompressInputStream`，不是 `CompressInputStream`」，实现导入的也是 `DecompressInputStream`（`ZipReader.cj:21`）。
  7. 变更规格 D2 写 `BufferSource` 用 `ByteBuffer.clone()`（`spec/.../design.md:70`），实现是共享数组 + 独立游标（`EntrySource.cj:63-65`）；模块设计稿 `:62-63` 已登记该偏差但 spec 未同步。
- **描述**：这些都是「照抄会写错」的陷阱，第 1 条会直接改变同名改名结果，第 6 条会让人找不到 API。
- **建议**：以实现为准逐条修订；`insertSuffix` 片段直接对照 `EntryNameTable.cj:75-84` 重写，并注明「点必须在段首之后才算扩展名」。

### [轻微][存量] 设计稿存在整段重复：同一段 `add()` 伪代码出现两次，§7.3 同一句重复两遍

- **位置**：`f_zip/doc/f_zip模块设计.md:613-622` 与 `:748-757`；`:1116` 与 `:1118`
- **来源**：存量（`66d934e7`）
- **判据**：review-checklist §2（重复逻辑——文字 / 代码块复制）
- **证据**：静态确定 —— 两处 `add(name, data): if (data.size <= memoryEntryThreshold) …` 逐行相同；`:1116` 与 `:1118` 是逐字相同的「bit 0 或 bit 6 置位 → 直接报错」段落。
- **描述**：§3.4 与 §3.4.2.1 各自维护一份伪代码，已出现改一处漏一处（上条 `insertSuffix` 即同源）；加密段落在 §7.3 重复，读者会怀疑是否漏了第二种情形。
- **建议**：删除 `:748-757`，改为「同 §3.4 的伪代码」；删除 `:1118` 重复行。

### [轻微][存量] 错误消息表：`缺少 data descriptor` 永不抛出；「报方法名」与实现 / 规格的「报数值」不一致

- **位置**：`f_zip/doc/f_zip模块设计.md:1141`、`:976`
- **来源**：存量（`66d934e7`）
- **判据**：review-checklist §13（文档承诺与实现不符）
- **证据**：静态确定 —— `缺少 data descriptor（bit 3 置位但数据后无签名）` 只出现在 `ZipException.cj:34` 的 KDoc，全模块无抛出点；读取侧从不解析 descriptor，只信中央目录的大小与偏移（`ZipReader.cj:218-238`）。§6.3 要求「报**具体的方法名**」，实现与 container spec 只报数值 `不支持压缩方法 ${method}（${name}）`（`ZipReader.cj:207`、`specs/f-zip-container/spec.md:129`）。
- **描述**：调用方按错误表做分支 / 告警时，第一条永远不会命中；按「方法名」匹配第三条也会落空。
- **建议**：删除未实现的错误消息；§6.3 改为「报方法数值与条目名（数值足以区分算法不支持与文件损坏）」，或实现方法名映射后同步 spec。

### [轻微][存量] 「`zip` / `unzip` 全程流式」对 `unzip(input: InputStream)` 不成立

- **位置**：`f_zip/README.md:33`、`f_zip/README_en.md:41`
- **来源**：存量（`66d934e7`）
- **判据**：review-checklist §13（文档承诺与实现相反）
- **证据**：静态确定 —— `unzip(input, dir, limits)` 构造 `ZipReader(input, limits)`（`Unzip.cj:34-35`），该构造函数把整个流读进内存（`ZipReader.cj:52-55` → `readAllBytes`，`:333-342`）；只有 `unzip(path, dir)` 走 `File.seek`。
- **描述**：使用者为了「不吃内存」选用流式 `unzip(input)` 时，RSS 仍等于整包大小，与同一段「大文件不吃内存」的承诺相反。`zip(output, dir)` 确实是流式的，问题只在 `unzip` 的流重载（README:109 其实写明 `ZipReader(input)` 全量缓冲，两处结论互相矛盾）。
- **建议**：改为「`zip` 与 `unzip(path)` 全程流式；`unzip(input)` 需要先把整个流读进内存（ZIP 随机访问所需）」。

### [轻微][存量] 分卷 ZIP 拒绝没有进 README 的能力 / 错误清单

- **位置**：`f_zip/README.md:235`、`:237-244`、`f_zip/doc/api.md:104-111`、`f_zip/doc/f_zip模块设计.md:1131-1143`
- **来源**：存量（分卷校验由 `bc44964e4`「第三轮 verify 返修：分卷 ZIP 校验」加入，文档未回写）
- **判据**：review-checklist §14.2（README 缺关键限制段落）/ §13（错误消息表不全）
- **证据**：静态确定 —— EOCD 与 EOCD64 的 disk 字段非 0 即抛 `不支持分卷 ZIP（disk ${disk}）`（`f_zip/src/Eocd.cj:94-106`、`:142-152`）；`README*.md`、`doc/api.md`、`doc/f_zip模块设计.md` 全仓 `grep "分卷"` 零命中，只有 `doc/spec/add-f-zip-module/proposal.md:54` 的 Out of Scope 提到。
- **描述**：用户拿到分卷包时只能从异常文案推断；README 的「安全默认值 / 限制」与 `ZipException` 错误清单都缺一条已实现的拒绝路径。
- **建议**：README「安全默认值」或「ZipException」段补「分卷 / 多磁盘 ZIP（disk ≠ 0）→ 拒绝」，并同步 api.md 与设计稿 §8 错误表。

### [轻微][存量] 「不返回部分数据」被扩到 `open` 流，与「读到 EOF 才校验」自相矛盾

- **位置**：`f_zip/doc/api.md:81-85`、`f_zip/doc/spec/add-f-zip-module/specs/f-zip-reader/spec.md:105-112`
- **来源**：存量（`api.md` `bc44964e4`；reader spec `66d934e7`）
- **判据**：review-checklist §13（文档内部矛盾）/ §11（契约与实现不符）
- **证据**：静态确定 —— `open` 返回的 `ZipEntryInputStream.read` 每读一块就返回并累计（`ZipReader.cj:309-328`），只有下一次读到 `<= 0` 才校验 CRC 与大小；超限也在 `account` 抛出（`:270-278`），此时调用方已拿到前序字节。README:112 自己也写「`open` 读到 EOF 才校验 CRC 与解压大小」。
- **描述**：`read(name)` 是原子返回，`open(name)` 按定义是流式；文档把「不返回部分数据」同时套到两者，会让调用方误以为 `open` 在超限 / CRC 失败时不会交付任何字节。实际语义应是「不把该条目报告为成功」。
- **建议**：`api.md` 与 reader spec 限定为「`read()` 不返回部分数据；`open()` 在 EOF / 超限处抛错，此前已交付的字节无法收回」，并在 `open` 小节写明调用方需自行丢弃已读数据。

存量缺陷共 14 条（严重 0 / 一般 5 / 轻微 9），是否纳入修复由用户决定。

<!-- 第 2 部分 -->

### [严重][存量] #1 EOCD 的 `cdSize` 不与文件长度交叉校验，`readFullyAt` 先按该长度预分配 —— 22 字节文件可触发约 4 GiB 分配

- **位置**：`f_zip/src/Eocd.cj:109`（`cdSize` 直接取自 EOCD）、`f_zip/src/Eocd.cj:165-169`（`checkCdOffset` 只校验 `cdOffset`）、`f_zip/src/Eocd.cj:47`（`Array<Byte>(want, repeat: 0)`）
- **来源**：存量（`git log --oneline -- f_zip/src/Eocd.cj` 为 `bc44964e4`、`66d934e7f`）
- **判据**：review-checklist §5「按不可信长度预分配」、§11「缺少边界校验」
- **证据**：静态确定 —— `cdSize` 是 EOCD 的 32 位字段（≤ `0xFFFFFFFF`），`checkCdOffset` 只判断 `cdOffset < 0 || cdOffset > size`，从不与 `cdSize`、`eocdOffset` 做关系校验；`readFullyAt` 在**读之前**就 `Array<Byte>(want, repeat: 0)`，长度完全等于 `want`。调用链：`ZipReader(path|input)` → `loadDirectory()`（`f_zip/src/ZipReader.cj:184-198`）→ `readFullyAt(source, info.cdOffset, info.cdSize)`（`ZipReader.cj:192`）。
- **描述**：构造 22 字节的「EOCD-only」文件：`entryCount = 1`（低于 `maxEntries` 默认 65535，能过 `ZipReader.cj:186` 的检查）、`cdSize = 0xFFFFFFF0`、`cdOffset = 0`。`ZipReader` 构造函数里立刻申请 4 292 967 280 字节，然后才发现「读不满 → 抛 `ZipException`」。也就是说：任何接收不可信 ZIP 的入口都能用 22 字节输入换一次 4 GiB 分配，并发解压时是稳定的 OOM / GC 抖动放大面。同一根因还让 `cdOffset + cdSize > eocdOffset`（中央目录延伸到 EOCD 之后）这类结构上不可能的包一路进入解析。
- **建议**：`checkCdOffset` 改成完整关系校验——`cdSize >= 0 && cdOffset >= 0 && cdOffset + cdSize <= eocdOffset`（ZIP64 分支同，且用减法形式避开溢出，见 #6）；`readFullyAt` 分配前用 `source.size` 兜底：`offset < 0 || offset > source.size || want > source.size - offset` 直接抛 `ZipException`。用例：把 `buildRawZip` 的 EOCD `cdSize` 改成 `0xFFFFFFF0`，断言抛 `ZipException` 且 `getAllocatedHeapSize()` 前后差 < 1 MB。

### [严重][存量] #2 `FileSource.readAt` 共用同一个 `File` 游标（seek + 读循环非原子），与 `ZipReader` 注释承诺的「`read()` 可并发调用」冲突

- **位置**：`f_zip/src/EntrySource.cj:89-110`（`99` 行 `file.seek(Begin(offset))`，`101-108` 行读循环）；被违背的承诺在 `f_zip/src/ZipReader.cj:34-35`、`f_zip/README.md:110`、`f_zip/doc/api.md:31`
- **来源**：存量（`af3ca77d8` 改写了读循环，`66d934e7f` 引入）
- **判据**：review-checklist §12.1「共享可变状态无保护」、§11「契约与实现不符」
- **证据**：静态确定 —— `FileSource` 只有一个 `private var file: File`（`:73`），`readAt` 的「seek 到 offset → 循环 read」没有任何锁 / 原子 / 线程封闭；`openRange` 每次另开句柄（`:112-114`），说明"另开句柄"只解决了 `open` 路径，没覆盖 `readAt`。并发路径明确：`ZipReader.read(name)` → `decodeEntry` → `locateData` → `readFullyAt` → `source.readAt`（`ZipReader.cj:192`、`:224`、`:233`）。`BufferSource`（`ZipReader(input)`）无状态、每流独立游标，不受影响。
- **描述**：两线程对同一 `ZipReader(path)` 调 `read("a")` / `read("b")`：T1 `seek(100)` 后、`read` 前被 T2 的 `seek(200)` 顶掉，T1 读到 200 处内容 → local header 签名不符或 `nameLen/extraLen` 荒谬 → 随机抛 `ZipException`；极端时序下长度恰好合法，则数据起点算错、内容错位（多数被 CRC 兜住，但报错指向完全无关的原因）。服务端共享一个 `ZipReader(path)` 是最自然的用法，这条把注释里的承诺变成了随机失败。
- **建议**：按代价从低到高：① `FileSource` 加 `Mutex`，只包住 `seek + 读循环`；② `readAt` 每次 `openRange` 式另开句柄；③ 让 `locateData` 也走 `openRange` + 读满关流。改了实现就同步 `ZipReader.cj:34-35`、`README.md:110`、`doc/api.md:31` 的措辞；若选 ①，补一条双线程交叉 `read` 的压力用例。

### [一般][存量] #3 ZIP64 形式的 disk number（`0xFFFF`）解析出 extra 里的盘号后从未校验 —— 分卷条目被当单卷接受

- **位置**：`f_zip/src/CentralHeader.cj:154-156`（放行 `0xFFFF`）、`:162`（`wantDiskStart = diskStart == 0xFFFF`）、`:165-179`（只用 size / offset，`zip64.diskStart` 无人消费）；字段定义在 `f_zip/src/LocalHeader.cj:34`
- **来源**：存量（`66d934e7f` 引入；`bc44964e4` 只补了 EOCD 层的分卷校验）
- **判据**：review-checklist §11「契约与实现不符」、§1「读了不用」
- **证据**：静态确定 —— 全仓 `grep "diskStart"` 只命中 `CentralHeader.cj:146/154/155/162`、`LocalHeader.cj:34/40/45/64/78`（编码侧）与 `Zip64ExtraValues` 的构造；`parseZip64Extra` 的返回值里 `diskStart` 从未被读。EOCD 层（`Eocd.cj:99-106`、`:145-152`）对分卷是「读到就报」，条目层却开了口子。
- **描述**：`if (diskStart != 0 && diskStart != 0xFFFF) throw` 的意图是「非 0 就是分卷」，但 ZIP64 条目恰恰把真实盘号放在 extra 里：`diskStart = 0xFFFF` + extra 中 disk = 1 的条目一路无阻，最终用「别的盘上的偏移」在本文件里取数据 —— 通常以 `local header 截断` 或 CRC 失败收场，错误信息与真实原因（分卷）完全无关。
- **建议**：`parseZip64Extra` 返回后补 `if (let Some(d) <- zip64.diskStart) { if (d != 0) throw ZipException("不支持分卷 ZIP（条目 ${e.name} 的 disk number start = ${d}）") }`；补一条用例（CD 的 `diskStart = 0xFFFF` + extra 中 disk = 1 → 断言抛「分卷」）。

### [一般][存量] #4 条目名 / extra / comment 长度按 `UInt16` 静默截断，写入侧没有任何上限校验

- **位置**：`f_zip/src/CentralHeader.cj:111`（`writeU16LE(out, UInt16(e.nameBytes.size))`，另见 `:112` extra、`:113` comment）、`f_zip/src/LocalHeader.cj:239`（local header 的 name length，另见 `:240` extra）
- **来源**：存量（`66d934e7f`）
- **判据**：review-checklist §11「静默数据错误 / 缺少边界校验」
- **证据**：静态确定 —— 写入侧只有这三处 `UInt16(...)` 强转，`grep "65535"` 在 `src/` 只命中 `ZipLayout.ZIP64_MAX_U16`，没有任何 `> 0xFFFF` 的判断；`ZipWriter.add*(name)` 是公开入口，`name` 长度不受约束。
- **描述**：传入 ≥ 64 KiB 的条目名（或 comment）时，头里的长度字段写成截断值（70000 → 4464），而 `out.write(e.nameBytes)` 仍写 70000 字节 → 之后所有字段与偏移整体错位。写侧不报错、`close()` 正常返回，产物是结构损坏的 ZIP，问题被推到下游（自家 reader / `7za t` 报「签名不符」）才发现。
- **建议**：`ZipWriter.add*` 入口（分配名字之前）校验 `name.toArray().size <= 0xFFFF`，超限抛 `ZipException("条目名过长：${len} 字节（上限 65535）")`；`writeCentralHeader` / `writeLocalHeader` 里把 `UInt16(...)` 换成带校验的辅助函数，避免二次回归。

### [一般][存量] #5 `decodeName` 在 bit 11 置位时直接 `String.fromUtf8`，非法字节抛 `IllegalArgumentException`，违反「不抛异常」的注释与「失败一律 `ZipException`」的契约

- **位置**：`f_zip/src/NameCodec.cj:53-56`（`if (utf8Flag) { return String.fromUtf8(bytes) }`）；被违背的注释在 `:50-52`（「任何输入都能得到一个字符串，不抛异常」）
- **来源**：存量（`66d934e7f`）
- **判据**：review-checklist §13「文档承诺与实现不符」、§11「错误处理 / 异常类型不符契约」
- **证据**：静态确定 —— `std/core/core_package_api/core_package_structs.md:6386`（`static func fromUtf8` 的「异常」小节）：「`IllegalArgumentException` - 入参不符合 utf-8 序列规则……抛出异常」；同文件 `fromUtf8Unchecked`（`:6411`）才是"不校验"的版本。本模块 `strictUtf8` 手写校验的理由正是"解码器会替换成 U+FFFD 而不报错"（`NameCodec.cj:88-93`），与 bit 11 分支的行为不一致。
- **描述**：伪造一个 bit 11 置位、名字字节为 `0xC3` 的条目：`entries()` / `read()` / `contains()` 触发 `CentralEntry.name`（`CentralHeader.cj:41-45`）→ `decodeName(bytes, true)` → `IllegalArgumentException` 逃出本模块的错误契约（调用方按 `doc/api.md` 只 catch `ZipException` 时会当未知异常冒到上层）。同时 bit 11 条目完全不走 `UTF-8 → GBK → Latin-1` 回退链，与「任何输入都能得到字符串」的目标相反；GBK 分支同类风险已被 `decodeGbk` 的 `catch` 挡住，只有这条裸奔。
- **建议**：bit 11 分支先走 `strictUtf8`，失败后回退 `decodeGbk → latin1`；若坚持「bit 11 即 UTF-8」，至少 `try { String.fromUtf8(bytes) } catch (_: IllegalArgumentException) { latin1(bytes) }`，并把注释改成与实现一致。补一条「bit 11 + 非法字节」用例。

### [一般][存量] #6 ZIP64 定位器偏移用 u64 直转 `Int64` 后做 `+ 56` 比较，越界触发溢出异常而非 `ZipException`

- **位置**：`f_zip/src/Eocd.cj:134-137`（`let eocd64Offset = Int64(u64At(locator, 8))`；`eocd64Offset + ZipLayout.EOCD64_SIZE > size`）
- **来源**：存量（`66d934e7f`）
- **判据**：review-checklist §11「错误处理 / 异常类型」、§10 边界
- **证据**：静态确定 —— 整数运算默认溢出策略为 `throwing`（`cangjie_docs/docs/dev-guide/source_zh_cn/Appendix/compile_options.md:235-237`：「默认为 `throwing`……整数运算溢出时会抛出异常」）。把 locator 的 offset 填成 `0x7FFF_FFFF_FFFF_FFFF`：`Int64(...)` 得到 `Int64.Max`，`+56` 立即溢出抛 `OverflowException`，绕过「所有失败都是 `ZipException`」的统一约定；大于 `Int64.Max` 的值在转换一步就可能抛同类异常（转换语义未逐个核对，结论对这两条路径都成立）。
- **描述**：调用方按文档只 catch `ZipException` 时表现为「未知异常」，`unzip` 的安全层（限额 / 半截文件清理）也接不住。同一文件的 `checkCdOffset` 用的是简单比较（没有 `+`，安全），但 `readZip64Eocd:135` 这处是 attacker-controlled 路径。
- **建议**：改成减法形式：`if (eocd64Offset < 0 || eocd64Offset > size - ZipLayout.EOCD64_SIZE)`（先判 `size >= EOCD64_SIZE`）；补一条用例：locator offset = `0x7FFFFFFFFFFFFFFF` → 断言抛「ZIP64 EOCD 偏移……超出文件长度」。

### [一般][存量] #7 `open()` 返回的条目流没有关闭途径（`InputStream` 只有 `read`，两处包装都未实现 `Resource`），提前放弃读取会一直占着文件句柄

- **位置**：`f_zip/src/BoundedStream.cj:103-150`（`FileRangeInputStream` 在 `:109` 打开 `File`，只有 `closeQuietly`，且仅被自身 `read` 的三个分支调用）、`f_zip/src/ZipReader.cj:291-330`（`ZipEntryInputStream` 只实现 `read`）
- **来源**：存量（`af3ca77d8`、`66d934e7f`）
- **判据**：review-checklist §11「资源不对称：打开未关、异常跳过释放」、mem §6（句柄生命周期）
- **证据**：静态确定 —— `std/io/io_package_api/io_package_interfaces.md:6-8`：`public interface InputStream { func read(buffer: Array<Byte>): Int64 }`，**没有 `close`**；关闭能力来自另一个接口 `Resource`（`f_io/src/DummyInputStream.cj:18` 的 `InputStream & Resource`、`f_io/src/BytePointerStream.cj:24` 的 `IOStream & Resource` 是仓内现成用法）。本模块两个包装类都没有实现 `Resource`，`ZipReader.openEntry`（`ZipReader.cj:143-150`）对外只暴露 `InputStream`。
- **描述**：`open(name)` 的典型用法就是"读一部分"（内容嗅探、只取前 4 KiB、按行读到第一行）。两种情况句柄不会及时归还：① 调用方提前 `return`；② 中途抛错（`owner.account` 触发限额、解压失败）。句柄只在"读到窗口末尾"时才由 `read` 内部关闭，于是批量处理 N 个条目时 FD 峰值不可控；Windows 上残留句柄还会让 ZIP 无法删除 / 改名。仓库内已有真实触发路径：`f_zip/src/Unzip.cj:147-171` 的 `writeEntryToFile` 在 `stream.read` 抛异常时，`finally` 只关 `target`、删半截文件，**不关 `stream`**；反复解压被限额打断的恶意包会持续累积 fd。`Resource*` 系列用例都是"读到底"，测不出这条。
- **建议**：让 `FileRangeInputStream` 与 `ZipEntryInputStream` 实现 `Resource`（`public func close(): Unit`），`ZipEntryInputStream.close()` 转发给 `inner`；并把未关闭的 range 流登记到 `ZipReader`，`ZipReader.close()` 统一收尾。`Unzip.writeEntryToFile` 把 `stream` 纳入 `finally`。用例：开 1000 个条目各读 1 字节后丢弃，`/proc/self/fd` 计数不线性增长。

### [轻微][存量] #8 重复逻辑：`LeBytes` 里 8 个端序原语两两同体（只差输入/出口）

- **位置**：`f_zip/src/LeBytes.cj:62-85`（`readU16LE/readU32LE/readU64LE`）↔ `:160-175`（`u16At/u32At/u64At`）；`:87-109`（`writeU16LE/writeU32LE/writeU64LE`）↔ `:112-134`（`u16LEBytes/u32LEBytes/u64LEBytes`）
- **来源**：存量（`66d934e7f`）
- **判据**：review-checklist §2「只改类型名 / 换控制流」
- **证据**：静态确定 —— 逐字节展开的移位与掩码在两处完全一致（`b[0] = UInt8(v & 0xFF); b[1] = UInt8((v >> 8) & 0xFF)`），差异只有「写进流」还是「返回数组」、「读缓冲」还是「按偏移取值」。
- **描述**：8 个函数、4 组语义，任何一处位移写错都要改两遍（`readU32LE` 与 `u32At` 的换行风格也已不一致）。合并成本为零：`writeU16LE` 改成 `out.write(u16LEBytes(v))` 不会多一次分配。
- **建议**：`write*LE` 改为 `out.write(u*LEBytes(v))`；`read*LE` 内部改成 `readBytes(buf, n)` + `u*At(b, 0)`（保持「越界不动游标」语义）。合并后配合 `LeBytes_test` 的往返/越界用例守住。

### [轻微][存量] #9 重复逻辑 + 行为漂移：三份「限长读」实现，空缓冲处理三者不一致（`FileRange` 空读会直接关句柄）

- **位置**：`f_zip/src/BoundedStream.cj:42-63`、`:83-97`、`:116-140`；空缓冲判断在 `:43-45`、`:84-86`、`:117-120`
- **来源**：存量（`af3ca77d8` 把三处都改成「读进目标切片」）
- **判据**：review-checklist §2「换控制流 / 近似重复」、§11「边界」
- **证据**：静态确定 —— 三者骨架相同（判剩余 → 取 `min(buffer.size, left)` → 读/拷贝 → 递减），差异是数据源与"到 EOF 是否 close"；`FileRangeInputStream` 自己又实现了一遍 `BoundedInputStream` 的限长逻辑。空缓冲分支三者都归到 `-1`，其中 `FileRange` 还先 `closeQuietly()`（`:118`）。
- **描述**：调用方做一次 `stream.read(Array<Byte>())` 探测（或用 `buffer[0..0]`）时：`Bounded` / `ArrayRange` 返回 -1（被外层 `while (n > 0)` 当成流结束，条目被判「数据不完整」）；`FileRange` 更重——直接关句柄，此后该条目任何读取都返回 -1。三份实现漂移是 `af3ca77d8` 一次同改三处的直接产物，后续新增流类型很容易再踩。
- **建议**：`FileRangeInputStream` 只保留「独立句柄 + 可关闭」职责，限长交给组合（底层实现一个内部 `Closeable`，由 `BoundedInputStream` 在耗尽时回调）；空缓冲统一 `return 0` 且不改状态（不关句柄、不动 `remaining`）。改完补一条「空读后仍能正常读到数据」与「到 EOF 仍关句柄」的用例。

### [轻微][存量] #10 重复逻辑：ZIP64 哨兵判定与分卷盘号校验各写了两份

- **位置**：`f_zip/src/LocalHeader.cj:209-227` ↔ `f_zip/src/CentralHeader.cj:69-87`（哨兵判定 + `buildZip64Extra`）；`f_zip/src/Eocd.cj:99-106` ↔ `:145-152`（分卷盘号 + 同一条错误消息）
- **来源**：存量（`66d934e7f`；`Eocd.cj` 的 ZIP64 那份在 `bc44964e4`）
- **判据**：review-checklist §2「字面量复制 / 换算复制」
- **证据**：静态确定 —— 两处哨兵判定都是 `origOver/compOver(±offsetOver) → version = 45 → 哨兵字段 → buildZip64Extra`，差异仅「central 多 offset、local 多 version 赋值」；两处分卷校验都是 `let disk = if (x != 0) {x} else {y}` + `throw ZipException("不支持分卷 ZIP（disk ${disk}）")`（一处 u16、一处 u32）。
- **描述**：「两处各判一次 ZIP64」已经出过一次真实漂移（`tasks.md:17.2`：写侧 `>` 与读侧哨兵口径不一致，导致 65535 条目的包自读不回来）；分卷错误消息重复，改文案要改两处。
- **建议**：抽 `zip64Sentinel(orig, comp, offset) -> (Bool, Bool, Bool)` 供读写两侧共用，差异用参数表达；抽 `rejectSpannedDisk(diskA, diskB)` 统一分卷报错。合并时保留 `>=` 语义与「extra 只放越界项」的顺序，并补等价性用例。

### [轻微][存量] #11 重复逻辑：`ExternalCompat_test` 三个反向校验用例同构，外加 6 份 tempdir/finally 样板

- **位置**：`f_zip/src/ExternalCompat_test.cj:76-98`、`:135-156`、`:158-179`（三个 `*AcceptsOurArchives`）；`:78-97`、`:103-132`、`:138-155`、`:161-178`、`:184-210`、`:216-242`、`:248-280`（`Directory.createTemp` + `finally { removeIfExists }`）
- **来源**：存量（`66d934e7f`、`bc44964e4`）
- **判据**：review-checklist §2「同文件重复」
- **证据**：静态确定 —— 三个反向用例体只差「可执行文件名 + 参数 + 断言文案」，其余逐行对齐（`samples(work)` 循环 → `executeWithOutput` → `skipMissingTool` → `@Fail`）；`samples()` 被三个用例各调一次，在同一 temp 目录里重复写 12 个文件。
- **描述**：新增一个外部工具校验要复制 20 行；更实际的问题是「工具缺失即 skip」的口径（`tasks.md` 19.2）分散在多处，容易再次漂移。
- **建议**：抽 `withTempDir { dir => ... }` 与 `expectToolAccepts(tool, args, scenario)`；`samples()` 结果按目录缓存一次。（本文件 `:89-91` 还有一处不可达分支，见 #12。）

### [轻微][存量] #12 死代码 / 不可达：5 处无引用或只写不读，另有 3 处可见性可收窄

- **位置与清单**：
  1. `f_zip/src/EntryNameTable.cj:48` —— `while (true) { ... }`（`:40`）之后的 `throw ZipException("名字分配失败：${name}")` 永不可达（两个出口都是 `return`）。
  2. `f_zip/src/EntryNameTable.cj:67-69` —— `size()` 全仓零调用（`grep "size()" f_zip/src` 只有定义处；测试里的 `names.size` 是别的列表）。
  3. `f_zip/src/Eocd.cj:25-26` —— `EocdInfo.eocdOffset` 与 `eocd64Offset` 只写不读（`ZipReader` 只用 `entryCount` / `cdSize` / `cdOffset`；全仓无 `info.eocdOffset` 形式的读取）。
  4. `f_zip/src/LocalHeader.cj:190` —— `dataOffset` 只在 `f_zip/src/ZipReader.cj:236` 被赋值（`header.dataOffset = total`），无任何读取。
  5. `f_zip/src/BoundedStream.cj:36-40` —— `left` 属性全仓零引用。
- **来源**：存量（`66d934e7f`）
- **判据**：review-checklist §1（不可达语句 / 非 public 符号无引用 / 读了不用）；`EocdInfo`、`LocalHeader`、`EntryNameTable` 都是 `internal` 顶层类型，其 `public` 成员按硬原则二判
- **证据**：静态确定 —— 逐符号全仓 `grep`，上述符号只有定义处或只有赋值处命中。另核对了其余符号：`leRemaining` / `skipBytes` / `needValue` / `concatBytes` / `u*At` / `safeRead` / `decodeGbk` / `latin1` / `strictUtf8` / `buildZip64Extra` / `parseZip64Extra` / `readFullyAt` / `locateEocd` / `readZip64Eocd` / `checkCdOffset` / `allocateDirectory` / `toZipEntry` / `deflateBytes` / `buildRawZip` 均有生产或测试调用。
- **描述**：`EocdInfo` 的两个字段是「设计稿预留、落位后没用上」的残留，构造方还要替它们算值；`LocalHeader.dataOffset` 让 `locateData` 多了一行无意义赋值，还配了一条「读取侧：数据起点」的注释，容易让维护者以为数据起点由 local header 解析得出（实际是 `e.localHeaderOffset + total` 现算）。可见性建议（不计死代码）：`EntryNameTable.contains` 仅 `EntryNameTable_test.cj:83-84` 使用，`insertSuffix` 仅同类内部使用，`BoundedInputStream` 整个类只被 `EntrySource_test.cj:93` 与 `ReadBufferReuse_test.cj:66` 引用。
- **建议**：删 `EntryNameTable.size()`、`BoundedInputStream.left`、`EocdInfo.eocdOffset/eocd64Offset`（连带简化 `readZip64Eocd` 的传参）、`LocalHeader.dataOffset` 与 `ZipReader.cj:236` 的赋值，以及 `EntryNameTable.allocate` 尾部的不可达 `throw`；`contains` / `insertSuffix` 收成 `internal` / `private`；`BoundedInputStream` 若确认没有下游用途就删除，或加注释说明"仅测试使用"。

### [轻微][存量] #13 文档与实现漂移（代码注释 / `tasks.md` 两处）

- **位置**：
  - `f_zip/src/BoundedStream.cj:25`（「传入的 `buffer` 比剩余长度大时用临时数组截断」）↔ 同文件 `:55-56`（「直接读入目标前缀，避免按剩余长度新建临时数组再拷贝」，实现是后者，`af3ca77d8` 改的）。
  - `f_zip/doc/spec/add-f-zip-module/tasks.md:30`（「`readBytes` / `skip`」）↔ 实现 `f_zip/src/LeBytes.cj:54`（`skipBytes`）。
  - `f_zip/doc/spec/add-f-zip-module/tasks.md:64`（`BoundedStream_test.cj`）↔ 实际位置 `f_zip/src/EntrySource_test.cj:87-118`。
- **来源**：存量（`af3ca77d8` / `66d934e7f`）
- **判据**：review-checklist §13「文档过期 / 描述的功能与实现不符」
- **证据**：静态确定 —— 直接对照行号；`grep "func skip" f_zip/src` 只有 `skipBytes`；`EntrySource_test.cj` 内含 `BoundedStream_test` 类。
- **描述**：类注释描述的分支已不存在，读者会照着去找；`tasks.md` 的用例落位偏差同类问题已被返修过一次（3.5 / 5.1 都补了注），这两处漏了。
- **建议**：类注释改成「超出剩余长度时只读入目标前缀」；`tasks.md:30` 的 `skip` 改 `skipBytes`、`:64` 补一句「用例寄居在 `EntrySource_test.cj` 的 `BoundedStream_test` 类」。

### [轻微][存量] #14 安全 spec 要求上限类错误消息包含「上限值与实际值」，实现只给上限值与条目名

- **位置**：`f_zip/doc/spec/add-f-zip-module/specs/f-zip-security/spec.md:136`（「涉及上限时 MUST 包含上限值与实际值」）↔ `f_zip/src/ZipReader.cj:272`、`:276`（`解压体积超过上限 ${limit}（${name}）`）
- **来源**：存量（`66d934e7f`）
- **判据**：review-checklist §13「规格与实现漂移」
- **证据**：静态确定 —— 消息模板只有上限与条目名；对应 Scenario（`spec.md:143-146`）只要求「上限值与条目名」，所以单测不会报错，只有 Requirement 正文这条不成立。
- **描述**：定位问题时看不到「超了多少」，对 512 MB / 2 GB 两档上限尤其难排查。属文档承诺与实现不一致，不是行为缺陷。
- **建议**：二选一——消息改成 `...超过上限 ${limit}（实际 ${actual}，${name}）`（`account` 里两个数都现成），或把 spec 正文收窄成「上限值与条目名」并同步 `doc/api.md`。

> **范围外提示**（不占本部分统计）：`ZipWriter` 四个 `add*` 各自重复同一段 `LocalHeader` 字段装配（`ZipWriter.cj:85-100`、`:148-160`、`:220-235`、`:341-350`）；`ZipReader.findLast` 每次 `read`/`contains` 做 O(n) 线性扫描并为每条目解码名字（`ZipReader.cj:174-182`）。两者属其他部分。

<!-- 第 3 部分 -->

### [一般][存量] 解压失败时删掉被覆盖的既有文件——"CRC 错"变成"目标文件消失"

- **位置**：`f_zip/src/Unzip.cj:142-167`（`writeEntryToFile`；`File(target, OpenMode.Write)` 在 `:145` 截断，失败清理 `removeIfExists(target)` 在 `:163`），对外语义见 `Unzip.cj:32`（"同名文件覆盖"）
- **来源**：存量（快照无 diff）
- **判据**：review-checklist §11「资源不对称 / 错误路径」、§10「错误处理」；严重度按「数据丢失」定
- **证据**：静态确定 —— `OpenMode.Write` 先截断目标文件，`ok` 只在 `file.flush()`（`:154`）之后才置真；`finally` 里 `if (!ok) removeIfExists(target)`。CRC / 大小校验发生在 `ZipEntryInputStream.read` 读到最后一块时抛异常（`ZipReader.cj:313-322`），异常沿 `stream.read` → `writeEntryToFile` 传出，`ok` 仍为 `false`。
- **描述**：调用方把 `a.txt` 解压到已有 `a.txt` 的目录，若该条目 CRC 不符 / 被截断 / 超 `maxEntrySize`，结果是：旧 `a.txt` 被截断清零后又被删除。也就是"解压失败"把目标目录里原有的正确文件一起销毁，与"失败不改变现状"的直觉相反。批量解压里一条坏条目就会抹掉上一版产物。
- **建议**：写临时文件（同目录 `.tmp` 后缀）→ 校验通过后 `rename` 覆盖；或至少记录写入前 `exists(target)`，失败清理只在"本次新建"时执行。补用例：目标目录预置 `a.txt`（内容 `old`），用 `RawEntrySpec` 造 CRC 错误的同名条目，断言抛错且 `a.txt` 内容仍为 `old`。

### [一般][存量] `Unzip` 文档的两条原子性承诺与实现不符（部分落盘 / 目标目录先建）

- **位置**：`f_zip/src/Unzip.cj:29-30`（"加密 ZIP 直接报错，**不产生**『解出来一半是对的』的部分结果"）、`Unzip.cj:111`（"校验**先于**任何落盘动作"）；实现 `Unzip.cj:61-79`
- **来源**：存量（快照无 diff）
- **判据**：review-checklist §11「契约与实现不符」、§13「文档承诺与实现相反」
- **证据**：静态确定 —— `unzipInto` 先 `ensureDirectory(dir)`（`:62`）再逐条 `resolveSafeTarget`（`:69`）/`writeEntryToFile`（`:75`）；`openEntry` 里的加密检查（`ZipReader.cj:203-205`）是**逐条**在循环中做的，之前的条目已经落盘。本模块自己的用例把这一点写成了断言：`Unzip_security_test.cj:78-98`（`validationHappensBeforeWriting`）断言 `good1.txt` / `good2.txt` 在 `../evil.txt` 报错**之后**仍然存在。
- **描述**：两个后果。(1) 一个"普通条目 + 加密条目"的包，解压会先写出普通条目再抛"不支持加密 ZIP"，调用方若按文档理解为"什么都没写"，重试 / 清理逻辑会漏掉这些残留文件；(2) 路径全非法的包，`unzip` 仍会在目标位置留下一个空目录（`unzipInto:62` 早于任何校验），与"校验先于任何落盘动作"字面相反。现有用例 `encryptedEntryNotWritten`（`Unzip_security_test.cj:167-182`）把加密条目放在第一条，恰好绕过了这个场景。
- **建议**：二选一——要么改文档（"逐条目校验；失败时已完成的条目会保留"），要么真做成两阶段（先全量 `resolveSafeTarget` + `checkEntryReadable` 预检，再落盘；`ensureDirectory(dir)` 移到预检之后）。同时补一条"普通条目在前、加密条目在后"的用例锁行为。

### [一般][存量] `ensureDirectory` 的 `exists` → `create` 非原子，并发解压同一目录会抛 `FSException`

- **位置**：`f_zip/src/Unzip.cj:82-86`（`ensureDirectory`），调用点 `:62`、`:71`、`:74`
- **来源**：存量（快照无 diff）
- **判据**：review-checklist §12.1「检查-然后-写入」；§11「并发正确性」
- **证据**：静态确定 + 文档核对 —— `std.fs.Directory.create` 明确"目录已存在…则抛出异常"（`stdlib/doc/libs/std/fs/fs_package_api/fs_package_classes.md:38`，`recursive: true` 也一样），所以这里必须先 `exists` 再创建；两步之间没有锁也没有 catch。
- **描述**：`unzip` 是自由函数、目标目录由调用方给出，两个线程（或两个进程各自的线程）解压到同一目录时，`!exists(p)` 同时为真 → 第二个 `Directory.create` 抛 `FSException`，整个解压中断（且抛出的不是 `ZipException`，与"唯一异常类型"的承诺再偏一层，后者第 1 部分已报）。同一条竞态也出现在 `target.parent` 的创建（`:74`）与目录条目（`:71`）。
- **建议**：`try { Directory.create(path, recursive: true) } catch (e: FSException) { if (!exists(path)) { throw ZipException(...) } }`，即"建失败后再确认一次是否已存在"，把竞态收敛为幂等。用例：两线程各解压同一包含嵌套目录的包到同一目标，断言两边都成功。

### [一般][存量] `unzip(InputStream, dir)` 全量物化且对归档大小没有任何上限

- **位置**：`f_zip/src/Unzip.cj:34-43`、`f_zip/src/ZipReader.cj:52-56`、`ZipReader.cj:333-342`（`readAllBytes`）
- **来源**：存量（快照无 diff）
- **判据**：review-checklist §5「一次性物化 / 全量读入」+「有没有拒绝路径」
- **证据**：静态确定 —— `readAllBytes` 用 `ByteBuffer(initialCapacity: 8192)` 循环 `write` 直到 EOF，长度完全由输入决定；`ByteBuffer` 扩容按倍增，峰值可到归档大小的 ~2 倍（旧缓冲 + 新缓冲同时存活）。`ZipLimits` 的四个上限全部作用在**解压后**的字节与条目数上，没有任何一项约束**归档本身**的大小。`unzip(path, dir)` 走 `FileSource`，不受影响。
- **描述**：量化：一个 4 GiB 的网络流交给 `unzip(input, dir)`，最坏峰值 ≈ 8 GiB 堆（倍增期间），且没有任何"太大就拒绝"的入口——只有 OOM 才知道。已知文档在 `ZipReader.cj:49-51` 说明了"先把整个流读进内存"，但 `unzip` 的公开注释（`Unzip.cj:22-33`）没有这条提示，使用者很容易把它当流式接口用。
- **建议**：给 stream 重载加 `maxArchiveSize!`（复用 `ZipLimits` 或独立参数），超限在 `readAllBytes` 里抛 `ZipException`；`ByteBuffer` 侧按已知 `Content-Length` 预分配可省一次翻倍（见"优化可行性方案"）。文档两条重载分别注明"缓冲整包 / 走 seek 不缓冲"。

### [一般][存量] `ZipReader.closed` 是普通字段：`close()` 与并发读之间既无同步也无契约

- **位置**：`f_zip/src/ZipReader.cj:47`（`private var closed = false`）、`:159-164`（`close`）、`:168-172`（`ensureOpen`）；并发承诺在 `:34-35`
- **来源**：存量（快照无 diff）
- **判据**：review-checklist §12.1「共享可变状态无保护 / 可见性」；§11「契约与实现不符」
- **证据**：静态确定 —— 同类里的 `consumed` 用了 `AtomicInt64`（`:46`），`closed` 却是裸 `var`；`close()` 置位后直接 `source.close()`，而 `FileSource.close`（`EntrySource.cj:116-123`）关掉的是**同一个** `File` 对象，`readAt`（`EntrySource.cj:89-110`）正拿它在读。注释只承诺"解析完成后 `entries()` / `read()` / `contains()` 只读，可并发调用"，没有定义 `close` 能否与读并发。
- **描述**：典型用法是"多线程读同一个 reader，收尾时任一线程 `close()`"。此时：(1) `closed` 的写对其他线程不可见（无原子/无同步），`ensureOpen` 可能放行已关闭的 reader；(2) 已放行的线程继续 `source.readAt` / `openRange`，与 `file.close()` 并发，读到已关闭句柄的未定义行为或原生异常。这与第 2 部分 #2（`FileSource.readAt` 共用游标）是同一族问题的**另一个窗口**，不重复计数但需一起修。
- **建议**：`closed` 换 `AtomicBool`（或 `AtomicInt64`），`close()` 用 CAS 保证只有一个线程执行收尾；更彻底的是记录活跃读计数（读入口 +1 / `finally` -1），`close()` 置位后等待归零再关句柄。无论选哪种，都在类注释里写清"`close` 与其它方法并发"的语义。

### [轻微][存量] `zip(output, dir)` 失败时不 `close()` writer，半成品输出无中央目录

- **位置**：`f_zip/src/Zip.cj:35-40`（`let count = addTree(...)` 后直接 `writer.close()`，无 `try/finally`）、`Zip.cj:42-63`
- **来源**：存量（快照无 diff）
- **判据**：review-checklist §11「资源不对称 / 错误路径」；对照 `unzip`（`Unzip.cj:37-41`）的 `try/finally`
- **证据**：静态确定 —— `addTree` 递归展开目录，任一 `Directory.readFrom` / `addFile` 抛错都会跳过 `:38` 的 `writer.close()`；`ZipWriter.close` 是唯一写中央目录 + EOCD 的地方（`ZipWriter.cj:440-449` 附近）。
- **描述**：写盘到一半出错时，`output` 里留下若干 local header + 数据，但没有中央目录，产物完全不可读。`ZipWriter.close()` 对"有条目未关""已 dirty"两种情况会拒绝收尾（`ZipWriter.cj:381-392`），但目录遍历阶段（`Directory.readFrom` 抛错，或 `addFile` 在打开文件前失败）既不置 `entryOpen` 也不置 `dirty`，于是之后任何一次 `close()` 都会写出一份"结构完整但少了若干文件"的包——失败变成静默的成功。`unzip` 侧有 `finally`（`Unzip.cj:37-41`），两个便捷函数不对称。
- **建议**：`try { count = addTree(...) } finally { try { writer.close() } catch (_: Exception) {} }`；只加 `finally` 还不够（上面第二种情况仍会写出半成品），需要让 `zip()` 在遍历失败分支调用包内的 `writer.entryFailed("<tree>")`（`ZipWriter.cj:298` 已是 `internal`）把 writer 置 dirty，使后续 `close()` 抛"ZIP 结构不完整"。用例：目录里放一个不可读文件，断言抛错且再 `close()` 也抛 `ZipException`。

### [轻微][存量] 目录条目在 `read` / `readAll` / `open` 三个 API 上语义不一致

- **位置**：`f_zip/src/ZipReader.cj:89-95`（`read` 不排除目录）、`:98-107`（`readAll` 显式 `!e.isDirectory`）、`:113-122`（`open` 对目录返回 `None`）
- **来源**：存量（快照无 diff）
- **判据**：review-checklist §11「语义与命名 / 注释不符」
- **证据**：静态确定 —— 目录条目 `compressedSize == 0`、`crc == 0`，`read` 会走完 `decodeEntry` 得到空数组并 `verifyEntry(0, 0, 0, 0)` 通过，返回 `Some(Array<Byte>())`；`readAll` 直接跳过；`open` 返回 `None`。
- **描述**：同一个名字（如 `"d/"`），`read` 说"存在且内容为空"，`open` 说"没有这条"，`readAll` 说"没有匹配"。调用方用 `read` 判断"目录条目是否可解压"会得到错误结论。
- **建议**：三处统一——建议 `read` 也跳过目录条目（返回 `None`），并在文档里写明"目录条目只有 `entries()` 能看到"。

### [轻微][存量] 条目流校验失败后置 `done`，之后 `read` 静默返回 `-1`

- **位置**：`f_zip/src/ZipReader.cj:309-329`（`done = true` 在 `:315`，两个 `throw` 在 `:317` / `:321`）
- **来源**：存量（快照无 diff）
- **判据**：review-checklist §3「错误被吞」、§11「错误处理」
- **证据**：静态确定 —— 首次读到 EOF 时先置 `done = true` 再校验，校验失败抛 `ZipException`；调用方若 `catch` 后继续循环（"记录错误、继续读下一个"的常见写法），下一次 `read` 在 `:310-312` 命中 `done` 直接返回 `-1`，等于把"数据损坏"降级成"正常 EOF"。
- **描述**：与 `decodeEntry`（一次性抛错、无后续状态）行为不同；流式 API 的失败不可重放也不应"变成功"。
- **建议**：失败时记 `failed` 而不是 `done`，`read` 在 `failed` 时重新抛同一个 `ZipException`（或至少返回 `-1` 前不再声称校验通过）。`flush`/`write` 侧已有 `failed` 字段（`ZipEntryOutputStream.cj:45`）可参照。

### [轻微][存量] `ZipEntryOutputStream.write` 在 `failed` 后静默返回，与类注释"此后任何操作都抛异常"不符

- **位置**：`f_zip/src/ZipEntryOutputStream.cj:88-97`（`if (failed) { return }` 在 `:92-94`），注释在 `:28-29`
- **来源**：存量（快照无 diff）
- **判据**：review-checklist §3「静默吞掉」、§11「契约与实现不符」
- **证据**：静态确定 —— 第一次写失败时 `catch` 里置 `failed` 并 rethrow（`:105-109`）；后续 `write` 直接 `return`，既不抛也不计数，`count`/`crc` 也不再更新。
- **描述**：调用方若在 `catch` 之后继续 `write`（例如循环里 catch 后继续下一块），数据被静默丢弃且不会二次报错，最终状态只能靠 `writer` 的 dirty 检查兜底；而类注释承诺"writer 的任何操作都抛异常"，读代码的人会以为 `write` 会抛。
- **建议**：`failed` 分支改为 `throw ZipException("条目 ${name} 上次写入失败，不能继续写入")`，或把注释改成"后续 `write` 静默丢弃"。

### [轻微][存量] `TempSpill.createIn` 四次 `catch { continue }` 丢掉底层失败原因

- **位置**：`f_zip/src/TempSpill.cj:69-89`（`catch (_: Exception) { continue }` 在 `:84`，最终抛错 `:88`）
- **来源**：存量（快照无 diff）
- **判据**：review-checklist §3「`catch {}` 静默吞异常」、§11「错误处理缺失」
- **证据**：静态确定 —— 逐候选 `try/catch` 只 `continue`，异常对象既不打日志也不带入最终消息；最终 `ZipException` 只有 `size` / `threshold` 两个数，没有"每个候选为什么失败"。
- **描述**：落盘失败在生产上最常见的原因是磁盘满 / 权限 / 目录只读，这三者的处置完全不同；现在的报错无法区分，只能靠猜。`createIn` 的 `logger.debug` 也只在**成功**分支（`:80`）。
- **建议**：catch 里 `logger.warn("zip: 候选临时目录 ${candidate} 不可用：${e.message}")`，或把最后一次异常作为 `cause` 带进最终消息。

### [轻微][存量] 死代码：`wrapMethod` 的 `case _` 兜底不可达（与 `checkEntryReadable` 重复校验）

- **位置**：`f_zip/src/ZipReader.cj:240-246`（`case _ =>` 在 `:244`），守卫在 `:202-208`，两个调用点 `:145-148` 与 `:249-252`
- **来源**：存量（快照无 diff）
- **判据**：review-checklist §1「恒真恒假分支 / 不可达」、§2「同一校验写两遍」
- **证据**：静态确定 —— `wrapMethod` 是 `private`，全仓只有两个调用点，且两点都紧跟在 `checkEntryReadable(e)` 之后（`openEntry` 在 `:145`，`decodeEntry` 在 `:249`）；`checkEntryReadable` 已经用 `e.method != 0 && e.method != 8` 拒绝了其它方法并抛出**同一句** "不支持压缩方法 ${method}（${name}）"（`:206-208`）。
- **描述**：`:244` 的分支在当前调用链上永远到不了；一旦以后有人新增调用点绕过 `checkEntryReadable`，两条错误路径的文案还会漂移。属于"防御性但结构上死"的代码。
- **建议**：把方法白名单收敛到一处——`checkEntryReadable` 只做读前检查、`wrapMethod` 保留 `match` 而删掉 `checkEntryReadable` 里的方法判断；或反过来让 `wrapMethod` 接受 `UInt16` 时假定已校验（加注释）。`CompressionMethod.fromValue`（`ZipLayout.cj:37-43`）正是为这件事准备的，见下一条。

### [轻微][存量] 死代码：`ZipEntryStream_test.cj` 的 `std.io.OutputStream` import 未使用

- **位置**：`f_zip/src/ZipEntryStream_test.cj:18`
- **来源**：存量（快照无 diff）
- **判据**：review-checklist §1「未使用的 import」
- **证据**：静态确定 —— 全文件 `OutputStream` 只出现在该 import 行与第 28 行注释里，没有任何类型标注或值使用（`build` 返回 `Array<Byte>`，`ByteBuffer` 来自 `fountain::f_io`）。
- **描述**：无行为影响，只是本轮 §1 机械检查的命中项。
- **建议**：删除该 import。

### [轻微][存量] 重复逻辑：`verifyEntry` 与 `ZipEntryInputStream.read` 各写一份长度 + CRC 校验（连文案都一样）

- **位置**：`f_zip/src/ZipReader.cj:280-287`（`verifyEntry`）与 `:316-322`（`ZipEntryInputStream.read` 的 EOF 分支）
- **来源**：存量（快照无 diff）
- **判据**：review-checklist §2「同语义双份实现 + 字面量复制」
- **证据**：静态确定 —— 两处都是"先 `produced != expectedSize` 抛『条目 X 数据不完整：期望 N 字节，实际 M 字节』，再 `crc != expectedCrc` 抛『CRC 校验失败：期望 A，实际 B（X）』"，只有变量名与插值位置不同。
- **描述**：语义差异为零（错误类型、顺序、文案全同），改一处忘另一处就会出现"批量 `read` 与流式 `open` 报不同消息"的漂移。
- **建议**：抽 `private func checkEntryIntegrity(name, produced, actualCrc, expectedSize, expectedCrc): Unit`，`verifyEntry` 直接删掉改调它，`ZipEntryInputStream.read` 复用；错误文案只留一份。

### [轻微][存量] 重复逻辑：`buildZipBytes` / `buildZipWithResult` 同体；`TempSpill` 两处同一异常文案

- **位置**：`f_zip/src/ZipTestSupport_test.cj:92-98` 与 `:101-110`；`f_zip/src/TempSpill.cj:66` 与 `:88`
- **来源**：存量（快照无 diff）
- **判据**：review-checklist §2「同文件两两比对 / 字面量复制」
- **证据**：静态确定 —— `buildZipBytes` 的四个动作（建 `ByteBuffer`、建 `ZipWriter`、执行 action、`close` + `bytes()`）是 `buildZipWithResult` 去掉返回值后的真子集；`:100` 的注释解释了"为什么要第二个"（闭包不能捕获可变变量），但没解释为什么不复用。`TempSpill` 的两处 `throw ZipException("无法创建临时文件，且条目大小 ${size} 超过内存路径阈值 ${threshold}")` 逐字节相同，只是触发条件不同（空候选列表 / 全部候选都失败）。
- **描述**：前者的差异只是"有无返回值"，可以 `buildZipBytes(a) = buildZipWithResult(a).0`；后者应保留两处语义（一个是"没有候选"，一个是"都失败"），但文案相同会让人以为两者等价，且改阈值措辞要改两处。
- **建议**：`buildZipBytes` 改为 `buildZipWithResult(action, options: options)[0]`；`TempSpill` 抽一个 `private func noTempFile(size: Int64, threshold: Int64): ZipException`，空候选处改用不同措辞（"没有可用的临时目录"）。

### [轻微][存量] 0/8 白名单散落 4 处，`CompressionMethod.fromValue` 未接入读取路径

- **位置**：`f_zip/src/ZipLayout.cj:22-51`（`value` / `fromValue`）、`f_zip/src/ZipReader.cj:206-208`（`method != 0 && method != 8`）、`ZipReader.cj:241-245`（`case 0 / case 8`）、`f_zip/src/ZipWriter.cj:497`（`method.value == Stored.value`）
- **来源**：存量（快照无 diff）
- **判据**：review-checklist §2「同一张表散落多处」、§14.1「能力未接入」
- **证据**：静态确定 —— `CompressionMethod.fromValue` 全仓只有 `ZipLayout_test.cj:64-65` 使用；读取侧（`checkEntryReadable`、`wrapMethod`）用的是裸 `UInt16` 字面量 0/8，写入侧用 `options.method.value`。新增一个方法（例如 BZIP2=12）要同时改这 3 处 + 枚举 2 处。
- **描述**：枚举是对外公开 API（`ZipWriterOptions.method`），读取侧却绕过它，形成"写侧有类型、读侧靠字面量"的分裂；`fromValue` 目前是"只给测试用"的公开 API。
- **建议**：`checkEntryReadable` 改 `if (CompressionMethod.fromValue(e.method).isNone()) { throw ... }`，`wrapMethod` 改 `match (CompressionMethod.fromValue(method))`；若暂时不接入，至少把 `fromValue` 的文档改成"预留给读取侧"，避免被当成已有能力。

### [轻微][存量] 注释「ZIP 没有独立的目录标志位」与同模块用 external attributes 判符号链接自相矛盾

- **位置**：`f_zip/src/ZipEntry.cj:26`（"`isDirectory` 由名字是否以 `/` 结尾判断（ZIP 没有独立的目录标志位）"）、对照 `f_zip/src/Unzip.cj:88-91`（`((e.externalAttributes >> 16) & 0xF000) == 0xA000`）
- **来源**：存量（快照无 diff）
- **判据**：review-checklist §13「文档过期 / 与实现相反」（代码内注释同样算契约）
- **证据**：静态确定 —— 同一模块靠 external attributes 的高 16 位（Unix mode）识别 `S_IFLNK`，`ZipLayout.cj:90-94` 还专门定义了 `VERSION_MADE_BY_UNIX` 与 `EXTERNAL_ATTRIBUTES_DIRECTORY`（`040755 << 16`），说明 mode 位是可用的。
- **描述**：注释把"本实现选择只看名字"说成"ZIP 格式没有这个信息"，会误导后续维护者（例如想做"目录条目不带斜杠也能识别"的兼容时，会以为不可能）。实际差异是"跨平台 mode 不可靠，故意不用"，不是"格式没有"。
- **建议**：改成"目录判定只看名字结尾 `/`，不采信 external attributes 的 Unix mode（Windows 造的包没有可信 mode）；符号链接例外，按 mode 判"。

### [轻微][存量] `openEntry(entry: ZipEntry)` 只按名字在本 reader 内重查，跨包传入会静默读到同名条目

- **位置**：`f_zip/src/ZipReader.cj:124-140`（`findLast(entry.name)` 在 `:133`）
- **来源**：存量（快照无 diff）
- **判据**：review-checklist §11「契约与实现不符」
- **证据**：待确认（缺下游用法）—— 静态可见：入参 `ZipEntry` 的 `localHeaderOffset` / `crc32` / `uncompressedSize` 全部被丢弃，只用 `name` 做一次 `findLast`。若调用方把 A 包的 `ZipEntry` 传给 B 包的 reader，得到的是 B 包里**最后一条同名条目**，且不会报错。
- **描述**：注释写"按已取到的 `[ZipEntry]` 打开解压流"，读者会以为用的是那条目的元数据；实际只是按名重查。同一 reader 内的正常用法没问题（`entries()` 出来的名字一定能在本包找到）。
- **建议**：要么在 `ZipEntry` 里加 `reader` 身份（弱引用/句柄）做校验，要么在文档里写明"`entry` 必须来自本 reader；同名条目取中央目录最后一条"。顺带把 `:130-136` 的两段 `isDirectory` 判断合并（入参判一次、查到后再判一次，第一次可省）。

### [轻微][存量] 日志 category 错配：`unzip` 的 warning 记在 `ZipReader` 名下，`zip` 的记在 `ZipWriter` 名下

- **位置**：`f_zip/src/Unzip.cj:57-59`（`UnzipLog.logger = LoggerFactory.getLogger<ZipReader>()`）、`f_zip/src/Zip.cj:22-24`（`getLogger<ZipWriter>()`）
- **来源**：存量（快照无 diff）
- **判据**：review-checklist §11「语义与命名不符」；`LoggerFactory.getLogger<O>` 用 `TypeInfo.of<O>().qualifiedName` 作 category（`f_log/src/base/LoggerFactory.cj:44-52`）
- **证据**：静态确定 —— "zip: 跳过符号链接条目 ${e.name}"（`Unzip.cj:66`）与"zip: 跳过符号链接 ${name}"（`Zip.cj:51`）都会落在 `fountain::f_zip.ZipReader` / `.ZipWriter` 这两个与它们无关的 category 下。
- **描述**：按类调日志级别（把 `ZipWriter` 调到 ERROR 以压制写入噪音、保留解压告警）的做法会直接失效；排查"哪个包被跳过"时也会被归到错误的 category。
- **建议**：`getLogger<UnzipLog>` / `getLogger<ZipLog>`（或 `LoggerFactory.getLogger("fountain::f_zip.unzip")`），让 category 与代码单元一致。

### [轻微][存量] 测试稳健性三处：分配量阈值断言、非 Linux 下资源用例恒真、符号链接用例未门控

- **位置**：`f_zip/src/ReadBufferReuse_test.cj:43-51` 与 `:69-77`（`@Expect(alloc < size / 4)`）；`f_zip/src/Resource_test.cj:261-273`（`peakRssKb` 读 `/proc/self/status`，读不到返回 `-1`）+ `:73`、`:117`、`:164`、`:230`（`deltaMb` / `totalMb` 断言）；`f_zip/src/Unzip_security_test.cj:209-230`（`SymbolicLink.create` 在 `:215-216`）
- **来源**：存量（快照无 diff）
- **判据**：review-checklist §11「边界 / 空值未处理」+ 测试可信度
- **证据**：静态确定 —— (1) `getAllocatedHeapSize()` / `getGCFreedSize()` 的差值受 GC 时机与运行时版本影响，`size/4` 是写死的经验阈值，`settle()` 只 `gc()` 三次；(2) `peakRssKb` 在非 Linux 返回 `-1`，`before` 与 `after` 都是 `-1` 时 `deltaMb == 0`，`@Assert(deltaMb < 256.0)` 恒真，用例"通过"但什么也没测；(3) `SymbolicLink.create` 在 Windows 需要特权（开发者模式/管理员），没有 `try/catch` 也没有 `skipGated`，非 Linux 环境下会直接失败。
- **描述**：三类问题都让"绿了的用例"骗人：前两类是假通过风险，第三类是跨平台假失败。资源用例另外依赖 `F_ZIP_RESOURCE` 门控（`:253-258`），门控正确但平台判定缺失。
- **建议**：分配量断言改成"同一进程内两种实现对照"（比值而非绝对阈值）或直接降级为打印；`peakRssKb` 返回 `?Int64`，`None` 时 `skipGated("VmHWM 不可用")`；符号链接用例在 `!OS.current.isLinux` 时走 `skipGated`。

### [轻微][存量] `zip` 对非普通文件（FIFO / socket / 设备）静默跳过，只有符号链接有 warning

- **位置**：`f_zip/src/Zip.cj:50-60`（`isSymbolicLink` 有 warning，`isDirectory` / `isRegular` 之外的类型无任何分支）
- **来源**：存量（快照无 diff）
- **判据**：review-checklist §3「静默跳过」、§11「语义与命名不符」（类注释只声明"符号链接一律跳过"）
- **证据**：静态确定 —— `addTree` 的 `if/else if` 链只覆盖符号链接、目录、普通文件；FIFO / socket / 设备文件落到链尾无操作，既不打日志也不计数。
- **描述**：打包一个含 FIFO 的目录（日志管道、`/dev` 镜像、某些构建产物目录）时，`zip` 返回的文件数与目录实际条目数不符，且没有任何提示；调用方无法区分"文件被跳过"和"目录本来就空"。符号链接跳过了反而有 warning（`:51`），两者标准不一致。
- **建议**：`else` 分支补 `ZipLog.logger.warn("zip: 跳过非普通文件 ${name}")`，或加 `options` 开关决定"报错 / 告警 / 静默"。用例：目录里放一个 FIFO（Linux），断言 `zip` 返回 0 且日志含跳过提示。

> 存量 20 条（一般 5 / 轻微 15），是否纳入修复待用户决定。其中 #7（条目流无关闭途径）与 #12 里的 `LocalHeader.dataOffset` 死写已由第 2 部分报告，本报告未重复计数。

<!-- 第 4 部分 -->

### [一般][存量] `close()` 失败后重试会在文件里留下残缺/重复的中央目录区

- **位置**：`f_zip/src/ZipWriter.cj:381-449`（`close()`；关键状态缺失在 `391-400`，置位在 `444-448`）
- **来源**：存量（工作区快照，无 diff 可比）
- **判据**：review-checklist §11（错误处理缺失 / 语义与注释不符）；§6.2 无关，属写入状态机缺陷
- **证据**：静态确定 —— `close()` 只用局部变量 `cdStart` 记录中央目录起点，没有任何字段记住「CD 已经开始写」。`closed` 仅在 `out.flush()` 之后置位（`448`），失败路径不复位 `cdStart`、也不置 `dirty`
- **描述**：`close()` 的注释（`377-380`）承诺「写失败时不算已关闭，再次调用会重试（而不是静默返回、留下半截文件）」。实际重试路径有二：
  1. 中央目录写到一半失败（磁盘满 / 传输中断）→ 第二次 `close()` 以 `position`（已含前一次的残缺字节）为新 `cdStart` 再写一整份 CD，EOCD 指向第二份。文件可被 `EOCD → cdOffset` 型读取器（本项目 `ZipReader`、Python `zipfile`、Info-ZIP）正常读出，但条目数据区与中央目录之间多出一段不可达字节，`zip -T` 一类严格校验会报「extra bytes」类告警。
  2. `flush` 失败（EOCD 已写出）→ 重试再写一份 CD + EOCD，尾部出现两个 EOCD。
  另外失败后 `closed == false && dirty == false`，`ensureUsable()`（`453-463`）放行，调用方还能继续 `add()`，把新条目插到残缺 CD 之后，进一步放大上述夹层字节。
- **建议**：新增 `private var cdWritten = false` 或在进入 CD 循环前置 `dirty = true`（配合专门的 `closingError` 消息），使「CD 已开始写」成为不可回退状态；若确实要支持重试，则必须记录 `cdStart` 并在重试时断言 `position == cdStart`，否则抛「上次 close 已写入部分中央目录，无法安全重试」。

### [一般][存量] 条目名未做任何校验：`/` 结尾的「文件」在 unzip 侧静默丢数据、超长名抛裸异常

- **位置**：`f_zip/src/ZipWriter.cj:86`（`add`）、`:142`（`addFileStream`）、`:216`（`openEntry`）、`:312`（`addFile`）、`:331`（`addDirectory`）；长度截断点在 `f_zip/src/LocalHeader.cj:239`
- **来源**：存量
- **判据**：review-checklist §11（边界/契约与实现不符）、§10 安全性（外部可控字符串直接进归档结构）
- **证据**：静态确定 —— 五条写入入口都只做 `names.allocate` + `encodeName`（`NameCodec.cj:41`，仅判 ASCII/UTF-8），没有任何空串 / 尾斜杠 / 长度检查；`writeLocalHeader` 直接 `writeU16LE(out, UInt16(h.nameBytes.size))`（`LocalHeader.cj:239`）
- **描述**：三种边界都缺校验，其中第一种会静默丢数据：
  1. `add("dir/", data)` 写出的是一个「名字以 `/` 结尾但带数据」的条目。`unzip` 按名字判目录（`Unzip.cj:70-73`：`if (e.isDirectory) { ensureDirectory; continue }`），于是数据被丢弃且不计入返回值——包里的内容永远取不回来，而 writer 侧毫无提示。
  2. 名字长度 > 65535 字节（`String` 参数可由调用方任意构造，如用户上传文件名）时，`UInt16(size)` 触发默认溢出策略抛异常（语言文档 `basic_data_type/integer.md:137`：「若溢出可提前被编译器检测出来，则编译器会直接给出报错，否则根据默认的溢出策略将抛出异常」）。异常发生在 local header 已写出前 26 字节之后，被 `add*` 的 `catch` 转成脏状态，调用方拿到的是 `ArithmeticException` 而不是 `ZipException`。
  3. 空名字直接写出 0 长度 name 的条目，读取侧 `decodeName` 得到 `""`，`unzip` 侧由 `resolveSafeTarget` 判非法（`Unzip.cj:114-116`）——自己写的包自己解不开。
- **建议**：在 `ZipWriter` 内加一个 `private func checkEntryName(name: String, isDirectory: Bool)`：拒绝空串、拒绝非目录语义下以 `/` 结尾、拒绝 `nameBytes.size > 0xFFFF`（用 `encodeName` 之后的字节数判），统一抛 `ZipException`；`addDirectory` 允许尾斜杠但同样限制长度。

### [一般][存量] 压缩失败路径不关闭 `CompressOutputStream`，原生 deflate 资源泄漏

- **位置**：`f_zip/src/ZipWriter.cj:170-192`（`addFileStream`：`compressor` 只在 `pump` 正常返回后 `close()`）、`:496-507`（`compressData`：`compressor.write/close` 都不在 `try` 内）；同根因另见 `f_zip/src/ZipEntryOutputStream.cj:127-134`
- **来源**：存量
- **判据**：review-checklist §11（资源不对称）、§3（错误路径静默跳过释放）
- **证据**：静态确定 —— `stdx.compress.zlib.CompressOutputStream.close()`（`cangjie_stdx/src/stdx/compress/zlib/zlib_stream.cj:242-253`）是唯一调用 `deflater.deflateEnd()` 的地方；`ZipWriter` 的异常分支只做 `markDirty` + `throw`，从不 `close()` 压缩器
- **描述**：`pump(crcStream, compressor)` 抛异常（源流中断、磁盘写失败都是真实场景，测试 `ZipWriter_test.cj:421-430` 就是模拟它）时，`deflater` 持有的 zlib `z_stream` 与其内部缓冲不会 `deflateEnd()`，只能等 GC（`Deflate` 无显式终结器）。`compressData` 的 `compressor.write(data)` 同理。`ZipEntryOutputStream` 更彻底：`failed == true` 时 `close()` 在 `132-134` 直接 `return`，连正常收尾的机会都没有。
- **建议**：`try { pump(...) } catch (e) { try { compressor.close() } catch (_) {}; throw e }`，或把 `compressor` 放进 `try ... finally { if (!closed) compressor.close() }`；`ZipEntryOutputStream.close()` 在 `failed` 分支里也应 `try { c.close() } catch (_) {}`。

### [一般][存量] 清理路径吞掉所有异常，临时文件可能静默残留

- **位置**：`f_zip/src/ZipWriter.cj:486-493`（`addSpilled` 的 `finally`：`file.close()` 与 `removeIfExists(tmpPath)` 各一个空 `catch`）、`:320-324`（`addFile` 的 `finally`）
- **来源**：存量
- **判据**：review-checklist §3（`catch (_: Exception) {}` 静默吞异常）
- **证据**：静态确定 —— 三处 `catch (_: Exception) {}` 内没有任何日志 / 计数，`TempSpill` 的 logger（`TempSpill.cj:36`）只用于创建成功的 debug 日志
- **描述**：`add()` 走落盘路径时，`removeIfExists(tmpPath)` 失败（Windows 上文件仍被占用、目录被外部清理、权限变化）会被完全吞掉。调用方看到的是成功的 `add()`，但磁盘上留下一个与条目同大的临时文件；反复触发就是持续磁盘增长，且没有任何观测点。`file.close()` 的静默失败同理（读句柄，影响较小）。
- **建议**：至少 `logger.warn("zip: 删除临时文件失败 ${tmpPath}: ${e.message}")`；`removeIfExists` 的失败要不要升级为异常应在注释里明确（推荐 warn，不破坏已成功写入的归档）。

### [一般][存量] 符号链接用例无平台门控，Windows 上必然失败

- **位置**：`f_zip/src/ZipWriter_test.cj:293-319`（`addFileFollowsSymlinkAndRejectsMissing`，`SymbolicLink.create` 在 `300`）
- **来源**：存量
- **判据**：review-checklist §11（错误处理 / 环境假设）
- **证据**：需实测 —— 用例没有 `OS.current` 判断或跳过分支；Windows 创建符号链接需要开发者模式或管理员权限，`std.fs.SymbolicLink.create` 会抛 `UnauthorizedAccessException`，`finally` 里只会删临时目录，用例直接失败。同根因另见 `Unzip_security_test.cj:215-216`（范围外，不重复计数）
- **描述**：模块本身支持 Windows（`ZipWriterOptions.cj:42` 的 `@When[os != "Linux" || env != "gnu"]` 分支、`f_base.OS` 的 `Windows` 分支齐备），但这条用例把「跟随符号链接」的核心断言绑死在 POSIX 权限模型上；Windows 开发者跑 `cjpm test` 会在这一段红。
- **建议**：`if (!SymbolicLink.tryCreate(...)) { skipGated("当前环境不允许创建符号链接"); return }`，或按 `OS.current.isWindows` 走 `skipGated`（`ZipTestSupport_test.cj:42` 已有统一出口）。

### [轻微][存量] `close()` 与 `ensureUsable()` 重复实现两条前置检查，错误文案字面相同

- **位置**：`f_zip/src/ZipWriter.cj:385-390`（`close`）与 `:457-462`（`ensureUsable`）
- **来源**：存量
- **判据**：review-checklist §2（换控制流 / 字面量复制）
- **证据**：静态确定 —— 两处都是 `if (entryOpen) throw ZipException("条目 ${openEntryName} 仍在写入，先关闭条目流")` + `if (dirty) throw ZipException("条目 ${dirtyEntry} 写入中断，ZIP 结构不完整")`
- **描述**：`close()` 不能直接调 `ensureUsable()`（后者还要拒绝已关闭状态），于是把两条检查抄了一遍。文案改一处漏一处就会出现两种措辞。
- **建议**：抽 `private func checkWritable(allowClosed: Bool)`，`close()` 传 `true`、`add*` 传 `false`；`ensureUsable()` 变成一行转发。

### [轻微][存量] data descriptor 与 local header 的构造各重复 4 处

- **位置**：`f_zip/src/ZipWriter.cj:185-188` 与 `:271-280`（24 字节 descriptor 的 4 次 `writeU32LE/writeU64LE`）；`:98-110`、`:150-160`、`:224-234`、`:343-352`（`LocalHeader` 的 flags / dosTime / dosDate / nameBytes 赋值）
- **来源**：存量
- **判据**：review-checklist §2（同一串字面量 / 同一组字段名散落多处）
- **证据**：静态确定 —— 两段 descriptor 代码逐行一致；四段 header 构造除 `streaming`、`method`、`crc/size` 外完全相同
- **描述**：`finishEntry` 是推模式条目的收尾，`addFileStream` 是拉模式收尾，两者写出完全相同的 `SIGNATURE_DATA_DESCRIPTOR + crc + comp + uncomp`。descriptor 格式若改动（例如改成 12 字节非 ZIP64 形式）必须同时改两处，漏一处就产出两种格式混存的包。header 构造同理（新增 flag 要改 4 处）。
- **建议**：`private func writeDescriptor(out: OutputStream, crc: UInt32, comp: Int64, uncomp: Int64)`；`private func newHeader(nameBytes, utf8, method, now, streaming) -> LocalHeader`。

### [轻微][存量] `spilling` 用例忙等自旋、无慢用例门控、断言依赖时序窗口

- **位置**：`f_zip/src/ZipWriter_test.cj:352-378`（`spillingObservedDuringSpill`）
- **来源**：存量
- **判据**：review-checklist §11（用例本身的健壮性）；模块约定见 `ZipTestSupport_test.cj:26-44`
- **证据**：需实测 —— `while (!done.load()) { if (writer.spilling) ... }`（`360-367`）没有 `sleep`/`yield`，在落盘期间占满一个核；断言 `seen == true` 取决于 poller 是否正好在 8 MB 临时文件写入窗口内被调度到（4 次机会）
- **描述**：该用例一次写 4×8 MB 到临时目录，却没有走模块统一的 `slowEnabled()` / `skipGated()` 门控（`Zip64BigEntry_test.cj:43`、`Zip64EntryCount_test.cj:36` 都走了），在 OHOS 真机或小 tmpfs 环境上既慢又可能因时序没抓到 `true` 而偶发失败。
- **建议**：断言改为「跨线程读到的值曾经为 true 或最终为 false」之外，再加一个确定性的观测点（例如让 `addSpilled` 支持注入回调 / 用 `AtomicBool` 记录 `maxSeen`）；至少补 `if (!slowEnabled()) { skipGated(...); return }`，并在轮询里加 `sleep(Duration.millisecond)`。

### [轻微][存量] `unzip` 返回值语义（条目数 vs 文件数）被测试固化，与文档不符

- **位置**：`f_zip/src/Zip_test.cj:87-95`（`duplicateEntriesOverwrite` 断言 `unzip(...) == 2`）；契约侧 `f_zip/src/Unzip.cj:23`（「返回解压出的**文件数**」）与 `:76`（`count += 1` 按条目累加）
- **来源**：存量
- **判据**：review-checklist §11（语义与注释不符）、§13（文档承诺与实现不一致）
- **证据**：静态确定 —— 两个同名条目 `x.txt` 依次写入，磁盘上只有 1 个文件，`unzipInto` 对每个非目录条目 `count += 1`，因此返回 2
- **描述**：用例把「返回值 = 写入的条目数」固化成契约。调用方按文档拿它做进度 / 完整性计数时，同名覆盖场景会得到大于实际文件数的值。
- **建议**：二选一——要么把 `Unzip.cj:23` 的注释改成「返回写入的条目数（同名覆盖会重复计数）」，要么按去重后的路径计数并同步改用例。属契约变更，需用户拍板。

### [轻微][存量] `TempSpill_test` 与 `Zip_test` 混在一个文件，且同一次失败调用连跑 3 遍

- **位置**：`f_zip/src/Zip_test.cj:122-181`（`TempSpill_test` 类在 `123`；`allCandidatesFailThrows` 的 `178-180` 三次相同调用）
- **来源**：存量
- **判据**：review-checklist §2（重复逻辑）、§10 可维护性
- **证据**：静态确定 —— 模块其余测试都是「一个类一个同名文件」（`ZipTime_test.cj` ↔ `ZipTime_test`、`ZipReader_test.cj` ↔ `ZipReader_test`），只有 `TempSpill_test` 没有独立文件；`178-180` 三次 `TempSpill.createIn(bogus, "x.bin", 1234, 1024)` 参数完全一致
- **描述**：文件命名与内容不对应，按类名找不到用例文件；三次重复调用只为断言同一条消息的三个片段，`captureZipError` 已经能一次拿到异常对象。
- **建议**：拆出 `TempSpill_test.cj`；`let e = captureZipError({=> ...}).getOrThrow()` 后连断言三次。

### [轻微][存量] 测试保真度与边界覆盖：模拟中断的输入流从不返回部分数据，若干边界无用例锚定

- **位置**：`f_zip/src/ZipWriter_test.cj:496-522`（`FailingInputStream`）；覆盖缺口见 `f_zip/src/ZipTime_test.cj:69-73`、`ZipWriter_test.cj` 全文
- **来源**：存量
- **判据**：review-checklist §11（用例与注释不符）、§14（关键分支无覆盖）
- **证据**：静态确定 —— `FailingInputStream.read`（`506-521`）只在**读开始时**判 `position >= failAfter`，从不截断一次读：`failAfter = 1` 且数据只有 3 字节时，第一次 `read` 直接返回 3，第二次才抛；注释「读到第 `failAfter` 个字节后抛异常（模拟传输中断）」描述的语义没有实现
- **描述**：三个缺口：(1) `FailingInputStream` 无法模拟「读了一半再断」，而 `pump` 的 `dst.write(chunk[0..n])` 只在完整读到数据后才写，真正的半截读路径没被覆盖；(2) `ZipTime` 的 1980/2107 钳位（`ZipTime.cj:36-42`）与非法日期分支（`:60-62`）无断言；(3) 上面 G2 的尾斜杠名、超长名无任何用例。
- **建议**：`FailingInputStream` 改为「最多返回 `min(remaining, buffer.size)` 字节，达到 `failAfter` 后下一次读抛」；补 `encodeDosDate(1979/2108)` 与 `decodeDosDateTime(0, 0x0021)` 用例；补 `add("dir/", data)` 的拒绝用例（修完 G2 后）。

## 优化可行性方案

> 不是缺陷，是「还能更好」；无基线的方案只作待验证假设，不进 tasks。

<!-- 第 1 部分 -->

本部分只有 `.md`，没有可改的源码对象；`scope.md` 也未提供本模块改前 / 改后的性能对照（设计稿 §10 的 VmHWM 与耗时是现状基线，不是优化前后对照）。按铁律不产出优化方案，性能线索只进「待验证假设」。

<!-- 第 2 部分 -->

> 不是缺陷，是「还能更好」。三条都无改前基线，`证据状态` 均为 `无基线（待验证，不进 tasks）`。

### [堆内存] 中央目录双份驻留：`readFullyAt` 的整块 + `ByteBuffer(array)` 的内部拷贝

- **现状**：`readFullyAt`（`f_zip/src/Eocd.cj:47-52`）返回长度为 `cdSize` 的新数组；`ZipReader.loadDirectory` 立刻交给 `ByteBuffer(cdBytes)`（`ZipReader.cj:192-193`），而 `f_io` 的这个构造是 `this(initialCapacity: array.size)` + `write(array)`（`f_io/src/ByteBuffer.cj:33-40`）——**新建数组并整块拷贝**。构造期间两份同时存活 ⇒ 峰值 ≈ 2 × `cdSize`；之后每条目的 name/extra/comment 再从缓冲拷出第三份（`CentralHeader.cj:150-152`）。
- **方案**：让 `readCentralHeader` 直接吃 `(Array<Byte>, offset)` 形式的游标（`LeBytes.cj:160-175` 已有 `u*At`），去掉 `ByteBuffer` 这一层；或给 `f_io.ByteBuffer` 增加零拷贝包装构造（需保证外部不再改写该数组）。
- **预期**：65535 条目 / CD ≈ 4 MB 时解析期峰值从 ~8 MB 降到 ~4 MB（数量级估算，未测）。
- **代价**：改 `readCentralHeader` 签名或新增 `f_io` 公开 API；零拷贝包装要明确所有权语义（`bytes()` 是引用视图，见 `std/core/core_package_api/core_package_structs.md:1187`）。
- **验证**：65537 条目样本解析前后 `getAllocatedHeapSize()` + RSS 差，5 轮取中位数。
- **证据状态**：无基线（待验证，不进 tasks）

### [CPU] `CentralEntry.name` 每次访问都重新解码名字

- **现状**：`name` 是计算属性（`f_zip/src/CentralHeader.cj:41-45`），每次 get 都跑 `decodeName`：`strictUtf8` 全串扫描 + `String.fromUtf8` 再拷一份，非 UTF-8 时还要试探 GBK。触发点密集：`toZipEntry()`（每条目一次）、`entries()`、`findLast`（按名读取时对每个条目解码一次）、错误消息。
- **方案**：解析时解一次存字段（常驻多一份 `String`）；或让 `findLast` 把目标名 `encodeName` 成字节后与 `nameBytes` 逐字节比较（零常驻，但要注意 bit 11 与回退链的等价性）。
- **预期**：65535 条目下按名 `read()` 从「扫描 × 逐条解码」降到「扫描 × 字节比较」；具体降幅需实测。
- **代价**：字段缓存版增加常驻堆；字节比较版要保证同一显示名对应字节唯一（编码回退可能让不同字节得到同名）。
- **验证**：`cjprof record` 跑 65535 条目 × `read(name)` 1000 次；`cjpm bench -O2` 前后对照，取中位数与离散度。
- **证据状态**：无基线（待验证，不进 tasks）

### [CPU] 头部字段逐字段申请 2/4/8 字节小数组（读、写两侧都有）

- **现状**：读侧 `readU16LE/readU32LE/readU64LE`（`f_zip/src/LeBytes.cj:62-85`）每次 `Array<Byte>(2|4|8)` 再 `buf.read(dst)`，`readCentralHeader` 一条目约 19 次；写侧 `writeU16LE/...`（`:87-109`）每次同样新建数组再 `out.write`，`writeCentralHeader` 一条目约 13 次。65535 条目即百万级小分配。
- **方案**：读侧按固定头长（46 / 30 字节）一次读入，再用 `u*At` 按偏移取值，`readBytes` 只留给变长字段；写侧先拼一块定长头缓冲（或复用 writer 的成员缓冲），最后一次 `out.write`。
- **预期**：字段级分配次数降一个数量级；解析/写入耗时降幅需实测（-O2 下小对象分配可能只占个位数百分比）。
- **代价**：重写游标推进与字段偏移，必须原样保留 `needValue` 的截断错误文案；写侧偏移表需与 APPNOTE 对齐，ZIP64 / descriptor 分支要重算。
- **验证**：`cjprof heap` 分配采样 + `cjpm bench -O2`，同输入解析 / 写 65537 条目空条目。
- **证据状态**：无基线（待验证，不进 tasks）

<!-- 第 3 部分 -->

> 不是缺陷，是"还能更好"。本部分**没有**改前基线数据，全部为 `无基线（待验证）`，不得进 `tasks.md`。

### [堆内存] `ZipReader(input)` 的整包缓冲：去掉倍增峰值与二次拷贝

- **现状**：`readAllBytes`（`ZipReader.cj:333-342`）用 `ByteBuffer(initialCapacity: 8192)` 承接整个归档，扩容按倍增 ⇒ 峰值 ≈ 2 × 归档大小（旧缓冲 + 新缓冲同时存活）；读完再交给 `BufferSource(data)`，`BufferSource` 只持有引用，不再复制（这一点已经做对了）。
- **方案**：`unzip(input)` / `ZipReader(input)` 增加 `maxArchiveSize!` 上限（先解决"能拒绝"），再考虑按 `InputStream` 的已知长度（`File` / `Socket` 可给出）预分配；无法得知长度时按 8 MB 起步、1.5 倍增长（比 2 倍更省峰值）。
- **预期**：4 GiB 归档的峰值从 ~8 GiB 降到 ~4.2 GiB；上限生效后最坏情况是有界失败而非 OOM。
- **代价**：`ByteBuffer` 增长策略若改成 1.5 倍，拷贝次数上升（CPU 略增）；新增参数是对外 API 变更。
- **验证**：同一 1 GiB / 4 GiB 归档，`getAllocatedHeapSize()` 峰值 + `VmHWM`（`Resource_test.cj` 的采集方式）改前改后对照，各跑 5 轮取中位数；同时记录 `ZIP_READAT_BENCH` 之类已有点位的输出。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [堆内存] `entries()` 每次全量重建 `ZipEntry`，可按需缓存

- **现状**：`entries()`（`ZipReader.cj:68-75`）每次调用都按 `rawEntries.size` 新建 `ArrayList<ZipEntry>`，每条 `toZipEntry()` 还会构造 `String`/`DateTime`；65k 条目的包，单次调用就是 65k 个新对象，循环里反复调用（`for (e in reader.entries())` 每次重来）会持续制造垃圾。
- **方案**：首次调用时物化一次不可变快照（`let cached: ?ArrayList<ZipEntry>`），之后返回 `clone()` 或只读视图；语义仍是"返回独立列表"（`entriesReturnsIndependentList` 用例继续成立）。
- **预期**：稳态下每次 `entries()` 的分配从 O(条目数) 降到 O(条目数) 的浅拷贝（`ZipEntry` 是 struct，但 `String` 字段共享）；具体降幅需实测。
- **代价**：多一份 `ZipEntry` 常驻（65k × ~80 B ≈ 5 MB 量级），换来调用期零解码；对一次性使用者是净亏。
- **验证**：`getAllocatedHeapSize()` 差 + 10 万次 `entries()` 的耗时中位数，改前改后对照。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] `findLast` 线性扫描：`read(name)` / `contains(name)` 是 O(n)

- **现状**：`findLast`（`ZipReader.cj:174-182`）对 `rawEntries` 全表扫描取最后一条；`read` / `contains` / `open` 各调一次。模块内已有 `EntryNameTable`（写侧用的哈希索引），读侧没有接。
- **方案**：构造期建 `HashMap<String, Int64>`（name → 最后一条的下标），`findLast` 退化为一次查表；重复名字的语义不变（后写覆盖）。
- **预期**：单次查找 O(n) → O(1)；对"逐条 `read(name)` 遍历大包"的调用方式收益随条目数线性放大。
- **代价**：常驻一份 name → index 的 map（65k 条 ≈ 数 MB）；`internalEntries()` 若被外部修改会失配（当前只有包内调用，可加注释约束）。
- **验证**：构造 1 万 / 10 万条目的包，跑 1 万次 `read(随机名)`，`cjpm bench -O2` 或分段计时取中位数，改前改后对照。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] `locateData` 每条目读两次 local header

- **现状**：`locateData`（`ZipReader.cj:222-238`）先 `readAt` 30 字节拿 name/extra 长度（`:223-229`），再用 `readFullyAt` 把 30+name+extra 整段读一遍（`:233`），`readLocalHeader` 只做校验、结果被丢弃（`:235-236`）。每打开/解码一个条目就是 2 次随机读。
- **方案**：一次读满（先读 30 字节，若 `nameLen+extraLen` 超过缓冲再补读剩余部分），把 `readLocalHeader` 的解析结果复用起来做数据起点；或在 `ZipReader` 构造期把每个条目的 data offset 预算并缓存（中央目录已全量在手）。
- **预期**：随机读次数减半；小条目（header 占比高）场景收益最大。绝对值需实测。
- **代价**：预算缓存需要 65k × 8 B ≈ 0.5 MB 常驻；`readLocalHeader` 的 ZIP64 extra 自洽性校验不能丢。
- **验证**：1 万个小条目的包，`unzip` 端到端耗时 + `readAt` 调用次数（分段计时），改前改后对照。
- **证据状态**：`无基线（待验证，不进 tasks）`

<!-- 第 4 部分 -->

### [堆内存] `add()` 内存路径可以不做整份压缩副本

- **现状**：`add()`（`ZipWriter.cj:86-134`）峰值持有三份数据：调用方的 `data`（N）、`compressData` 里 1.5× 增长的 `ByteBuffer`（容量 ≤1.5×C）、以及 `buf.bytes()`（`f_io/src/ByteBuffer.cj:56-58` 返回 `buffer[roffset..woffset]` 切片，即 C 的完整副本）。按 `memoryEntryThreshold` 默认 64 MB 算，单条目峰值约 N + 2.5C（不可压数据时 ≈ 3.5N ≈ 224 MB）
- **方案**：方案 A——内存路径改为复用流式写法的骨架：先写 `streaming = true` 的 local header（`writeLocalHeader` 已经支持 ZIP64 占位），header 里 CRC/大小留 0，数据直接 `out.write(data)`，末尾补 24 字节 descriptor，把 `compressData` 与 `payload` 整体删掉（压缩改由 `CompressOutputStream(out)` 直写）。方案 B（保留真实 header 语义）——`ByteBuffer(initialCapacity: data.size + 64)` 一次预留，避免 1.5× 增长轨迹，并把 `compressData` 改成返回 `(ByteBuffer, len)` 由调用方 `write(buf[0..len])`
- **预期**：方案 A 单条目峰值从 ≈3.5N 降到 ≈N（deflate 内部 8 KB 缓冲 + 32 KB 窗口除外），64 MB 条目省 ~160 MB；方案 B 省掉增长期的旧数组与末尾切片副本，约省 1.5C
- **代价**：方案 A 会让「内存路径」也带 descriptor（bit 3 置位、version 45），与 `ZipWriter.cj:32-37` 表格承诺的「内存路径不写 descriptor」冲突，老工具兼容性需回归；方案 B 无行为变化，收益较小
- **验证**：固定 64 MB 可压 / 不可压两种输入，`cjpm bench -O2` 对照 `getAllocatedHeapSize()` 峰值与 RSS，各跑 10 轮取中位数
- **证据状态**：无基线（待验证，不进 tasks）

### [CPU] 每条目新建压缩器的固定开销

- **现状**：`add()` → `compressData`（`ZipWriter.cj:500-501`）、`addFileStream`（`:174`）、`openEntry` → `ZipEntryOutputStream`（`ZipEntryOutputStream.cj:60-61`）都为**每个条目**新建 `CompressOutputStream`（`deflateInit` + 8 KB `outBuf`）。打包 1 万个 1 KB 小文件时，deflate 初始化的固定成本与有效压缩工作量同数量级
- **方案**：writer 级持有一个 `ZipWriter` 内复用的压缩器（zlib 层面用 `deflateReset`），每条目只重置状态；或给 `ZipWriterOptions` 增加 `smallEntryThreshold`，低于阈值的条目强制 `Stored`（小文件压缩收益本就接近 0）
- **预期**：小条目占比高的场景减少每条目一次 native 初始化与 8 KB 分配；收益需实测（Amdahl：若 deflate 初始化占总耗时 <5%，不做）
- **代价**：复用压缩器会把「条目级独立」变成共享状态，必须保证异常后能安全重置，否则脏状态跨条目传播；阈值型方案会给归档体积带来可预期的小幅上升
- **验证**：`cjpm bench -O2`，输入 1 万 × 1 KB 与 100 × 1 MB 两组，对照总耗时中位数；`cjprof record` 确认 `deflateInit`/`Deflate.init` 自耗时占比
- **证据状态**：无基线（待验证，不进 tasks）

### [CPU] `pump` 每 8 KB 一次切片分配

- **现状**：`pump`（`ZipWriter.cj:509-516`）循环里 `dst.write(chunk[0..n])` 每次生成一个长度 n 的新数组；2 GB 条目 ≈ 26 万次切片 + 26 万次 8 KB 拷贝
- **方案**：`OutputStream.write` 只接受整数组，可改为固定 8 KB 缓冲 + 每次按 `n` 复用（`chunk[0..n]` 无法避免）→ 实际可行的是把 `bufLen` 提到 64 KB（切片次数降到 1/8），或让 `pump` 直接读满 `chunk` 再写（当前已是）
- **预期**：切片次数与单次拷贝开销按 bufLen 线性下降；吞吐提升幅度需实测（大文件场景受磁盘带宽限制，可能 <5%）
- **代价**：64 KB 缓冲 × 并发 writer 的内存占用；对小条目无收益
- **验证**：`cjpm bench -O2`，2 GB 文件写入对照墙钟与 `cjprof` 中 `Array.copyTo` 占比
- **证据状态**：无基线（待验证，不进 tasks）

## 待验证假设

<!-- 第 1 部分 -->

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `entries()` 每次全量拷贝 `CentralEntry → ZipEntry`，65535 条时每次产生约 6.5 万个临时对象 | `f_zip/src/ZipReader.cj:68-75` | 单次耗时、分配量与真实调用频次 | `F_ZIP_SLOW=1` 造 65535 条包，循环 `entries()` 1000 次，`cjprof heap` 看分配与 GC；同环境对照「缓存快照 + 复制接口」 |
| 2 | deflate 的 `bufLen: 8192` 偏小，加大缓冲可减少边界调用（设计稿只给方向，无数据） | `f_zip/src/ZipReader.cj:243`、`ZipWriter.cj:174`、`:501` | 8K/32K/64K 的吞吐与内存对照 | `cjpm bench -O2`，1 GiB 可压缩 / 不可压缩各 5 轮，取中位数与离散度 |
| 3 | 文档引用的性能数字（CRC 51~58 MB/s、`9.7b` 200 s、1 GB 包 RSS +3.6 MB）未在本轮复测，可能随环境漂移 | `f_zip/doc/f_zip模块设计.md:1234-1264` | 当前机器上的实测值 | `F_UTIL_PERF=1`、`F_ZIP_SLOW=1`、`F_ZIP_RESOURCE=1` 分别重跑，记录中位数与机器差异 |

<!-- 第 2 部分 -->

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `locateEocd` 每次构造都分配 64 KiB 尾窗，最坏逐字节倒扫 65535 次（每次 4 次带边界检查的数组读） | `f_zip/src/Eocd.cj:67-89` | 每次 `ZipReader(path)` 构造的分配量与耗时 | 造「0 注释」与「65535 字节注释」两个样本，构造 10k 次分段计时 |
| 2 | 中央目录双份驻留是解析期峰值主项 | `f_zip/src/Eocd.cj:47` + `ZipReader.cj:192-193` | 解析前后 heapUsed / RSS 峰值 | 65537 条目样本，`getAllocatedHeapSize()` + `/proc/self/status` 前后对照 |
| 3 | 按名读取的解码放大（`findLast` 每条目解码）在条目上万时成为 CPU 热点 | `f_zip/src/CentralHeader.cj:41-45` | 该段自耗时占比 | `cjprof record` 跑 65535 条目 × 1000 次 `read(name)`，看 `decodeName` 占比 |
| 4 | 头部字段的小数组分配是解析/写入期 GC 压力主要来源 | `f_zip/src/LeBytes.cj:62`、`:87` | 分配次数 / GC 次数 | `cjprof heap` 采样 65537 条目解析与写入，按调用点聚合分配量 |
| 5 | 未关闭的条目 range 流会让 FD 峰值随「丢弃的条目数」线性增长 | `f_zip/src/BoundedStream.cj:142-149` | FD 峰值与 GC 触发点 | 打开 1000 个条目各读 1 字节后丢弃，读 `/proc/self/fd` 计数，再手动 GC 观察是否回落 |

<!-- 第 3 部分 -->

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `findLast` 线性扫描是批量 `read(name)` 的主要开销 | `f_zip/src/ZipReader.cj:174-182` | 单次查找自耗时占比 | `cjprof record` 跑 10 万条目的包 + 1 万次 `read(随机名)`，看 `findLast` self time |
| 2 | `locateData` 双读 local header 在"多小条目"场景是热点 | `ZipReader.cj:222-238` | 每条目平均随机读耗时 | 1 万 × 1 KB 条目的包，`unzip` 前后分段计时 + I/O 计数 |
| 3 | `entries()` 反复调用造成 GC 压力 | `ZipReader.cj:68-75` | 分配速率与 GC 次数 | 循环 1 万次 `entries()`，采 `getAllocatedHeapSize()` 与 GC 次数 |
| 4 | Windows 下 `".. "`（尾随空格）/ 尾随点可绕过 `resolveSafeTarget` 的前缀校验 | `f_zip/src/Unzip.cj:113-136` | Windows 上 `Path.normalize` 与 `File` 打开时是否裁掉尾随空格/点 | 在 Windows 上解压含 `".. /evil.txt"` 条目的包，检查 `<base>/../evil.txt` 是否被创建 |
| 5 | 目标目录里**预置**的符号链接可让 `resolveSafeTarget` 前缀校验失效（`normalize` 只做字符串解析，不解析链接） | `Unzip.cj:129-135`；`Path.normalize` 文档：`stdlib/doc/libs/std/fs/fs_package_api/fs_package_structs.md:1734`"仅做字符串解析，不会进行 io 操作" | 是否把"目标目录含符号链接"纳入威胁模型 | 预置 `dir/link -> /tmp/out`，解压 `link/x.txt`，检查是否写到了 `/tmp/out/x.txt` |
| 6 | `ensureDirectory` 的竞态在并发解压时真会触发（而非仅理论） | `Unzip.cj:82-86` | 双线程同目标目录解压的失败率 | 两线程 × 1000 轮解压同一包到同一目录，统计 `FSException` 次数 |
| 7 | `ReadBufferReuse_test` 的 `alloc < size/4` 在不同运行时/负载下是否稳定 | `ReadBufferReuse_test.cj:51`、`:77` | 多轮 CI 的实际 `alloc` 分布 | 连续 20 轮跑该用例，记录 `ZIP_READAT_BENCH` / `ZIP_BOUNDED_BENCH` 输出的离散程度 |

<!-- 第 4 部分 -->

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 小条目场景下 `deflateInit` 固定开销占比可观 | `f_zip/src/ZipWriter.cj:174`、`:500` | `Deflate.init` 自耗时占比、条目平均大小分布 | `cjprof record` 跑 1 万 × 1 KB 打包，读 self time 排序前 10 |
| 2 | `add()` 内存路径的 2.5× 压缩副本是 GC 压力主源 | `f_zip/src/ZipWriter.cj:496-507` | 每轮分配量、GC 次数、峰值 RSS | 64 MB 条目循环 100 次，采 `getAllocatedHeapSize()` 与 `cjprof heap` |
| 3 | `pump` 的 8 KB 切片复制在 2 GB 条目上可观测 | `f_zip/src/ZipWriter.cj:510-514` | `Array.copyTo` / 分配点占比 | `cjprof record` 写 2 GB 稀疏文件，按函数自耗时排序 |

## 文件覆盖

> 与 `files/f_zip.txt` 一一对应；分部分报告逐文件确认已读。

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_zip/README.md` | .md | ✅ | — |
| 2 | `f_zip/README_en.md` | .md | ✅ | — |
| 3 | `f_zip/doc/api.md` | .md | ✅ | — |
| 4 | `f_zip/doc/f_zip模块设计.md` | .md | ✅ | — |
| 5 | `f_zip/doc/spec/add-f-zip-module/design.md` | .md | ✅ | — |
| 6 | `f_zip/doc/spec/add-f-zip-module/proposal.md` | .md | ✅ | — |
| 7 | `f_zip/doc/spec/add-f-zip-module/specs/f-util-crc/spec.md` | .md | ✅ | — |
| 8 | `f_zip/doc/spec/add-f-zip-module/specs/f-zip-container/spec.md` | .md | ✅ | — |
| 9 | `f_zip/doc/spec/add-f-zip-module/specs/f-zip-reader/spec.md` | .md | ✅ | — |
| 10 | `f_zip/doc/spec/add-f-zip-module/specs/f-zip-security/spec.md` | .md | ✅ | — |
| 11 | `f_zip/doc/spec/add-f-zip-module/specs/f-zip-writer/spec.md` | .md | ✅ | — |
| 12 | `f_zip/doc/spec/add-f-zip-module/tasks.md` | .md | ✅ | — |
| 13 | `f_zip/doc/兼容性例外.md` | .md | ✅ | — |
| 14 | `f_zip/src/BoundedStream.cj` | .cj | ✅ | — |
| 15 | `f_zip/src/CentralHeader.cj` | .cj | ✅ | — |
| 16 | `f_zip/src/EntryNameTable.cj` | .cj | ✅ | — |
| 17 | `f_zip/src/EntryNameTable_test.cj` | .cj | ✅ | — |
| 18 | `f_zip/src/EntrySource.cj` | .cj | ✅ | — |
| 19 | `f_zip/src/EntrySource_test.cj` | .cj | ✅ | — |
| 20 | `f_zip/src/Eocd.cj` | .cj | ✅ | — |
| 21 | `f_zip/src/Eocd_test.cj` | .cj | ✅ | — |
| 22 | `f_zip/src/ExternalCompat_test.cj` | .cj | ✅ | — |
| 23 | `f_zip/src/LeBytes.cj` | .cj | ✅ | — |
| 24 | `f_zip/src/LeBytes_test.cj` | .cj | ✅ | — |
| 25 | `f_zip/src/LocalHeader.cj` | .cj | ✅ | — |
| 26 | `f_zip/src/LocalHeader_test.cj` | .cj | ✅ | — |
| 27 | `f_zip/src/NameCodec.cj` | .cj | ✅ | — |
| 28 | `f_zip/src/NameCodec_test.cj` | .cj | ✅ | — |
| 29 | `f_zip/src/RawZipBuilder_test.cj` | .cj | ✅ | — |
| 30 | `f_zip/src/ReadBufferReuse_test.cj` | .cj | ✅ | — |
| 31 | `f_zip/src/Resource_test.cj` | .cj | ✅ | — |
| 32 | `f_zip/src/TempSpill.cj` | .cj | ✅ | — |
| 33 | `f_zip/src/Unzip.cj` | .cj | ✅ | — |
| 34 | `f_zip/src/Unzip_security_test.cj` | .cj | ✅ | — |
| 35 | `f_zip/src/Zip.cj` | .cj | ✅ | — |
| 36 | `f_zip/src/Zip64BigEntry_test.cj` | .cj | ✅ | — |
| 37 | `f_zip/src/Zip64EntryCount_test.cj` | .cj | ✅ | — |
| 38 | `f_zip/src/ZipEntry.cj` | .cj | ✅ | — |
| 39 | `f_zip/src/ZipEntryOutputStream.cj` | .cj | ✅ | — |
| 40 | `f_zip/src/ZipEntryStream_test.cj` | .cj | ✅ | — |
| 41 | `f_zip/src/ZipException.cj` | .cj | ✅ | — |
| 42 | `f_zip/src/ZipLayout.cj` | .cj | ✅ | — |
| 43 | `f_zip/src/ZipLayout_test.cj` | .cj | ✅ | — |
| 44 | `f_zip/src/ZipLimits.cj` | .cj | ✅ | — |
| 45 | `f_zip/src/ZipReader.cj` | .cj | ✅ | — |
| 46 | `f_zip/src/ZipReader_path_test.cj` | .cj | ✅ | — |
| 47 | `f_zip/src/ZipReader_test.cj` | .cj | ✅ | — |
| 48 | `f_zip/src/ZipTestSupport_test.cj` | .cj | ✅ | — |
| 49 | `f_zip/src/ZipTime.cj` | .cj | ✅ | — |
| 50 | `f_zip/src/ZipTime_test.cj` | .cj | ✅ | — |
| 51 | `f_zip/src/ZipWriter.cj` | .cj | ✅ | — |
| 52 | `f_zip/src/ZipWriterOptions.cj` | .cj | ✅ | — |
| 53 | `f_zip/src/ZipWriter_test.cj` | .cj | ✅ | — |
| 54 | `f_zip/src/Zip_test.cj` | .cj | ✅ | — |
| 55 | `f_zip/src/f_zip_test.cj` | .cj | ✅ | — |

合计：`.cj` 42 个 / `.md` 13 个 / 共 55 个，全部读完。

## 覆盖自检

### 第 1 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 14 | 本部分无源码；按「文档承诺 vs 实现」逐条取证，14 条全部计入（安全类：#1 异常契约、#3 ZIP64 声明、#6 bit 13） |
| §1 死代码 | 0 | 本部分 0 个 `.cj`，无声明可搜；README 误列 `internal` 成员按 §13/§14 计入 #5，符号级死代码归第 2~4 部分（线索见范围外提示） |
| §2 重复逻辑 | 1 | 9 个 `.md` 逐节比对：命中设计稿整段重复（#10）；README 中英两版为刻意翻译，不算重复 |
| §3 空实现 | 0 | 文档无空实现；「承诺的错误消息永不抛出」按 §13 计入 #11 |
| §4 栈溢出 | 0 | 文档不含递归算法；`zip()` 的目录递归为代码侧疑点，见范围外提示 |
| §5 OOM | 0 | 文档不含分配逻辑；`cdSize` 预分配已由第 2 部分 #1 记为严重，本部分不重复统计 |
| §6.1 热点瓶颈 | 0 | `scope.md` 未给本模块 profile/bench；设计稿 §10 只有现状 VmHWM，无改前/改后对照，热点不成立，见待验证假设 #1–#3 |
| §6.2 大粒度锁 | 0 | 本部分无锁相关描述与实现 |
| §6.3 并发串行 | 0 | 本部分无 `spawn` / 批处理描述 |
| §6.4 低效算法 | 0 | 本部分无算法实现；`entries()` 拷贝、`bufLen` 疑点列入待验证假设 |
| §7 降堆内存方案 | 0 | 无改前/改后峰值数据，按铁律不产出方案；`unzip(input)` 全量缓冲已作为契约问题记 #12 |
| §8 降 CPU 方案 | 0 | 无 `cjpm bench` / `cjprof` 对照数据，不产出方案 |
| §9 local mode 可行性 | 0 | 本部分无函数级代码，无临时对象可评估 |
| §11 现有代码的 BUG（存量） | 0 | 本部分为文档；文档侧存量问题统一计 §13/§14，代码侧线索见范围外提示 |
| §12 并发安全与锁粒度 | 0 | 本部分无并发代码；`position` 的非原子可见性疑点见范围外提示 |
| §13 文档一致性 | 13 | #1 #2 #3 #4 #6 #7 #8 #9 #10 #11 #12 #13 #14 |
| §14 功能完备性与 README 覆盖 | 4 | #2（openEntry 未进 api/spec）、#5（README 公开 API 清单失真）、#6（bit 13 承诺未实现）、#13（分卷拒绝未进 README） |
| 文件覆盖（§13 等） | 9/9 | 无缺读；`.cj` 不在本部分，未计入 |

### 第 2 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 7 | #1~#7。已核对而非缺陷的项：`dst[got..want]` / `buffer[0..remaining]` 依赖"切片是引用"语义（`std/core/core_package_api/core_package_structs.md:1187`、`:2616`），写入落到原数组、不丢数据；`ByteBuffer.read` 短读会 `clear()`，所以 `readBytes` 必须先算剩余（`leRemaining`）；ZIP64 extra 字段顺序、哨兵判定、EOCD64 字段偏移手工核算正确；`insertSuffix` 的字节下标与 `String` 切片语义一致（`core_package_structs.md:9383`） |
| §1 死代码 | 5 | #12 的五处：不可达 `throw`、`EntryNameTable.size()`、`EocdInfo.eocdOffset/eocd64Offset`、`LocalHeader.dataOffset`、`BoundedInputStream.left`。其余符号逐个全仓 grep 均有引用；对外不可达的 `public` 成员按硬原则二判；仅测试引用的 `BoundedInputStream` / `contains` 记为可见性建议，不判死代码 |
| §2 重复逻辑 | 4 | #8（8 个端序原语）、#9（三份限长读）、#10（ZIP64 哨兵 + 分卷校验）、#11（测试同构 + tempdir 样板）。同文件函数体两两比对了 20 个：`buildZip64Extra`/`parseZip64Extra` 与 `buildZip64Sample`/`buildRawZip` 职责不同，不并；`readLocalHeader`/`readCentralHeader` 字段布局不同，不并 |
| §3 空实现 | 0 | `BufferSource.close`（`EntrySource.cj:67`）是内存源的有意 no-op；`catch (_: Exception) {}` 只包「关闭 / 删除临时文件」这类无业务后果的清理（`EntrySource.cj:119-122`、`BoundedStream.cj:145-148`、`Unzip.cj:157-170`）；无 `TODO` / 未接线分支 |
| §4 栈溢出 | 0 | 本部分无递归：`decodeName` 的回退链是三条独立函数；`locateEocd` / `parseZip64Extra` / `readCentralHeader` 全是深度由常量决定的循环 |
| §5 OOM | 1 | #1（按不可信 `cdSize` 预分配）。其余分配均有上界：尾窗 ≤ 22+65535、local header `total ≤ 30+65535+65535`、`readBytes` 的 n ≤ 65535、`latin1` 的 Rune 数组 ≤ nameLen |
| §6.1 热点瓶颈 | 0 | 无 profile / bench 数据，热点结论不成立；三个候选已进「待验证假设」与优化方案（均无基线） |
| §6.2 大粒度锁 | 0 | 本部分没有任何锁；`#2` 是「该加锁而没加」，不是锁太大 |
| §6.3 并发串行 | 0 | 本部分无 `spawn` / `Future` / 线程池 |
| §6.4 低效算法 | 0 | 结构上可指出 `findLast` 的 O(n) 扫描 + 每条目解码（`ZipReader.cj:174-182`），无实测支撑，只作范围外提示与假设 3 |
| §7 降堆内存方案 | 1 | 「中央目录双份驻留」，`无基线（待验证）` |
| §8 降 CPU 方案 | 2 | 「`CentralEntry.name` 重复解码」「头部字段逐字段小数组（读+写）」，均 `无基线（待验证）` |
| §9 local mode 可行性 | 0 | 热点候选产出的是逃逸对象（`CentralEntry` 进 `rawEntries`、`cdBytes` 交给 `ByteBuffer`），不满足 local region 的「不离开函数」前提；剩余临时对象（2/4/8 字节数组）峰值太小，无法用峰值内存证明收益 |
| §11 现有代码的 BUG（存量） | 7 | #1~#7 全部存量。另核对了 6 处边界未成立：`readBytes(n==0)`、`skipBytes` 负数、`u32At` 在 `i = window-22` 时的上界、`parseZip64Extra` 的 `pos+4` 上界、`ArrayRangeInputStream` 的 `offset+length` 截到 `data.size`、`buildZip64Extra` 空 payload 早退 |
| §12 并发安全与锁粒度 | 1 | #2。`BufferSource` 无状态、`ArrayRangeInputStream` 每流独立游标、`CountingOutputStream` / `Crc32InputStream` 每实例独占——逐类核对过线程封闭性；`ZipReader.consumed` 的原子记账不在本部分文件 |
| §13 文档一致性（.md 与代码注释） | 3 | #14（spec 正文 vs 错误消息）、#13（类注释 + `tasks.md` 两处）、#5 的注释侧（「不抛异常」vs `String.fromUtf8`）。两个 spec 的验收口径与实现逐条对得上（含 `unzip` 可选证据口径、`>= 0xFFFF` 升级、临时目录首选+逐级回退） |
| §14 功能完备性与 README 覆盖 | 0 | 本部分文件不新增对外符号（`EntrySource` / 各流 / `EntryNameTable` / `CentralEntry` / `LocalHeader` 均 `internal`），README 覆盖由公开 API 所在部分负责；spec / tasks 承诺的能力（ZIP64 extra、分卷拒绝、GBK 回退、同名消解、24 字节 descriptor）在本部分均有实现与用例 |
| 文件覆盖（§13 等） | 20/20 | 20 个文件全部读完，无缺项 |

### 第 3 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 9 | #1 数据丢失、#2 契约、#3 竞态、#7 语义分裂、#8 错误降级、#9 静默丢弃、#17 跨包误读、#18 日志错配、#19 测试可信度 |
| §1 死代码 | 2 | 逐个 `private` / `internal` / `protected` / 非可达 `public` 搜引用：`isSymbolicLinkEntry`、`resolveSafeTarget`、`readAllBytes`、`account`、`encodeDos*`、`decodeDosDateTime`、`TempSpill` 四个 `public static`、`peakRssKb`、`RepeatingBlockInputStream`、13 个测试 helper 均有调用者（`internal class TempSpill` 的成员按硬原则二全项目搜过，`createIn` 仅测试 + 自身、`candidates`/`fallbackDirectory` 内部使用，均非零引用）；20 个文件的 `import` 逐条核对，仅 `ZipEntryStream_test.cj:18` 未使用；`return`/`throw` 后同层语句逐处看过，另命中 `wrapMethod` 的不可达 `case _`。`ZipLayout` 27 个常量全部有引用。第 2 部分已报的 `LocalHeader.dataOffset` 死写不重复计 |
| §2 重复逻辑 | 3 | 同文件两两比对 20 个文件的函数体：命中 `verifyEntry` vs `ZipEntryInputStream.read`（同语义同文案）、`buildZipBytes` vs `buildZipWithResult`（真子集）、`TempSpill` 两处同文案；跨文件搜相同错误文案另查到 `条目路径非法`（`Unzip.cj:115/119/122/126/133`）5 处，属"为可读性刻意展开"的误报边界，未计 |
| §3 空实现 | 3 | 无空函数体、无 `TODO`/`FIXME`、无 `UnsupportedException`；命中三处静默：`TempSpill` 的 `catch { continue }`（#10）、`ZipEntryOutputStream.write` 的 `if (failed) return`（#9）、`addTree` 对非常规文件无分支（#20） |
| §4 栈溢出 | 0 | 唯一递归是 `Zip.addTree`（`Zip.cj:42-63`），深度 = 目录深度且 `info.isSymbolicLink()` 在递归前就跳过（`Zip.cj:50-53`），不存在环；深度上界受路径长度限制（Windows 260 / Linux 4096 字符量级），未构成可达的爆栈路径。`readLinkTarget`/`ensureDirectory` 均非递归 |
| §5 OOM | 1 | #4（`unzip(InputStream)` 全量物化 + 无归档上限）。`decodeEntry` 的 `ByteBuffer` 有 `maxEntrySize` 兜底（`account` 按实际字节记账），`readAll` 是"显式要求全部同名条目"的语义，均未计 |
| §6.1 热点瓶颈 | 0 | 无 `cjprof` / `cjpm bench` 数据，`findLast`、`locateData` 双读、`entries()` 重建全部降级为"待验证假设" #1-#3，不进统计 |
| §6.2 大粒度锁 | 0 | 本部分无锁；`ZipReader` 只用 `AtomicInt64` 记账（`ZipReader.cj:46`） |
| §6.3 并发串行 | 0 | 无 `spawn` / 无批处理 / 无线程池，不适用 |
| §6.4 低效算法 | 0 | `findLast` 的 O(n) 与 `locateData` 的二次读都是"没有测量数据"的线索，已入待验证假设，未计为缺陷 |
| §7 降堆内存方案 | 2 | "整包缓冲峰值"、"`entries()` 重建"两条，均标 `无基线` |
| §8 降 CPU 方案 | 2 | "`findLast` 哈希索引"、"`locateData` 单次读"两条，均标 `无基线` |
| §9 local mode 可行性 | 0 | 本部分的热点候选（`decodeEntry` 的 8 KB chunk、`writeEntryToFile` 的 8 KB 缓冲、`entries()` 的 `ZipEntry` 列表）都要么逃逸（作为返回值/成员），要么是 `Array` 无法直接标注；且无峰值内存前后对照，按铁律只能停在"待验证假设"，本轮不单列 |
| §11 现有代码的 BUG（存量） | 7 | #1、#3、#7、#8、#9、#17、#20；`ZipTime` 的 DOS 编解码边界（年 <1980 截断、非法月/日返回 `None`、秒 60-62 由 `DateTime.of` 抛错兜底）逐条核对，无缺陷 |
| §12 并发安全与锁粒度 | 2 | #3（`exists`→`create`）、#5（`closed` 裸 `var` + `close` 与读并发）；无锁粒度问题可谈（本部分没有锁） |
| §14 功能完备性与 README 覆盖 | 1 | #15（`CompressionMethod.fromValue` 未接入读取侧，属"能力未接线"）；README 不在本部分文件清单内，`.md` 覆盖由第 1 部分负责 |
| 文件覆盖（§13 等） | 20/20 | 无缺文件；本部分 0 个 `.md`，§13 文档一致性在其余部分 |

### 第 4 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 11 | 正确性与契约 5 条（G1–G5），可读性/重复 4 条（M1、M2、M5、M6），语义一致性 2 条（M4、G2 的 unzip 侧行为）；本部分无网络、无外部字节流解析（写入侧只收调用方给的字符串与数组） |
| §1 死代码 | 0 | 已逐个符号 grep：`ZipWriter` 7 个 private 方法 + 2 个 internal 方法全有调用者；`ZipWriterOptions` 两个 `@When` 版 `defaultMemoryEntryThreshold` 都被 `init` 默认参数使用；测试内 `text`、`FailingInputStream`、`CountingSink`、`FailingOutputStream`、`captureZipError`、`assertZipError` 均有引用；`forServer`/`forLowMemory` 属对外可达 public，只记录「仓内仅测试引用」，不判死代码；无 `return/throw/break/continue` 之后的同层语句；6 个文件的 import 全部用到 |
| §2 重复逻辑 | 3 | M1（前置检查两份）、M2（descriptor 2 处 + LocalHeader 构造 4 处）、M5（同参数失败调用 3 次） |
| §3 空实现 | 1 | G4 的 3 处 `catch (_: Exception) {}`；无空函数体、无 TODO/FIXME |
| §4 栈溢出 | 0 | 本部分唯一的递归在 `Zip.cj`（不在本部分）；`pump`/`compressData`/`names.allocate` 都是单层循环，`EntryNameTable.allocate` 的后缀递增保证终止 |
| §5 OOM | 0 | 内存路径有 `memoryEntryThreshold` 上限且四级临时目录全失败会抛错而非降级（`ZipWriter.cj:88`、`TempSpill.cj:88`）；有界但峰值偏高，归入优化方案 1；`entries`/`names` 与条目数同阶，`close()` 后随 writer 释放，无只增不减的全局容器 |
| §6.1 热点瓶颈 | 0 | 无 `cjprof` / `cjpm bench` 数据，热点不成立；两条候选写入待验证假设 #1/#3 |
| §6.2 大粒度锁 | 0 | 本部分无锁；`ZipWriter` 注释明确非线程安全（`ZipWriter.cj:39`） |
| §6.3 并发串行 | 0 | 无 `spawn` 提交任务、无线程池；`spillingObservedDuringSpill` 的 poller 只读一个 `AtomicBool` |
| §6.4 低效算法 | 0 | 无嵌套循环 / 热路径 `contains` / `remove(at: 0)`；`compressData` 的 1.5× 增长是摊还 O(n)；`EntryNameTable.allocate` 的 `while(true)` 由后缀递增收敛 |
| §7 降堆内存方案 | 1 | 优化方案 1（去掉 payload 副本） |
| §8 降 CPU 方案 | 2 | 优化方案 2（复用压缩器）、3（`pump` 切片） |
| §9 local mode 可行性 | 0 | `compressData` 的缓冲区作为返回值逃逸，不满足 local 约束；`pump` 内 8 KB 数组生命周期虽短但没有峰值内存前后对照，收益无法证明 |
| §11 现有代码的 BUG（存量） | 5 | G1–G5；均为工作区快照下的存量（`git diff` 为空，无本次改动） |
| §12 并发安全与锁粒度 | 0 | 类注释声明非线程安全，唯一跨线程可见状态是 `spillingFlag: AtomicBool`（`ZipWriter.cj:50`、`74-78`），测试只跨线程读它；`dirty`/`entryOpen`/`closed` 无线程共享证据；无锁粒度问题可谈 |
| §14 功能完备性与 README 覆盖 | 0 | 本部分无 `.md`；写入侧 public 入口（`add`/`addFile`/`addFileStream`/`addDirectory`/`openEntry`/`close`/`position`/`spilling`）均有接口注释与用例（`openEntry` 的用例在 `ZipEntryStream_test.cj`）；模块 README 覆盖由 part1 判定 |
| 文件覆盖（§13 等） | 6/6 | 清单 6 个文件全部读完，无 `.md` |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 2 |
| 一般 | 20 |
| 轻微 | 37 |
| 其中存量 | 59 |
| 优化方案 | 见「优化可行性方案」各条 |

## 总评

**第 1 部分**：文档整体质量高于仓库平均水平：设计稿把「为什么这样写」讲透了，21 条决策、字节布局、错误消息、限额语义、平台分档都有落点；README 与 api.md 的限额默认值、临时目录四级回退、`spilling`/`position` 语义也与实现一致，这在自研 ZIP 容器里是难得的。

主要风险集中在**「文档冻结在 2026-10-28，之后新增的能力与修复没有回写」**：`openEntry` 推模式让 api.md 的「九个名字 / 不需要推模式」变成错误信息；「对外只抛 `ZipException`」会让调用方漏 catch；「小文件不产生 ZIP64 字节」与流式路径相反；ZIP64 的 `0xFFFF` 边界在两份变更文档里仍是错的 `>`；`f624bf2fa` 自动补的「其他公开 API」把 33 个 `internal` 成员写成对外契约。这五条都属于「照着文档写会出错」，建议合并模块报告时优先修文档而不是改代码。

真正需要代码侧跟进的是 bit 13 那条（设计承诺的拒绝路径不存在），但按加密位前置判定，正常样本会先被加密检查拦下，影响限于畸形包的错误可诊断性。其余为轻微文档漂移。本部分 14 条全部为存量，无严重级缺陷；模块唯一的严重项（`cdSize` 预分配触发 ~4 GiB 分配）已在第 2 部分 #1 统计，本部分不重复计入。存量 14 条是否纳入修复待用户决定。

**第 2 部分**：本部分是 f_zip 的地基：端序原语、四种 header 读写、EOCD/ZIP64 链、名字编码与同名消解。硬约定（越界不动游标、extra 只放越界项、按长度决定读几个 8 字节、`>=` 哨兵）都有注释与用例兜住，读写两侧的字段往返测试相当齐，是本模块质量最高的一段。

阻塞项两条，都在「打开归档」这一侧：#1 的 `cdSize` 预分配是真正能打崩进程的那条（22 字节换约 4 GiB，发生在 `ZipReader` 构造函数里，任何网关都会先撞上），修法很小（两处减法比较 + `readFullyAt` 的长度兜底），应优先；#2 的并发共享游标与 `ZipReader.cj:34-35` 的承诺直接矛盾，加一把只包住 seek+read 的 `Mutex` 即可，不必改架构。这两条建议同批修，并各补一条负例（`cdSize` 伪造、双线程交叉 `read`）。

其余五条一般问题（ZIP64 条目分卷口子、名字长度截断、bit 11 非法 UTF-8 抛错类型、u64 偏移溢出、条目流无关闭途径）单条触发条件都不算常见，但都是「静默或错误类型不符」型：#3 / #6 与 #1 同属「EOCD 链校验不足」，建议一起改、一起补负例；#4 / #5 是写入侧与解码侧各一处缺校验，改动小；#7 需要在 `BoundedStream` / `ZipReader` 之间引入 `Resource` 契约，顺带修掉 `Unzip` 的 fd 泄漏，值得排进同一次迭代。

轻微项（端序原语与限长流重复、ZIP64 判定两处、测试同构、5 处死代码、两处文档漂移、一处 spec 措辞）纯属可维护性，可随下次触碰该文件顺手处理；#9 / #10 有耦合，建议同一次改完，否则「三份实现漂移」「两处哨兵判定漂移」还会复现。三条优化方案与五条待验证假设都缺改前基线，只用于下一轮补数据，不进修复清单。

本报告只报不修，未改动任何源码、未跑构建。

**第 3 部分**：本部分代码的整体质量偏好：`unzip` 的 zip-slip 校验（绝对路径 / 盘符 / `..` 段 / 规范化前缀四道）思路完整且有对照用例，炸弹防护按"实际解压字节"记账而不是信 header，`ZipEntryOutputStream` 的 dirty 状态与幂等 `close` 设计清楚，测试分层（慢用例 / 资源用例 / 外部工具）也有门控。

阻塞项不在"能不能解压"，而在**失败路径的副作用**：`writeEntryToFile` 在失败时删除目标文件（#1）是唯一会造成数据丢失的问题，应优先修；紧随其后的是 `ensureDirectory` 的 TOCTOU（#3）与 `ZipReader.closed` 的裸字段（#5）——两者都只在并发下暴露，但只要 f_zip 被放进服务端并发路径就会命中，属"先安全后粒度"里必须先处理的安全项。#2 是文档高估了原子性（含本模块自己的用例已经把"部分落盘"写成断言），改文档或改实现都行，但不能两者都不动。`unzip(InputStream)` 无归档上限（#4）是设计选择，补一个上限参数即可把它从"OOM 面"降级为"有界失败"。

轻微项以契约细节为主（目录条目三 API 语义、错误降级、静默丢弃、日志 category、注释与实现相反），可排期批量修；死代码与重复逻辑各 2-3 处，量很小。性能侧本轮没有 profile，`findLast` 的 O(n)、`locateData` 的双读都只作为待验证假设登记，等下一轮补 `cjprof` 数据再决定是否动结构。

**第 4 部分**：写入侧是这套代码里质量偏高的一块：两条写入路径的分工与注释表一致，脏状态把 header / 泵送 / descriptor 三个阶段都包住（且有专门用例），ZIP64 升级判据（`>= 0xFFFF` 的条目数、CD 起点与大小）逐条写清了理由。本部分**没有阻塞项**，5 条一般问题都集中在「边界与失败之后」：`close()` 重试的中间状态没有被记录、条目名没有规范化校验（尾斜杠会静默丢数据）、异常路径跳过压缩器释放和临时文件清理日志、以及一条绑死 POSIX 符号链接权限的用例。

性能侧没有 profile / bench 数据，三条候选（整份压缩副本、每条目压缩器初始化、`pump` 切片）全部落在「待验证假设 / 无基线优化方案」，不构成缺陷。

本部分存量缺陷 11 条（5 一般 + 6 轻微），默认只报不修，是否纳入修复待用户决定。

范围外提示：`EntryNameTable.cj:48` 的 `throw ZipException` 位于 `while (true)` 之后，是不可达语句（死代码）；同文件的 `contains` 仅被测试引用、`size()` 全仓无引用，属 part1–3 范围，未计入本部分统计。
