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
    private static func executor(buffer: SocketBuffer, message: Message): Message {
        let cmd = message.command
        match(message.command){
            case Command.REGISTER => FleetServerRegister(buffer, message.id, message.data).exec()
            case Command.DEREGISTER => FleetServerDeregister(buffer, message.id, message.data).exec()
            case Command.SUBSCRIBE => FleetServerSubscribe(buffer, message.id, message.data).exec()
            case Command.UNSUBSCRIBE => FleetServerUnsubscribe(message.id).exec()
            case Command.CONSUME(tag) => FleetServerConsume(buffer, message.id, message.data, tag).exec()
            case _ => error(message.id, 'UNSUPPORTED Command')
        }
    }
    private static func error(id: MessageID, message: String): Message {
        Message.error(id, data: message)
    }
}