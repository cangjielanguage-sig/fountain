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
package fountain::f_net.client

import std.sync.AtomicBool

public class ListeningClient<T> <: Resource where T <: DataFields<T> {
    private static let log = LoggerFactory.getLogger('fountain::f_net.client.ListeningClient')
    private let closed = AtomicBool(false)
    private var timer: Timer = ZERO_TIMER
    private let future: Future<Unit> 
    ListeningClient(
        private let buffer: AtomicReference<SocketBuffer>,
        private var client: Client<T>,
        private let message: Message,
        private let executor: (Message) -> Unit
    ){
        client.transfer(buffer.load(), message, once: false)
        this.future = spawn{
            while(!Thread.currentThread.hasPendingCancellation && let m <- Message.decode<T>(buffer.load())){
                spawn{executor(m)}
            }
        }
    }
    init(buffer: SocketBuffer, client: Client<T>, message: Message, executor: (Message) -> Unit){
        this(AtomicReference(buffer), client, message, executor)
    }
    public func isClosed(): Bool {
        closed.load()
    }
    public func close(): Unit {
        if (!closed.compareAndSwap(false, true)) {
            return
        }
        timer.cancel()
        future.cancel()
        buffer.load().close()
    }
}