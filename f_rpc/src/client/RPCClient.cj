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

import std.sync.AtomicReference
import std.collection.{ArrayList, HashSet, HashMap}
import std.collection.concurrent.ConcurrentHashMap
import std.time.MonoTime
import fountain::f_data.macros.*

public class RPCClient {
    private static let retryCount = ClientConfig.retryCount
    private static let services = ConcurrentHashMap<ServiceMeta, MultiClient<Float64, RPCMessage>>()

    static init(){
        let hosts = HashSet<String>()
        let clients = ClientConfig.createClient()
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
        }
        clients.close()
        let metas = HashMap<ServiceMeta, ArrayList<String>>()
        for(host in hosts){
            while(true){
                let client: Client
                while(true){
                    try{
                        client = Client.builder(address: address, checkDuration: Duration.second, checker: {=> Message.ping()}).build()
                        break
                    }catch(e: Exception){
                        rpclog.error("[FOUNTAIN_RPC.subscribe.hosts] ${host}", e)
                    }
                }
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
                        break
                    }
                    for(meta in array){
                        let view = metas.entryView(meta)
                        if(view.value.isNone()){
                            view.value = ArrayList<String>()
                        }
                        view.value?.add(all: array)
                    }
                    break
                }catch(e: Exception){
                    rpclog.error("[FOUNTAIN_RPC.subscribe.services] ${host}", e)
                }finally{
                    client.close()
                }
            }
        }
        for((meta, hosts) in metas){
            services[meta] = ClientConfig.createClient(hosts.toArray())
        }
    }

    public static func call<R>(message: RPCMessage): R where R <: DataFields<R> {
        var tried = 0
        var ex = None<RPCException>
        var result = LogMessage(message.params)
        let start = MonoTime.now()
        try{
            for(client in services[message.meta]){
                if(tried >= retryCount){
                    throw RPCException("retry count exceeded")
                }
                try{
                    let resp = client.transfer(Message.consume<Message>(once: true, qos: AtMostOnce, data: message)).get()
                    result.result = resp.data
                    return DataObject<R>.populate(resp.data)
                }catch(e: Exception){
                    tried++
                    errorLog(message.id, 'Stub', message.command, e)
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
        }finally{
            infoLog<LogMessage>(message.id, message.label, message.command){
                result.consumed = MonoTim.now() - start
                result
            }
        }
    }
}
@DataFields[fields]
public class LogMessage {
    public let params: Array<Data>,
    public var result: ?Data,
    public var consumed: Duration = Duration.Zero
    public init(params: Array<Data>){
        this.params = params
        this.result = None<Data>
    }
}