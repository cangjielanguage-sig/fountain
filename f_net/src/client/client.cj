/*
Copyright (c) 2025 WuJingrun（吴京润）

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
 */
package fountain::f_net.client

import std.env
import std.collection.concurrent.ConcurrentHashMap
import fountain::f_protocol.*
import fountain::f_random.*
internal import std.net.IPSocketAddress
internal import std.sync.{Timer, CatchupStyle, AtomicInt64, Mutex, AtomicReference}
internal import fountain::f_data.*
internal import fountain::f_log.*
internal import fountain::f_net.*
internal import fountain::f_protocol.default.*

public class Client<T> <: Resource where T <: DataFields<T> {
    private static let log = LoggerFactory.getLogger('fountain::f_net.client.Client')
    private let futures = ConcurrentHashMap<MessageID, MessageFuture<Message>>()
    private let buffers: Array<SocketBuffer>
    private var checkTimer: Timer = unsafeZeroValue<Timer>()
    private let closed = AtomicInt64(0)
    private let closeLock = Mutex()
    
    Client(queueSize: Int64, 
        let checkDuration: Duration, 
        let checker: () -> ?Message,
        private let pingTimeout: Duration,
        private let socketCreator: () -> TcpSocket, 
        private let sockets: Array<TcpSocket>) {
        let futures = this.futures
        let buffers = Array<SocketBuffer>(sockets.size) {
            i =>
                let buffer = SocketBuffer(queueSize, sockets[i])
                spawn {
                    while (!buffer.isClosed()) {
                        var id = None<MessageID>
                        try {
                            let message = Message.decode<T>(buffer)
                            let mid = message.id
                            id = mid
                            if (let Some(fut) <- futures.remove(mid)) {
                                var f = fut
                                f.set(message)
                            }
                        } catch (e: Exception) {
                            let eid = id
                            log.error(e){'Client reader error; ${eid}'}
                            break
                        }
                    }
                }
                buffer
        }
        this.buffers = buffers
        checkTimer = Timer.repeat(checkDuration, checkDuration, {
            => for (i in 0..sockets.size) {
                func new() {
                    try {
                        sockets[i] = socketCreator()
                        let buffer = SocketBuffer(queueSize, sockets[i]) 
                        buffers[i] = buffer
                        spawn {
                            while (!buffer.isClosed()) {
                                var mid = None<MessageID>
                                var cmd = None<Command>
                                try {
                                    let message: Message = Message.decode<T>(buffer)
                                    let id = message.id
                                    mid = id
                                    cmd = message.command
                                    if(let Command.PING(_) <- message.command){
                                        transfer(buffer, Message.ack(id))
                                    }else if (let Some(fut) <- futures.remove(id)) {
                                        var f = fut
                                        f.set(message)
                                    }
                                } catch (e: Exception) {
                                    let mid = mid
                                    let cmd = cmd
                                    log.error(e){'Client reader error ${cmd}:${mid}'}
                                    break
                                }
                            }
                        }
                    } catch (e: Exception) {
                        log.error('SocketBuffer.new', e)
                        throw e
                    }
                }
                let buffer = buffers[i]
                try {
                    if (let Some(m) <- checker() && let Some(res) <- transfer(buffer, m).tryGet(pingTimeout) && res.id == m.id && res.command == Command.ACK) {
                        //do nothing
                    }else{
                        buffer.close()
                        new()
                    }
                } catch (e: Exception) {
                    log.error('SocketBuffer.checker', e)
                    try {
                        if (!buffer.isClosed()) {
                            buffer.close()
                        }
                    } catch (e: Exception) {
                        log.error('SocketBuffer.close', e)
                    }
                    try{
                        new()
                    }catch(e: Exception){
                        log.error('SocketBuffer.new', e)
                    }
                }
            }
        }, style: Burst)
        env.atExit(close)
    }

    public func close(): Unit {
        synchronized(closeLock) {
            closed.store(1)
            checkTimer.cancel()
            for (buf in buffers) {
                if (!buf.isClosed()) {
                    try {
                        buf.close()
                    } catch (e: Exception) {
                        log.error('SocketBuffer.close', e)
                    }
                }
            }
        }
    }

    public func isClosed(): Bool {
        closed.load() == 1
    }
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
        checkDuration!: Duration, checker!: () -> ?Message): SocketBuilder<T> {
        SocketBuilder<T>(queueSize: queueSize, socketCount: socketCount, host: host, port: port,
            checkDuration: checkDuration, checker: checker)
    }
    /**
     * @param queueSize 写数据任务队列大小
     * @param socketCount 连接数
     * @param address     String是待连接的主机名、域名、IP，UInt16是端口号
     * @param idGetter  从DE获得消息ID的函数
     * @param checkDuration 连接有效性的检查周期
     * @param checker   连接有效性检查函数，务必使用client.transfer(socketBuffer, id, message, timeout)传检查包
     */
    public static func builder(queueSize!: Int64 = 1024, socketCount!: Int64 = 1, address!: (String, UInt16),
        checkDuration!: Duration, checker!: () -> ?Message): SocketBuilder<T> {
        SocketBuilder<T>(queueSize: queueSize, socketCount: socketCount, address: '${address[0]}:${address[1]}',
            checkDuration: checkDuration, checker: checker)
    }
    /**
     * @param queueSize 写数据任务队列大小
     * @param socketCount 连接数
     * @param address     <host>:<port>，<host>是主机名、域名、IP
     * @param idGetter  从DE获得消息ID的函数
     * @param checkDuration 连接有效性的检查周期
     * @param checker   连接有效性检查函数，务必使用client.transfer(socketBuffer, id, message, timeout)传检查包
     */
    public static func builder(queueSize!: Int64 = 1024, socketCount!: Int64 = 1, address!: String,
        checkDuration!: Duration, checker!: () -> ?Message): SocketBuilder<T> {
        SocketBuilder<T>(queueSize: queueSize, socketCount: socketCount, address: address,
            checkDuration: checkDuration, checker: checker)
    }
    /**
     * @param queueSize 写数据任务队列大小
     * @param socketCount 连接数
     * @param address    IPSocketAddress
     * @param idGetter  从DE获得消息ID的函数
     * @param checkDuration 连接有效性的检查周期
     * @param checker   连接有效性检查函数，务必使用client.transfer(socketBuffer, id, message, timeout)传检查包
     */
    public static func builder(queueSize!: Int64 = 1024, socketCount!: Int64 = 1, address!: IPSocketAddress,
        checkDuration!: Duration, checker!: () -> ?Message): SocketBuilder<T> {
        SocketBuilder<T>(queueSize: queueSize, socketCount: socketCount, address: address,
            checkDuration: checkDuration, checker: checker)
    }
    private prop index: Int64 {
        get(){
            ThreadLocalRandom.current.nextInt64(0, sockets.size, closed: false)
        }
    }
    public func transfer(message: Message): MessageFuture<Message> {
        synchronized(closeLock) {
            if (isClosed()) {
                throw Exception('Client is closed')
            }
            transfer(index, message)
        }
    }
    public func transfer(message: Message, timeout: Duration): ?Message {
        let future: MessageFuture<Message>
        synchronized(closeLock) {
            if (isClosed()) {
                return None
            }
            future = transfer(index, message)
        }
        let result = future.tryGet(timeout)
        if (result.isNone()) {
            futures.remove(message.id)
        }
        result
    }
    private func transfer(index: Int64, message: Message): MessageFuture<Message> {
        transfer(buffers[index], message)
    }

    internal func transfer(buffer: SocketBuffer, message: Message, once!: Bool = true): MessageFuture<Message> {
        let future = MessageFuture<Message>()
        if(once){
            futures.add(message.id, future)
        }
        buffer.transfer(message)
        future
    }

    public func transfer(message: Message, executor: (Message) -> Unit): ListeningClient<T> {
        ListeningClient<T>(buffers[0].clone(), this, message, executor)
    }
}

public class SocketBuilder<T> where T <: DataFields<T> {
    private var pingTimeout_ = Duration.millisecond * 10
    SocketBuilder(let queueSize!: Int64 = 1024, private let socketCount!: Int64 = 1, private let address!: IPSocketAddress, 
                  private let checkDuration!: Duration, private let checker!: () -> ?Message){}
    init(queueSize!: Int64 = 1024, socketCount!: Int64 = 1, 
        host!: String, port!: UInt16, 
        checkDuration!: Duration, checker!: () -> ?Message) {
            this(queueSize: queueSize, 
                 socketCount: socketCount,
                 address: '${host}:${port}',
                 checkDuration: checkDuration, checker: checker)
    }
    init(queueSize!: Int64 = 1024, socketCount!: Int64 = 1, address!: String, 
        checkDuration!: Duration, checker!: () -> ?Message){
        this(queueSize: queueSize, 
            socketCount: socketCount,
            address: IPSocketAddress.tryParse(address).getOrThrow(),
            checkDuration: checkDuration, checker: checker)
    }
    private let params = SocketParams()

    public func bindToDevice(bindToDevice: ?String): This {
        params.bindToDevice(bindToDevice)
        this
    }
    public func keepAlive(keepAlive: ?SocketKeepAliveConfig): This {
        params.keepAlive(keepAlive)
        this
    }
    public func linger(linger: ?Duration): This {
        params.linger(linger)
        this
    }
    public func noDelay(noDelay: Bool): This {
        params.noDelay(noDelay)
        this
    }
    public func quickAcknowledge(quickAcknowledge: Bool): This {
        params.quickAcknowledge(quickAcknowledge)
        this
    }
    public func readTimeout(readTimeout: ?Duration): This {
        params.readTimeout(readTimeout)
        this
    }
    public func receiveBufferSize(receiveBufferSize: Int64): This {
        params.receiveBufferSize(receiveBufferSize)
        this
    }
    public func sendBufferSize(sendBufferSize: Int64): This {
        params.sendBufferSize(sendBufferSize)
        this
    }
    public func writeTimeout(writeTimeout: ?Duration): This {
        params.writeTimeout(writeTimeout)
        this
    }
    public func socketOption(level: Int32, option: Int32, value: CPointer<Unit>, valueLength: UIntNative): This {
        params.socketOption(level, option, value, valueLength)
        this
    }
    public func socketOptionBool(level: Int32, option: Int32, value: Bool): This {
        params.socketOptionBool(level, option, value)
        this
    }
    public func socketOptionIntNative(level: Int32, option: Int32, value: IntNative): This {
        params.socketOptionIntNative(level, option, value)
        this
    }
    public func pingTimeout(timeout: Duration): This {
        pingTimeout_ = timeout
        this
    }
    public func build(): Client<T> {
        Client<T>(queueSize, checkDuration, checker,  pingTimeout_, this.newSocket,
            Array<TcpSocket>(socketCount) {_ => newSocket()})
    }
    func newSocket() {
        let s = TcpSocket(address)
        params.populate(s)
        s.connect()
        s
    }
}
