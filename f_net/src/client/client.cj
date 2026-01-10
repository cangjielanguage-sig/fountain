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

import std.io.BufferedInputStream
import std.collection.ArrayList
import std.collection.concurrent.{ArrayBlockingQueue, ConcurrentHashMap}
import std.sync.Mutex
import std.net.{TcpServerSocket, TcpSocket, IPSocketAddress, SocketKeepAliveConfig}
import f_data.*
import f_protocol.*
import f_random.*
import f_net.SocketParams

public struct Client<DE, EN, M, T, ID> where EN <: MessageCopier, M <: Protocol<EN, DE>, T <: DataFields<T>, ID <: Hashable & Equatable<ID> {
    private let futures: ConcurrentHashMap<ID, ClientFuture<DE>>
    private let buffer: Array<ClientBuffer>
    Client(queueSize: Int64, idGetter: (DE) -> ID, private let sockets: Array<TcpSocket>){
        let futures = ConcurrentHashMap<ID, ClientFuture<DE>>()
        this.futures = futures
        buffer = Array<ClientBuffer>(sockets.size){i => 
            let buffer = ClientBuffer(queueSize, sockets[i])
            spawn {
                let de = M.decode<TcpSocket, T>(buffer.buffered, closeFromOnEnd: false)
                let id = idGetter(de)
                if(let Some(fut) <- futures.remove(id)){
                    var f = fut
                    f.set(de)
                }
            }
            buffer
        }
    }
    public static func builder(queueSize!: Int64 = 1024, socketCount!: Int64 = 1, host!: String, port!: UInt16, idGetter!: (DE) -> ID){
        SocketBuilder<DE, EN, M, T, ID>(socketCount: queueSize, host: host, port: port, idGetter: idGetter)
    }
    public func transfer(id: ID, message: M): ClientFuture<DE> {
        let index = ThreadLocalRandom.current.nextInt64(0, sockets.size, closed: true)
        let socket = sockets[index]
        let future = ClientFuture<DE>()
        futures.add(id, future)
        let en = message.encode()
        buffer[index].queue.add({=>
            en.copy(to: socket, closeToOnEnd: false)
        })
        future
    }
}
private struct ClientBuffer {
    let buffered: BufferedInputStream<TcpSocket>
    let queue: ArrayBlockingQueue<() -> Unit>
    init(queueSize: Int64, socket: TcpSocket){
        buffered = BufferedInputStream<TcpSocket>(socket)
        let queue = ArrayBlockingQueue<() -> Unit>(queueSize)
        this.queue = queue
        spawn{
            while(let fn <- queue.remove()){
                fn()
            }
        }
    }
}
public struct ClientFuture<DE>{
    private let mutex = Mutex()
    private var ref = None<DE>
    private let condition = synchronized(mutex){
        mutex.condition()
    }
    mut func set(data: DE): Unit {
        synchronized(mutex){
            ref = data
            condition.notify()
        }
    }
    public func get(): DE {
        synchronized(mutex){
            if(let Some(d) <- ref){
                d
            }else{
                condition.wait()
                ref.getOrThrow()
            }
        }
    }
    public func tryGet(): ?DE {
        synchronized(mutex){
            ref
        }
    }
    public func tryGet(timeout: Duration): ?DE {
        synchronized(mutex){
            if(let Some(d) <- ref){
                d
            }else{
                condition.wait(timeout: timeout)
                ref
            }
        }
    }
}
public class SocketBuilder<DE, EN, M, T, ID> where EN <: MessageCopier, M <: Protocol<EN, DE>, T <: DataFields<T>, ID <: Hashable & Equatable<ID> {
    SocketBuilder(let queueSize!: Int64 = 1024, 
                private let socketCount!: Int64 = 1, 
                private let host!: String, 
                private let port!: UInt16,
                private let idGetter!: (DE) -> ID){}
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
        Client<DE, EN, M, T, ID>(queueSize, idGetter, Array<TcpSocket>(socketCount){_ =>
            TcpSocket(host, port) |> params.populate
        })
    }
}