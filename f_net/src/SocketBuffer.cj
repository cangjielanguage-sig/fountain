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

import std.io.{IOStream, BufferedInputStream}
import std.sync.AtomicInt64
import fountain::f_log.*
import fountain::f_protocol.default.*

internal class StopSignal {
    let stopped = AtomicInt64(0)
}

public class SocketBuffer <: IOStream & Resource {
    private static let log = LoggerFactory.getLogger('fountain::f_net.SocketBuffer')
    private let queue: ArrayBlockingQueue<() -> Unit>
    private let socket: TcpSocket
    private let stop = StopSignal()

    SocketBuffer(queueSize: Int64, socket: TcpSocket) {
        this.socket = socket
        let queue = ArrayBlockingQueue<() -> Unit>(queueSize)
        this.queue = queue
        let stop = this.stop
        spawn {
            while (stop.stopped.load() == 0 && let Some(fn) <- queue.remove(Duration.millisecond * 50)) {
                try {
                    fn()
                } catch (e: Exception) {
                    log.warn('SocketBuffer write error', e)
                }
            }
        }
    }
    public prop localAddress: SocketAddress{
        get(){
            socket.localAddress
        }
    }
    public func transfer(message: Message): Unit {
        queue.add({=> 
            message.encode().copy(to: this, closeToOnEnd: false)
            flush()
        })
    }
    public func read(bytes: Array<Byte>): Int64 {
        return socket.read(bytes)
    }
    public func write(bytes: Array<Byte>): Unit {
        socket.write(bytes)
    }
    public func flush(): Unit {
        socket.flush()
    }
    public func close(): Unit {
        stop.stopped.store(1)
        if(!socket.isClosed()){
            socket.close()
        }
    }
    private func isStopped(): Bool {
        stop.stopped.load() == 1
    }
    public func isClosed(): Bool {
        if(isStopped() && !socket.isClosed()){
            socket.close()
            true
        }else if(!isStopped() && socket.isClosed()){
            stop.stopped.store(1)
            true
        }else{
            isStopped() && socket.isClosed()
        }
    }
}
