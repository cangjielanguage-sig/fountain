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
package fountain::f_rpc.server

private let serviceHosts = ConcurrentHashSet<String>()
private func error(id: MessageID, message: String): Message {
    Message.error(id, data: message)
}
class Server {
    internal static func start(): Unit {
        let qsize = ServerConfig.bufferQueueSize
        let port = ServerConfig.port
        let checkDuration = ServerConfig.connectionCheckDuration
        let server = Server<Array<Byte>>(queueSize: qsize, bindAt: port, checkDuration: checkDuration, checker: checker,
            defaultResp: {id => error(id, OVERFEEDING)}, limiter: rateLimiter()
        )
        for(address in ServerConfig.baseAddresses){
            spawn{
                let client: Client<UInt16>
                while(true){
                    try{
                        client = Client<UInt16>.builder(address: address, checkDuration: Duration.second, checker: {=> Message.pint()}).build()
                        break
                    }catch(_){}
                }
                let message = Message.register(data: port)
                try{
                    while(true){
                        client.transfer(message)
                        return
                    }
                }catch(_){}finally{
                    client.close()
                }
            }
        }
        server.start(executor)
    }
    private static func checker(): ?Message {
        Message.ping()
    }
    /**
     * REGISTER 向其它服务节点注册自身
     * ACK
     * PING 向其它服务节点发送心跳
     * SUBSCRIBE 获取服务节点能够提供的服务
     * CONSUME 向服务节点发起RPC调用
     * RESP 服务节点返回调用结果或当前服务节点能够提供的服务
     */
    private static func executor(buffer: SocketBuffer, message: Message): ?Message {
        let cmd = message.command
        match(message.command){
            case Command.REGISTER => RegisterExecutor(buffer, message.id, message.tryFromData<UInt16>() ?? 0).exec()
            case Command.SUBSCRIBE => SubscribeExecutor(message.id, message.tryFromData<Bool>() ?? false).exec()
            case Command.CONSUME => ConsumeExecutor(buffer, message.id, message.tryFromData<RPCMessage>().getOrThrow()).exec()
            case Command.PING(_) => Message.ack(message.id)
            case Command.ACK => None<Message>
            case _ => error(message.id, UNSUPPORTED_COMMAND)
        }
    }
}
private struct RegisterExecutor{
    RegisterExecutor(private let buffer: SocketBuffer, private let id: MessageID, private let port: UInt16){}
    func exec(): Message {
        let addr = buffer.remoteAddress.toString()
        serviceHosts.add('${addr[0 .. addr.indexOf(":").getOrThrow()]}:${port}')
        Message.ack(id, DataNone.INSTANCE)
    }
}
private struct SubscribeExecutor{
    SubscribeExecutor(private let id: MessageID, private let hosts: Bool){}
    private exec(): Message {
        Message.resp(id, if(hosts){
            let hosts = serviceHosts.iterator()
            Array<String>(serviceHosts.size){_ => hosts.next().getOrThrow()}.toData()
        }else{
            ServiceHub.meats.toData()
        })
    }
}
private struct ConsumeExecutor{
    ConsumeExecutor(private let id: MessageID, private let message: RPCMessage){}
    func exec(): Message {
        try{
            Message.resp(id, ServiceHub.call(message))
        }catch(e: Exception){
            let buffer = ByteBuffer()
            printStackTrace(e, buffer)
            error(id, String.fromUtf8(buffer.bytes()))
        }
    }
}