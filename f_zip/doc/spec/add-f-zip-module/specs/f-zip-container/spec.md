# Spec Delta

## Purpose

为 `fountain::f_zip` 提供 ZIP 容器层的静态格式能力：显式小端读写、三类 header 的编解码、EOCD 自洽定位、ZIP64 双向支持、压缩方法白名单、文件名编码判定链与 DOS 时间。这一层不关心"从哪读、往哪写"，只保证"给定字节，能解析出正确结构；给定结构，能产出规范字节"。

## ADDED Requirements

### Requirement: 显式小端读写原语

`f_zip` SHALL 在模块内部提供 16/32/64 位无符号整数的显式小端读写函数（`readU16LE` / `readU32LE` / `readU64LE` / `writeU16LE` / `writeU32LE` / `writeU64LE`）与定长字节读函数（`readBytes` / `skip`）。这些函数 SHALL 基于 `f_io.ByteBuffer` 的 `readByte()` / `read(buf)` / `writeByte` / `write(buf)` 实现，SHALL NOT 依赖任何"默认端序"的 API，且 SHALL NOT 进入公开 API。

#### Scenario: 越界返回 None 且游标不位移

- **WHEN** 在一个只剩 2 字节可读的 `ByteBuffer` 上调用 `readU32LE`
- **THEN** 返回 `None`
- **AND** `readOffset` 与调用前完全相同

#### Scenario: 校验实际读到的字节数

- **WHEN** 底层 `read(buf)` 返回的字节数少于请求长度
- **THEN** 结果为 `None`
- **AND** 不得把未读满的缓冲区补零后当作合法值返回

#### Scenario: 小端字节序确定

- **WHEN** 写出 `writeU32LE(0x04034b50)`
- **THEN** 产出的四个字节依次为 `0x50 0x4B 0x03 0x04`
- **AND** 在同一序列上调用 `readU32LE` 能还原出 `0x04034b50`

#### Scenario: 读越界后可继续读

- **WHEN** 一次越界读失败后，从一个更大缓冲区的已知偏移处继续读取
- **THEN** 读到的值与直接从该偏移读一致，说明失败没有污染游标

### Requirement: Local File Header 编解码

`f_zip` SHALL 提供 Local File Header（固定 30 字节：签名 `0x04034b50`、version needed、general purpose flag、compression method、DOS time、DOS date、crc-32、compressed size、uncompressed size、name length、extra length，后接 name 与 extra）的读与写函数，且 SHALL 支持 ZIP64 extra（ID `0x0001`）的解析与构造。

#### Scenario: 30 字节头往返

- **WHEN** 以任一组合法字段值写出 local header，再读回
- **THEN** 所有字段逐字段相等，且 name 与 extra 原样还原

#### Scenario: ZIP64 extra 按固定顺序只含越界项

- **WHEN** 构造一个 `uncompressedSize` 与 `localHeaderOffset` 越界、`compressedSize` 不越界的条目
- **THEN** extra `0x0001` 依次只包含 `originalSize(8)` 与 `localHeaderOffset(8)` 两个值，`compressedSize` 不出现在其中
- **AND** header 中对应字段写成 `0xFFFFFFFF`

#### Scenario: ZIP64 extra 长度不足即拒绝

- **WHEN** 一个条目的 extra 中 `0x0001` 声明的长度小于按哨兵字段个数计算出的需求
- **THEN** 抛出 `ZipException`，消息形如 `ZIP64 extra 长度不足：需要 ${need}，实际 ${got}（${name}）`
- **AND** 不得按字段位置硬读越界内存

### Requirement: Central Directory Header 编解码

`f_zip` SHALL 提供 Central Directory Header（固定 46 字节：签名 `0x02014b50`、version made by、version needed、flag、method、DOS time/date、crc-32、compressed size、uncompressed size、name length、extra length、comment length、disk number start、internal attributes、external attributes、local header offset，后接 name / extra / comment）的读与写函数。

#### Scenario: 46 字节头往返

- **WHEN** 写出一个 central header 再读回
- **THEN** 20 个字段与 `localHeaderOffset` 全部相等，external attributes 保持原始 32 位值

#### Scenario: 注释被完整跳过

- **WHEN** 解析一个带非空 file comment 的 central header
- **THEN** 解析出的字段正确，且下一条记录从 comment 之后开始

### Requirement: EOCD 自洽定位

`f_zip` SHALL 从文件尾部窗口（`min(fileLength, 22 + 65535)` 字节）由后向前扫描签名 `0x06054b50`，并对每个候选项校验"`22 + 注释长度 == 该候选到文件尾的距离`"，取第一个自洽者。尾部窗口内扫不到时 SHALL 直接报错，SHALL NOT 退化为全文件扫描。

#### Scenario: 注释里嵌了 EOCD 签名

- **WHEN** 一个 ZIP 的归档注释中包含字节序列 `0x06054b50`
- **THEN** 定位结果仍是真正的 EOCD（因为注释内候选的 `22 + commentLen` 与到文件尾距离不自洽）

#### Scenario: 尾部窗口内找不到 EOCD

- **WHEN** 输入不是 ZIP 或被截断
- **THEN** 抛出 `ZipException`，消息为 `不是有效的 ZIP 文件（未找到中央目录）`
- **AND** 不做全文件回溯扫描

#### Scenario: 空 ZIP

- **WHEN** 解析一个只有 EOCD、0 条目的 ZIP
- **THEN** 条目数为 0，中央目录大小与偏移均为 0，`entries()` 返回空列表且不抛异常

### Requirement: ZIP64 读取链

`f_zip` SHALL 在读普通 EOCD 后，**仅当**条目数 / CD 大小 / CD 偏移为哨兵值（`0xFFFF` / `0xFFFFFFFF`）时，才去读 ZIP64 EOCD 定位器（`0x07064b50`，20 字节）与 ZIP64 EOCD（`0x06064b50`）；SHALL NOT 无条件按 8 字节读条目数字段。

#### Scenario: 不越界时不查 ZIP64

- **WHEN** 一个普通 ZIP 的 EOCD 三个字段都不是哨兵值
- **THEN** 直接使用普通 EOCD 的值，不读取任何 EOCD64 结构

#### Scenario: 定位器签名不匹配

- **WHEN** 普通 EOCD 有哨兵值，但 EOCD 之前的 20 字节不是 `0x07064b50`
- **THEN** 抛出 `ZipException`，说明 ZIP64 定位器缺失或损坏

#### Scenario: CD 偏移越界

- **WHEN** 解析出的中央目录偏移大于文件长度
- **THEN** 抛出 `ZipException`，消息形如 `中央目录偏移 ${off} 超出文件长度 ${len}`

### Requirement: ZIP64 写入仅在越界时启用

`f_zip` SHALL 在写入时逐字段判断：单条目的 `uncompressedSize` / `compressedSize` / `localHeaderOffset` 任一 ≥ `0xFFFFFFFF` 时，该条目走 ZIP64（对应字段写哨兵 + extra `0x0001` 只放越界项 + `version needed = 45`）；`close()` 时条目数 ≥ `0xFFFF` 或 CD 大小 / 偏移 ≥ `0xFFFFFFFF` 时，写 EOCD64 + 定位器并在普通 EOCD 对应字段填哨兵（`0xFFFF` 本身是读取侧的哨兵值，写侧不能把它当真实值）。都不越界时 SHALL NOT 写任何 ZIP64 结构。

#### Scenario: 小文件不产生 ZIP64 字节

- **WHEN** 写出一个条目数少、单条小、偏移小的 ZIP
- **THEN** 输出中不存在 `0x06064b50` 与 `0x07064b50`，且所有 header 的 extra 里没有 `0x0001`
- **AND** 普通 EOCD 的条目数字段为真实值（不是 `0xFFFF`）

#### Scenario: 条目数越界自动升级

- **WHEN** 写入的条目数达到 `0xFFFF`（恰好 65535 或更多）后调用 `close()`
- **THEN** 输出包含 EOCD64 与定位器
- **AND** 普通 EOCD 的条目数字段为 `0xFFFF`，真实值出现在 EOCD64 中
- **AND** 不抛异常、不告警

### Requirement: 压缩方法白名单

`f_zip` SHALL 只支持 Stored(0) 与 Deflate(8) 两种压缩方法；其余方法（9 Deflate64、12 BZIP2、14 LZMA、93 Zstandard、95 XZ、98 PPMd 等）读取时 SHALL 抛出 `ZipException` 并携带方法数值与条目名。

#### Scenario: 不支持的方法报出具体数值

- **WHEN** 读取一条 method 为 12 的条目
- **THEN** 抛出 `ZipException`，消息包含 `12` 与条目名
- **AND** 消息能让人区分"算法不支持"与"文件损坏"

#### Scenario: Stored 与 Deflate 可用

- **WHEN** 分别读取 method 为 0 与 8 的条目
- **THEN** 都能得到原始字节，且 CRC 校验通过

### Requirement: 文件名编码判定

写入时 `f_zip` SHALL 判定文件名是否全为 ASCII：全 ASCII 时不置位 bit 11、按 ASCII 字节写出；否则置位 bit 11、按 UTF-8 写出。读取时 SHALL 按以下固定顺序：bit 11 置位 → UTF-8；否则 UTF-8 严格解码 → GBK → Latin-1 逐字节映射。回退链 SHALL 固定写死，SHALL NOT 引入编码检测库。

#### Scenario: 中文名置位 bit 11

- **WHEN** 写入条目名 `中文.txt`
- **THEN** 该条目的 general purpose flag 的 bit 11 为 1
- **AND** 名字字节是 `中文.txt` 的 UTF-8 编码

#### Scenario: 纯 ASCII 名不置位 bit 11

- **WHEN** 写入条目名 `a/b.txt`
- **THEN** bit 11 为 0，名字字节与 ASCII 原文一致

#### Scenario: 未置位 bit 11 的合法 UTF-8 名

- **WHEN** 读取一个 bit 11 为 0、名字字节是合法 UTF-8 的条目
- **THEN** 按 UTF-8 解码成功，名字正确

#### Scenario: 未置位 bit 11 的 GBK 名

- **WHEN** 读取一个 bit 11 为 0、名字字节是合法 GBK 但非法 UTF-8 的条目
- **THEN** 按 GBK 解码成功，中文名不出现乱码

#### Scenario: 两种编码都非法

- **WHEN** 读取一个 bit 11 为 0、字节序列既非合法 UTF-8 也非合法 GBK 的条目名
- **THEN** 按 Latin-1 逐字节映射得到字符串，不抛异常

### Requirement: DOS 时间编解码

`f_zip` SHALL 按 ZIP 规范编解码 DOS 时间（time: 时 5 位 / 分 6 位 / 秒除以 2 共 5 位；date: 年减 1980 共 7 位 / 月 4 位 / 日 5 位），秒精度为 2 秒。

#### Scenario: 往返精度

- **WHEN** 将 `2026-10-24 13:45:30` 编码为 DOS 时间再解码
- **THEN** 得到 `2026-10-24 13:45:30`

#### Scenario: 奇数秒被截断

- **WHEN** 将 `2026-10-24 13:45:31` 编码后解码
- **THEN** 秒为 30（向偶数秒截断，属格式限制）

### Requirement: 加密 ZIP 拒绝

`f_zip` SHALL 在读取时检查 general purpose flag 的 bit 0（加密）与 bit 6（强加密），任一置位即抛出 `ZipException`，消息形如 `不支持加密 ZIP（${name}）`。SHALL NOT 做任何部分支持。

#### Scenario: 普通加密（bit 0）

- **WHEN** 读取 bit 0 为 1 的条目
- **THEN** 立即抛出 `ZipException`，不返回任何数据

#### Scenario: 强加密（bit 6）

- **WHEN** 读取 bit 6 为 1 的条目
- **THEN** 立即抛出 `ZipException`

### Requirement: CRC32 复用 f_util 且作用于未压缩数据

`f_zip` SHALL 使用 `fountain::f_util.crc32(data: Array<Byte>): UInt32` 计算 CRC32，SHALL NOT 自行实现 CRC 表；CRC SHALL 对**原始未压缩**数据计算，写入顺序 MUST 为"先算 CRC，再压缩"。

#### Scenario: CRC 与已知向量一致

- **WHEN** 对字节 `"123456789"` 计算写入侧 CRC
- **THEN** 结果等于 `0xCBF43926`

#### Scenario: 压缩数据不会被当作 CRC 输入

- **WHEN** 写入一条 Deflate 条目后从中央目录读回 crc
- **THEN** 该值等于对原始数据调用 `f_util.crc32` 的结果，而非对压缩数据计算的结果
