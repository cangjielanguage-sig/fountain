## murmur hash
```cj
public struct MurmurHash3X128 <: ToString & Hashable & Comparable<MurmurHash3X128> & DataParsable<MurmurHash3X128> & Parsable<MurmurHash3X128>{
    private MurmurHash3X128(
        public let left: UInt64,
        public let right: UInt64
    ){}
    public func toString(): String 
    public static func tryParse(s: String): ?MurmurHash3X128 
    public static func parse(s: String): MurmurHash3X128 
    public func hashCode(): Int64 
    public func compare(other: MurmurHash3X128): Ordering 
    public func toBytes(): Array<Byte> 
    public static func fromBytes(bytes: Array<Byte>): MurmurHash3X128
    // 核心哈希函数：对字节数组进行哈希（静态方法）
    @OverflowWrapping
    public static func hashBytes(data: Array<Byte>, seed!: UInt64 = 0): MurmurHash3X128 
    // 便捷函数：直接对字符串进行哈希（静态方法）
    public static func hashString(text: String, seed!: UInt64 = 0): MurmurHash3X128 
}
```
