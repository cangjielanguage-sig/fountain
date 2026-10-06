# 编解码器

`fountain::f_codec` 是 fountain 的编解码模块：`Codec = Encoder & Decoder`，用**一个 head 字节**同时表达
「数据类型」与「长度信息」，把 `fountain::f_data` 的 `Data` 家族与 std 基础类型编成字节流。
接口在 `fountain::f_codec`，默认实现在 `fountain::f_codec.default`。

## 接口

```cj
public interface Encoder {
    func encode(data: Data): Encoder
    func encode(data: DataAny): Encoder
    func encode<T>(data: T): Encoder where T <: DataFields<T>
    func encodeNone(): Encoder
    func encode(value: Bool): Encoder
    func encode(value: String): Encoder
    func encode(value: Int8): Encoder        // … Int16/Int32/Int64/UInt8…UInt64 同理
    func encode(value: Float16): Encoder     // … Float32/Float64 同理
    func encode(value: BigInt): Encoder
    func encode(value: Decimal): Encoder
    func encode(value: Duration): Encoder
    func encode(value: DateTime): Encoder
    func encode(value: Array<Byte>): Encoder
    func encode(value: ArrayList<Byte>): Encoder
    func encode(data: InputStream, size: Int64): Encoder
    func encode(data: File): Encoder
    func finish(): BytesCopyTo
}

public interface Decoder {
    /** T 是期望的载荷类型（FromToData；DataFields<T> 是它的子接口） */
    func decode<T>(input: InputStream): ?T where T <: FromToData
}

/**
 * 知道「本帧还剩多少字节」的输入流。实现它，解码器就能在**按线上声明长度分配缓冲之前**挡下超大长度：
 * 帧头的 len 只限住可读字节数，限不住 `Array<Byte>(声明长度)` 这一步，载荷里一个损坏的长度字段
 * 就能让解码器尝试 TB 级分配。实现方：f_protocol 的帧体流。
 */
public interface SizeBoundedInput <: InputStream {
    /** 本帧剩余可读字节数（不得为负） */
    prop remainingBytes: Int64
}

public interface Codec <: Encoder & Decoder {}
```

## 数据类型

head 字节：**高 4 位 = `DataType` 序号**，低 4 位 = 长度信息（含义按类型不同，见下）。

```cj
public enum DataType <: ToString {
    | NONE      //  0 | 字符串 STRING      //  1 | Bool BOOL         //  2 | 整数 INT      //  3
    | FLOAT     //  4 | BigInt BIGINT      //  5 | Decimal DECIMAL1  //  6 | Decimal DECIMAL2  // 7
    | DURATION1 //  8 | DURATION2          //  9 | DATETIME1         // 10 | DATETIME2         // 11
    | COLLECTION// 12 | MAP               // 13 | OBJECT            // 14 | INPUTSTREAM       // 15
    public func toString(): String
    public prop value: UInt8
    public prop lowValue: UInt8
    public static func convert(byte: Byte): DataType   // 未知字节抛 CodecException
}
```

### head 低 4 位的两套含义（最容易踩的点）

| 类型 | 低 4 位含义 |
| --- | --- |
| `INT` / `FLOAT` / `INPUTSTREAM` / `BIGINT` / `DECIMAL*` / `DURATION*` / `DATETIME*` | 长度**字节数**（1..7）；**0 表示 8 字节**（数值路径的 `0 ⇒ 8` 约定） |
| `STRING` / `COLLECTION` / `MAP` | 长度字节数，编码侧恒写 8（不写 0）；**0 表示「空值、后面不跟长度字节」** |

因此**空值有专门的紧凑编码**，解码侧必须按类型分开处理：

- 空字符串：只写 head（低半字节 0，不写长度字节）⇒ 解码 `ss == 0` ⇒ `''`；
- 空集合 / 空映射：只写 `COLLECTION.value` / `MAP.value` 一个字节 ⇒ 解码 `s == 0` ⇒ 空 `DataList()` / `DataTuples()`；
  （编码侧的空值短路在 `encode()` 的 `x.isEmpty()` 分支；漏了这条解码分支就会去读长度字节，
  在 `parseInt64` 里索引长度为 0 的数组越界 —— 见 `.autocode/bugs/bug-archived-20261004-2.md` 第 1 部分。）
- `FLOAT` 编码禁止 NaN/±Inf，抛 `CodecException`。

## 默认实现

```cj
public class DefaultCodec <: Codec & Releasable {
    /** 按配置重建「编码缓冲池」（超时取不到池项就抛，由调用方记录可见失败） */
    public static func setBufferPool(initSize!: Int64 = 1024, minSize!: Int64 = 1024, maxSize!: Int64 = 1024,
        maxWaiting!: Duration = Duration.second * 30): Unit
    /** 按配置重建「字节数组池」；同时把 fileThreshold 设为 arraySize */
    public static func setBytesPool(initSize!: Int64 = 0, minSize!: Int64 = 1, maxSize!: Int64 = 1024,
        arraySize!: Int64 = 4096, maxWaiting!: Duration = Duration.second * 30): Unit
    public static func setBytesPool(output: BytesListOutputStreamBuilder): Unit

    /** 登记对象类型（键 = murmurHash(限定名)）：跨模块解码对象类型前必须登记 */
    public static func registerType<T>(): UInt128 where T <: Object & ObjectData<T> & DataFields<T>
    /** 同上，但不要求调用方静态满足 T 的约束（宏展开处自动登记走这条） */
    public static func registerType(qualifiedName: String, creator: () -> SimpleDataObject): Unit

    /** 中性解码：按 head 自带的类型解出 Data（RPC / f_net 的读取循环用） */
    public func decodeData(input: InputStream): Data
    /** 幂等：归还编码期间借出的池项。只解码、不写出也必须调用 */
    public func release(): Unit
}
```

行为要点：

- **类型登记**：解码遇到未登记的对象类型时，会自动从 `f_data` 的 `DataTypeRegistry`（`@DataAssist` 自登记）补表；
  仍未命中则抛 `CodecException`。`@RPCStub` / `@RPCSkeleton` 展开时会自动登记接口的参数/返回类型，业务代码通常不用手写；
- **大载荷落盘**：payload 超过 `fileThreshold`（默认 4096，随 `setBytesPool(arraySize:)` 变化）时写入
  `/tmp/tmpFile<UUID>` 并携带文件名，避免大对象全量驻留内存；
- **池**：编码缓冲池与字节数组池默认在包初始化时建好，`f_rpc` 会在首次 `start()` 时按 `rpc_codec*` 配置重建（见 f_rpc README）；
- `parseInt64(head, sign, bytes)` 是内部实现，第 2 个参数是**符号位标记**（不是浮点标记，FLOAT 不走它）。

## 用法

```cj
import fountain::f_codec.*
import fountain::f_codec.default.*
import fountain::f_data.*

let codec = DefaultCodec()
// 编码：类型化 API 与 Data 家族可以混用，按调用顺序写成一帧
let bytes = codec
    .encode(Int64(42))
    .encode('hello world')
    .encode(DataList())          // 空集合：只写一个 COLLECTION head 字节
    .finish()                    // BytesCopyTo（也是 Releasable：写完后同样要 release）
codec.release()                  // 归还编码期间借出的池项（幂等）

// 解码：按编码顺序读回；input 除 InputStream 外最好还实现 SizeBoundedInput（见上）
let input = /* InputStream */
let a: ?Int64 = codec.decode<Int64>(input)
let b: ?String = codec.decode<String>(input)
let c = codec.decodeData(input)  // 中性解码：拿到 Data，由调用方自行转换
codec.release()
```

可运行的完整例子见 `src/default/DefaultCodec_test.cj`（含空集合/空映射往返、对象类型登记、池与 release 用例）。

## 相关文档

原 `doc/` 下的旧版摘录（数据类型 / 默认实现 / 用法）已删除，本 README 是唯一出处：

- 类型号与 head 布局的权威定义在源码注释里（`src/Codec.cj`、`src/default/DataType.cj`）；
- 可运行的完整用例见 `src/default/DefaultCodec_test.cj`（含空集合/空映射往返、对象类型登记、池与 release）。
