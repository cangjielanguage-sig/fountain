## UInt128

```cj
//不提供四则运算能力，只有字符串<->UInt128、Array<Byte> <-> UInt128和UInt128的比较能力
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