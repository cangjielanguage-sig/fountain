/*
    Copyright (c) [2022] [WuJingrun（吴京润）]
    fountain is licensed under Mulan PSL v2.
    You can use this software according to the terms and conditions of the Mulan PSL v2.
    You may obtain a copy of Mulan PSL v2 at:
            http://license.coscl.org.cn/MulanPSL2
    THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
    See the Mulan PSL v2 for more details.  
*/
package f_net

public class PipelineServer<EN, DE> <: Resource where EN <: ProtocolData<EN>, DE <: ProtocolData<DE> {
    private static let LOG = LoggerFactory.getLogger<PipelineServer<EN, DE, E, D>>()
    private let closed = AtomicBool(false)
    public PipelineServer(
        private let server!: TcpServerSocket, 
        private let encoder!: Encoder<EN>,
        private let decoder!: Decoder<DE>
        private let executor!: (EN) -> DE
    ){
        server.bind()
        start()
    }
    public init(serverCreater!: ()->TcpServerSocket, encoder!: Encoder<EN>, decoder!: Decoder<DE>, executor!: (EN) -> DE) {
        this(server: serverCreater(), encoder: encoder, decoder: decoder, executor: executor)
    }
    public init(port!: UInt16, encoder!: Encoder<EN>, decoder!: Decoder<DE>, executor!: (EN) -> DE) {
        this(socket: TcpServerSocket(bindAt: port), encoder: encoder, decoder: decoder, executor: executor)
    }
    public init(port!: UInt16, codec!: Codec<EN, DE>, executor!: (EN) -> DE): PipelineServer<EN, DE> {
        this(socket: TcpServerSocket(bindAt: port), encoder: codec, decoder: codec, executor: executor)
    }
    private func start(): Unit {
        spawn{
            while(!closed.load() && let socket <- server.accept()){
                spawn{
                    while(!closed.load()){
                        let buf = Array<Byte>(128, repeat: 0)
                        let len = try{
                            socket.read(buf)
                        }catch(e: Exception){
                            LOG.warn('socket {} read': e, socket.remoteAddress)
                            continue
                        }
                        if(let Some(d) <- decoder.decode(buf[0 .. len])){
                            if(d.isToClose){
                                try{
                                    socket.close()
                                }catch(e: Exception){
                                    LOG.warn('socket {} close', e, socket.remoteAddress)
                                }
                            }else{
                                try{
                                    socket.write(encoder.encode(executor(d)))
                                }catch(e: Exception){
                                    LOG.warn('socket {} write', e, socket.remoteAddress)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    public func isClosed(): Bool {
        socket.isClosed()
    }
    public func close(): Unit {
        closed.store(true)
        socket.close()
    }
}