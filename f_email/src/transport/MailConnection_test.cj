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

import std.net.{TcpServerSocket, TcpSocket}
import std.sync.AtomicBool
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_email.{IoStage, MailIoException}

@Test
public class MailConnection_test {
    @TestCase
    public func readsLineFromRealSocket(): Unit {
        let server = TcpServerSocket(bindAt: 24655)
        server.bind()
        spawn {
            try (socket = server.accept()) {
                socket.write("220 hello\r\n".toArray())
            } catch (_: Exception) {}
        }
        let conn = MailConnection.open("127.0.0.1", 24655)
        @Assert(String.fromUtf8(conn.channel().readLine() ?? Array<Byte>()), "220 hello")
        conn.close()
        server.close()
    }

    @TestCase
    public func closeIsIdempotent(): Unit {
        let server = TcpServerSocket(bindAt: 24656)
        server.bind()
        spawn {
            try (socket = server.accept()) {
                sleep(Duration.millisecond * 300)
            } catch (_: Exception) {}
        }
        let conn = MailConnection.open("127.0.0.1", 24656)
        conn.close()
        conn.close()
        @Assert(conn.isClosed(), true)
        server.close()
    }

    /** 一个线程阻塞在 read 上，另一个线程 close()，阻塞读必须以 MailIoException 结束。 */
    @TestCase
    public func crossThreadCloseInterruptsRead(): Unit {
        let server = TcpServerSocket(bindAt: 24657)
        server.bind()
        spawn {
            try {
                let socket = server.accept()
                sleep(Duration.second * 3)
                socket.close()
            } catch (_: Exception) {}
        }
        let conn = MailConnection.open(
            "127.0.0.1",
            24657,
            timeouts: MailTimeouts(command: Duration.second * 20)
        )
        let channel = conn.channel()
        let failed = AtomicBool(false)
        spawn {
            try {
                channel.readLine()
            } catch (_: MailIoException) {
                failed.store(true)
            } catch (_: Exception) {}
        }
        sleep(Duration.millisecond * 300)
        conn.close()
        sleep(Duration.millisecond * 500)
        @Assert(failed.load(), true)
        @Assert(conn.isClosed(), true)
        server.close()
    }

    /** 服务器每 50 ms 吐一个字节：单次读不会超时，但命令总超时必须到点失败。 */
    @TestCase
    public func commandDeadlineExpires(): Unit {
        let server = TcpServerSocket(bindAt: 24658)
        server.bind()
        spawn {
            try (socket = server.accept()) {
                let one = Array<Byte>(1, repeat: b'x')
                for (_ in 0..40) {
                    try {
                        socket.write(one)
                    } catch (_: Exception) {
                        break
                    }
                    sleep(Duration.millisecond * 50)
                }
            } catch (_: Exception) {}
        }
        let conn = MailConnection.open(
            "127.0.0.1",
            24658,
            timeouts: MailTimeouts(command: Duration.millisecond * 250)
        )
        let channel = conn.channel()
        channel.withDeadline(Duration.millisecond * 250)
        var stage = IoStage.Read
        try {
            channel.readLine()
        } catch (e: MailIoException) {
            stage = e.stage
        }
        @Assert(stage.toString(), "Timeout")
        @Assert(conn.isClosed(), true)
        server.close()
    }

    /** 脚本化传输：逐字节断言客户端写出内容，不依赖网络。 */
    @TestCase
    public func scriptedTransportRecordsClientBytes(): Unit {
        let transport = ScriptedTransport(server: "220 ready\r\n")
        let conn = transport.connect("script", 25, TlsMode.None)
        let channel = conn.channel()
        @Assert(String.fromUtf8(channel.readLine() ?? Array<Byte>()), "220 ready")
        channel.writeLine("EHLO example.com")
        @Assert(transport.recordedText(), "EHLO example.com\r\n")
    }
}
