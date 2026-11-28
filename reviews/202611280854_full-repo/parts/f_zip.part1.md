# f_zip 模块审查报告（第 1/4 部分：文档层）

> **模块第 1/4 部分**：本报告只覆盖 `files/f_zip.part1.txt` 列出的 9 个 `.md`（`README.md`、`README_en.md`、`doc/api.md`、`doc/f_zip模块设计.md`、`doc/spec/add-f-zip-module/{design,proposal}.md`、`specs/f-util-crc|f-zip-container|f-zip-reader/spec.md`）。本部分无 `.cj`，所有发现都是「文档承诺 ↔ 实现取证」；`.cj` 只作为证据读取，不展开逐项审查，源码缺陷归第 2~4 部分。
>
> **版本说明**：v2（2026-11-28 重跑，覆盖 13:58 的 v1）。v1 的 13 条已逐条复核：12 条保留（其中 bit 13 的后果按加密位前置判定下调为轻微），`f-util-crc` 规格那条按 review-checklist §13 误报边界（归档变更不要求与当前实现一致）降为「覆盖说明」不再计入；新增 2 条（分卷 ZIP 未进 README/错误表、`open` 不返回部分数据的承诺自相矛盾）。v1 关于 `cdSize` 预分配的范围外提示已由第 2 部分 #1 坐实为严重项，本部分不重复统计。
>
> **合并提示（给主 Agent）**：#14（`open` 不返回部分数据）与第 3/4 部分 `ZipReader` 的流式校验同源，合并时保留代码侧取证；`cdSize` 严重项只在第 2 部分计一次，本部分仅保留范围外提示。

- **审查日期**：2026-11-28
- **模块路径**：`f_zip`（全模块 42 个 `.cj` + 13 个 `.md`；本部分 9 个 `.md`）
- **基线**：工作区快照（master 与 `sts/1.3.x` 同一提交 `120fd2542`，`git diff` 为空 ⇒ 全部记「存量」）
- **审查重点**：压缩包解析与安全（Zip Slip / ZIP 炸弹）、流式与内存、资源释放、死代码、重复逻辑；本部分落在文档契约与安全承诺（§13 / §14）
- **报告版本**：v2（第 1/4 部分）

## 发现

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

## 优化可行性方案

本部分只有 `.md`，没有可改的源码对象；`scope.md` 也未提供本模块改前 / 改后的性能对照（设计稿 §10 的 VmHWM 与耗时是现状基线，不是优化前后对照）。按铁律不产出优化方案，性能线索只进「待验证假设」。

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `entries()` 每次全量拷贝 `CentralEntry → ZipEntry`，65535 条时每次产生约 6.5 万个临时对象 | `f_zip/src/ZipReader.cj:68-75` | 单次耗时、分配量与真实调用频次 | `F_ZIP_SLOW=1` 造 65535 条包，循环 `entries()` 1000 次，`cjprof heap` 看分配与 GC；同环境对照「缓存快照 + 复制接口」 |
| 2 | deflate 的 `bufLen: 8192` 偏小，加大缓冲可减少边界调用（设计稿只给方向，无数据） | `f_zip/src/ZipReader.cj:243`、`ZipWriter.cj:174`、`:501` | 8K/32K/64K 的吞吐与内存对照 | `cjpm bench -O2`，1 GiB 可压缩 / 不可压缩各 5 轮，取中位数与离散度 |
| 3 | 文档引用的性能数字（CRC 51~58 MB/s、`9.7b` 200 s、1 GB 包 RSS +3.6 MB）未在本轮复测，可能随环境漂移 | `f_zip/doc/f_zip模块设计.md:1234-1264` | 当前机器上的实测值 | `F_UTIL_PERF=1`、`F_ZIP_SLOW=1`、`F_ZIP_RESOURCE=1` 分别重跑，记录中位数与机器差异 |

## 文件覆盖

> 与 `reviews/202611280854_full-repo/files/f_zip.part1.txt` 一一对应。

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_zip/README.md` | .md | ✅ | 发现 #1 #2 #3 #5 #12 #13；API 签名、限额默认值、临时目录四级回退、`spilling` 语义逐项核对通过 |
| 2 | `f_zip/README_en.md` | .md | ✅ | 与中文版逐节对齐；#1 #2 #3 #5 #12 #13 同样存在，不重复计数 |
| 3 | `f_zip/doc/api.md` | .md | ✅ | 发现 #1 #2 #13 #14；`ZipLimits` 早拒语义、`tempDir` 回退、`spilling`/`position` 说明核对通过 |
| 4 | `f_zip/doc/f_zip模块设计.md` | .md | ✅ | 发现 #6 #7 #8 #9 #10 #11 #13；§2.4 / §5.2 / §7.2.1 为 #3、#4 提供正确口径与反证；§10 实测数字未复测（假设 #3） |
| 5 | `f_zip/doc/spec/add-f-zip-module/design.md` | .md | ✅ | 发现 #2 #4 #7 #9；D1–D16 与实现总体一致 |
| 6 | `f_zip/doc/spec/add-f-zip-module/proposal.md` | .md | ✅ | 发现 #2 #4；Why / Impact 的依赖面与 `cjpm.toml` 一致 |
| 7 | `f_zip/doc/spec/add-f-zip-module/specs/f-util-crc/spec.md` | .md | ✅ | 无发现。归档变更记录：其「16/64 位保持逐字节」与当前 `f_util/src/CrcEngine.cj:278/364`（slicing-by-8 / slicing-by-2）已漂移，但按 §13 误报边界不计缺陷 |
| 8 | `f_zip/doc/spec/add-f-zip-module/specs/f-zip-container/spec.md` | .md | ✅ | 发现 #3、#4 的反证；小端原语、三类 header、EOCD 自洽、方法白名单、编码链、DOS 时间、CRC 归属核对通过。仅 `readBytes`/`skip` 与实现 `skipBytes` 命名不同，不影响契约 |
| 9 | `f_zip/doc/spec/add-f-zip-module/specs/f-zip-reader/spec.md` | .md | ✅ | 发现 #14；`entries()` 顺序、同名取最后一个、`maxTotalSize` 每实例、关闭语义与实现逐条核对通过 |

合计：`.cj` 0 个 / `.md` 9 个 / 共 9 个，全部读完。

## 覆盖自检

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

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 0 |
| 一般 | 5 |
| 轻微 | 9 |
| 优化方案（堆内存 / CPU） | 0 / 0 |

## 总评

文档整体质量高于仓库平均水平：设计稿把「为什么这样写」讲透了，21 条决策、字节布局、错误消息、限额语义、平台分档都有落点；README 与 api.md 的限额默认值、临时目录四级回退、`spilling`/`position` 语义也与实现一致，这在自研 ZIP 容器里是难得的。

主要风险集中在**「文档冻结在 2026-10-28，之后新增的能力与修复没有回写」**：`openEntry` 推模式让 api.md 的「九个名字 / 不需要推模式」变成错误信息；「对外只抛 `ZipException`」会让调用方漏 catch；「小文件不产生 ZIP64 字节」与流式路径相反；ZIP64 的 `0xFFFF` 边界在两份变更文档里仍是错的 `>`；`f624bf2fa` 自动补的「其他公开 API」把 33 个 `internal` 成员写成对外契约。这五条都属于「照着文档写会出错」，建议合并模块报告时优先修文档而不是改代码。

真正需要代码侧跟进的是 bit 13 那条（设计承诺的拒绝路径不存在），但按加密位前置判定，正常样本会先被加密检查拦下，影响限于畸形包的错误可诊断性。其余为轻微文档漂移。本部分 14 条全部为存量，无严重级缺陷；模块唯一的严重项（`cdSize` 预分配触发 ~4 GiB 分配）已在第 2 部分 #1 统计，本部分不重复计入。存量 14 条是否纳入修复待用户决定。

## 范围外提示

> 取证时顺带读到、属于其他子轮文件的问题，只记一句，不占本部分统计。

- `[§5 OOM][严重]` `EOCD.cj` 的 `cdSize` 未与文件长度交叉校验，`readFullyAt` 先按该长度预分配（`Eocd.cj:47`、`:109`、`:165-169` → `ZipReader.cj:192`）；22 字节输入可触发 ~4 GiB 分配。详见第 2 部分 #1，不在此重复。
- `[§12.1][需复核]` `ZipWriter.position` 底层 `CountingOutputStream` 的计数字段是普通 `Int64`（`BoundedStream.cj:155`、`:169`），而 README:160 与设计稿 D9 把它定位为可跨线程轮询的展示值；写线程与 UI 线程之间没有原子或屏障。
- `[§1]` `EntryNameTable.allocate` 的 `while (true)` 之后的 `throw` 不可达（`EntryNameTable.cj:48`）；`LocalHeader.dataOffset` 只写不读（`LocalHeader.cj:190`、`ZipReader.cj:236`）。
- `[§11][需复核]` `ZipWriter.close()` 写 CD 中途失败时 `closed` 仍为 false（`ZipWriter.cj:446-448`），但失败前可能已写出部分 CD；再次调用会从新位置再写一整份 CD/EOCD（`:391-402`），与 KDoc「再次调用会重试」叠加可能产出重复中央目录。
- `[§4][需实测]` `zip()` 的 `addTree` 按目录深度递归（`Zip.cj:42-62`），无深度上限；极深目录树是路径长度先报错还是栈先溢出未验证。
