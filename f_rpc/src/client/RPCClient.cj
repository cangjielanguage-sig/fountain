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

import std.collection.{TreeSet, HashSet, HashMap, TreeMap}
import std.collection.concurrent.ConcurrentHashMap
import std.sync.AtomicInt8
import std.time.MonoTime
import fountain::f_data.macros.*
import fountain::f_log.*

public class RPCClient {
    private static let retryCount = ClientConfig.retryCount
    private static let services = ConcurrentHashMap<ServiceMeta, MultiClient<Float64, RPCMessage>>()
    private static let started = AtomicInt8(0)
    static func start(): Unit {
        if (started.load() == 2) {
            return
        } else if (started.compareAndSwap(0, 1)) {
            spawn{
                while(true){
                    // 每轮重新建立“发现用”连接：上一轮末尾会 close() 掉它们，
                    // 若在循环外只建一次，第二轮起 transfer 会抛 "Client is closed"，发现流程整体中断（bug.md 7.10）
                    let clients = ClientConfig.createClient()
                    let metas = HashMap<ServiceMeta, TreeSet<String>>()
                    func subscribe(client: Client<RPCMessage>, closingOnEnd: Bool){
                        try{
                            let message = Message.subscribe(data: RPCMessage.subscribe(false))
                            rpclog.debug{'[RPCClient.init.diag] subscribe request sent id=${message.id} to ${client.address}'}
                            let data = client.transfer(message).get().data
                            rpclog.debug{'[RPCClient.init.diag] subscribe response received from ${client.address}'}
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
                    let hostMap = TreeMap<String, Float64>()
                    try{
                        for(client in clients){
                            // 载荷必须是 RPCMessage：服务端会 tryFromData<RPCMessage>() 后取 params[0]，
                            // 传裸 Bool 会被宽松转成“params 为空的 RPCMessage”⇒ 服务端取 params[0] 越界（见 bug.md 7.10）
                            let msg = Message.subscribe(data: RPCMessage.subscribe(true))
                            rpclog.debug{'[RPCClient.init.diag] hosts request sent id=${msg.id} to ${client.address}'}
                            let response = client.transfer(msg).get()
                            rpclog.debug{'[RPCClient.init.diag] hosts response received from ${client.address}, command=${response.command}, id=${response.id}'}
                            let resp = response.data
                            let any = Array<String>.tryFromData(resp)
                            let array: Array<String> = match(any){
                                case x: Array<String> => x
                                case x: ?Array<String> => x ?? []
                                case _ => []
                            }
                            for(h in array){
                                let idx = h.indexOf(',').getOrThrow()
                                let host = h[0 .. idx]
                                let weight = Float64.parse(h[idx + 1 ..])
                                hostMap.add(host, weight)
                            }
                            let ok = subscribe(client, false)
                            rpclog.debug{'[RPCClient.init.diag] services subscribe ok=${ok}, metas=${metas.size}'}
                        }
                        rpclog.debug{'[RPCClient.init.diag] hostMap=${hostMap.size}, closing initial clients'}
                        clients.close()
                        rpclog.debug{'[RPCClient.init.diag] initial clients closed, building per-host clients'}
                        for((host, weight) in hostMap){
                            while(true){
                                var client: Client<RPCMessage> = unsafeZeroValue<Client<RPCMessage>>()
                                while(true){
                                    try{
                                        client = Client<RPCMessage>.builder(address: host, checkDuration: Duration.second, checker: checker).build()
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
                        for((meta, hostSet) in metas){
                            let hostIterator = hostSet.iterator()
                            let hosts = Array<(Float64, String)>(hostSet.size){i =>
                                let host = hostIterator.next().getOrThrow()
                                let weight = if(meta.weight != 1.0){
                                    meta.weight
                                }else{
                                    // 服务节点可能没有上报该主机权重（键不存在时下标取值会抛 NoneValueException），缺省按 1.0
                                    hostMap.get(host) ?? 1.0
                                }
                                (weight, host)
                            }
                            if(let Some(clients) <- services.get(meta)){
                                let set = TreeSet<String>()
                                for(c in clients){
                                    set.add(c.address.toString())
                                }
                                if(let hostArray <- hostSet.toArray() && set.toArray() != hostArray){
                                    services[meta] = ClientConfig.createClient(hosts)
                                    clients.close()
                                }
                            }else{
                                services[meta] = ClientConfig.createClient(hosts)
                            }
                        }
                    }catch(e: Exception){
                        rpclog.warn('error on RPCClient init', e)
                    }finally{
                        sleep(ClientConfig.refreshIntervalSeconds)
                    }
                }
            }
            ExitCallbacks.atExit(252){
                for((_, client) in services where !client.isClosed()){
                    client.close()
                }
            }
            started.store(2)
        }else{
            while(started.load() != 2){}
        }
    }
    private init(){}
    /**
     * 取某个服务对应的客户端集合。服务发现由 start() 的后台线程异步完成，首个调用可能早于发现完成；
     * 直接写 services[meta] 在键不存在时会抛 NoneValueException（既无法重试也说不清原因），
     * 这里改成在 discoveryTimeout 内等待，超时则明确报出服务名。
     */
    private static func availableClients(meta: ServiceMeta): MultiClient<Float64, RPCMessage> {
        let timeout = ClientConfig.discoveryTimeout
        let deadline = MonoTime.now() + timeout
        while(true){
            if(let Some(clients) <- services.get(meta)){
                return clients
            }
            if(MonoTime.now() >= deadline){
                break
            }
            sleep(Duration.millisecond * 20)
        }
        throw RPCException("no available client for ${meta.typeName}.${meta.methodName}(version ${meta.version}) after ${timeout}, check that the service node is started and registered")
    }
    public static func call<R>(message: RPCMessage): R where R <: DataFields<R> {
        start()
        var tried = 0
        var ex = None<RPCException>
        let result = LogMessage(message)
        // 不能用 unsafeZeroValue<Message>()：它的id是零值，一旦调用在发出消息前就失败，
        // finally里的日志会格式化零值MessageID（DateTime未初始化）而段错误
        var consume = None<Message>
        let start = MonoTime.now()
        try{
            for(client in availableClients(message.meta)){
                // retryCount 是“重试次数”，must allow tried==0（首次尝试）；
                // 原来写 tried >= retryCount，默认 retryCount=0 时首次尝试就被判为超出重试，调用永远发不出去
                if(tried > retryCount){
                    let exceeded = RPCException("retry count exceeded")
                    if(let Some(e) <- ex){
                        e.addSuppressed(exceeded)
                    }else{
                        ex = exceeded
                    }
                    break
                }
                let sending = Message.consume<RPCMessage>(once: true, qos: AtMostOnce, data: message)
                consume = Some(sending)
                try{
                    let resp = client.transfer(sending).get()
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
                    errorLog(sending.id, 'Stub', sending.command, message, e)
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
            // 只有真的发出过消息才有消息id可记
            if(let Some(c) <- consume){
                infoLog<LogMessage>(c.id, 'Stub', c.command){
                    result.consumed = MonoTime.now() - start
                    result
                }
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