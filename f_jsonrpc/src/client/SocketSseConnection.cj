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

import std.collection.*
import std.convert.*
import std.net.TcpSocket

import fountain::f_data.*

/**
 * 一条真实的 SSE 连接：`GET` + 读响应头 + 解 chunked。
 *
 * 只做 SSE 需要的最小子集：不跟随重定向、不处理 gzip；连接结束返回 `None`。
 */
public class SocketSseConnection <: SseConnection {
    private let socket: TcpSocket
    private var buffer: String = ''
    private var finished: Bool = false

    private init(socket: TcpSocket) {
        this.socket = socket
    }

    public static func open(url: String, topic: String, taskId: String,
                            headers: HashMap<String, String>): ?SseConnection {
        let target = Endpoint.parse(url)
        let socket = TcpSocket(target.host, target.port)
        try {
            socket.connect()
        } catch (e: Exception) {
            return None
        }
        let path = target.path + '?topic=${topic}&taskId=${taskId}'
        var request = 'GET ${path} HTTP/1.1\r\nHost: ${target.host}:${target.port}\r\n' +
            'Accept: text/event-stream\r\nCache-Control: no-cache\r\nConnection: keep-alive\r\n'
        for ((key, value) in headers) {
            request += '${key}: ${value}\r\n'
        }
        request += '\r\n'
        try {
            socket.write(request.unsafeBytes())
        } catch (e: Exception) {
            socket.close()
            return None
        }
        let connection = SocketSseConnection(socket)
        return if (connection.skipHeaders()) {
            Some(connection)
        } else {
            socket.close()
            None
        }
    }

    /** 跳过响应头；非 200 视为失败 */
    private func skipHeaders(): Bool {
        while (true) {
            match (nextLine()) {
                case Some(line) =>
                    if (line.startsWith('HTTP/')) {
                        if (!line.contains(' 200')) {
                            return false
                        }
                    } else if (line.isEmpty()) {
                        return true
                    }
                case None => return false
            }
        }
        return false
    }

    /** 每次读一块（解 chunked），连接结束返回 None */
    public func readChunk(): ?String {
        if (finished) {
            return None
        }
        let text = match (nextLine()) {
            case Some(value) => value
            case None =>
                finished = true
                return None
        }
        if (text.isEmpty()) {
            // chunk 之间的空行：继续读下一块长度
            return readChunk()
        }
        let size = match (Int64.tryParse(text, radix: 16)) {
            case Some(value) => value
            case None =>
                finished = true
                return None
        }
        if (size <= 0) {
            finished = true
            return None
        }
        var remaining = size
        let data = StringBuilder()
        while (remaining > 0) {
            let piece = match (nextLine()) {
                case Some(value) => value
                case None =>
                    finished = true
                    return None
            }
            // chunk 内的换行是数据的一部分，按原始长度截取
            if (Int64(piece.size) >= remaining) {
                data.append(piece[..remaining])
                remaining = 0
            } else {
                data.append(piece)
                data.append('\n')
                remaining -= Int64(piece.size) + 1
            }
        }
        // 丢弃 chunk 末尾的 CRLF
        let _ = nextLine()
        data.toString()
    }

    public func close(): Unit {
        finished = true
        try {
            socket.close()
        } catch (e: Exception) {
            ()
        }
    }

    /** 从缓冲里取一行（不含换行符）；需要时从 socket 补数据 */
    private func nextLine(): ?String {
        while (true) {
            let index = match (buffer.indexOf('\n')) {
                case Some(value) => value
                case None => -1
            }
            if (index >= 0) {
                var line = buffer[..index]
                if (line.endsWith('\r')) {
                    line = line[..Int64(line.size) - 1]
                }
                buffer = buffer[index + 1..]
                return Some(line)
            }
            let chunk = Array<Byte>(4096, repeat: 0)
            let count = try {
                socket.read(chunk)
            } catch (e: Exception) {
                0
            }
            if (count <= 0) {
                return None
            }
            buffer += String.fromUtf8(chunk[..count])
        }
        return None
    }
}

/** `http://host:port/path` 的最小解析（SSE 端点只需要这些） */
class Endpoint {
    let host: String
    let port: UInt16
    let path: String

    private init(host: String, port: UInt16, path: String) {
        this.host = host
        this.port = port
        this.path = path
    }

    static func parse(url: String): Endpoint {
        var rest = url
        if (rest.startsWith('http://')) {
            rest = rest[7..]
        }
        let slash = match (rest.indexOf('/')) {
            case Some(value) => value
            case None => Int64(rest.size)
        }
        let authority = rest[..slash]
        let path = if (slash < Int64(rest.size)) {
            rest[slash..]
        } else {
            '/'
        }
        var port: Int64 = 80
        var host = authority
        match (authority.indexOf(':')) {
            case Some(value) =>
                if (value > 0) {
                    host = authority[..value]
                    match (Int64.tryParse(authority[value + 1..])) {
                        case Some(number) => port = number
                        case None => ()
                    }
                }
            case None => ()
        }
        Endpoint(host, UInt16(port), path)
    }
}
