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
package fountain::f_net.server

import std.collection.concurrent.{ConcurrentHashMap, LinkedBlockingQueue}
import std.env
import std.net.{TcpServerSocket, SocketAddress}
import std.sync.{Timer, CatchupStyle}
import fountain::f_base.ZERO_TIMER
import fountain::f_concurrent.*
import fountain::f_data.*
import fountain::f_log.*
import fountain::f_protocol.default.*
internal import fountain::f_net.*
public import fountain::f_net.*

private class PingCounter{
    PingCounter(var id: MessageID, var count: Int64){}
}
public class Server<T> <: Resource where T <: DataFields<T> {
    private static let log = LoggerFactory.getLogger('fountain::f_net.server.Server')
    private let buffers = LinkedBlockingQueue<SocketBuffer>()
    private var checkTimer: Timer = ZERO_TIMER
    private let executors: Executors<Message>
    private let checkerId = ConcurrentHashMap<SocketAddress, PingCounter>()
    internal Server(checkDuration!: Duration, checker!: () -> ?Message, executors!: Int64 = 200,
        private let bufferQueueSize!: Int64 = 1024, private let unavailableChecked!: Int64 = 3,
        private let limiter!: RateLimiter<Unit> = UnlimitedRateLimiter<Unit>(),
        private let defaultResp!: (MessageID) -> ?Message = {_ => None},
        private let server!: TcpServerSocket, private let params!: SocketParams) {
        let buffers = this.buffers
        this.executors = Executors<Message>(executors: executors, maxQueueSize: 1)
        this.checkTimer = Timer.repeat(
            checkDuration,
            checkDuration,
            {=>
                let size = buffers.size
                var i = 0
                while (i < size && let buffer <- buffers.remove()) {
                    spawn {
                        let available = try {
                            if(let Some(m) <- checker()){
                                let counter = checkerId.entryView(buffer.remoteAddress){view => 
                                    if(let Some(c) <- view.value){
                                        c.id = m.id
                                        c.count++
                                    }else{
                                        let c = PingCounter(m.id, 1)
                                        view.value = c
                                    }
                                }
                                if(let Some(c) <- counter && c.count > unavailableChecked){
                                    false
                                }else{
                                    buffer.transfer(m)
                                    true
                                }
                            }else{
                                false
                            }
                        } catch (e: Exception) {
                            log.warn('TcpSocket.check', e)
                            false
                        }
                        if (available) {
                            buffers.add(buffer)
                        } else {
                            try {
                                if(!buffer.isClosed()){
                                    buffer.close()
                                }
                            } catch (e: Exception) {
                                log.warn('TcpSocket.close', e)
                            }
                        }
                    }
                    i++
                }
            },
            style: Burst
        )
    }
    /**
     * @param bufferQueueSize 数据传输任务队列
     * @param bindAt    绑定的端口号
     * @param checkDuration tcp连接有效性检查周期
     * @param executors  线程池大小
     * @param limiter   限流器
     * @param checker   tcp连接有效性检查函数，务必使用server.transfer(socketBuffer, id, message, timeout)
     */
    public init(bufferQueueSize!: Int64 = 1024, bindAt!: UInt16, checkDuration!: Duration, executors!: Int64 = 200, 
                unavailableChecked!: Int64 = 3,
                defaultResp!: (MessageID) -> ?Message = {_=> None},
                limiter!: RateLimiter<Unit> = UnlimitedRateLimiter<Unit>(),
                checker!: () -> ?Message) {
        this(bufferQueueSize: bufferQueueSize, checkDuration: checkDuration, checker: checker, executors: executors, 
             unavailableChecked: unavailableChecked,
            server: newServerSocket(bindAt), params: SocketParams())
    }
    public static func builder(bufferQueueSize!: Int64 = 1024, checkDuration!: Duration, checker!: () -> ?Message, bindAt!: UInt16): ServerBuilder<T> {
        ServerBuilder<T>(bufferQueueSize, checkDuration, checker, bindAt)
    }
    public func start(executor: (SocketBuffer, Message) -> ?Message): Unit {
        while (let socket <- server.accept()) {
            params.populate(socket)
            let buffer = SocketBuffer(bufferQueueSize, socket)
            this.buffers.add(buffer)
            spawn{
                while (!socket.isClosed()) {
                    try{
                        let m = try {
                            let req = Message.decode<T>(buffer)
                            let remoteAddress = socket.remoteAddress
                            if(let Some(c) <- checkerId.get(remoteAddress) && c.id == req.id && req.command == Command.ACK){
                                checkerId.remove(remoteAddress)
                                continue
                            }else if (let Command.PING(_) <- req.command){
                                buffer.transfer(Message.ack(req.id))
                                continue
                            }
                            let msg = executors.call(limiter){executor(buffer, req)}.get{defaultResp(req.id)}
                            if(let Some(m) <- msg){
                                m
                            }else{
                                continue
                            }
                        } catch (e: Exception) {
                            log.warn('error occurred on reading or executing', e)
                            continue
                        }
                        buffer.transfer(m)
                    }catch(e: Exception){
                        log.warn('error occurred on responding', e)
                    }finally{
                        socket.close()
                    }
                }
            }
        }
    }
    //hasClosed doClose是为了在struct构造函数使用atExit而声明，struct构造函数不能访问实例函数
    private static func hasClosed(server: TcpServerSocket) {
        server.isClosed()
    }
    private static func doClose(server: TcpServerSocket, checkTimer: Timer, buffers: LinkedBlockingQueue<SocketBuffer>){
        server.close()
        checkTimer.cancel()
        for (i in 0..3) {
            while (buffers.size > 0) {
                if (let Some(buffer) <- buffers.remove(Duration.millisecond)) {
                    try {
                        buffer.close()
                    } catch (e: Exception) {
                        log.warn('SocketBuffer.close', e)
                    }
                }
            }
        }
    }
    public func isClosed(): Bool {
        hasClosed(server)
    }
    public func close(): Unit {
        doClose(server, checkTimer, buffers)
    }
}

public class ServerBuilder<T> where T <: DataFields<T> {
    private let server: TcpServerSocket
    private let params = SocketParams()
    private var executors_ = 200
    private var rateLimiter: RateLimiter<Unit> = UnlimitedRateLimiter<Unit>()
    private var defaultResp: (MessageID) -> ?Message = {_ => None}
    private var unavailableChecked_ = 3
    ServerBuilder(private let bufferQueueSize: Int64, private let checkDuration: Duration,
        private let checker: () -> ?Message, private let bindAt: UInt16) {
        server = newServerSocket(bindAt)
    }
    public func build(): Server<T> {
        Server<T>(bufferQueueSize: bufferQueueSize, checkDuration: checkDuration, checker: checker, 
                  unavailableChecked: unavailableChecked_,
                  executors: executors_, defaultResp: defaultResp, limiter: rateLimiter, server: server, params: params.copy())
    }
    public func backlogSize(size: Int64): This {
        server.backlogSize = size
        this
    }
    public func bindToDevice(device: ?String): This {
        server.bindToDevice = device
        this
    }
    public func receiveBufferSize(size: Int64): This {
        server.receiveBufferSize = size
        this
    }
    public func reuseAddress(reuse: Bool): This {
        server.reuseAddress = reuse
        this
    }
    public func sendBufferSize(size: Int64): This {
        server.sendBufferSize = size
        this
    }
    public func socketOption(level: Int32, option: Int32, value: CPointer<Unit>, valueLength: UIntNative): This {
        server.setSocketOption(level, option, value, valueLength)
        this
    }
    public func setSocketOptionBool(level: Int32, option: Int32, value: Bool): This {
        server.setSocketOptionBool(level, option, value)
        this
    }
    public func setSocketOptionIntNative(level: Int32, option: Int32, value: IntNative): This {
        server.setSocketOptionIntNative(level, option, value)
        this
    }

    public func socketBindToDevice(bindToDevice: ?String): This {
        params.bindToDevice(bindToDevice)
        this
    }
    public func socketLinger(linger: ?Duration): This {
        params.linger(linger)
        this
    }
    public func socketNoDelay(noDelay: Bool): This {
        params.noDelay(noDelay)
        this
    }
    public func socketQuickAcknowledge(quickAcknowledge: Bool): This {
        params.quickAcknowledge(quickAcknowledge)
        this
    }
    public func socketReadTimeout(readTimeout: ?Duration): This {
        params.readTimeout(readTimeout)
        this
    }
    public func socketReceiveBufferSize(receiveBufferSize: Int64): This {
        params.receiveBufferSize(receiveBufferSize)
        this
    }
    public func socketSendBufferSize(sendBufferSize: Int64): This {
        params.sendBufferSize(sendBufferSize)
        this
    }
    public func socketWriteTimeout(writeTimeout: ?Duration): This {
        params.writeTimeout(writeTimeout)
        this
    }
    public func executors(executors: Int64): This {
        executors_ = executors
        this
    }
    public func unavailableChecked(unavailableChecked: Int64): This {
        unavailableChecked_ = unavailableChecked
        this
    }
    public func anyMomentRateLimiter(maxTokens!: Int64, timeout!: Duration): This {
        this.rateLimiter = AnyMomentRateLimiter<Unit>(maxTokens: maxTokens, timeout: timeout)
        this
    }
    public func leakingBucketRateLimiter(timeout!: Duration, maxWaitings!: Int64, leakingPerDuration!: Int64, leakingDuration!: Duration): This {
            this.rateLimiter = LeakingBucketRateLimiter<Unit>(timeout: timeout,
            maxWaitings: maxWaitings,
            leakingPerDuration: leakingPerDuration,
            leakingDuration: leakingDuration)
        this
    }
    public func slidingWindowRateLimiter(window!: Duration, timeout!: Duration, limit!: Int64): This {
        this.rateLimiter = SlidingWindowRateLimiter<Unit>(window: window, timeout: timeout, limit: limit)
        this
    }
    public func tokenBucketRateLimiter(tokens!: Int64, timeout!: Duration, populationPeriod!: Duration): This {
        this.rateLimiter = TokenBucketRateLimiter<Unit>(tokens: tokens, timeout: timeout, populationPeriod: populationPeriod)
        this
    }
    public func defaultResponse(resp: (MessageID) -> ?Message): This {
        defaultResp = resp
        this
    }
}
func newServerSocket(bindAt: UInt16){
    var sopt = None<TcpServerSocket>
    try{
        let s = TcpServerSocket(bindAt: bindAt)
        s.bind()
        sopt = s 
    }catch(e: Exception){
        sopt?.close()
        throw e
    }
    sopt.getOrThrow()
}