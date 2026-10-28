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

import std.collection.ArrayList
import std.io.{InputStream, OutputStream}
import std.sync.Mutex
import stdx.net.tls.TlsClientConfig
import fountain::f_email.model.MailProtocolException

/**
 * 传输工厂：协议客户端只依赖这个接口，因此测试可以注入字节脚本，
 * 未来接 SOCKS5 / HTTP CONNECT 代理时也只换这一处实现。
 */
public interface TransportFactory {
    func connect(host: String, port: UInt16, tls: TlsMode): MailConnection
}

/** 真实 socket 实现。 */
public class SocketTransportFactory <: TransportFactory {
    private let timeouts: MailTimeouts
    private let trace: ?MailTrace
    private let maxLine: Int64
    private let tlsConfig: ?TlsClientConfig

    public init(
        timeouts!: MailTimeouts = MailTimeouts(),
        trace!: ?MailTrace = None,
        maxLine!: Int64 = 4096,
        tlsConfig!: ?TlsClientConfig = None
    ) {
        this.timeouts = timeouts
        this.trace = trace
        this.maxLine = maxLine
        this.tlsConfig = tlsConfig
    }

    public func connect(host: String, port: UInt16, tls: TlsMode): MailConnection {
        MailConnection.open(
            host,
            port,
            tls: tls,
            timeouts: timeouts,
            tlsConfig: tlsConfig,
            trace: trace,
            maxLine: maxLine
        )
    }
}

/**
 * 测试用传输：预置"服务器要说的字节"，记录"客户端说了什么"。
 *
 * - [chunkSize] 为 1 时模拟"每次 read 只返回 1 字节"的慢速流，这是暴露
 *   "依赖一次读满一行"这类 bug 的唯一手段；
 * - [pushServer] 允许在测试过程中追加服务器字节（模拟 IDLE 推送这类异步事件）；
 * - 脚本耗尽后读取返回 EOF；需要"服务器保持连接但不说话"时用 [blockAtEnd]。
 */
public class ScriptedTransport <: TransportFactory {
    private let mutex = Mutex()
    private var serverBytes = ArrayList<Byte>()
    private var readPos = 0
    private var clientBytes = ArrayList<Byte>()
    private let chunkSize: Int64
    private var blockAtEnd: Bool
    private var eofAtEnd = true

    /**
     * @param server 预置的服务器字节
     * @param chunkSize 每次 read 最多返回多少字节；1 = 慢速流
     * @param blockAtEnd 脚本耗尽后是否一直"没有数据"（阻塞）而不是 EOF
     */
    public init(server!: String = "", chunkSize!: Int64 = 0, blockAtEnd!: Bool = false) {
        this.serverBytes = ArrayList<Byte>(server.toArray())
        this.chunkSize = chunkSize
        this.blockAtEnd = blockAtEnd
    }

    public static func of(server: String, chunkSize!: Int64 = 0): ScriptedTransport {
        ScriptedTransport(server: server, chunkSize: chunkSize)
    }

    public func pushServer(bytes: String): Unit {
        pushServer(bytes.toArray())
    }

    public func pushServer(bytes: Array<Byte>): Unit {
        synchronized(mutex) {
            for (b in bytes) {
                serverBytes.add(b)
            }
        }
    }

    /** 已写出的客户端字节。 */
    public func recorded(): Array<Byte> {
        synchronized(mutex) {
            clientBytes.toArray()
        }
    }

    public func recordedText(): String {
        String.fromUtf8(recorded())
    }

    public func clearRecorded(): Unit {
        synchronized(mutex) {
            clientBytes = ArrayList<Byte>()
        }
    }

    public func connect(host: String, port: UInt16, tls: TlsMode): MailConnection {
        match (tls) {
            case TlsMode.Implicit =>
                throw MailProtocolException("ScriptedTransport 不支持隐式 TLS")
            case _ => ()
        }
        MailConnection.fromStreams(
            ScriptedInput(this),
            ScriptedOutput(this),
            remote: "${host}:${port}"
        )
    }

    // ---------- 供内部流调用 ----------

    func readServer(target: Array<Byte>): Int64 {
        if (target.size == 0) {
            return 0
        }
        var available = 0
        synchronized(mutex) {
            available = serverBytes.size - readPos
        }
        if (available <= 0) {
            if (blockAtEnd) {
                // 模拟"连接还在但服务器不说话"：阻塞到有数据为止
                while (true) {
                    synchronized(mutex) {
                        available = serverBytes.size - readPos
                    }
                    if (available > 0) {
                        break
                    }
                    sleep(Duration.millisecond * 2)
                }
            } else {
                return 0
            }
        }
        let n = if (chunkSize > 0 && chunkSize < available) {
            chunkSize
        } else {
            available
        }
        let take = if (n < target.size) {
            n
        } else {
            target.size
        }
        synchronized(mutex) {
            for (i in 0..take) {
                target[i] = serverBytes[readPos + i]
            }
            readPos += take
        }
        take
    }

    func writeClient(bytes: Array<Byte>): Unit {
        synchronized(mutex) {
            for (b in bytes) {
                clientBytes.add(b)
            }
        }
    }
}

class ScriptedInput <: InputStream {
    private let transport: ScriptedTransport

    init(transport: ScriptedTransport) {
        this.transport = transport
    }

    public func read(buffer: Array<Byte>): Int64 {
        transport.readServer(buffer)
    }
}

class ScriptedOutput <: OutputStream {
    private let transport: ScriptedTransport

    init(transport: ScriptedTransport) {
        this.transport = transport
    }

    public func write(buffer: Array<Byte>): Unit {
        transport.writeClient(buffer)
    }
}
