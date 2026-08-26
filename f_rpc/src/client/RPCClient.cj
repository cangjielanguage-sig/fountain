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

import std.collection.{TreeSet, HashSet, HashMap}
import std.collection.concurrent.ConcurrentHashMap
import std.time.MonoTime
import fountain::f_data.macros.*
import fountain::f_log.*

public class RPCClient {
    private static let retryCount = ClientConfig.retryCount
    private static let services = ConcurrentHashMap<ServiceMeta, MultiClient<Float64>>()

    static init(){
        let metas = HashMap<ServiceMeta, TreeSet<String>>()
        func subscribe(client: Client, closingOnEnd: Bool){
            try{
                let message = Message.subscribe(data: false)
                let data = client.transfer(message).get().data
                let any = Array<ServiceMeta>.tryFromData(data)
                let array: Array<ServiceMeta> = match(any){
                    case x: Array<ServiceMeta> => x
                    case x: ?Array<ServiceMeta> => x ?? []
                    case _ => []
                }
                if(array.isEmpty()){
                    return true
                }
                for(meta in array){
                    let view = metas.entryView(meta)
                    if(view.value.isNone()){
                        view.value = TreeSet<String>()
                    }
                    view.value?.add(client.address.toString())
                }
                return true
            }catch(e: Exception){
                rpclog.error("[FOUNTAIN_RPC.subscribe.services] ${client.address}", e)
                return false
            }finally{
                if(closingOnEnd){
                    client.close()
                }
            }
        }
        let hosts = TreeSet<String>()
        let clients = ClientConfig.createClient()
        spawn{
            try{
                for(client in clients){
                    let msg = Message.subscribe(data: true)
                    let resp = client.transfer(msg).get().data
                    let any = Array<String>.tryFromData(resp)
                    let array: Array<String> = match(any){
                        case x: Array<String> => x
                        case x: ?Array<String> => x ?? []
                        case _ => []
                    }
                    hosts.add(all: array)
                    subscribe(client, false)
                }
                clients.close()
                for(host in hosts){
                    while(true){
                        var client: Client = unsafeZeroValue<Client>()
                        while(true){
                            try{
                                client = Client.builder(address: host, checkDuration: Duration.second, checker: {=> Message.ping()}).build()
                                break
                            }catch(e: Exception){
                                rpclog.error("[FOUNTAIN_RPC.subscribe.hosts] ${host}", e)
                            }
                        }
                        if(subscribe(client, true)){
                            break
                        }
                    }
                }
                for((meta, hosts) in metas){
                    if(let Some(clients) <- services.get(meta)){
                        let set = TreeSet<String>()
                        for(c in clients){
                            set.add(c.address.toString())
                        }
                        if(let hostArray <- hosts.toArray() && set.toArray() != hostArray){
                            services[meta] = ClientConfig.createClient(hostArray)
                            clients.close()//todo 此处应该先发送一个关闭通知，可以改造DEREGISTER命令，服务端等待所有任务都结束以后再返回，然后两边关闭。要为Client中的每个同服务节点的连接各发送一次
                        }
                    }else{
                        services[meta] = ClientConfig.createClient(hosts.toArray())
                    }
                }
            }catch(e: Exception){
                rpclog.warn('error on RPCClient init', e)
            }finally{
                metas.clear()
                sleep(ClientConfig.refreshIntervalSeconds)
            }
        }
        atExit{
            for((_, client) in services){
                client.close()
            }
        }
    }
    private init(){}
    public static func call<R>(message: RPCMessage): R where R <: DataFields<R> {
        var tried = 0
        var ex = None<RPCException>
        let result = LogMessage(message)
        var consume = unsafeZeroValue<Message>()
        let start = MonoTime.now()
        try{
            for(client in services[message.meta]){
                if(tried >= retryCount){
                    let exceeded = RPCException("retry count exceeded")
                    if(let Some(e) <- ex){
                        e.addSuppressed(exceeded)
                    }else{
                        ex = exceeded
                    }
                    break
                }
                consume = Message.consume<RPCMessage>(once: true, qos: AtMostOnce, data: message)
                try{
                    let resp = client.transfer(consume).get()
                    let data = resp.data
                    result.result = DataAny(data)
                    return match(resp.command){//必须明确return，否则编译器推断最后的throw才是返回值
                        case Command.RESP(b) =>
                            match(R.fromData(data)){
                                case x: R => x
                                case x: ?R => match(x){
                                    case x: R => x
                                    case x: ToData => throw RPCException("response data ${JsonValue.from(x.toData())} is not a ${TypeInfo.of<R>()}")
                                    case _ => throw RPCException("response data is not a ${TypeInfo.of<R>()}")
                                }
                                case x: ToData => throw RPCException("response data ${JsonValue.from(x.toData())} is not a ${TypeInfo.of<R>()}")
                                case _ => throw RPCException("response data is not a ${TypeInfo.of<R>()}")
                            }
                        case Command.ERROR => throw RPCException(data.toString())
                        case x => throw RPCException("unexpected command ${x}")
                    }
                }catch(e: Exception){
                    tried++
                    errorLog(consume.id, 'Stub', consume.command, message, e)
                    if(let Some(ee) <- ex){
                        ee.addSuppressed(e)
                    }else{
                        let ee = RPCException()
                        ee.addSuppressed(e)
                        ex = Some(ee)
                    }
                }
            }
            if(let Some(e) <- ex){
                throw e
            }
            throw RPCException("no client is available")
        }finally{
            infoLog<LogMessage>(consume.id, 'Stub', consume.command){
                result.consumed = MonoTime.now() - start
                result
            }
        }
    }
}
@DataAssist[fields props]
public class LogMessage {
    public let message: RPCMessage
    public var result: ?DataAny
    public var consumed: Duration = Duration.Zero
    public init(){
        this(unsafeZeroValue<RPCMessage>())
    }
    public init(message: RPCMessage){
        this.message = message
        this.result = None<DataAny>
    }
}