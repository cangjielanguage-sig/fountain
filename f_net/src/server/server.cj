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
package f_net.server

import std.io.BufferedInputStream
import std.collection.concurrent.{ArrayBlockingQueue, LinkedBlockingQueue}
import std.net.{TcpServerSocket, TcpSocket, IPSocketAddress}
import std.sync.Timer
import f_data.*
import f_log.*
import f_protocol.*
import f_net.SocketParams

public struct Server <: Resource {
    private static let log = LoggerFactory.getLogger<Server>()
    private let queue: ArrayBlockingQueue<() -> Unit>
    private let sockets = LinkedBlockingQueue<TcpSocket>()
    public Server(queueSize!: Int64 = 1024, 
                checkDuration!: Duration, checker!: (TcpSocket) -> Bool, 
                private let server!: TcpServerSocket, private let params!: SocketParams){
        let queue = ArrayBlockingQueue<() -> Unit>(queueSize)
        this.queue = queue
        spawn {
            while(let task <- queue.remove()){
                task()
            }
        }
        Timer.repeat(checkDuration, checkDuration){
            let size = sockets.size
            var i = 0
            while(i < size && let socket <- sockets.remove()){
                spawn{
                    let available = try{
                        checker(socket)
                    }catch(e: Exception){
                        log.warn('TcpSocket.check', e)
                        false
                    }
                    if(available){
                        sockets.add(socket)
                    }else{
                        try{
                            if(!socket.isClosed()){
                                socket.close()
                            }
                        }catch(e: Exception){
                            log.warn('TcpSocket.close', e)
                        }
                    }
                }
                i++
            }
        }
    }
    public init(queueSize!: Int64 = 1024, bindAt!: UInt16, checkDuration!: Duration, checker!: (TcpSocket) -> Bool){
        this(queueSize: queueSize, checkDuration: checkDuration, checker: checker, server: TcpServerSocket(bindAt: bindAt), params: SocketParams())
    }
    public static func build(queueSize!: Int64 = 1024, checkDuration!: Duration, checker!: (TcpSocket) -> Bool, bindAt!: UInt16): ServerBuilder {
        ServerBuilder(queueSize, checkDuration, checker, bindAt)
    }
    public func start<DE, EN, M, T>(executor: (DE) -> M): Unit where EN <: MessageCopier, M <: Protocol<EN, DE>, T <: DataFields<T> {
        while(let socket <- server.accept()){
            this.sockets.add(socket)
            params.populate(socket)
            let buffered = BufferedInputStream(socket)
            spawn {
                while(!socket.isClosed()){
                    let m = M.decode<TcpSocket, T>(buffered, closeFromOnEnd: false) |> executor
                    let en = m.encode()
                    queue.add({=>
                        en.copy(to: socket, closeToOnEnd: false)
                    })
                }
            }
        }
    }
    public func isClosed(): Bool {
        server.isClosed()
    }
    public func close(): Unit {
        server.close()
    }
}
public class ServerBuilder {
    private let server: TcpServerSocket
    private let params = SocketParams()
    private let checkDuration = Duration.minute
    ServerBuilder(private let queueSize: Int64, 
                private let checkDuration: Duration, 
                private let checker: (TcpSocket) -> Bool, 
                private let bindAt: UInt16){
        server = TcpServerSocket(bindAt: bindAt)
    }
    public func build(): Server {
        Server(queueSize: queueSize, checkDuration: checkDuration, checker: checker, server: server, params: params)
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