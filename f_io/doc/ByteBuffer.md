```cj
public class ByteBuffer <: IOStream {
    public ByteBuffer(
        initialCapacity!: Int64 = 32,
        public let toOverwriteOnClearing!: Bool = false
    )

    public init(
        array: Array<Byte>,
        toOverwriteOnClearing!: Bool = false
    )
    // 缓冲区容量
    public prop capacity: Int64 
    
    // 缓冲区写入位置
    public prop writeOffset: Int64 
    // 缓冲区读取位置
    public prop readOffset: Int64 

    // 获取未读字节切片
    public func bytes(): Array<Byte> 
    // 修改writeOffset 和readOffset为0，是否清除数据由toOverwriteOnClearing决定
    public func clear(): Unit 
    public func clone(): ByteBuffer 
    // 扩容，如果capacity - writeOffset + readOffset >= addition，则只将未读数据移到缓冲区头部，而不扩容
    public func reserve(addition: Int64): Unit 
    // 改变缓冲区的读取位置，读取范围从缓冲区头部到writeOffset
    public func seekReading(pos: SeekPosition): Unit 
    // 改变缓冲区的写入位置，读取范围从readOffset到缓冲区尾
    public func seekWriting(pos: SeekPosition): Unit 
    // 读取一字节，如果没有可读字节立即返回None
    public func readByte(): ?Byte
    // 读取字节数组，返回实际读取的字节数，读取字节数小于等于writeOffset - readOffset
    public func read(buf: Array<Byte>): Int64 
    // 写一字节，如果缓冲区已满将自动扩容capacity/2
    public func writeByte(b: Byte): Unit 
    // 写入缓冲区，如果可写空间不足，将自动扩容capacity/2 + buf.size
    public func write(buf: Array<Byte>): Unit 
    public func flush(): Unit {}
}

public class SyncByteBuffer <: IOStream {
    public init(
        initialCapacity!: Int64 = 32,
        toOverwriteOnClearing!: Bool = false
    )
    public init(
        array: Array<Byte>,
        toOverwriteOnClearing!: Bool = false
    )
    
    // 缓冲区容量
    public prop capacity: Int64 
    // 缓冲区写入位置
    public prop writeOffset: Int64 
    // 缓冲区读取位置
    public prop readOffset: Int64 
    // 不安全的操作，返回缓冲区全部未读字节切片
    public unsafe func bytes(): Array<Byte> 
    // 只把readOffset和writeOffset改为0，是否清除数据由toOverwriteOnClearing决定
    public func clear(): Unit 
    public func clone(): ByteBuffer 
    // 扩容，如果缓冲区已满将自动扩容addition，如果
    public func reserve(addition: Int64): Unit 
    // 改变缓冲区的读取位置，读取范围从缓冲区头部到writeOffset
    public func seekReading(pos: SeekPosition): Unit 
    // 改变缓冲区的写入位置，写入范围从readOffset到缓冲区尾部
    public func seekWriting(pos: SeekPosition): Unit 
    // 读取一字节，如果没有可读字节立即返回None
    public func readByte(): ?Byte
    // 读取一字节，无可读字节将等待timeout时长，如果timeout==Duration.Zero立即返回None<Byte>
    // 如果超时后尚无可读字节返回None，如果已调用end()函数返回None
    public func readByte(timeout: Duration): ?Byte 
    // 读取的字节数小于等于buf.size，如果没有可读内容将等待timeout时长，如果timeout==Duration.Zero立即返回None<Int64>
    // 如果超时后尚无可读字节返回None，如果已调用end()函数返回0
    public func read(buf: Array<Byte>, timeout: Duration): ?Int64 
    // 如果没有可读内容将立即返回0
    public func read(buf: Array<Byte>): Int64 
    // 写入一字节，如果缓冲区已满将自动扩容capacity/2
    public func writeByte(b: Byte): Unit 
    // 写入字节数组，如果缓冲区已满将自动扩容capacity/2 + buf.size
    public func write(bytes: Array<Byte>): Unit 
    public func flush(): Unit {}
    // 确认不再需要写入字节调用此函数
    public func end(): Unit 
    // 在同步块内调用fn，跟其它函数使用同一个锁实例
    public func batch(fn: (ByteBuffer) -> Unit): Unit
}
```