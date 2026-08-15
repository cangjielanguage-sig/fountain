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

import fountain::f_net.server.Server

private let serviceHosts = ConcurrentHashSet<String>()

private func error(id: MessageID, cmd: Command, msg: ErrorMessage): Message {
    errorLog(id, cmd, msg)
    Message.error(id, data: msg.error)
}

class RPCServer {
    internal static func start(): Unit {
        let qsize = ServerConfig.bufferQueueSize
        let port = ServerConfig.port
        let checkDuration = ServerConfig.connectionCheckDuration
        let unavailableChecked = ServerConfig.unavailableChecked
        let executors = ServerConfig.executors
        let server = Server<Data>(bufferQueueSize: qsize, bindAt: port, checkDuration: checkDuration, 
            executors: executors, checker: checker, unavailableChecked: unavailableChecked,
            defaultResp: {id => error(id, OVERFEEDING)}, limiter: rateLimiter()
        )
        server.start(executor)
        for(address in ServerConfig.baseAddresses){
            spawn{
                let client: Client
                while(true){
                    try{
                        client = Client.builder(address: address, checkDuration: Duration.second, checker: {=> Message.ping()}).build()
                        break
                    }catch(e: Exception){
                        rpclog.error('[FOUNTAIN_RPC.register.newClient] ${address}', e)
                    }
                }
                let message = Message.register(data: port.toData())
                try{
                    while(true){
                        client.transfer(message)
                        return
                    }
                }catch(e: Exception){
                    rpclog.error('[FOUNTAIN_RPC.register] ${address}', e)
                }finally{
                    client.close()
                }
            }
        }
    }
    private static func checker(): ?Message {
        Message.ping()
    }
    /**
     * REGISTER 向其它服务节点注册自身
     * ACK
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
            case Command.ACK => None<Message>
            case x => error(message.id, x, UNSUPPORTED_COMMAND)
        }
    }
}
private struct RegisterExecutor{
    RegisterExecutor(private let buffer: SocketBuffer, private let id: MessageID, private let port: UInt16){}
    func exec(): Message {
        debugLog(id, Command.REGISTER){port}
        let addr = buffer.remoteAddress.toString()
        serviceHosts.add('${addr[0 .. addr.indexOf(":").getOrThrow()]}:${port}')
        Message.ack(id, DataNone.INSTANCE)
    }
}
private struct SubscribeExecutor{
    SubscribeExecutor(private let id: MessageID, private let hosts: Bool){}
    private exec(): Message {
        let start = MonoTime.now()
        let data = if(hosts){
            let hosts = serviceHosts.iterator()
            Array<String>(serviceHosts.size){_ => hosts.next().getOrThrow()}
        }else{
            ServiceHub.metas
        }.toData()
        debugLog(id, Command.SUBSCRIBE){DebugMessage(hosts, data, MonoTime.now() - start)}
        Message.resp(id, data)
    }
}
private struct ConsumeExecutor{
    ConsumeExecutor(private let id: MessageID, private let message: RPCMessage){}
    func exec(): Message {
        var result: ToData = ()
        let start = MonoTime.now()
        try{
            result = ServiceHub.call(message)
            Message.resp(id, result)
        }catch(e: Exception){
            let buffer = ByteBuffer()
            printStackTrace(e, buffer)
            error(id, Command.CONSUME, ErrorMessage(message, buffer.bytes() |> String.fromUtf8))
        }finally{
            let consumed = MonoTime.now() - start
            infoLog(id, Command.CONSUME){LogMessage(message, result, consumed)}
        }
    }
}
@DataAssist
public class LogMessage<A, R> where A <: ToData, R <: ToData {
    public LogMessage(
        public let param: A,
        public let result: R,
        public let consumed: Duration
    ){}
}
@DataAssist
public class ErrorMessage<A> where A <: ToData {
    public ErrorMessage(
        public let param: A,
        public let error: String
    ){}
}