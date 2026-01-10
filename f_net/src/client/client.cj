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
package f_net.client

import std.io.OutputStream
import std.collection.ArrayList
import std.collection.concurrent.ConcurrentHashMap
import std.sync.{Timer, CatchupStyle}
import std.net.IPSocketAddress
import f_data.*
import f_log.*
import f_protocol.*
import f_random.*
import f_net.*

public struct Client<DE, EN, M, T, ID> where EN <: MessageCopier, M <: Protocol<EN, DE>, T <: DataFields<T>,
    ID <: Hashable & Equatable<ID> {
    private static let log = LoggerFactory.getLogger('fountain::net.Client')
    private let futures = ConcurrentHashMap<ID, MessageFuture<DE>>()
    private let buffers: Array<SocketBuffer>

    Client(queueSize: Int64, idGetter: (DE) -> ID, checkDuration: Duration, checker: (SocketBuffer) -> Bool,
        private let socketCreator: () -> TcpSocket, private let sockets: Array<TcpSocket>) {
        let futures = this.futures
        let buffers = Array<SocketBuffer>(sockets.size) {
            i =>
                let buffer = SocketBuffer(queueSize, sockets[i])
                spawn {
                    let de = M.decode<TcpSocket, T>(buffer.buffered, closeFromOnEnd: false)
                    let id = idGetter(de)
                    if (let Some(fut) <- futures.remove(id)) {
                        var f = fut
                        f.set(de)
                    }
                }
                buffer
        }
        this.buffers = buffers
        Timer.repeat(checkDuration, checkDuration, {
            => for (i in 0..sockets.size) {
                spawn {
                    func new() {
                        try {
                            sockets[i] = socketCreator()
                        } catch (e: Exception) {
                            log.error('TcpSocket.new', e)
                            throw e
                        }
                    }
                    let buffer = buffers[i]
                    let socket = buffer.socket
                    try {
                        if (!checker(buffer)) {
                            if (!socket.isClosed()) {
                                socket.close()
                            }
                            new()
                        }
                    } catch (e: Exception) {
                        log.error('TcpSocket.checker', e)
                        try {
                            socket.close()
                        } catch (e: Exception) {
                            log.error('TcpSocket.close', e)
                        }
                        new()
                    }
                }
            }
        }, style: Burst)
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
        idGetter!: (DE) -> ID, checkDuration!: Duration, checker!: (SocketBuffer) -> Bool) {
        SocketBuilder<DE, EN, M, T, ID>(socketCount: queueSize, host: host, port: port, idGetter: idGetter,
            checkDuration: checkDuration, checker: checker)
    }
    public func transfer(id: ID, message: M): MessageFuture<DE> {
        let index = ThreadLocalRandom.current.nextInt64(0, sockets.size, closed: true)
        transfer(index, id, message)
    }
    private func transfer(index: Int64, id: ID, message: M): MessageFuture<DE> {
        transfer(buffers[index], id, message)
    }
    public func transfer(buffer: SocketBuffer, id: ID, message: M): MessageFuture<DE> {
        let future = MessageFuture<DE>()
        futures.add(id, future)
        let en = message.encode()
        buffer.queue.add({
            => en.copy(to: buffer.socket, closeToOnEnd: false)
        })
        future
    }
    public func transfer(buffer: SocketBuffer, id: ID, message: M, timeout: Duration): ?DE {
        transfer(buffer, id, message).tryGet(timeout)
    }
}

public class SocketBuilder<DE, EN, M, T, ID> where EN <: MessageCopier, M <: Protocol<EN, DE>, T <: DataFields<T>,
    ID <: Hashable & Equatable<ID> {
    SocketBuilder(let queueSize!: Int64 = 1024, private let socketCount!: Int64 = 1, private let host!: String,
        private let port!: UInt16, private let idGetter!: (DE) -> ID, private let checkDuration!: Duration,
        private let checker!: (SocketBuffer) -> Bool) {}
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
    public func build(): Client<DE, EN, M, T, ID> {
        Client<DE, EN, M, T, ID>(queueSize, idGetter, checkDuration, checker, this.newSocket,
            Array<TcpSocket>(socketCount) {_ => newSocket()})
    }
    func newSocket() {
        TcpSocket(host, port) |> params.populate
    }
}
