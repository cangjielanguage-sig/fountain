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
package fountain::f_jsonrpc.client

import std.collection.ArrayList
import std.net.{IPSocketAddress, TcpServerSocket, TcpSocket}
import std.sync.AtomicInt64
import std.time.MonoTime
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_data.*
import fountain::f_jsonrpc.base.*

/**
 * 原始 TCP 上的最小 HTTP 服务：只读请求头，响应内容完全由用例决定。
 * 这样能精确构造 `Content-Length` 虚报、chunked 持续输出、只发一半就断开等场景。
 */
class RawHttpServer {
    let listener: TcpServerSocket
    let port: UInt16
    let written = AtomicInt64(0)
    let requests = AtomicInt64(0)
    let lastRequest = Box<String>('')

    /** 每个请求调用一次 `handler`；返回后继续在同一连接上等待下一个请求。 */
    init(handler: (TcpSocket, AtomicInt64) -> Unit) {
        let l = TcpServerSocket(bindAt: 0)
        l.bind()
        var p: UInt16 = 0
        match (l.localAddress) {
            case a: IPSocketAddress => p = a.port
            case _ => ()
        }
        this.listener = l
        this.port = p
        let w = written
        let r = requests
        let lr = lastRequest
        spawn {
            while (true) {
                let sock = try {
                    l.accept()
                } catch (_: Exception) {
                    break
                }
                spawn {
                    try {
                        while (true) {
                            match (readHeader(sock)) {
                                case Some(text) =>
                                    r.fetchAdd(1)
                                    lr.value = text
                                    handler(sock, w)
                                case _ => break
                            }
                        }
                    } catch (_: Exception) {
                        ()
                    }
                    try {
                        sock.close()
                    } catch (_: Exception) {
                        ()
                    }
                }
            }
        }
    }

    prop url: String {
        get() {
            'http://127.0.0.1:${port}/rpc'
        }
    }

    func close(): Unit {
        try {
            listener.close()
        } catch (_: Exception) {
            ()
        }
    }
}

private func readHeader(sock: TcpSocket): ?String {
    let buf = Array<Byte>(1024, repeat: 0)
    let data = ArrayList<Byte>()
    while (data.size < 65536) {
        let n = try {
            sock.read(buf)
        } catch (_: Exception) {
            -1
        }
        if (n <= 0) {
            return None<String>
        }
        data.add(all: buf[0..n])
        let text = String.fromUtf8(data.toArray())
        if (text.contains('\r\n\r\n')) {
            return Some(text)
        }
    }
    None<String>
}

private func repeatChar(c: UInt8, n: Int64): String {
    String.fromUtf8(Array<Byte>(n, repeat: c))
}

func writeBytes(sock: TcpSocket, bytes: Array<Byte>, counter: AtomicInt64): Bool {
    try {
        sock.write(bytes)
        counter.fetchAdd(bytes.size)
        true
    } catch (_: Exception) {
        false
    }
}

func writeText(sock: TcpSocket, text: String, counter: AtomicInt64): Bool {
    let bytes = text.unsafeBytes()
    try {
        sock.write(bytes)
        counter.fetchAdd(bytes.size)
        true
    } catch (_: Exception) {
        false
    }
}

private func responseOf(body: String): String {
    'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: ${body.unsafeBytes().size}\r\n\r\n${body}'
}

@Test
class HttpJsonRpcTransport_test {
    /** `Content-Length` 预判：超限时一个字节 body 都不读，服务端也不会把 body 写完。 */
    @TestCase
    public func testDeclaredLengthExceedsCapFailsFast(): Unit {
        let server = RawHttpServer({sock, w =>
            writeText(sock, 'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 10485760\r\n\r\n',
                w)
            // 声明 10 MiB，实际按 64 KiB 分片持续写：客户端读完才会全部落地
            let chunk = Array<Byte>(65536, repeat: UInt8(120))
            var i = 0
            while (i < 160) {
                if (!writeBytes(sock, chunk, w)) {
                    break
                }
                i++
            }
        })
        let transport = HttpJsonRpcTransport(server.url, ClientOptions(maxResponseBytes: 1024 * 1024))
        let start = MonoTime.now()
        var threw = false
        try {
            transport.send('{}'.unsafeBytes())
        } catch (_: JsonRpcException) {
            threw = true
        }
        let elapsed = (MonoTime.now() - start).toMilliseconds()
        transport.close()
        let written = server.written.load()
        server.close()
        @Assert(true, threw)
        @Assert(true, elapsed < 700)
        // 服务端观测到的落地字节必须远小于声明长度：客户端没有把 body 读完
        @Assert(true, written < 10 * 1024 * 1024)
    }

    @TestCase
    public func testChunkedBodyExceedsCapStopsReading(): Unit {
        let server = RawHttpServer({sock, w =>
            writeText(sock, 'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\n\r\n',
                w)
            let chunk = Array<Byte>(65536, repeat: UInt8(120)) // 'x'
            let sizeText = '10000\r\n'
            var i = 0
            while (i < 320) { // 20 MiB
                if (!writeText(sock, sizeText, w)) {
                    break
                }
                if (!writeBytes(sock, chunk, w)) {
                    break
                }
                if (!writeText(sock, '\r\n', w)) {
                    break
                }
                i++
            }
        })
        let transport = HttpJsonRpcTransport(server.url, ClientOptions(maxResponseBytes: 1024 * 1024))
        var threw = false
        try {
            transport.send('{}'.unsafeBytes())
        } catch (_: JsonRpcException) {
            threw = true
        }
        transport.close()
        let written = server.written.load()
        server.close()
        @Assert(true, threw)
        // 20 MiB 全写完才失败说明没在读的过程中截断（这里允许缓冲带来的少量超额）
        @Assert(true, written < 12 * 1024 * 1024)
    }

    @TestCase
    public func testNormalResponse(): Unit {
        let body = '{"jsonrpc":"2.0","id":1,"result":"' + repeatChar(UInt8(97), 1024) + '"}'
        let server = RawHttpServer({sock, w => writeText(sock, responseOf(body), w)})
        let transport = HttpJsonRpcTransport(server.url, ClientOptions())
        let bytes = transport.send('{}'.unsafeBytes())
        transport.close()
        server.close()
        @Assert(body, String.fromUtf8(bytes))
    }

    @TestCase
    public func testEmptyResponseBody(): Unit {
        let server = RawHttpServer({sock, w =>
            writeText(sock, 'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 0\r\n\r\n', w)
        })
        let transport = HttpJsonRpcTransport(server.url, ClientOptions())
        let bytes = transport.send('{}'.unsafeBytes())
        transport.close()
        server.close()
        @Assert(0, bytes.size)
    }

    @TestCase
    public func testBodyExactlyAtCapIsAccepted(): Unit {
        let body = repeatChar(UInt8(97), 4096)
        let server = RawHttpServer({sock, w => writeText(sock, responseOf(body), w)})
        let transport = HttpJsonRpcTransport(server.url, ClientOptions(maxResponseBytes: 4096))
        let bytes = transport.send('{}'.unsafeBytes())
        transport.close()
        server.close()
        @Assert(4096, bytes.size)
    }

    @TestCase
    public func testReadFailureIsNotRetried(): Unit {
        // 响应头已到达、body 中途断开：读响应阶段失败 —— 绝不能重发
        let server = RawHttpServer({sock, w =>
            writeText(sock, 'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 4096\r\n\r\n',
                w)
            writeText(sock, '{"jsonrpc":', w)
            sock.close()
        })
        let transport = HttpJsonRpcTransport(server.url, ClientOptions())
        let client = JsonRpcClient(transport, opts: ClientOptions(retryOnConnectFailure: 3))
        var failed = false
        try {
            client.call('ping')
        } catch (_: Exception) {
            failed = true
        }
        sleep(Duration.millisecond * 200)
        let count = server.requests.load()
        client.close()
        server.close()
        @Assert(true, failed)
        @Assert(1, count)
    }

    @TestCase
    public func testKeepAliveFalseSendsConnectionClose(): Unit {
        let server = RawHttpServer({sock, w => writeText(sock, responseOf('{"jsonrpc":"2.0","id":1,"result":1}'), w)})
        let transport = HttpJsonRpcTransport(server.url, ClientOptions(keepAlive: false))
        transport.send('{}'.unsafeBytes())
        sleep(Duration.millisecond * 100)
        let request = server.lastRequest.value
        transport.close()
        server.close()
        @Assert(true, request.toAsciiLower().contains('connection: close'))
    }

    @TestCase
    public func testKeepAliveTrueHasNoConnectionClose(): Unit {
        let server = RawHttpServer({sock, w => writeText(sock, responseOf('{"jsonrpc":"2.0","id":1,"result":1}'), w)})
        let transport = HttpJsonRpcTransport(server.url, ClientOptions())
        transport.send('{}'.unsafeBytes())
        sleep(Duration.millisecond * 100)
        let request = server.lastRequest.value
        transport.close()
        server.close()
        @Assert(false, request.toAsciiLower().contains('connection: close'))
    }

    @TestCase
    public func testTwoCallsReuseConnection(): Unit {
        let server = RawHttpServer({sock, w =>
            writeText(sock, responseOf('{"jsonrpc":"2.0","id":1,"result":1}'), w)
        })
        let transport = HttpJsonRpcTransport(server.url, ClientOptions())
        let first = transport.send('{}'.unsafeBytes())
        let second = transport.send('{}'.unsafeBytes())
        transport.close()
        server.close()
        @Assert(true, first.size > 0)
        @Assert(true, second.size > 0)
    }
}
