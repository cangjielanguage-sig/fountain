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
package fountain::fsync.server

import fountain::f_log.*
import fountain::f_net.*
import fountain::f_net.server.*
import fountain::f_protocol.default.*
import fountain::fsync.base.SyncData

public class SyncServer <: Resource {
    private static let log = LoggerFactory.getLogger('fountain::fsync.SyncServer')
    private let server: Server<Message, EncodedMessage, Message, SyncData>

    public init(bindPort: UInt16, queueSize!: Int64 = 1024,
            checkDuration!: Duration = Duration.second * 30,
            checker!: (SocketBuffer) -> Bool = { _ => true }) {
        this.server = Server<Message, EncodedMessage, Message, SyncData>(
            queueSize: queueSize,
            bindAt: bindPort,
            checkDuration: checkDuration,
            checker: checker
        )
    }

    public func start(handler: SyncHandler): Future<Unit> {
        spawn {
            try {
                server.start({ msg => handler.handle(msg) })
            } catch (e: Exception) {
                log.error('server start failed: ${e.message}')
            }
        }
    }

    public func close(): Unit {
        if (!server.isClosed()) {
            server.close()
        }
    }

    public func isClosed(): Bool {
        server.isClosed()
    }
}
