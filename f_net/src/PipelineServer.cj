/*
    Copyright (c) 2022 WuJingrun（吴京润）
    fountain is licensed under Mulan PSL v2.
    You can use this software according to the terms and conditions of the Mulan PSL v2.
    You may obtain a copy of Mulan PSL v2 at:
            http://license.coscl.org.cn/MulanPSL2
    THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
    See the Mulan PSL v2 for more details.
 */
package f_net

import std.env

public class PipelineServer<EN, DE> <: Resource where EN <: ProtocolData<EN>, DE <: ProtocolData<DE> {
    private static func log() {
        LoggerFactory.getLogger<PipelineServer<EN, DE>>()
    }
    private let closed = AtomicBool(false)
    public PipelineServer(
        private let server!: TcpServerSocket,
        private let encoder!: Encoder<EN>,
        private let decoder!: Decoder<DE>,
        private let executor!: (DE) -> EN
    ) {
        server.bind()
        start()
        env.atExit(close)
    }
    public init(
        server!: TcpServerSocket,
        codec!: Codec<EN, DE>,
        executor!: (DE) -> EN
    ) {
        this(server: server, encoder: codec, decoder: codec, executor: executor)
    }

    private func start(): Unit {
        while (!closed.load() && let socket <- server.accept()) {
            let decoder = this.decoder.decoder()
            spawn {
                while (!(closed.load() || socket.isClosed())) {
                    let buf = Array<Byte>(128, repeat: 0)
                    let len = try {
                        socket.read(buf)
                    } catch (e: Exception) {
                        log().warn<SocketAddress>('socket {} read', e, [socket.remoteAddress])
                        continue
                    }
                    if (let Some(d) <- decoder.decode(buf[0..len])) {
                        if (d.isToClose) {
                            try {
                                socket.close()
                            } catch (e: Exception) {
                                log().warn<SocketAddress>('socket {} close', e, [socket.remoteAddress])
                            }
                        } else {
                            let r = try {
                                executor(d)
                            } catch (e: Exception) {
                                log().warn<SocketAddress>('pipeline executor {}', e, [socket.remoteAddress])
                                continue
                            }
                            let bytes = try {
                                encoder.encoder().encode(r)
                            } catch (e: Exception) {
                                log().warn<SocketAddress>('pipeline encode {}', e, [socket.remoteAddress])
                                continue
                            }
                            try {
                                socket.write(bytes)
                            } catch (e: Exception) {
                                log().warn<SocketAddress>('socket {} write', e, [socket.remoteAddress])
                            }
                        }
                    }
                }
            }
        }
    }
    public func isClosed(): Bool {
        server.isClosed()
    }
    public func close(): Unit {
        closed.store(true)
        server.close()
    }
}
