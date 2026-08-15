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
package fountain::fleet.client

public struct Fleet {
    private init(){}
    private static let clients = {
        =>
            let hosts = FleetConfig.hosts
            Array<Client>(hosts.size) {
                i =>
                    Client
                        .builder(address: hosts[i], checkDuration: Duration.second, checker: {=> Message.ping()})
                        .build()
            }
    }()
    private static func confirmClient(path: String): Client {
        clients[path.hashCode() % clients.size]
    }
    public static func get<T>(path: String): ?T where T <: DataFields<T> {
        let resp = confirmClient(path).transfer(Message.consume(once: true, qos: QoS.AtMostOnce, data: path)).get()
        match (resp.command) {
            case Command.RESP(_) =>
                let data = DataObject<FleetDataMessage>.populate(resp.data).getOrThrow().data
                if (let Some(x) <- data) {
                    DefaultCodec().decode<T>(ByteBuffer(x))
                } else {
                    None<T>
                }
            case _ => throw FleetClientException("unexpected response command: ${resp.command}")
        }
    }
    public static func set<T>(path: String, data: T, expireAt: ?DateTime): Unit where T <: DataFields<T> {
        let buf = ByteBuffer()
        DefaultCodec().encode(data).finish().copy(to: buf, closeFromOnEnd: true, closeToOnEnd: false)
        let bytes = buf.bytes()
        let message = FleetDataMessage(path, bytes, expireAt)
        confirmClient(path).transfer(Message.register(data: message))
    }
    public static func set<T>(path: String, data: T): Unit where T <: DataFields<T> {
        set(path, data, None)
    }
    public static func set<T>(path: String, data: T, expire!: Duration = Duration.Zero): Unit where T <: DataFields<T> {
        set(path, data, if (expire <= Duration.Zero) {
            None
        } else {
            DateTime.now() + expire
        })
    }
    public static func remove(path: String): Unit {
        confirmClient(path).transfer(Message.deregister(data: path))
    }
    public static func listen(path: String, executor: (Message) -> Unit): ListeningFleet {
        let message = Message.subscribe(data: path)
        let listening = confirmClient(path).transfer<FleetDataMessage>(message, executor)
        ListeningFleet(path, message.id, listening)
    }
    static func cancel(path: String, id: MessageID): Unit {
        confirmClient(path).transfer(Message.unsubscribe(id))
    }
}
