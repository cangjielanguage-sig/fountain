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
package fountain::f_email.imap

import std.collection.ArrayList
import std.sync.{Condition, Mutex}
import std.time.MonoTime
import fountain::f_email.model.{IoStage, MailIoException, MailProtocolException}
import fountain::f_email.transport.LineChannel

/** IDLE 期间服务器推来的事件类别。 */
public enum ImapEventKind <: ToString {
    | Exists
    | Expunge
    | Recent
    | Fetch
    | Vanished
    | Flags
    /** 服务器发了 `* BYE`：此后 `nextEvent` 抛异常。 */
    | Bye
    | Other

    public func toString(): String {
        match (this) {
            case Exists => "EXISTS"
            case Expunge => "EXPUNGE"
            case Recent => "RECENT"
            case Fetch => "FETCH"
            case Vanished => "VANISHED"
            case Flags => "FLAGS"
            case Bye => "BYE"
            case Other => "OTHER"
        }
    }
}

/** 一条 IDLE 事件。 */
public struct ImapEvent {
    public let kind: ImapEventKind
    public let sequence: ?Int64
    public let raw: String

    public init(kind: ImapEventKind, sequence!: ?Int64 = None, raw!: String = "") {
        this.kind = kind
        this.sequence = sequence
        this.raw = raw
    }
}

/**
 * 一个正在进行的 IDLE 会话（RFC 2177）。
 *
 * 三条纪律：
 *
 * 1. **用户代码永不在读线程上执行**：读线程只做"读行 → 分类 → 入队"，调用方用
 *    [nextEvent] 取。一次慢回调不会让服务器判超时。
 * 2. **IDLE 期间普通命令立即抛错**，不排队——排队会把"用户以为并发、实际串行"
 *    变成难以复现的超时。
 * 3. **25 分钟主动重建**：RFC 2177 允许服务器 30 分钟后断开，固定提前到 25 分钟
 *    写 `DONE` 再重新 `IDLE`。重建由可注入的时钟驱动，测试里可以把时间拨快。
 */
public class ImapIdleSession <: Resource {
    private let client: ImapClient
    private let channel: LineChannel
    private let queue = ArrayList<ImapEvent>()
    private var head: Int64 = 0
    private let maxQueuedEvents: Int64 = 1024
    private let mutex: Mutex
    private let notEmpty: Condition
    private let writeMutex = Mutex()
    private let rebuildAfter: Duration
    private let pollInterval: Duration
    private let started: MonoTime
    private var tag = ""
    private var running = true
    private var finished = false
    private var byeSeen = false
    private var stopRequested = false
    private var doneSent = false
    private var lastFailure: ?Exception = None
    private var worker: ?Future<Unit> = None
    private var rounds: Int64 = 0
    private var lastRoundStart: MonoTime = MonoTime.now()

    init(
        client: ImapClient,
        channel: LineChannel,
        tag: String,
        rebuildAfter: Duration,
        pollInterval: Duration
    ) {
        this.client = client
        this.channel = channel
        this.tag = tag
        this.rebuildAfter = rebuildAfter
        this.pollInterval = pollInterval
        this.started = MonoTime.now()
        let guard = Mutex()
        this.mutex = guard
        guard.lock()
        this.notEmpty = guard.condition()
        guard.unlock()
    }

    // ---------- 供 [ImapIdle] 使用 ----------

    func startWorker(): Unit {
        worker = spawn {
            =>
                readLoop()
        }
    }

    /** 已经重建过几轮 IDLE（25 分钟一到就 +1）。 */
    public prop rebuildCount: Int64 {
        get() {
            rounds
        }
    }

    public func isFinished(): Bool {
        synchronized(mutex) {
            finished
        }
    }

    /**
     * 取一条事件；`timeout` 到点返回 `None` 且**不关连接**。
     *
     * 会话因 `* BYE` 或读失败结束后，队列里的事件仍能取完；取空之后再调用会抛
     * `MailProtocolException`，不会静默返回 `None`——"没有事件"和"会话没了"是两件事。
     */
    public func nextEvent(timeout!: Duration = Duration.second * 30): ?ImapEvent {
        synchronized(mutex) {
            if (head < queue.size) {
                let event = queue[head]
                head += 1
                return Some(event)
            }
            if (finished) {
                throw failure("IDLE 会话已结束")
            }
            notEmpty.wait(timeout: timeout)
            if (head < queue.size) {
                let event = queue[head]
                head += 1
                return Some(event)
            }
            if (finished) {
                throw failure("IDLE 会话已结束")
            }
            None<ImapEvent>
        }
    }

    /** 发 `DONE` 结束 IDLE；幂等。 */
    public func done(): Unit {
        synchronized(mutex) {
            stopRequested = true
        }
        synchronized(writeMutex) {
            if (!doneSent) {
                doneSent = true
                // `DONE` 是唯一不带 tag 的命令
                try {
                    channel.writeLine("DONE")
                } catch (_: Exception) {}
            }
        }
        valJoin()
        client.markIdle(false)
    }

    /** `done()` 之后不再需要连接时用；同样幂等。 */
    public func close(): Unit {
        done()
    }

    public func isClosed(): Bool {
        isFinished()
    }

    // ---------- 读线程 ----------

    private func readLoop(): Unit {
        try {
            while (true) {
                let stop = synchronized(mutex) {
                    stopRequested
                }
                let raw = channel.readLineSoft(pollInterval)
                if (raw.isNone()) {
                    if (channel.lastReadTimedOut()) {
                        if (stop) {
                            break
                        }
                        if (MonoTime.now() - lastRoundStart >= rebuildAfter) {
                            rebuild()
                        }
                        continue
                    }
                    // EOF：连接没了，按 Bye 处理
                    enqueue(ImapEvent(ImapEventKind.Bye, raw: "connection closed"))
                    setBye()
                    break
                }
                let line = String.fromUtf8(raw.getOrThrow())
                if (line.size == 0) {
                    continue
                }
                if (isTagged(line, tag)) {
                    break
                }
                let event = classify(line)
                enqueue(event)
                if (event.kind.toString() == "BYE") {
                    setBye()
                    break
                }
            }
        } catch (e: Exception) {
            synchronized(mutex) {
                lastFailure = Some(e)
            }
            enqueue(ImapEvent(ImapEventKind.Bye, raw: "read failed: ${e.message}"))
            setBye()
        } finally {
            synchronized(mutex) {
                finished = true
                notEmpty.notifyAll()
            }
            client.markIdle(false)
        }
    }

    private func rebuild(): Unit {
        synchronized(writeMutex) {
            try {
                channel.writeLine("DONE")
            } catch (_: Exception) {
                return
            }
        }
        // 等 tagged OK；期间推来的 untagged 照常入队
        while (true) {
            let raw = channel.readLineSoft(Duration.second * 30)
            if (raw.isNone()) {
                if (channel.lastReadTimedOut()) {
                    continue
                }
                enqueue(ImapEvent(ImapEventKind.Bye, raw: "connection closed during rebuild"))
                setBye()
                return
            }
            let line = String.fromUtf8(raw.getOrThrow())
            if (isTagged(line, tag)) {
                break
            }
            if (line.size > 0) {
                enqueue(classify(line))
            }
        }
        tag = client.nextTag()
        synchronized(writeMutex) {
            channel.writeLine("${tag} IDLE")
        }
        while (true) {
            let raw = channel.readLineSoft(Duration.second * 30)
            if (raw.isNone()) {
                if (channel.lastReadTimedOut()) {
                    continue
                }
                setBye()
                return
            }
            let line = String.fromUtf8(raw.getOrThrow())
            if (line.size > 0 && line[0..1] == "+") {
                break
            }
        }
        rounds += 1
        lastRoundStart = MonoTime.now()
    }

    private func classify(line: String): ImapEvent {
        if (line.size > 1 && line[0..1] == "+") {
            return ImapEvent(ImapEventKind.Other, raw: line)
        }
        let response = try {
            ImapResponse.parse(line)
        } catch (_: Exception) {
            return ImapEvent(ImapEventKind.Other, raw: line)
        }
        let name = (response.name ?? "").toAsciiUpper()
        match (name) {
            case "EXISTS" => ImapEvent(ImapEventKind.Exists, sequence: response.numberOf(), raw: line)
            case "EXPUNGE" => ImapEvent(ImapEventKind.Expunge, sequence: response.numberOf(), raw: line)
            case "RECENT" => ImapEvent(ImapEventKind.Recent, sequence: response.numberOf(), raw: line)
            case "FETCH" => ImapEvent(ImapEventKind.Fetch, sequence: response.numberOf(), raw: line)
            case "VANISHED" => ImapEvent(ImapEventKind.Vanished, raw: line)
            case "FLAGS" => ImapEvent(ImapEventKind.Flags, raw: line)
            case "BYE" => ImapEvent(ImapEventKind.Bye, raw: line)
            case _ => ImapEvent(ImapEventKind.Other, raw: line)
        }
    }

    private func isTagged(line: String, expected: String): Bool {
        if (line.size <= expected.size) {
            return false
        }
        line[0..expected.size] == expected && line[expected.size..(expected.size + 1)] == " "
    }

    private func enqueue(event: ImapEvent): Unit {
        synchronized(mutex) {
            if (queue.size - head >= maxQueuedEvents) {
                // 有界队列：消费者长期不取时丢弃最旧事件，避免内存无限增长。
                head += 1
                if (head > maxQueuedEvents && head * 2 > queue.size) {
                    let rest = ArrayList<ImapEvent>()
                    for (i in head..queue.size) {
                        rest.add(queue[i])
                    }
                    queue.clear()
                    for (item in rest) {
                        queue.add(item)
                    }
                    head = 0
                }
            }
            queue.add(event)
            notEmpty.notify()
        }
    }

    private func setBye(): Unit {
        synchronized(mutex) {
            byeSeen = true
        }
    }

    private func valJoin(): Unit {
        if (let Some(future) <- worker) {
            try {
                future.get(Duration.second * 10)
            } catch (_: Exception) {
                // 读线程卡在 readLineSoft 上时不必强杀：连接关闭会让它退出
            }
        }
        synchronized(mutex) {
            finished = true
            notEmpty.notifyAll()
        }
    }

    private func failure(message: String): Exception {
        let cause = synchronized(mutex) {
            lastFailure
        }
        match (cause) {
            case Some(error) => MailIoException(IoStage.Read, "${message}：${error.message}", error)
            case None =>
                if (byeSeen) {
                    MailProtocolException("${message}：服务器已发送 BYE")
                } else {
                    MailProtocolException(message)
                }
        }
    }
}

/**
 * `IDLE` 的入口。
 *
 * 前置校验在本地完成（已认证 + 已 SELECT/EXAMINE），不浪费一次往返；
 * 服务器未广告 `IDLE` 时抛 `MailProtocolException(capability="IDLE")`。
 */
public class ImapIdle {
    private let client: ImapClient
    private var rebuildAfter: Duration = Duration.second * 60 * 25
    private var pollInterval: Duration = Duration.second * 5

    public init(client: ImapClient) {
        this.client = client
    }

    /** 重建间隔，默认 25 分钟；测试里可以拨到毫秒级。 */
    public func withRebuildAfter(interval: Duration): This {
        rebuildAfter = interval
        this
    }

    /** 读线程的轮询粒度：每次 `readLineSoft` 最多等这么久。 */
    public func withPollInterval(interval: Duration): This {
        pollInterval = interval
        this
    }

    public func start(): ImapIdleSession {
        client.requireSelected("IDLE")
        client.requireCapability("IDLE")
        let channel = client.channel()
        let tag = client.nextTag()
        channel.clearDeadline()
        channel.withDeadline(Duration.second * 30)
        channel.writeLine("${tag} IDLE")
        // 等 `+ idling`
        while (true) {
            let raw = channel.readLine()
            if (raw.isNone()) {
                throw MailIoException(IoStage.Read, "IDLE 未收到继续请求就断开")
            }
            let line = String.fromUtf8(raw.getOrThrow())
            if (line.size > 0 && line[0..1] == "+") {
                break
            }
            let response = ImapResponse.parse(line)
            if ((response.tag ?? "") == tag) {
                throw MailProtocolException("IDLE 被拒绝：${line}", capability: "IDLE")
            }
        }
        channel.clearDeadline()
        client.markIdle(true)
        let session = ImapIdleSession(client, channel, tag, rebuildAfter, pollInterval)
        session.startWorker()
        session
    }
}
