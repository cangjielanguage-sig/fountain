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
package fountain::f_net

import std.collection.ArrayList

internal class SocketParams {
    private var bindToDevice_ = None<String>
    private var keepAlive_ = None<SocketKeepAliveConfig>
    private var linger_ = None<Duration>
    private var noDelay_ = None<Bool>
    private var quickAcknowledge_ = None<Bool>
    private var readTimeout_ = None<Duration>
    private var receiveBufferSize_ = 0
    private var sendBufferSize_ = 0
    private var writeTimeout_ = None<Duration>
    private var socketOption_ = ArrayList<(Int32, Int32, CPointer<Unit>, UIntNative)>()
    private var socketOptionBool_ = ArrayList<(Int32, Int32, Bool)>()
    private var socketOptionIntNative_ = ArrayList<(Int32, Int32, IntNative)>()

    internal func populate(socket: TcpSocket): TcpSocket {
        socket.bindToDevice = bindToDevice_
        socket.keepAlive = keepAlive_
        socket.linger = linger_
        if(let Some(noDelay) <- noDelay_){
            socket.noDelay = noDelay
        }
        if(let Some(quickAcknowledge) <- quickAcknowledge_){
            socket.quickAcknowledge = quickAcknowledge
        }
        socket.readTimeout = readTimeout_
        socket.receiveBufferSize = receiveBufferSize_
        socket.sendBufferSize = sendBufferSize_
        for((level, option, value, length) in socketOption_){
            socket.setSocketOption(level, option, value, length)
        }
        for((level, option, value) in socketOptionBool_){
            socket.setSocketOptionBool(level, option, value)
        }
        for((level, option, value) in socketOptionIntNative_){
            socket.setSocketOptionIntNative(level, option, value)
        }
        socket
    }

    public func bindToDevice(bindToDevice: ?String): This {
        bindToDevice_ = bindToDevice
        this
    }
    public func keepAlive(keepAlive: ?SocketKeepAliveConfig): This {
        keepAlive_ = keepAlive
        this
    }
    public func linger(linger: ?Duration): This {
        linger_ = linger
        this
    }
    public func noDelay(noDelay: Bool): This {
        noDelay_ = noDelay
        this
    }
    public func quickAcknowledge(quickAcknowledge: Bool): This {
        quickAcknowledge_ = quickAcknowledge
        this
    }
    public func readTimeout(readTimeout: ?Duration): This {
        readTimeout_ = readTimeout
        this
    }
    public func receiveBufferSize(receiveBufferSize: Int64): This {
        receiveBufferSize_ = receiveBufferSize
        this
    }
    public func sendBufferSize(sendBufferSize: Int64): This {
        sendBufferSize_ = sendBufferSize
        this
    }
    public func writeTimeout(writeTimeout: ?Duration): This {
        writeTimeout_ = writeTimeout
        this
    }
    public func socketOption(level: Int32, option: Int32, value: CPointer<Unit>, valueLength: UIntNative): This {
        socketOption_.add((level, option, value, valueLength))
        this
    }
    public func socketOptionBool(level: Int32, option: Int32, value: Bool): This {
        socketOptionBool_.add((level, option, value))
        this
    }
    public func socketOptionIntNative(level: Int32, option: Int32, value: IntNative): This {
        socketOptionIntNative_.add((level, option, value))
        this
    }
}