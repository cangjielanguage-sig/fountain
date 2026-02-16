带应用协议的网络通讯
---

## 包名
`fountain::f_net`

## 基本类型
### `MessageFuture<DE>`
```cj
/**
 * 获取解码数据，本类型的公共函数是并发安全的
 */
public struct MessageFuture<DE>{
    /**
     * 如果当前没有数据可返回，会一直阻塞，当前模块会从tcp流读取并解码数据，将解码结果填充到本类型的实例，最后唤醒获取数据的线程
     */
    public func get(): DE 
    /**
     * 如果没有数据可返回就立即返回None<DE>，否则返回Some包含的数据实例
     */
    public func tryGet(): ?DE
    /**
     * 如果没有数据可返回就阻塞，直到等待timeout时间后超时，超时不论有没有数据都会立即返回。超时前如果有数据，等待的线程会被本模块唤醒并返回数据实例。
     */
    public func tryGet(timeout: Duration): ?DE 
}
```

## 客户端
```cj
package fountain::f_net.client
public struct Client<DE, EN, M, T, ID> where EN <: MessageCopier, M <: Protocol<EN, DE>, T <: DataFields<T>,
    ID <: Hashable & Equatable<ID> {
    /**
     * @param queueSize 写数据任务队列大小
     * @param socketCount 连接数
     * @param host      待连接的主机名、域名、IP
     * @param port      待连接的服务端号号
     * @param idGetter  从DE获得消息ID的函数
     * @param checkDuration 连接有效性的检查周期
     * @param checker   连接有效性检查函数，务必使用client.transfer(socketBuffer, id, message, timeout)传检查包
     */
    public static func builder(queueSize!: Int64 = 1024, socketCount!: Int64 = 1, host!: String, port!: UInt16,
        idGetter!: (DE) -> ID, checkDuration!: Duration, checker!: (SocketBuffer) -> Bool): SocketBuilder<DE, EN, M, T, ID>
    /**
     * 将数据编码后传输到客户端维持的tcp连接，客户端可能维持多个连接，传输时会随机选一个
     * @param id 消息ID
     * @param message 消息的内容
     * @return 服务端的响应
     */
    public func transfer(id: ID, message: M): MessageFuture<DE> 
    /**
     * 将数据编码后传输到客户端维持的tcp连接，客户端可能维持多个连接，传输时会随机选一个。
     * @param id 消息ID
     * @param message 消息的内容
     * @param timeout 等待响应的超时时间
     * @return 服务端的响应
     */
    public func transfer(id: ID, message: M, timeout: Duration): ?DE 
    
}
```
```cj
package fountain::f_net.server
/**
 * 客户端构造器
 */
public class SocketBuilder<DE, EN, M, T, ID> where EN <: MessageCopier, M <: Protocol<EN, DE>, T <: DataFields<T>, ID <: Hashable & Equatable<ID> {
    /**
     * 设置绑定的网卡
     */
    public func bindToDevice(bindToDevice: ?String): This 
    /**
     * 设置keepalive
     */
    public func keepAlive(keepAlive: ?SocketKeepAliveConfig): This 
    /**
     * 设置SO_LINGER 
     */
    public func linger(linger: ?Duration): This 
    /**
     * 设置SO_NODELAY 
     */
    public func noDelay(noDelay: Bool): This 
    /**
     * 设置TCP_QUICKACK 
     */ 
    public func quickAcknowledge(quickAcknowledge: Bool): This 
    /**
     * 设置读超时
     */
    public func readTimeout(readTimeout: ?Duration): This 
    /**
     * 设置SO_RCVBUF
     */
    public func receiveBufferSize(receiveBufferSize: Int64): This 
    /**
     * 设置SO_SNDBUF 
     */
    public func sendBufferSize(sendBufferSize: Int64): This 
    /**
     * 设置写超时 
     */
    public func writeTimeout(writeTimeout: ?Duration): This 
    /**
     * 设置套接字选项
     */
    public func socketOption(level: Int32, option: Int32, value: CPointer<Unit>, valueLength: UIntNative): This 
    /**
     * 设置套接字选项
     */
    public func socketOptionBool(level: Int32, option: Int32, value: Bool): This 
    /**
     * 设置套接字选项
     */
    public func socketOptionIntNative(level: Int32, option: Int32, value: IntNative): This 
    /**
     * 创建客户端实例
     */
    public func build(): Client<DE, EN, M, T, ID> 
}
```

## 服务端
```cj
public struct Server<DE, EN, M, T, ID> <: Resource where EN <: MessageCopier, M <: Protocol<EN, DE>, T <: DataFields<T>, ID <: Hashable & Equatable<ID> {
    /**
     * @param queueSize 数据传输任务队列
     * @param bindAt    绑定的端口号
     * @param checkDuration tcp连接有效性检查周期
     * @param checker   tcp连接有效性检查函数，务必使用server.transfer(socketBuffer, id, message, timeout)
     */
    public init(queueSize!: Int64 = 1024, bindAt!: UInt16, checkDuration!: Duration, checker!: (SocketBuffer) -> Bool) 
    /**
     * 创建服务器构造器
     */
    public static func build(queueSize!: Int64 = 1024, checkDuration!: Duration, checker!: (SocketBuffer) -> Bool, bindAt!: UInt16): ServerBuilder<DE, EN, M, T, ID> 
    /**
     * 启动服务端
     * 接收到客户端请求，服务端实例自动解码，以解码的实例作为参数调用executor，将返回
     */
    public func start(executor: (DE) -> M, idGetter: (M) -> ID): Unit 
    public func isClosed(): Bool 
    public func close(): Unit 
}
```