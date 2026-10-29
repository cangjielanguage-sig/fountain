# f_zip

ZIP 容器读写模块：**容器层（local header / 中央目录 / EOCD / ZIP64 / CRC 编排）完全自主实现**，
deflate 数据流复用 `stdx.compress.zlib`（`WrapType.DeflateFormat`）。
不引入任何第三方 ZIP 库、不引 FFI、不做 native 链接。

## STDX 依赖

配置环境变量：`export CANGJIE_STDX_DYNAMIC_PATH=/path/to/dynamic_stdx`

## 依赖

```
f_zip
├── stdx.compress.zlib   DecompressInputStream / CompressOutputStream
├── f_util               crc32(data: Array<Byte>): UInt32
├── f_base               BaseException（ZipException 的基类）
├── f_io                 ByteBuffer（流模式的随机访问缓冲）
├── f_log                LoggerFactory（落盘 debug 日志 / 压缩比告警 / 符号链接跳过）
├── charset4cj           GBK 解码（文件名回退链）
└── std.fs / std.io / std.time / std.sync
```

## 能力清单

- **读取**：`ZipReader(input)` 全量缓冲、`ZipReader(path)` 走 `File.seek` 窗口读（1 GB 的包 RSS 不随文件线性增长）；
  条目枚举、按名读取（同名取最后一个）、`readAll`、`open` 流式解压（每次独立游标，可并发）。
- **写入**：`add`（内存路径，header 写真实值、无 descriptor）、`addFileStream`（流式路径，
  24 字节 ZIP64 data descriptor）、`addFile`、`addDirectory`。
- **ZIP64 双向**：读取识别 EOCD64 / 定位器 / extra `0x0001`；写入仅在越界时升级，小文件不产生任何 ZIP64 字节。
- **安全默认开**：Zip Slip 拦截、符号链接跳过、ZIP 炸弹上限、加密 ZIP 拒绝。
- **大文件不吃内存**：`add()` 超阈值自动落临时文件后走流式；`zip` / `unzip` 全程流式。

## 快速开始

```cangjie
import fountain::f_zip.*

// 打包目录（每个文件走流式路径）
let out = File("export.zip", OpenMode.Write)
let count = zip(out, Path("/data/reports"))
out.close()
println("${count} 个文件")

// 解压（默认上限：单条 512 MB / 累计 2 GB / 65535 条）
let files = unzip("/data/export.zip", Path("/tmp/unpacked"))
println("${files} 个文件")

// 按名取一条
let reader = ZipReader("/data/export.zip")
if (let Some(bytes) <- reader.read("a.txt")) {
    println(String.fromUtf8(bytes))
}
reader.close()

// 流式写入（长度未知也安全）
let buffer = ByteBuffer()
let writer = ZipWriter(buffer)
writer.add("config.json", "{ }".toArray())
writer.addFileStream("huge.log", File("/var/log/app.log", OpenMode.Read))
writer.close()
```

## 安全默认值

| 风险 | 默认行为 |
| --- | --- |
| Zip Slip | 绝对路径 / `..` 段 / 规范化后在目标目录外 → 拒绝，且不创建任何中间目录 |
| 符号链接 | `unzip` / `zip` 跳过并记 warning；`addFile` 跟随（调用方显式指定单个文件） |
| ZIP 炸弹 | `ZipLimits` 四道上限，按**实际解压字节**累计，超限中断且不留半截文件 |
| 加密 ZIP | bit 0 / bit 6 置位即报错，不做部分支持 |

## 文档

- `doc/f_zip模块设计.md` —— 设计稿（21 条决策表、字节布局、实施顺序）
- `doc/api.md` —— 九个公开名字的速查与约束（每实例限额、非线程安全、`spilling` 语义）
- `doc/兼容性例外.md` —— 与 APPNOTE 不一致的真实样本登记表（初始为空）
