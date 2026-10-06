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
import std.sync.{AtomicInt64, Mutex}
import fountain::f_log.*
import fountain::f_protocol.default.*

internal class StopSignal {
    let stopped = AtomicInt64(0)
}

public class SocketBuffer <: IOStream & Resource {
    private static let log = LoggerFactory.getLogger('fountain::f_net.SocketBuffer')
    private let queueSize: Int64
    private let queue: ArrayBlockingQueue<() -> Unit>
    private let socket: TcpSocket
    private let stop = StopSignal()
    /**
     * 整帧写出的互斥（见 .autocode/bugs/bug-archived-on-20261004.md 7.1）：`close()` 先等正在写的那一帧退场再关 socket，
     * 这样正常关闭时序下对端看到的是「完整帧 + EOF」，而不是**半帧**。
     */
    private let frameLock = Mutex()
    private let frameDone = synchronized(frameLock){ frameLock.condition() }
    private var writingFrame = false

    SocketBuffer(queueSize: Int64, socket: TcpSocket) {
        this.queueSize = queueSize
        this.socket = socket
        let queue = ArrayBlockingQueue<() -> Unit>(queueSize)
        this.queue = queue
        let stop = this.stop
        spawn {
            while (stop.stopped.load() == 0) {
                if(let Some(fn) <- queue.remove(Duration.millisecond * 50)){
                    beginFrame()
                    try {
                        fn()
                    } catch (e: Exception) {
                        log.warn('SocketBuffer write error', e)
                    } finally {
                        endFrame()
                    }
                }
            }
        }
    }
    func clone(): SocketBuffer{
        let socket = TcpSocket(socket.remoteAddress)
        socket.connect()
        SocketBuffer(queueSize, socket)
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
        let s = socket.read(bytes)
        s
    }
    public func write(bytes: Array<Byte>): Unit {
        socket.write(bytes)
    }
    public func flush(): Unit {
        socket.flush()
    }
    public func close(): Unit {
        stop.stopped.store(1)
        // 先等在写的那一帧退场，再关 socket：对端应看到「完整帧 + EOF」而不是半帧（.autocode/bugs/bug-archived-on-20261004.md 7.1）
        awaitFrameWrite()
        if(!socket.isClosed()){
            socket.close()
        }
    }
    /** `close()` 愿意等一帧写完的上限：超过就照关 —— 不把“截断”换成“挂起”（见 .autocode/bugs/bug-archived-on-20261004.md 7.1）。 */
    private static let FRAME_CLOSE_WAIT = Duration.second * 2
    /**
     * 等正在写的那一帧退场。写帧本身受 socket 写超时约束（`socketWriteTimeout`，默认未设置），
     * 这里再兜一层上限：真等不到就记 WARN 后照关，避免把「对端看到半帧」换成「close 挂死」。
     */
    private func awaitFrameWrite(): Unit {
        synchronized(frameLock) {
            var waited = Duration.Zero
            while (writingFrame) {
                if (!frameDone.wait(timeout: Duration.millisecond * 10)) {
                    waited += Duration.millisecond * 10
                    if (waited >= FRAME_CLOSE_WAIT) {
                        log.warn('close: a frame is still being written after ${FRAME_CLOSE_WAIT}, closing anyway')
                        break
                    }
                }
            }
        }
    }
    private func beginFrame(): Unit {
        synchronized(frameLock) {
            writingFrame = true
        }
    }
    private func endFrame(): Unit {
        synchronized(frameLock) {
            writingFrame = false
            frameDone.notifyAll()
        }
    }
    private func isStopped(): Bool {
        stop.stopped.load() == 1
    }
    public func isClosed(): Bool {
        if(isStopped() && !socket.isClosed()){
            // 与 close() 同样的纪律：懒关闭也要先等在写的那一帧退场（有上限）
            awaitFrameWrite()
            socket.close()
            true
        }else if(!isStopped() && socket.isClosed()){
            stop.stopped.store(1)
            true
        }else{
            isStopped() && socket.isClosed()
        }
    }
    public prop remoteAddress: SocketAddress {
        get(){
            socket.remoteAddress
        }
    }
}
