## UUID
```cj
/**
 * reference https://www.ietf.org/archive/id/draft-ietf-uuidrev-rfc4122bis-00.html
 * 实现各个版本的UUID
 */
public struct UUID <: Hashable & Comparable<UUID> & ToString & Parsable<UUID> & DataParsable<UUID> & DataFields<UUID> {
    /**
     * UUID转Data实例
     */
    public func toData(): Data 
    /**
     * Data转UUID
     */
    public static func tryFromData(data: Data, flag: DataConversionFlag): Any
    public func hashCode(): Int64
    public operator func ==(other: UUID): Bool 
    public operator func !=(other: UUID): Bool 
    public func compare(other: UUID): Ordering
    /**
     * 空UUID
     */
    public static let Nil = UUID()
    /**
     * 最大的UUID
     */
    public static let Max = UUID(values: Array<Byte>(16, repeat: 0xff))
    public func toString(): String
    /**
     * UUID转成指定进制的字符串
     */
    public func toString(radix: Int64)
    /**
     * UUID转成指定16进制的字符串
     */
    public func toHexString(): String
    /**
     * UUID版本
     */
    public prop version: Int64
    /**
     * UUID时间戳
     */
    public prop timestampNanos: Int64
    /**
     * UUID时间戳
     */
    public prop timestamp: DateTime
    public prop variant: Int64
    public static func parse(uuid: String): UUID
    public static func tryParse(uuid: String): ?UUID
    /**
     * 基于时间戳的UUID，兼容UUID version 1 2 6
     */
    public static func timeBased(timeLowFirst!: Bool = false): TimeBasedUUIDBuilder
    /**
     * version 3
     */
    public static func md5(value: String): UUID
    /**
     * 用随机字节数组创建基于md5的UUID 
     */
    public static func randomMd5(bytes!: Int64 = 16): UUID
    /**
     * 用指定字节数组创建基于md5的UUID 
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
     * 用随机字节数组创建基于sha1的UUID 
     */
    public static func randomSha1(bytes!: Int64 = 20): UUID
    /**
     * 用指定字节数组创建基于sha1的UUID 
     */
    public static func sha1(value: Array<Byte>): UUID
    /**
     * version 7 基于UNIX时间戳的UUID 
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
    /**注册序列号生成器*/
    public func registerSequenceGenerator(generator: (Int64) -> UInt16) 
    /**注册文件序列号生成器*/
    public func registerFileSequenceGenerator(): This
    /**使用原子整型注册一个序列号生成器*/
    public func registerSequenceGenerator(): This
    /**随机序列号生成器*/
    public prop randomSeq: TimeBasedUUIDBuilder 
    /**顺序序列号生成器*/
    public prop serialSeq: TimeBasedUUIDBuilder 
    /**Linux uid */
    public func UID(uid: UInt32): TimeBasedUUIDBuilder 
    /**Linux gid*/
    public func GID(gid: UInt32): TimeBasedUUIDBuilder 
    /**使用eth0*/ 
    @When[os == 'Linux']
    public func eth0()
    /**使用指定名称的网卡地址*/
    @When[os == 'Linux']
    public func etherName(name: String): UUID 
    /**使用指定的网卡地址*/
    public func ether(ether: String): UUID 
    public func node(node: Int64): UUID 
    public func node(node: UInt64): UUID 
    public func randomNode(): UUID 
    public func node(node: Array<Byte>): UUID 
    /**使用高位时间戳*/
    public func timeHighFirst(timestamp: Int64): (Int64) -> Byte 
}

public class TimestampSequenceBuilder <: Resource {
    public func isClosed(): Bool 
    public func close(): Unit 
    /**注册序列号生成器*/
    public func registerSequenceGenerator(generator: (Int64) -> UInt16) 
    /**注册文件序列号生成器*/
    public func registerFileSequenceGenerator(): This
    /**使用原子整型注册一个序列号生成器*/
    public func registerSequenceGenerator(): This
}

```
