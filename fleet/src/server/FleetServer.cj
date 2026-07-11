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
package fountain::fleet.server

internal struct FleetServer {
    internal static func start(): Unit {
        let qsize = FleetServerConfig.bufferQueueSize
        let port = FleetServerConfig.port
        let checkDuration = FleetServerConfig.connectionCheckDuration
        let server = Server<Array<Byte>>(queueSize: qsize, bindAt: port, checkDuration: checkDuration, checker: checker)
        server.start(executor)
    }
    private static func checker(): ?Message {
        Message.ping()
    }
    private static func executor(message: Message): Message {
        let cmd = message.command
        match(message.command){
            case Command.REGISTER => register(message.id, message.data)
            case Command.DEREGISTER => deregister(message.id, message.data)
            case Command.SUBSCRIBE => subscribe(message.id, message.data)
            case Command.UNSUBSCRIBE => unsubscribe(message.id, message.data)
            case Command.CONSUME(tag) => consume(message.id, message.data, tag)
            case _ => error(message.id)
        }
    }
    private static func register(id: MessageID, data: Data): Message {
        // 注册数据
        unsafeZeroValue<Message>()
    }
    private static func deregister(id: MessageID, data: Data): Message {
        // 注销数据
        unsafeZeroValue<Message>()
    }
    private static func subscribe(id: MessageID, data: Data): Message {
        // 订阅数据 数据有变化时主动发送消息，订阅时返回ACK，数据变化时返回RESP
        unsafeZeroValue<Message>()
    }
    private static func unsubscribe(id: MessageID, data: Data): Message {
        // 取消订阅
        unsafeZeroValue<Message>()
    }
    private static func consume(id: MessageID, data: Data, tag: Byte): Message {
        // TODO 应当返回RESP
        unsafeZeroValue<Message>()
    }
    private static func error(id: MessageID): Message {
        Message.error(id)
    }
}