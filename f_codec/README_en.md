# Codec

`fountain::f_codec` is the codec module of fountain: `Codec = Encoder & Decoder`, using **a single head byte** to express
both "data type" and "length information", encoding the `Data` family of `fountain::f_data` and std basic types into byte streams.
The interfaces live in `fountain::f_codec`, and the default implementation in `fountain::f_codec.default`.

## Interfaces

```cj
public interface Encoder {
    func encode(data: Data): Encoder
    func encode(data: DataAny): Encoder
    func encode<T>(data: T): Encoder where T <: DataFields<T>
    func encodeNone(): Encoder
    func encode(value: Bool): Encoder
    func encode(value: String): Encoder
    func encode(value: Int8): Encoder        // … Int16/Int32/Int64/UInt8…UInt64 likewise
    func encode(value: Float16): Encoder     // … Float32/Float64 likewise
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
    /** T is the expected payload type (FromToData; DataFields<T> is a sub-interface of it) */
    func decode<T>(input: InputStream): ?T where T <: FromToData
}

/**
 * An input stream that knows "how many bytes are left in this frame". By implementing it, a decoder can reject
 * oversized lengths **before allocating buffers according to the length declared on the wire**: the len in the frame
 * header only bounds the readable bytes, not the step `Array<Byte>(declared length)`, so a single corrupted length
 * field in the payload could make the decoder attempt a terabyte-scale allocation. Implemented by: the frame body
 * stream of f_protocol.
 */
public interface SizeBoundedInput <: InputStream {
    /** Number of readable bytes remaining in this frame (must not be negative) */
    prop remainingBytes: Int64
}

public interface Codec <: Encoder & Decoder {}
```

## Data types

head byte: **the high 4 bits are the `DataType` ordinal**, the low 4 bits hold length information (the meaning depends on the type, see below).

```cj
public enum DataType <: ToString {
    | NONE      //  0 | String STRING      //  1 | Bool BOOL         //  2 | integer INT      //  3
    | FLOAT     //  4 | BigInt BIGINT      //  5 | Decimal DECIMAL1  //  6 | Decimal DECIMAL2  // 7
    | DURATION1 //  8 | DURATION2          //  9 | DATETIME1         // 10 | DATETIME2         // 11
    | COLLECTION// 12 | MAP               // 13 | OBJECT            // 14 | INPUTSTREAM       // 15
    public func toString(): String
    public prop value: UInt8
    public prop lowValue: UInt8
    public static func convert(byte: Byte): DataType   // An unknown byte throws CodecException
}
```

### The two meanings of the low 4 bits of head (the easiest place to trip)

| Type | Meaning of the low 4 bits |
| --- | --- |
| `INT` / `FLOAT` / `INPUTSTREAM` / `BIGINT` / `DECIMAL*` / `DURATION*` / `DATETIME*` | Length in **bytes** (1..7); **0 means 8 bytes** (the `0 ⇒ 8` convention on the numeric path) |
| `STRING` / `COLLECTION` / `MAP` | Length in bytes; the encoder side always writes 8 (never 0); **0 means "empty value, no length byte follows"** |

Therefore **empty values have their own compact encoding**, and the decoder side must handle them separately per type:

- Empty string: only the head is written (low nibble 0, no length byte) ⇒ decoding sees `ss == 0` ⇒ `''`;
- Empty collection / empty map: only one byte `COLLECTION.value` / `MAP.value` is written ⇒ decoding sees `s == 0` ⇒ an empty `DataList()` / `DataTuples()`;
  (the empty-value shortcut on the encoder side is in the `x.isEmpty()` branch of `encode()`; missing this decoder branch
  makes it read a length byte and then index out of bounds inside `parseInt64` on a zero-length array —— see
  part 1 of `.autocode/bugs/bug-archived-20261004-2.md`.)
- `FLOAT` encoding forbids NaN/±Inf and throws `CodecException`.

## Default implementation

```cj
public class DefaultCodec <: Codec & Releasable {
    /** Rebuild the "encoding buffer pool" from the configuration (throws if a pool item cannot be obtained before the timeout; the caller records the visible failure) */
    public static func setBufferPool(initSize!: Int64 = 1024, minSize!: Int64 = 1024, maxSize!: Int64 = 1024,
        maxWaiting!: Duration = Duration.second * 30): Unit
    /** Rebuild the "byte array pool" from the configuration; also sets fileThreshold to arraySize */
    public static func setBytesPool(initSize!: Int64 = 0, minSize!: Int64 = 1, maxSize!: Int64 = 1024,
        arraySize!: Int64 = 4096, maxWaiting!: Duration = Duration.second * 30): Unit
    public static func setBytesPool(output: BytesListOutputStreamBuilder): Unit

    /** Register an object type (key = murmurHash(qualified name)): object types must be registered before they can be decoded across modules */
    public static func registerType<T>(): UInt128 where T <: Object & ObjectData<T> & DataFields<T>
    /** Same as above, but does not require the caller to satisfy the constraints of T statically (used automatically at macro expansion sites to register) */
    public static func registerType(qualifiedName: String, creator: () -> SimpleDataObject): Unit

    /** Neutral decoding: decode Data according to the type carried in head (used by the read loops of RPC / f_net) */
    public func decodeData(input: InputStream): Data
    /** Idempotent: return the pool items borrowed during encoding. Must be called even when only decoding, without writing out */
    public func release(): Unit
}
```

Behavior highlights:

- **Type registration**: when decoding meets an unregistered object type, it automatically fills the table from the `DataTypeRegistry` of `f_data` (`@DataAssist` self-registration);
  if it still misses, `CodecException` is thrown. When `@RPCStub` / `@RPCSkeleton` expand, they automatically register the parameter/return types of the interface, so business code usually does not write this by hand;
- **Large payloads spilled to disk**: when a payload exceeds `fileThreshold` (4096 by default, following `setBytesPool(arraySize:)`), it is written to
  `/tmp/tmpFile<UUID>` and the file name is carried along, so that large objects do not stay fully in memory;
- **Pools**: the encoding buffer pool and the byte array pool are created at package initialization by default, and `f_rpc` rebuilds them from the `rpc_codec*` configuration at the first `start()` (see the f_rpc README);
- `parseInt64(head, sign, bytes)` is an internal implementation detail; its second argument is the **sign flag** (not a float flag; FLOAT does not go through it).

## Usage

```cj
import fountain::f_codec.*
import fountain::f_codec.default.*
import fountain::f_data.*

let codec = DefaultCodec()
// Encoding: the typed API and the Data family can be mixed and are written into one frame in call order
let bytes = codec
    .encode(Int64(42))
    .encode('hello world')
    .encode(DataList())          // Empty collection: writes a single COLLECTION head byte
    .finish()                    // BytesCopyTo (it is also Releasable: release is needed after writing too)
codec.release()                  // Return the pool items borrowed during encoding (idempotent)

// Decoding: read back in encoding order; besides InputStream, input should preferably also implement SizeBoundedInput (see above)
let input = /* InputStream */
let a: ?Int64 = codec.decode<Int64>(input)
let b: ?String = codec.decode<String>(input)
let c = codec.decodeData(input)  // Neutral decoding: get Data and let the caller convert it
codec.release()
```

A complete runnable example is in `src/default/DefaultCodec_test.cj` (covering empty collection/empty map round trips, object type registration, and pool and release cases).

## Related documents

The old excerpts formerly under `doc/` (data types / default implementation / usage) have been removed; this README is the only source:

- The authoritative definition of the type numbers and the head layout is in the source comments (`src/Codec.cj`, `src/default/DataType.cj`);
- For complete runnable cases see `src/default/DefaultCodec_test.cj` (covering empty collection/empty map round trips, object type registration, and pool and release).
