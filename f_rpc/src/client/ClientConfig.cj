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
package fountain::f_rpc.client

import std.convert.*
import fountain::f_concurrent.exception.LoadBalanceException

class ClientConfig {
    private static const RPC_CLIENT_PREFIX = 'rpcClient'
    private static const RPC_SERVER_ADDRESS = RPC_CLIENT_PREFIX + '_serverAddress'
    private static const RPC_CLIENT_LOADBALANCE = RPC_CLIENT_PREFIX + '_loadbalance'
    private static const RPC_CLIENT_QUEUE_SIZE = RPC_CLIENT_PREFIX + '_queueSize'
    private static const RPC_CLIENT_SOCKET_COUNT = RPC_CLIENT_PREFIX + '_socketCount'
    private static const RPC_CLIENT_CHECK_DURATION = RPC_CLIENT_PREFIX + '_checkDuration'
    private static const RPC_CLIENT_BIND_TO_DEVICE = RPC_CLIENT_PREFIX + '_bindToDevice'
    private static const RPC_CLIENT_SOCKET_KEEPALIVE_COUNT = RPC_CLIENT_PREFIX + '_socketKeepaliveConfig_count'
    private static const RPC_CLIENT_SOCKET_KEEPALIVE_IDLE = RPC_CLIENT_PREFIX + '_socketKeepaliveConfig_idle'
    private static const RPC_CLIENT_SOCKET_KEEPALIVE_INTERVAL = RPC_CLIENT_PREFIX + '_socketKeepaliveConfig_interval'
    private static const RPC_CLIENT_LINGER = RPC_CLIENT_PREFIX + '_linger'
    private static const RPC_CLIENT_NO_DELAY = RPC_CLIENT_PREFIX + '_noDelay'
    private static const RPC_CLIENT_QUICK_ACKNOWLEDGE = RPC_CLIENT_PREFIX + '_acknowledge'
    private static const RPC_CLIENT_READTIMEOUT = RPC_CLIENT_PREFIX + '_readTimeout'
    private static const RPC_CLIENT_RECEIVE_BUFFER_SIZE = RPC_CLIENT_PREFIX + '_receiveBufferSize'
    private static const RPC_CLIENT_SEND_BUFFER_SIZE = RPC_CLIENT_PREFIX + '_sendBufferSize'
    private static const RPC_CLIENT_WRITE_TIMEOUT = RPC_CLIENT_PREFIX + '_writeTimeout'
    private static const RPC_CLIENT_SOCKET_OPTION_BOOL = RPC_CLIENT_PREFIX + '_socketOptionBool'
    private static const RPC_CLIENT_SOCKET_OPTION_INT = RPC_CLIENT_PREFIX + '_socketOptionInt'
    private static const RPC_CLIENT_PING_TIMEOUT = RPC_CLIENT_PREFIX + '_pingTimeout'
    private static const RPC_CLIENT_RETRY_COUNT = RPC_CLIENT_PREFIX + '_retryCount'
    private static const RPC_CURRENT_SKELETON = 'rpc_currentSkeleton'

    public static prop currentSkeleton: String {
        get(){
            Config.getString(RPC_CURRENT_SKELETON) ?? ''
        }
    }
    private static prop serverAddresses: Array<(Float64, String)> {
        get(){
            let array = Config.getStringArray(RPC_SERVER_ADDRESS, delim: '|')
            Array<(Float64, String)>(array.size){i => 
                let addr = array[i]
                let arr = addr.split(',')
                (Float64.parse(arr[0]), arr[1])
            }
        }
    }
    private static prop loadbalance: String {
        get(){
            Config.getString(RPC_CLIENT_LOADBALANCE)?.toAsciiLower() ?? 'random'
        }
    }
    private static prop queueSize: ?Int64 {
        get(){
            Config.getValue<Int64>(RPC_CLIENT_QUEUE_SIZE)
        }
    }
    private static prop socketCount: ?Int64 {
        get(){
            Config.getValue<Int64>(RPC_CLIENT_SOCKET_COUNT)
        }
    }
    private static prop checkDuration: Duration {
        get(){
            Config.getDuration(RPC_CLIENT_CHECK_DURATION) ?? Duration.second
        }
    }
    private static prop bindToDevice: ?String {
        get(){
            Config.getString(RPC_CLIENT_BIND_TO_DEVICE)
        }
    }
    private static prop socketKeepaliveConfig: ?SocketKeepAliveConfig {
        get(){
            let count = Config.getValue<UInt32>(RPC_CLIENT_SOCKET_KEEPALIVE_COUNT)
            let idle = Config.getDuration(RPC_CLIENT_SOCKET_KEEPALIVE_IDLE)
            let interval = Config.getDuration(RPC_CLIENT_SOCKET_KEEPALIVE_INTERVAL)
            match((count, idle, interval)){
                case (Some(c), Some(id), Some(inter)) => SocketKeepAliveConfig(count: c, idle: id, interval: inter)
                case (Some(c), Some(id), _) => SocketKeepAliveConfig(count: c, idle: id)
                case (Some(c), _, Some(inter)) => SocketKeepAliveConfig(count: c, interval: inter)
                case (_, Some(id), Some(inter)) => SocketKeepAliveConfig(idle: id, interval: inter)
                case (Some(c), _, _) => SocketKeepAliveConfig(count: c)
                case (_, Some(id), _) => SocketKeepAliveConfig(idle: id)
                case (_, _, Some(inter)) => SocketKeepAliveConfig(interval: inter)
                case _ => None
            }
        }
    }
    private static prop linger: ?Duration {
        get(){
            Config.getDuration(RPC_CLIENT_LINGER)
        }
    }
    private static prop noDelay: ?Bool {
        get(){
            Config.getValue<Bool>(RPC_CLIENT_NO_DELAY)
        }
    }
    private static prop quickAcknowledge: ?Bool {
        get(){
            Config.getValue<Bool>(RPC_CLIENT_QUICK_ACKNOWLEDGE)
        }
    }
    private static prop readTimeout: ?Duration {
        get(){
            Config.getDuration(RPC_CLIENT_READTIMEOUT)
        }
    }
    private static prop receiveBufferSize: ?Int64 {
        get(){
            Config.getValue<Int64>(RPC_CLIENT_RECEIVE_BUFFER_SIZE)
        }
    }
    private static prop sendBufferSize: ?Int64 {
        get(){
            Config.getValue<Int64>(RPC_CLIENT_SEND_BUFFER_SIZE)
        }
    }
    private static prop writeTimeout: ?Duration {
        get(){
            Config.getDuration(RPC_CLIENT_WRITE_TIMEOUT)
        }
    }
    private static prop socketOptionBool: ?(Int32, Int32, Bool) {
        get(){
            let option = Config.getString(RPC_CLIENT_SOCKET_OPTION_BOOL)
            if(let Some(opt) <- option && let arr <- opt.split(',')){
                (Int32.parse(arr[0]), Int32.parse(arr[1]), Bool.parse(arr[2]))
            }else{
                None
            }
        }
    }
    private static prop socketOptionInt: ?(Int32, Int32, IntNative) {
        get(){
            let option = Config.getString(RPC_CLIENT_SOCKET_OPTION_INT)
            if(let Some(opt) <- option && let arr <- opt.split(',')){
                (Int32.parse(arr[0]), Int32.parse(arr[1]), IntNative(Int64.parse(arr[2])))
            }else{
                None
            }
        }
    }
    private static prop pingTimeout: ?Duration {
        get(){
            Config.getDuration(RPC_CLIENT_PING_TIMEOUT)
        }
    }
    internal static prop retryCount: Int64 {
        get(){
            Config.getValue<Int64>(RPC_CLIENT_RETRY_COUNT) ?? 0
        }
    }
    private  static func createClient(addresses: Array<(Float64, String)>): MultiClient<Float64>{
        func checker(){
            Message.ping()
        }
        let builder = if(let (Some(qs), Some(sc)) <- (queueSize, socketCount)){
            MultiClient<Float64>.builder(queueSize: qs, socketCount: sc, checkDuration: checkDuration, checker: checker)
        }else if(let (Some(qs), _) <- (queueSize, socketCount)){
            MultiClient<Float64>.builder(queueSize: qs, checkDuration: checkDuration, checker: checker)
        }else if(let (_, Some(sc)) <- (queueSize, socketCount)){
            MultiClient<Float64>.builder(socketCount: sc, checkDuration: checkDuration, checker: checker)
        }else{
            MultiClient<Float64>.builder(checkDuration: checkDuration, checker: checker)
        }
        builder.bindToDevice(bindToDevice)
        builder.socketKeepaliveConfig(socketKeepaliveConfig)
        builder.linger(linger)
        if(let Some(nd) <- noDelay){
            builder.noDelay(nd)
        }
        if(let Some(qack) <- quickAcknowledge){
            builder.quickAcknowledge(qack)
        }
        builder.readTimeout(readTimeout)
        builder.receiveBufferSize(receiveBufferSize)
        builder.sendBufferSize(sendBufferSize)
        builder.writeTimeout(writeTimeout)
        if(let Some((l, o, v)) <- socketOptionBool){
            builder.socketOptionBool(l, o, v)
        }
        if(let Some((l, o, v)) <- socketOptionInt){
            builder.socketOptionInt(l, o, v)
        }
        if(let Some(pt) <- pingTimeout){
            builder.pingTimeout(pt)
        }
        var min = 0.0f64
        var max = 0.0f64
        for((w, _) in addresses){
            if(min > w){
                min = w
            }
            if(max < w){
                max = w
            }
        }
        match(loadbalance){
            case 'random' => builder.random(min, max)
            case 'roundrobin' => builder.roundRobin(1, min, max)
            case x => throw LoadBalanceException("unsupported loadbalance algorithm: ${x}")
        }
        builder.add(addresses)
        builder.build()
    }
    internal static func createClient(hosts: Array<String>): MultiClient<Float64> {
        createClient(Array<(Float64, String)>(hosts.size){i => (1.0f64, hosts[i])})
    }

    internal static func createClient(): MultiClient<Float64> {
        createClient(serverAddresses)
    }
}
