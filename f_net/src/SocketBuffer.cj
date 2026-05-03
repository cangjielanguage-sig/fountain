/*
Copyright (c) 2025 WuJingrun（吴京润）

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
package fountain::f_net

import std.io.InputStream
import std.sync.AtomicInt64

internal class StopSignal {
    let stopped = AtomicInt64(0)
}

public struct SocketBuffer <: Resource {
    let buffered: BufferedInputStream<TcpSocket>
    let queue: ArrayBlockingQueue<() -> Unit>
    let socket: TcpSocket
    private let stop = StopSignal()

    SocketBuffer(queueSize: Int64, socket: TcpSocket) {
        this.socket = socket
        buffered = BufferedInputStream<TcpSocket>(socket)
        let queue = ArrayBlockingQueue<() -> Unit>(queueSize)
        this.queue = queue
        let stop = this.stop
        spawn {
            while (stop.stopped.load() == 0) {
                if (let Some(fn) <- queue.remove(Duration.millisecond * 50)) {
                    fn()
                }
            }
        }
    }

    public func close(): Unit {
        stop.stopped.store(1)
        if (!socket.isClosed()) {
            socket.close()
        }
        buffered.close()
    }

    public func isClosed(): Bool {
        stop.stopped.load() == 1
    }
}
