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

import std.io.{InputStream, OutputStream}
import std.net.TcpSocket
import std.sync.Mutex
import stdx.net.tls.{TlsClientConfig, TlsSocket}
import fountain::f_email.{IoStage, MailIoException, MailProtocolException, MailTlsException}

/**
 * 唯一知道 `TcpSocket` / `TlsSocket` 的类。
 *
 * 协议客户端只拿 [LineChannel]，因此测试里可以换成内存管道（见 [ScriptedTransport]）。
 * `startTls()` 会替换底层流并**重建**通道，调用方升级后必须重新 `connection.channel()`。
 */
public class MailConnection <: Resource & IoTimeout {
    private let host: String
    private let port: UInt16
    private let timeouts: MailTimeouts
    private let trace: ?MailTrace
    private let maxLine: Int64
    private let closeMutex = Mutex()

    private var tcp: ?TcpSocket = None
    private var tlsSocket: ?TlsSocket = None
    private var input: ?InputStream = None
    private var output: ?OutputStream = None
    private var channelValue: ?LineChannel = None
    private var closedFlag = false
    private var tlsActive = false

    private init(
        host: String,
        port: UInt16,
        timeouts: MailTimeouts,
        trace: ?MailTrace,
        maxLine: Int64
    ) {
        this.host = host
        this.port = port
        this.timeouts = timeouts
        this.trace = trace
        this.maxLine = maxLine
    }

    /**
     * 建立连接。
     *
     * `tls` 为 [TlsMode.Implicit] 时在返回前完成 TLS 握手；为 [TlsMode.StartTls] 时
     * 通道以**非缓冲**模式建立（升级前不预读），升级由调用方在收到服务器确认后触发。
     */
    public static func open(
        host: String,
        port: UInt16,
        tls!: TlsMode = TlsMode.None,
        timeouts!: MailTimeouts = MailTimeouts(),
        tlsConfig!: ?TlsClientConfig = None,
        trace!: ?MailTrace = None,
        maxLine!: Int64 = 4096
    ): MailConnection {
        let connection = MailConnection(host, port, timeouts, trace, maxLine)
        let socket = TcpSocket(host, port)
        try {
            socket.connect(timeout: timeouts.connect)
        } catch (e: Exception) {
            try {
                socket.close()
            } catch (_: Exception) {}
            throw MailIoException(IoStage.Connect, "连接 ${host}:${port} 失败：${e.message}", e)
        }
        socket.readTimeout = timeouts.command
        socket.writeTimeout = timeouts.command
        connection.tcp = socket
        match (tls) {
            case TlsMode.Implicit => connection.upgradeTls(tlsConfig)
            case TlsMode.StartTls => connection.install(socket, socket, false)
            case TlsMode.None => connection.install(socket, socket, true)
        }
        connection
    }

    /**
     * 用任意内存流构造连接（测试与代理实现使用）。
     *
     * 不建立任何 socket；[startTls] 在这类连接上会抛异常。
     */
    public static func fromStreams(
        input: InputStream,
        output: OutputStream,
        remote!: String = "memory",
        timeouts!: MailTimeouts = MailTimeouts(),
        trace!: ?MailTrace = None,
        maxLine!: Int64 = 4096
    ): MailConnection {
        let connection = MailConnection(remote, 0, timeouts, trace, maxLine)
        connection.install(input, output, true)
        connection
    }

    /**
     * 在已建立的明文连接上升级 TLS。
     *
     * 升级后旧的 [LineChannel] 立即失效；调用方必须用 [channel] 重新取。
     */
    public func startTls(config!: ?TlsClientConfig = None): Unit {
        if (closedFlag) {
            throw MailProtocolException("client is closed")
        }
        if (tlsActive) {
            throw MailProtocolException("TLS already active")
        }
        upgradeTls(config)
    }

    public func channel(): LineChannel {
        if (let Some(ch) <- channelValue) {
            return ch
        }
        throw MailProtocolException("connection has no channel")
    }

    public prop remoteAddress: String {
        get() {
            if (let Some(s) <- tcp) {
                return "${host}:${port} (${s.remoteAddress})"
            }
            "${host}:${port}"
        }
    }

    public prop isTls: Bool {
        get() {
            tlsActive
        }
    }

    public func close(): Unit {
        synchronized(closeMutex) {
            if (closedFlag) {
                return
            }
            closedFlag = true
        }
        closeUnderlying()
    }

    public func isClosed(): Bool {
        closedFlag
    }

    public func setReadTimeout(timeout: ?Duration): Unit {
        if (let Some(t) <- tlsSocket) {
            t.readTimeout = timeout
        }
        if (let Some(s) <- tcp) {
            s.readTimeout = timeout
        }
    }

    public func setWriteTimeout(timeout: ?Duration): Unit {
        if (let Some(t) <- tlsSocket) {
            t.writeTimeout = timeout
        }
        if (let Some(s) <- tcp) {
            s.writeTimeout = timeout
        }
    }

    // ---------- 内部 ----------

    private func install(input: InputStream, output: OutputStream, buffered: Bool): Unit {
        this.input = Some(input)
        this.output = Some(output)
        let channel = LineChannel(
            input,
            output,
            maxLine: maxLine,
            buffered: buffered,
            trace: trace,
            timeouts: this,
            onFatal: { => this.closeUnderlying() }
        )
        if (let Some(old) <- channelValue) {
            old.invalidate()
        }
        channelValue = channel
    }

    private func upgradeTls(config: ?TlsClientConfig): Unit {
        let socket = match (tcp) {
            case Some(s) => s
            case None => throw MailProtocolException("connection has no TCP socket")
        }
        let tlsConfig = match (config) {
            case Some(c) => c
            case None =>
                var c = TlsClientConfig()
                c.serverName = host
                c
        }
        let secure = try {
            TlsSocket.client(socket, clientConfig: tlsConfig)
        } catch (e: Exception) {
            closeUnderlying()
            throw MailTlsException("创建 TLS 套接字失败：${e.message}", e)
        }
        try {
            secure.handshake(timeout: timeouts.connect)
        } catch (e: Exception) {
            try {
                secure.close()
            } catch (_: Exception) {}
            closeUnderlying()
            throw MailTlsException("TLS 握手失败：${e.message}", e)
        }
        tlsSocket = secure
        tlsActive = true
        install(secure, secure, true)
    }

    /**
     * 只关闭底层 socket，不碰当前 channel。
     *
     * 被 [LineChannel] 的致命错误回调调用；也用于 `close()`。重复调用无副作用。
     */
    private func closeUnderlying(): Unit {
        synchronized(closeMutex) {
            closedFlag = true
        }
        if (let Some(t) <- tlsSocket) {
            try {
                t.close()
            } catch (_: Exception) {}
        }
        if (let Some(s) <- tcp) {
            try {
                s.close()
            } catch (_: Exception) {}
        }
    }
}
