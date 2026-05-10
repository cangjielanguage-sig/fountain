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

import std.collection.concurrent.LinkedBlockingQueue
import std.net.TcpServerSocket
import std.sync.{Timer, CatchupStyle}
import fountain::f_data.*
import fountain::f_log.*
import fountain::f_protocol.*
import fountain::f_net.*

public struct Server<DE, EN, M, T> <: Resource where EN <: MessageCopier, M <: Protocol<EN, DE>, T <: DataFields<T> {
    private static let log = LoggerFactory.getLogger('fountain:net.Server')
    private let buffers = LinkedBlockingQueue<SocketBuffer>()
    private let checkTimer: Timer

    internal Server(checkDuration!: Duration, checker!: (SocketBuffer) -> Bool, private let queueSize!: Int64 = 1024,
        private let server!: TcpServerSocket, private let params!: SocketParams) {
        let buffers = this.buffers
        checkTimer = Timer.repeat(
            checkDuration,
            checkDuration,
            {
                =>
                    let size = buffers.size
                    var i = 0
                    while (i < size && let buffer <- buffers.remove()) {
                        spawn {
                            let available = try {
                                checker(buffer)
                            } catch (e: Exception) {
                                log.warn('TcpSocket.check', e)
                                false
                            }
                            if (available) {
                                buffers.add(buffer)
                            } else {
                                try {
                                    let socket = buffer.socket
                                    if (!socket.isClosed()) {
                                        socket.close()
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
     * @param queueSize 数据传输任务队列
     * @param bindAt    绑定的端口号
     * @param checkDuration tcp连接有效性检查周期
     * @param checker   tcp连接有效性检查函数，务必使用server.transfer(socketBuffer, id, message, timeout)
     */
    public init(queueSize!: Int64 = 1024, bindAt!: UInt16, checkDuration!: Duration, checker!: (SocketBuffer) -> Bool) {
        this(queueSize: queueSize, checkDuration: checkDuration, checker: checker,
            server: TcpServerSocket(bindAt: bindAt), params: SocketParams())
    }
    public static func build(queueSize!: Int64 = 1024, checkDuration!: Duration, checker!: (SocketBuffer) -> Bool,
        bindAt!: UInt16): ServerBuilder<DE, EN, M, T> {
        ServerBuilder<DE, EN, M, T>(queueSize, checkDuration, checker, bindAt)
    }
    public func start(executor: (DE) -> M): Unit {
        while (let socket <- server.accept()) {
            params.populate(socket)
            let buffer = SocketBuffer(queueSize, socket)
            this.buffers.add(buffer)
            spawn {
                while (!socket.isClosed()) {
                    try {
                        let req = M.decode<TcpSocket, T>(buffer.buffered)
                        let m = req |> executor
                        transfer(buffer, m)
                    } catch (e: Exception) {
                        log.warn('Server reader error', e)
                        break
                    }
                }
            }
        }
    }
    private func transfer(buffer: SocketBuffer, message: M): Unit {
        let en = message.encode()
        buffer.queue.add({
            => en.copy(to: buffer.socket, closeToOnEnd: false)
        })
    }
    public func isClosed(): Bool {
        server.isClosed()
    }
    public func close(): Unit {
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
}

public class ServerBuilder<DE, EN, M, T> where EN <: MessageCopier, M <: Protocol<EN, DE>, T <: DataFields<T> {
    private let server: TcpServerSocket
    private let params = SocketParams()
    ServerBuilder(private let queueSize: Int64, private let checkDuration: Duration,
        private let checker: (SocketBuffer) -> Bool, private let bindAt: UInt16) {
        server = TcpServerSocket(bindAt: bindAt)
    }
    public func build(): Server<DE, EN, M, T> {
        Server<DE, EN, M, T>(queueSize: queueSize, checkDuration: checkDuration, checker: checker, server: server,
            params: params.copy())
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
    public func reusePort(reuse: Bool): This {
        server.reusePort = reuse
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
}
