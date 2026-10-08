# f_util


## STDX dependency

Configure the environment variable: `export CANGJIE_STDX_DYNAMIC_PATH=/path/to/dynamic_stdx`

## CaseFormat conversion
Converts between the six styles PascalCase, camelCase, lower_case_with_underscores, UPPER_CASE_WITH_UNDERSCORES, lower-case-with-hyphens and UPPER-CASE-WITH-HYPHENS
```cj
@Assert(CaseFormat.Pascal.convert("CaseFormat", to: CaseFormat.Camel), "caseFormat")
@Assert(CaseFormat.Pascal.convert("CaseFormat", to: CaseFormat.LowerUnderScore), "case_format")
@Assert(CaseFormat.Pascal.convert("CaseFormat", to: CaseFormat.UpperUnderScore), "CASE_FORMAT")
@Assert(CaseFormat.Pascal.convert("CaseFormat", to: CaseFormat.LowerHyphen), "case-format")
@Assert(CaseFormat.Pascal.convert("CaseFormat", to: CaseFormat.UpperHyphen), "CASE-FORMAT")

@Assert(CaseFormat.Camel.convert("caseFormat", to: CaseFormat.Pascal), "CaseFormat")
@Assert(CaseFormat.Camel.convert("caseFormat", to: CaseFormat.LowerUnderScore), "case_format")
@Assert(CaseFormat.Camel.convert("caseFormat", to: CaseFormat.UpperUnderScore), "CASE_FORMAT")
@Assert(CaseFormat.Camel.convert("caseFormat", to: CaseFormat.LowerHyphen), "case-format")
@Assert(CaseFormat.Camel.convert("caseFormat", to: CaseFormat.UpperHyphen), "CASE-FORMAT")

@Assert(CaseFormat.LowerUnderScore.convert("case_format", to: CaseFormat.Camel), "caseFormat")
@Assert(CaseFormat.LowerUnderScore.convert("case_format", to: CaseFormat.Pascal), "CaseFormat")
@Assert(CaseFormat.LowerUnderScore.convert("case_format", to: CaseFormat.UpperUnderScore), "CASE_FORMAT")
@Assert(CaseFormat.LowerUnderScore.convert("case_format", to: CaseFormat.LowerHyphen), "case-format")
@Assert(CaseFormat.LowerUnderScore.convert("case_format", to: CaseFormat.UpperHyphen), "CASE-FORMAT")

@Assert(CaseFormat.UpperUnderScore.convert("CASE_FORMAT", to: CaseFormat.Camel), "caseFormat")
@Assert(CaseFormat.UpperUnderScore.convert("CASE_FORMAT", to: CaseFormat.Pascal), "CaseFormat")
@Assert(CaseFormat.UpperUnderScore.convert("CASE_FORMAT", to: CaseFormat.LowerUnderScore), "case_format")
@Assert(CaseFormat.UpperUnderScore.convert("CASE_FORMAT", to: CaseFormat.LowerHyphen), "case-format")
@Assert(CaseFormat.UpperUnderScore.convert("CASE_FORMAT", to: CaseFormat.UpperHyphen), "CASE-FORMAT")

@Assert(CaseFormat.LowerHyphen.convert("case-format", to: CaseFormat.Camel), "caseFormat")
@Assert(CaseFormat.LowerHyphen.convert("case-format", to: CaseFormat.Pascal), "CaseFormat")
@Assert(CaseFormat.LowerHyphen.convert("case-format", to: CaseFormat.LowerUnderScore), "case_format")
@Assert(CaseFormat.LowerHyphen.convert("case-format", to: CaseFormat.UpperUnderScore), "CASE_FORMAT")
@Assert(CaseFormat.LowerHyphen.convert("case-format", to: CaseFormat.UpperHyphen), "CASE-FORMAT")

@Assert(CaseFormat.UpperHyphen.convert("CASE-FORMAT", to: CaseFormat.Camel), "caseFormat")
@Assert(CaseFormat.UpperHyphen.convert("CASE-FORMAT", to: CaseFormat.Pascal), "CaseFormat")
@Assert(CaseFormat.UpperHyphen.convert("CASE-FORMAT", to: CaseFormat.LowerUnderScore), "case_format")
@Assert(CaseFormat.UpperHyphen.convert("CASE-FORMAT", to: CaseFormat.UpperUnderScore), "CASE_FORMAT")
@Assert(CaseFormat.UpperHyphen.convert("CASE-FORMAT", to: CaseFormat.LowerHyphen), "case-format")
```

## crc16
```cj
@Frozen
public func crc16(bytes: Array<Byte>): UInt16 
@Frozen
public func crc16(s: String): UInt16 
@Frozen
public func crc16<T>(s: T): UInt16 where T <: ToString 
```

## crc32
```cj
// 2.4 Core computation function: compute the CRC32 value of a byte array
// Parameter data: the byte array whose checksum must be computed
// Return value: the computed 32-bit CRC checksum (of type UInt32)
@Frozen
public func crc32(data: Array<Byte>): UInt32 
@Frozen
public func crc32(data: String): UInt32 
@Frozen
public func crc32<T>(s: T): UInt16 where T <: ToString 
```

## crc64
```cj

// --- 4. Core computation function ---
// Purpose: compute the CRC64 value of a byte array
// Parameter data: the byte array whose checksum must be computed
// Return value: the computed 64-bit CRC checksum
@Frozen
public func crc64(data: Array<Byte>): UInt64 
@Frozen
public func crc64(data: String): UInt64 
@Frozen
public func crc64<T>(s: T): UInt16 where T <: ToString 
```

## wyhash

```cj
@Frozen
public func wyrand(seed: Int64): UInt64 
@Frozen
@OverflowWrapping
public func wyrand(seed: UInt64): UInt64 
@Frozen
public func wyhash(s: String, start!: Int64 = 0, size!: Int64 = s.size, see!: UInt64 = 0): UInt64 
@Frozen
public func wyhash<T>(s: T, start!: Int64 = 0, see!: UInt64 = 0): UInt64 where T <: ToString 
@Frozen
@OverflowWrapping
public func wyhash(arr: Array<UInt8>, start!: Int64 = 0, size!: Int64 = arr.size, see!: UInt64 = 0): UInt64
```

## cityhash

```cj
@Frozen
public func cityHash(data: String): UInt128 
@Frozen
public func cityHash<T>(data: T): UInt128 where T <: ToString 
@Frozen
public func cityHash(data: Array<UInt8>): UInt128
```

## UInt128

```cj
//No arithmetic is provided, only conversions between string <-> UInt128 and Array<Byte> <-> UInt128, plus comparisons of UInt128
public struct UInt128 <: ToString & Hashable & Comparable<UInt128> & DataParsable<UInt128> & Parsable<UInt128> {
    UInt128(
        public let left: UInt64,
        public let right: UInt64
    ) {}
    public func toString(): String 
    public static func tryParse(s: String): ?UInt128 
    public static func parse(s: String): UInt128 
    public func hashCode(): Int64 
    public func compare(other: UInt128): Ordering 
    public func toBytes(): Array<Byte> 
    public static func fromBytes(bytes: Array<Byte>): UInt128 
}
```

## Factory pattern
```cj
public interface Producer<A, O> {
    /**Create an instance of type O; the default implementation throws IllegalAccessException*/
    func produce(): O 
    /**Create an instance of type O with the argument A; the default implementation throws IllegalAccessException*/
    func produce(arg: A): O 
}
/**
 * Object factory
 * The assemble function registers object-producing instances
 * The produce function manufactures objects of the given type using the registered producing instances
 */
public class Factory<A, O> {
    public func assemble<T>(producer: Producer<A, O>): Unit
    public func assemble<T>(producers: Iterable<Producer<A, O>>): Unit
    public func produce<T>(): T
    public func produce<T>(arg: A): T
}
```

### Mediator pattern
```cj
//Strategy definition interface
public interface Colleague<N, A, R> where A <: ColleagueArgument<N>, N <: Hashable & Equatable<N> {
    prop name: N//Strategy name
    func execute(arg: A): R//Strategy function
}
public interface ColleagueArgument<N> where N <: Hashable & Equatable<N> {
    prop name: N
}
public class Mediator<N, C, A, R> where C <: Colleague<N, A, R>, A <: ColleagueArgument<N>, N <: Hashable & Equatable<N> {
    /**Register a strategy*/
    public func register(colleague: Colleague<N, A, R>): Unit
    /**Look up a strategy by the argument and execute it*/
    public func execute(arg: A): R 
}
```

### Chain of responsibility pattern
```cj
/*
 * The interface of the chain of responsibility pattern; every responsibility strategy must implement this interface
 * S is the concrete implementation of the strategy; N and S must correspond one to one
 * C is the condition argument for executing the strategy; strategies satisfying the condition are executed
 * A is the argument with which the strategy is executed
 * R is the result of executing the strategy
 */
public interface Responsibility<C, A, R> {
    /**
     * Check whether the given condition satisfies the requirement for executing the current strategy
     */
    func check(condition: C): Bool

    /**
     * Execute the current strategy
     */
    func execute(arg: A): R
}
/**
 * Responsibility strategy
 */
public interface ValidationResponsibility<C, A> <: Responsibility<C, A, Unit> {
    func execute(arg: A): Unit {}
}
/**
 * Chain of responsibility
 */ 
public class ResponsibilityChain<C, A, R> {
    public init() {}
    public init(resposibilities: Iterable<Responsibility<C, A, R>>)
    /**
     * Register one strategy
     */
    public func register(resposibility: Responsibility<C, A, R>): ResponsibilityChain<C, A, R>
    /**
     * Register a batch of strategies
     */
    public func register<S>(resposibilities: Iterable<S>): Unit where S <: Responsibility<C, A, R>
    /**  
     * Execute one strategy: traverse the set of strategies until a strategy whose Responsibility.check(condition)
     * returns true is found, and execute that strategy.
     * When no strategy satisfies the condition, IllegalAccessException is thrown
     */
    public func execute(condition: C, arg: A): R
    /**
     * Execute all strategies that satisfy the condition
     */
    public func executeAll(condition: C, arg: A): Unit 
}
```

### State pattern
```cj
/**
 * State pattern
 */
public interface State<D> {
    /**
     * Whether there is a following state
     */
    prop continues: Bool{
        get(){
            true
        }
    }
    /**
     * Execute the current state
     */
    func exec<S>(): S where S <: State<D>
    /**
     * The data of the current state
     */
    prop data: D
    /**
     * Execute the states
     */
    func startup<D>(): D
}
```

### Strategy pattern
```cj
/**
 * The interface of the strategy pattern; every strategy must implement this interface
 * N is the identifier of the strategy; N is used to find the corresponding strategy,
 * S is the concrete implementation of the strategy; N and S must correspond one to one
 * A is the argument with which the strategy is executed
 * R is the result of executing the strategy
 */
public interface Strategy<N, A, R> where N <: Hashable & Equatable<N> {
    /**
     * Return the strategy identifier
     */
    prop name: N

    /**
     * Execute the strategy
     */
    func execute(arg: A): R
}

/**A collection of strategies*/
public class Strategies<N, A, R> where N <: Hashable & Equatable<N> {
    public init() {}

    /** Register the given strategy*/
    public func register(strategy: Strategy<N, A, R>): Strategies<N, A, R> 
    public func register<S>(strategies: Iterable<S>): Unit where S <: Strategy<N, A, R> 

    /**
     * Execute a strategy with the given identifier and argument; when no strategy named name is found
     * base.IllegalAccessException is thrown
     */
    public func execute(name: N, arg: A): R 
}

```


## geohash

```cj
public struct GeoHash <: Hashable & Equatable<GeoHash> & ToString & Parsable<GeoHash> & DataParsable<GeoHash> {
    /**Initialize a geohash*/
    public static func encode(latitude: Float64, longitude: Float64): GeoHash
    /**
     * GeoHash.encode(coordinate[0], coordinate[1])
     */
    public static func encode(coordinate: (Float64, Float64)): GeoHash
    /**Compute the longitude and latitude back from a geohash; the returned tuple is (longitude, latitude)*/
    public func decode(): (Float64, Float64)
    public operator func ==(other: GeoHash): Bool
    public func hashCode(): Int64
    /**Convert the geohash into base 4*/
    public func toString(): String 
    /**Convert a base 4 string into a GeoHash*/
    public static func tryParse(hash: String): Option<GeoHash>
    /**Convert a base 4 string into a GeoHash*/
    public static func parse(hash: String): GeoHash
}
```


## IdMaker

```cj
public class IdMaker {
    /**
     * hostSerial Host serial number
     */
    public IdMaker(private let hostSerial!: Int64)
    /**
     * Take the host serial from the configuration item idMakerHostSerial
     */
    public init()
    /**
     * Get the next ID
     */
    public func nextInt64(): Int64
}
```


## @IsUUID

The IsUUID annotation is a subclass of `fountain::f_data.validation`.
The validated data must be a UUID


## murmur hash

```cj
@Frozen
@OverflowWrapping
public func murmurHash(data: Array<Byte>, seed!: UInt64 = 0): UInt128 

// Convenience function: hash a string directly (static method)
@Frozen
public func murmurHash(text: String, seed!: UInt64 = 0): UInt128 
@Frozen
public func murmurHash<T>(text: T, seed!: UInt64 = 0): UInt128 where T <: ToString 
// 64-bit circular left shift (private static helper function)
@Frozen
@OverflowWrapping
private func rotl64(x: UInt64, r: Int): UInt64 
```

## Path matching

```cj
let patterns = PathPattern<Object>()
patterns.compileIfAbsent(path){Object()}//Register path with PathPattern, and add the object corresponding to the path
patterns.extractVariableInPath(path, name)//Find the path variable named name in path and return the corresponding path variable value in path
patterns.data<Object>(path)//Find the object corresponding to the path from PathPattern
```


## isPrime

```cj
/**
 * Determine whether a number is prime
 * @param p
 * @return
 */
public func isPrime(p: UInt64): Bool
```


## Text template

```cj
/**
 * A simple text template
 * This class depends on ThreadLocalStringBuilder; if a method of this class also uses ThreadLocalStringBuilder, do not
 * call methods of this class while building a string inside that method.
 * If the return value of an object of this class is part of a constructed string, call this class first, and only then
 * obtain the StringBuilder object with ThreadLocalStringBuilder inside the method that uses this class.
 * A placeholder-style text template: the text between prefix and suffix is a property of the data object or a key of the map,
 * a placeholder beginning with "regex:" means it is a regular expression, and a template containing a regular expression
 * only accepts a map as its data source, replacing the regular expression placeholder with the value corresponding to the
 * first key in the map matching that regular expression; the regular expression is enclosed in `
 * A placeholder containing "time:`FORMAT`" means FORMAT is replaced by a date format template in actual use; the
 * placeholder name is separated by a space before time:, or by a space after `FORMAT`
 * <p>
 * A placeholder containing "number:`##.##,HALF_UP`" means `##.##,HALF_UP`
 * is replaced by a number format template in actual use; the placeholder name is separated by a space before number:,
 * or by a space after `##.##,HALF_UP`; the number of # in the format template gives the number of digits and . gives the
 * position of the decimal point; HALF_UP is the default rounding rule and is optional
 * A number format may start with any one of the symbols o O x X e E + (, and these markers must not appear at the same time
 * o O means conversion to octal and x X means conversion to hexadecimal; the decimal precision is automatically set to 0 before conversion
 * e E means conversion to scientific notation
 * + means positive numbers need a leading +, ( means negative numbers need the - removed and the digit string enclosed in ()
 * <p>
 * A placeholder may be a string split by . and a placeholder split by . accepts an array, list, po or map as its argument;
 * a.0.b.c means property a of the argument is an array or list, its index 0 has a property b (a key if it is a map), and
 * property b has a property c whose value is the content to be formatted
 * Because ` has a special meaning in modes such as number: and regex: and time:
 */
public class TextTemplate {
    /**
     * Compile template into a TextTemplate; the string enclosed in a pair of # inside the template is a template variable
     */
    public static func compile(template: String, placeholder!: String = "#"): TextTemplate 
    /**
     * Compile template into a TextTemplate; the string enclosed by prefix and suffix is a template variable
     */
    public static func compile(template: String, prefix!: String = #"${"#, suffix!: String = "}"): TextTemplate
    /**
     * format replaces the template variables of the string template with the elements of data, using noneConverter when
     * the corresponding template variable does not exist
     */
    public func format<T>(data: Array<T>, noneConverter!: ?String = None<String>): String where T <: ToString 
    /**
     * format replaces the template variables of the string template with the elements of data, using noneConverter when
     * the corresponding template variable does not exist
     */
    public func format<T>(data: ArrayList<T>, noneConverter!: ?String = None<String>): String where T <: ToString 
    /**
     * format replaces the template variables of the string template with the elements of data, using noneConverter when
     * the corresponding template variable does not exist
     */
    public func format<V>(data: ConcurrentHashMap<String, V>, noneConverter!: ?String = None<String>): String where V <: ToString 
    /**
     * format replaces the template variables of the string template with the elements of data, using noneConverter when
     * the corresponding template variable does not exist
     */
    public func format<V>(data: HashMap<String, V>, noneConverter!: ?String = None<String>): String where V <: ToString 
    /**
     * format replaces the template variables of the string template with the elements of data, using noneConverter when
     * the corresponding template variable does not exist
     */
    public func format<V>(data: TreeMap<String, V>, noneConverter!: ?String = None<String>): String where V <: ToString 
    /**
     * format replaces the template variables of the string template with the elements of data, using noneConverter when
     * the corresponding template variable does not exist
     */
    public func format<V>(data: LinkedHashMap<String, V>, noneConverter!: ?String = None<String>): String where V <: ToString 
    /**
     * format replaces the template variables of the string template with the elements of data, using noneConverter when
     * the corresponding template variable does not exist
     */
    public func format<T>(data: T, noneConverter!: ?String = None<String>): String where T <: Object & ObjectData<T> 
}
```


## UUID

```cj
/**
 * reference https://www.ietf.org/archive/id/draft-ietf-uuidrev-rfc4122bis-00.html
 * Implements UUIDs of the various versions
 */
public struct UUID <: Hashable & Comparable<UUID> & ToString & Parsable<UUID> & DataParsable<UUID> & DataFields<UUID> {
    /**
     * Convert the UUID into a Data instance
     */
    public func toData(): Data 
    /**
     * Convert Data into a UUID
     */
    public static func tryFromData(data: Data, flag: DataConversionFlag): Any
    public func hashCode(): Int64
    public operator func ==(other: UUID): Bool 
    public operator func !=(other: UUID): Bool 
    public func compare(other: UUID): Ordering
    /**
     * The nil UUID
     */
    public static let Nil = UUID()
    /**
     * The largest UUID
     */
    public static let Max = UUID(values: Array<Byte>(16, repeat: 0xff))
    public func toString(): String
    /**
     * Convert the UUID into a string in the given radix
     */
    public func toString(radix: Int64)
    /**
     * Convert the UUID into a hexadecimal string
     */
    public func toHexString(): String
    /**
     * UUID version
     */
    public prop version: Int64
    /**
     * UUID timestamp
     */
    public prop timestampNanos: Int64
    /**
     * UUID timestamp
     */
    public prop timestamp: DateTime
    public prop variant: Int64
    public static func parse(uuid: String): UUID
    public static func tryParse(uuid: String): ?UUID
    /**
     * A timestamp-based UUID, compatible with UUID version 1, 2 and 6
     */
    public static func timeBased(timeLowFirst!: Bool = false): TimeBasedUUIDBuilder
    /**
     * version 3
     */
    public static func md5(value: String): UUID
    /**
     * Create an md5-based UUID from a random byte array 
     */
    public static func randomMd5(bytes!: Int64 = 16): UUID
    /**
     * Create an md5-based UUID from the given byte array 
     */
    public static func md5(value: Array<Byte>): UUID
    /**
     * version 4
     */
    public static func random(): UUID
    /**
     * version 5
     */
    public static func sha1(value: String): UUID
    /**
     * Create a sha1-based UUID from a random byte array 
     */
    public static func randomSha1(bytes!: Int64 = 20): UUID
    /**
     * Create a sha1-based UUID from the given byte array 
     */
    public static func sha1(value: Array<Byte>): UUID
    /**
     * version 7, a UUID based on the UNIX timestamp 
     */
    public static func unixTimeBased(): UUID
    /**
     * version 8
     */
    public static func custom(values: Array<Byte>): UUID
}

public class TimeBasedUUIDBuilder <: Resource {
    public func isClosed(): Bool 
    public func close(): Unit 
    /**Register a sequence number generator*/
    public func registerSequenceGenerator(generator: (Int64) -> UInt16) 
    /**Register a file sequence number generator*/
    public func registerFileSequenceGenerator(): This
    /**Register a sequence number generator using an atomic integer*/
    public func registerSequenceGenerator(): This
    /**Random sequence number generator*/
    public prop randomSeq: TimeBasedUUIDBuilder 
    /**Sequential sequence number generator*/
    public prop serialSeq: TimeBasedUUIDBuilder 
    /**Linux uid */
    public func UID(uid: UInt32): TimeBasedUUIDBuilder 
    /**Linux gid*/
    public func GID(gid: UInt32): TimeBasedUUIDBuilder 
    /**Use eth0*/ 
    @When[os == 'Linux']
    public func eth0()
    /**Use the network card address with the given name*/
    @When[os == 'Linux']
    public func etherName(name: String): UUID 
    /**Use the given network card address*/
    public func ether(ether: String): UUID 
    public func node(node: Int64): UUID 
    public func node(node: UInt64): UUID 
    public func randomNode(): UUID 
    public func node(node: Array<Byte>): UUID 
    /**Use a high-order timestamp*/
    public func timeHighFirst(timestamp: Int64): (Int64) -> Byte 
}

public class TimestampSequenceBuilder <: Resource {
    public func isClosed(): Bool 
    public func close(): Unit 
    /**Register a sequence number generator*/
    public func registerSequenceGenerator(generator: (Int64) -> UInt16) 
    /**Register a file sequence number generator*/
    public func registerFileSequenceGenerator(): This
    /**Register a sequence number generator using an atomic integer*/
    public func registerSequenceGenerator(): This
}

```


## Unit conversion

```cj
/**Convert a string with a unit such as "123KB" or "24M" into a number of bytes; a mismatched format throws (getOrThrow internally)*/
public func computeBytes(size: String): Option<Int64>
/**Convert a number into a number of bytes in the given unit; an unrecognized unit throws IllegalArgumentException*/
public func computeBytes(n: Int64, unit: String): Option<Int64>
```

Supported units (case insensitive, an optional trailing B is allowed): `b`, `k/kb`, `m/mb`, `g/gb`, `t/tb`, `p/pb`, `e/eb`, `z/zb`, `y/yb`, converted in base 1024.

## Tree structure conversion

```cj
/**Tree node contract: provides the child node list and addChild*/
public interface TreeNode<ID, T> where ID <: Hashable & Equatable<ID>, T <: Object & TreeNode<ID, T> {
    prop children: ArrayList<T>
    func addChild(child: T): Unit
}
```

`TreeNode.transform` assembles a flat collection of "parent ID + own ID" into a tree (`emptyId` denotes the root node; when
`ignoreDuplicate = false` a duplicate ID throws `IllegalArgumentException`), and there are several overloads such as "transferFn
only" and "ignoreDuplicate only".

## Companion types and exceptions

- Text template companions: `TextTemplateKey`, `TextTemplateObject`, `ObjectTextTemplateArgs`, `SimpleDataObjectTextTemplateArgs` (`src/TextTemplate.cj`).
- UUID companions: `SequenceResource` (`src/uuid.cj`).
- Exception family (`src/exception/`): `UUIDException`, `TextTemplateException`, `IdException`, `HashException`, `GeoHashException`.

## Key exchange protocol

```cj
/**
 * 1.      Alice and Bob first agree on p and g and publish them. Eve therefore knows their values too.
 *
 * 2.      Alice picks a private integer a, known to nobody, and sends Bob the computed result: A=(g pow a) mod p. Eve also sees the value of A.
 *
 * 3.      Similarly, Bob picks a private integer b and sends Alice the computed result B=(g pow b) mod p. Eve likewise sees what B is.
 *
 * 4.      Alice computes S=(B pow a) mod p=((g pow b) pow a) mod p=(g pow (a*b)) mod p.
 *
 * 5.      Bob can equally compute S=(A pow b) mod p=((g pow a) pow b) mod p=(g pow (a*b)) mod p.
 *
 * 6.      Alice and Bob now share a common key S.
 *
 * 7.      Although Eve has seen p, g, A and B, the difficulty of computing discrete logarithms means she cannot know the
 *         concrete values of a and b. Eve therefore has no way of knowing what the key S is.
 * Alice always initiates the key exchange request
 * let alice = DiffieHellmanKeyExchangerClient();
 * let semi=alice.semi(16);
 * //alice sends semi to bob
 *
 * //bob receives the request
 * let bob = DiffieHellmanKeyExchangerServer();
 * let bobKey = bob.key(A,p);//bob keeps the key, never exposing it
 * let B=bob.finish(g,p);//bob returns B to alice as the response
 *
 * //alice receives the response
 * let aliceKey=alice.key(B,p);//alice keeps the key, never exposing it
 */
public struct Semi {
    public Semi(public let g: Array<Byte>, public let p: Array<Byte>, public let A: BigInt) {}
}

public class DiffieHellmanKeyExchangerClient <: DiffieHellmanKeyExchanger {
    public func semi(gBytes!: Int32 = 16, pBytes!: Int32 = 16) 
}

public class DiffieHellmanKeyExchangerServer <: DiffieHellmanKeyExchanger {
    public func key(m: Array<Byte>, p: Array<Byte>): String 
    /**
     * Bob must run Bob.key first
     * @param g
     * @param p
     * @return B
     */
    public func finish(g: Array<Byte>, p: Array<Byte>): BigInt 
}

abstract sealed class DiffieHellmanKeyExchanger {
    public open func key(m: Array<Byte>, p: Array<Byte>): String 

    public static func randomByteLen(): Int32 
}

```

---

## Other public API

The declarations below are not expanded above; they are grouped by module level and by type (members declared in `extend` blocks are listed under the extended type). See the corresponding files under `src/` for the full semantics.

- Module level: `Crc16` (class), `Crc32` (class), `Crc64` (class), `public class IsUUID <: Validator`, `public func crc32Finish(crc: UInt32): UInt32`, `public func crc32Init(): UInt32`, `public func crc32Update(crc: UInt32, data: Array<Byte>): UInt32`, `millerRabin` (func), `qpow` (func)
- `Crc16`: `all` (let), `arc` (let), `buypass` (let), `ccittFalse` (let), `cdma2000` (let), `checkValue` (let), `cms` (let), `func compute(data: Array<Byte>): UInt16`, `dectR` (let), `dectX` (let), `dnp` (let), `en13757` (let), `genibus` (let), `gsm` (let), `func initRegister(): UInt16`, `kermit` (let), `maximDow` (let), `mcrf4xx` (let), `modbus` (let), `profibus` (let), `riello` (let), `spiFujitsu` (let), `t10Dif` (let), `teledisk` (let), `tms37157` (let), `func update(crc: UInt16, data: Array<Byte>): UInt16`, `usb` (let), `x25` (let), `xmodem` (let)
- `Crc32`: `all` (let), `autosar` (let), `base91D` (let), `bzip2` (let), `checkValue` (let), `func compute(data: Array<Byte>): UInt32`, `crc32c` (let), `func initRegister(): UInt32`, `isoHdlc` (let), `jamcrc` (let), `koopman` (let), `mpeg2` (let), `posix` (let), `q` (let), `func update(crc: UInt32, data: Array<Byte>): UInt32`, `xfer` (let)
- `Crc64`: `all` (let), `checkValue` (let), `func compute(data: Array<Byte>): UInt64`, `ecma182` (let), `func initRegister(): UInt64`, `iso` (let), `jones` (let), `redis` (let), `func update(crc: UInt64, data: Array<Byte>): UInt64`, `we` (let), `xz` (let)
- `IsUUID`: `prop description: String`, `func validate(value: ?String): Bool`
- `PathPattern`: `dataByPrefix` (func), `func extractDataParsableVariableInPath<T>(path: String, name: String): Option<T> where T <: DataParsable<T>`, `func extractParsableVariableInPath<T>(path: String, name: String): Option<T> where T <: Parsable<T>`, `func extractTimeVariableInPath(path: String, name: String, format: String): Option<DateTime>`, `func extractVariablesInPath(path: String): Map<String, String>`, `matches` (func), `func matchesPrefix(path: String): Bool`
