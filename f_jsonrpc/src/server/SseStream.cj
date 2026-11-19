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
package fountain::f_jsonrpc.server

import std.collection.*
import std.io.InputStream
import std.sync.*
import std.time.*

/**
 * SSE 帧流：`SseHub` 往队列里写，`f_mvc` 从 `read` 拉——一个不会主动结束的 `InputStream`。
 *
 * 契约与 `std.io` 一致：`read` 返回 **0** 表示结束，且只有 `close()` 之后才会返回 0。
 */
public class SseStream <: InputStream {
    private let mutex = Mutex()
    private let available: Condition
    private let capacity: Int64
    private let heartbeat: Duration
    /** 待发帧（FIFO）；`head` 之前的槽位是已消费的，定期压缩 */
    private let frames = ArrayList<String>()
    private var head: Int64 = 0
    private var current: String = ''
    private var offset: Int64 = 0
    private var closed: Bool = false
    private var dropReported: Bool = false

    public init(capacity!: Int64 = 256, heartbeat!: Duration = Duration.second * 15) {
        this.capacity = if (capacity > 0) {
            capacity
        } else {
            1
        }
        this.heartbeat = heartbeat
        this.available = synchronized(mutex) {
            mutex.condition()
        }
    }

    /** 入队一帧；满了丢最旧的（慢消费者不该把发布方拖住）。返回 false 表示本次发生了丢弃 */
    public func push(frame: String): Bool {
        synchronized(mutex) {
            if (closed) {
                return true
            }
            let pendingCount = Int64(frames.size) - head
            if (pendingCount >= capacity) {
                head++
                dropReported = true
                compact()
            }
            frames.add(frame)
            available.notifyAll()
            pendingCount < capacity
        }
    }

    /** 是否丢过帧（只用来打一次 warn） */
    public prop dropped: Bool {
        get() {
            synchronized(mutex) {
                dropReported
            }
        }
    }

    public prop isClosed: Bool {
        get() {
            synchronized(mutex) {
                closed
            }
        }
    }

    public func read(buffer: Array<Byte>): Int64 {
        if (buffer.size == 0) {
            return 0
        }
        if (offset >= Int64(current.size)) {
            match (nextFrame()) {
                case Some(frame) => current = frame
                case None => return 0
            }
            offset = 0
        }
        var written: Int64 = 0
        while (written < Int64(buffer.size) && offset < Int64(current.size)) {
            buffer[written] = current[offset]
            written++
            offset++
        }
        written
    }

    /** 取下一帧：空则等一个心跳周期，超时给一行注释帧（防止中间代理断连） */
    private func nextFrame(): ?String {
        synchronized(mutex) {
            while (head >= Int64(frames.size)) {
                if (closed) {
                    return None
                }
                available.wait(timeout: heartbeat)
                if (head >= Int64(frames.size)) {
                    if (closed) {
                        return None
                    }
                    return Some(PING)
                }
            }
            let frame = frames[head]
            head++
            compact()
            Some(frame)
        }
    }

    /** 已消费的槽位过多时重建列表，避免长期运行下的内存膨胀 */
    private func compact(): Unit {
        if (head >= 64 && head * 2 >= Int64(frames.size)) {
            let kept = ArrayList<String>()
            for (index in head..frames.size) {
                kept.add(frames[index])
            }
            frames.clear()
            for (frame in kept) {
                frames.add(frame)
            }
            head = 0
        }
    }

    public func close(): Unit {
        synchronized(mutex) {
            closed = true
            available.notifyAll()
        }
    }

    private static let PING: String = ': ping\n\n'
}
