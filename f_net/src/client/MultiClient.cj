/*
Copyright (c) 2026 WuJingrun（吴京润）

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

import fountain::f_concurrent.*
import fountain::f_concurrent.exception.LoadBalanceException

public class MultiClientBuilder<W, T> where T <: DataFields<T>, W <: Addable<W> & Comparable<W>{
    MultiClientBuilder(private let queueSize!: Int64 = 1024, 
                       private let socketCount!: Int64 = 1, 
                       private let checkDuration!: Duration, 
                       private let checker!: () -> ?Message){}
    private var bindToDevice_ = None<String>
    public func bindToDevice(bindToDevice: ?String): This {
        bindToDevice_ = bindToDevice
        this
    }
    private var keepAlive_ = None<SocketKeepAliveConfig>
    public func keepAlive(keepAlive: ?SocketKeepAliveConfig): This {
        keepAlive_ = keepAlive
        this
    }
    private var linger_ = None<Duration>
    public func linger(linger: ?Duration): This {
        linger_ = linger
        this
    }
    private var noDelay_ = None<Bool>
    public func noDelay(noDelay: Bool): This {
        noDelay_ = noDelay
        this
    }
    private var quickAcknowledge_ = None<Bool>
    public func quickAcknowledge(quickAcknowledge: Bool): This {
        quickAcknowledge_ = quickAcknowledge
        this
    }
    private var readTimeout_ = None<Duration>
    public func readTimeout(readTimeout: ?Duration): This {
        readTimeout_ = readTimeout
        this
    }
    private var receiveBufferSize_ = None<Int64>
    public func receiveBufferSize(receiveBufferSize: Int64): This {
        receiveBufferSize_ = receiveBufferSize
        this
    }
    private var sendBufferSize_ = None<Int64>
    public func sendBufferSize(sendBufferSize: Int64): This {
        sendBufferSize_ = sendBufferSize
        this
    }
    private var writeTimeout_ = None<Duration>
    public func writeTimeout(writeTimeout: ?Duration): This {
        writeTimeout_ = writeTimeout
        this
    }
    private var socketOptions_ = None<(Int32, Int32, CPointer<Unit>, UIntNative)>
    public func socketOption(level: Int32, option: Int32, value: CPointer<Unit>, valueLength: UIntNative): This {
        socketOptions_ = (level, option, value, valueLength)
        this
    }
    private var socketOptionBool_ = None<(Int32, Int32, Bool)>
    public func socketOptionBool(level: Int32, option: Int32, value: Bool): This {
        socketOptionBool_ = (level, option, value)
        this
    }
    private var socketOptionIntNative_ = None<(Int32, Int32, IntNative)>
    public func socketOptionIntNative(level: Int32, option: Int32, value: IntNative): This {
        socketOptionIntNative_ = (level, option, value)
        this
    }
    private var pingTimeout_ = None<Duration>
    public func pingTimeout(timeout: Duration): This {
        pingTimeout_ = timeout
        this
    }
    private var balance = None<LoadBalance<W, Unit, Client<T>>>
    public func roundRobin(step: W, min: W, max: W): This {
        let algo = RoundRobin<W>(step, min, max)
        balance = LoadBalance<W, Unit, Client<T>>(min, algo)
        this
    }
    public func random(min: W, max: W): This {
        let algo = (match((min, max)){
            case (a: Int64, b: Int64) => Int64Weight(a, b)
            case (a: Float64, b: Float64) => Float64Weight(a, b)
            case _ => throw LoadBalanceException('generic type W must be Int64 or Float64')
        } as LoadBalanceAlgo<W>).getOrThrow()
        balance = LoadBalance<W, Unit, Client<T>>(min, algo)
        this
    }
    /**
     * 先调用roundRobin(step, min, max)或random(min, max)再调用add函数
     */
    public func add(weight: W, address: String): This {
        add(weight, IPSocketAddress.tryParse(address).getOrThrow())
    }
    /**
     * 先调用roundRobin(step, min, max)或random(min, max)再调用add函数
     */
    public func add(weight: W, host: String, port: UInt16): This {
        add(weight, IPSocketAddress(host, port))
    }
    /**
     * 先调用roundRobin(step, min, max)或random(min, max)再调用add函数
     */
    public func add(weight: W, address: IPSocketAddress): This {
        let builder = Client<T>.builder(queueSize: queueSize, socketCount: socketCount, address: address, checkDuration: checkDuration, checker: checker)
        builder.bindToDevice(bindToDevice_)
        builder.keepAlive(keepAlive_)
        builder.linger(linger_)
        if(let Some(noDelay) <- noDelay_){
            builder.noDelay(noDelay)
        }
        if(let Some(quickAcknowledge) <- quickAcknowledge_){
            builder.quickAcknowledge(quickAcknowledge)
        }
        builder.readTimeout(readTimeout_)
        if(let Some(receiveBufferSize) <- receiveBufferSize_){
            builder.receiveBufferSize(receiveBufferSize)
        }
        if(let Some(sendBufferSize) <- sendBufferSize_){
            builder.sendBufferSize(sendBufferSize)
        }
        builder.writeTimeout(writeTimeout_)
        if(let Some((level, option, value, valueLength)) <- socketOptions_){
            builder.socketOption(level, option, value, valueLength)
        }
        if(let Some((level, option, value)) <- socketOptionBool_){
            builder.socketOptionBool(level, option, value)
        }
        if(let Some((level, option, value)) <- socketOptionIntNative_){
            builder.socketOptionIntNative(level, option, value)
        }
        if(let Some(pingTimeout) <- pingTimeout_){
            builder.pingTimeout(pingTimeout)
        }
        let client = builder.build()
        balance?.add(weight){_ => client}
        this
    }
    /**
     * 先调用roundRobin(step, min, max)或random(min, max)再调用add函数
     */
    public func add(address: Iterable<(W, String)>): This {
        for((weight, address) in address){
            add(weight, address)
        }
        this
    }
    /**
     * 先调用roundRobin(step, min, max)或random(min, max)再调用add函数
     */
    public func add(address: Iterable<(W, String, UInt16)>): This {
        for((weight, host, port) in address){
            add(weight, host, port)
        }
        this
    }
    /**
     * 先调用roundRobin(step, min, max)或random(min, max)再调用add函数
     */
    public func add(address: Iterable<(W, IPSocketAddress)>): This {
        for((weight, address) in address){
            add(weight, address)
        }
        this
    }
    
    public func build(): MultiClient<W, T> {
        return MultiClient<W, T>(balance.getOrThrow())
    }
}
public class MultiClient<W, T> where T <: DataFields<T>, W <: Addable<W> & Comparable<W> {
    MultiClient(private let clients: LoadBalance<W, Unit, Client<T>> ){}
    /**
     * @param queueSize 写数据任务队列大小
     * @param socketCount 连接数
     * @param idGetter  从DE获得消息ID的函数
     * @param checkDuration 连接有效性的检查周期
     * @param checker   连接有效性检查函数，务必使用client.transfer(socketBuffer, id, message, timeout)传检查包
     */
    public static func builder(queueSize!: Int64 = 1024, socketCount!: Int64 = 1, 
        checkDuration!: Duration, checker!: () -> ?Message): MultiClientBuilder<W, T> {
        builder(queueSize: queueSize, socketCount: socketCount, 
            checkDuration: checkDuration, checker: checker)
    }
    public func iterator(): Iterator<Client<T>> {
        clients.iterator().map{f => f(())}
    }
}