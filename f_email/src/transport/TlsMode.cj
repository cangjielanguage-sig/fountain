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
package fountain::f_email.transport

import std.time.MonoTime

/** 传输层的三种 TLS 模式。 */
public enum TlsMode <: ToString {
    /** 明文。 */
    | None
    /** 先明文，再由 STARTTLS / STLS 命令升级。 */
    | StartTls
    /** 连上即 TLS（SMTPS 465 / POP3S 995 / IMAPS 993）。 */
    | Implicit

    public func toString(): String {
        match (this) {
            case None => "None"
            case StartTls => "StartTls"
            case Implicit => "Implicit"
        }
    }
}

/**
 * 五类超时。
 *
 * `TcpSocket.readTimeout` 是**单次系统调用**超时；命令总超时由 [Deadline] 在每次读写前
 * 折算成剩余时长设置。`idle` 只用于 IDLE 期间的事件轮询判断，不会因为长时间静默而断开连接。
 */
public struct MailTimeouts {
    public let connect: Duration
    public let greeting: Duration
    public let command: Duration
    public let data: Duration
    public let idle: Duration

    public init(
        connect!: Duration = Duration.second * 15,
        greeting!: Duration = Duration.second * 30,
        command!: Duration = Duration.second * 60,
        data!: Duration = Duration.second * 300,
        idle!: Duration = Duration.second * 60
    ) {
        this.connect = connect
        this.greeting = greeting
        this.command = command
        this.data = data
        this.idle = idle
    }
}

/**
 * 命令总超时。
 *
 * 每次读写前用 [remaining] 得到"还剩多少"，把它设成 socket 的单次读超时。
 * 这样即使服务器每 50 ms 吐一个字节，也会在总时长到点时失败，而不是被单次超时无限续命。
 */
internal class Deadline {
    private let start: MonoTime
    private let total: Duration

    public init(total: Duration) {
        this.start = MonoTime.now()
        this.total = total
    }

    public func remaining(): Duration {
        let used = MonoTime.now() - start
        if (used >= total) {
            Duration.Zero
        } else {
            total - used
        }
    }

    public func expired(): Bool {
        MonoTime.now() - start >= total
    }
}

/** 由 [MailConnection] 实现，让 [LineChannel] 能在每次读写前调整 socket 超时。 */
public interface IoTimeout {
    func setReadTimeout(timeout: ?Duration): Unit
    func setWriteTimeout(timeout: ?Duration): Unit
}
