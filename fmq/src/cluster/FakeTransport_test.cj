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
package fountain::fmq.cluster

import std.collection.ArrayList
import std.sync.Mutex
import fountain::f_protocol.default.Message

/** 元数据/备份测试用的内存节点传输。 */
protected class FakeTransport <: MQNodeTransport {
    private let total: Int64
    private let self: Int64
    private let lock = Mutex()
    private let sent = ArrayList<(Int64, Message)>()
    private var attempts: Int64 = 0
    let available: Array<Bool>
    /** 显式标记「已知死亡」：用于验证广播跳过死节点。 */
    let knownDead: Array<Bool>
    /** 显式标记「存活」：用于验证反熵选点的分层。 */
    let alive: Array<Bool>
    /** 可选应答器：返回 `None` 表示本次调用失败。 */
    var responder: (Int64, Message) -> ?Message = {_, _ => None<Message>}

    protected init(nodeCount: Int64, selfIndex: Int64) {
        this.total = nodeCount
        this.self = selfIndex
        this.available = Array<Bool>(nodeCount, repeat: true)
        this.knownDead = Array<Bool>(nodeCount, repeat: false)
        this.alive = Array<Bool>(nodeCount, repeat: false)
    }

    public prop nodeCount: Int64 {
        get() {
            total
        }
    }

    public prop selfIndex: Int64 {
        get() {
            self
        }
    }

    public func send(index: Int64, message: Message): ?Message {
        synchronized(lock) {
            attempts++
        }
        if (index == self || index < 0 || index >= total || !available[index]) {
            return None<Message>
        }
        synchronized(lock) {
            sent.add((index, message))
        }
        responder(index, message)
    }

    public func isKnownDead(index: Int64): Bool {
        if (index < 0 || index >= total) {
            return true
        }
        knownDead[index] || !available[index]
    }

    public func isAlive(index: Int64): Bool {
        if (index < 0 || index >= total) {
            return false
        }
        alive[index]
    }

    /** 发送尝试次数（含被跳过的死节点）。 */
    func attemptCount(): Int64 {
        synchronized(lock) {
            attempts
        }
    }

    public func successors(count: Int64): Array<Int64> {
        let result = ArrayList<Int64>()
        if (count <= 0 || total <= 1) {
            return result.toArray()
        }
        let limit = if (count < total) {
            count
        } else {
            total - 1
        }
        for (i in 1..=limit) {
            result.add((self + i) % total)
        }
        result.toArray()
    }

    func messagesSentTo(index: Int64): Array<Message> {
        let result = ArrayList<Message>()
        synchronized(lock) {
            for ((target, message) in sent) {
                if (target == index) {
                    result.add(message)
                }
            }
        }
        result.toArray()
    }

    func sentCount(): Int64 {
        synchronized(lock) {
            sent.size
        }
    }

    func clear(): Unit {
        synchronized(lock) {
            sent.clear()
        }
    }
}
