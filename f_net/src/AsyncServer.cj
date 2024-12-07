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

public class AsyncServer<EN, DE> <: Resource where EN <: ProtocolData<EN>, DE <: ProtocolData<DE> {
    private static let LOG = LoggerFactory.getLogger<AsyncServer<EN, DE, E, D>>()
    private let closed = AtomicBool(false)
    private let serial = AtomicUInt64(0)
    private let codecQueues: Array<ArrayBlockingQueue<()->Unit>>
    private let taskQueue: ArrayBlockingQueue<()->Unit>
    private let writeQueues: Array<ArrayBlockingQueue<()->Unit>
    public KeyedServer(
        codecParallelism!: Int64 = 8,
        codecBuffer!: Int64 = 1024,
        taskBuffer!: Int64 = 1024,
        writeParallelism!: Int64 = 8,
        writeBuffer!: Int64 = 1024,
        private let server!: TcpServerSocket, 
        private let encoder!: Encoder<EN>,
        private let decoder!: Decoder<DE>
        private let executor!: (EN) -> DE
    ){
        var parallelism = 1
        while(parallelism < codecParallelism){
            parallelism++
        }
        codecQueues = Array<ArrayBlockingQueue<()->Unit>>(parallelism){i => 
            ArrayBlockingQueue<()->Unit>(codecBuffer)
        }
        parallelism = 1
        while(parallelism < writeParallelism){
            parallelism++
        }
        taskQueue = ArrayBlockingQueue<()->Unit>(taskBuffer)
        writeQueues = Array<ArrayBlockingQueue<()->Unit>(parallelism){i =>
            ArrayBlockingQueue<()->Unit>(writeBuffer)
        }
        startConsume()
        server.bind()
        start()
    }
    public init(codecParallelism!: Int64 = 8, codecBuffer!: Int64 = 1024, taskBuffer!: Int64 = 1024, 
        writeParallelism!: Int64 = 8, writeBuffer!: Int64 = 1024,
        serverCreater!: ()->TcpServerSocket, encoder!: Encoder<EN>, decoder!: Decoder<DE>, executor!: (EN) -> DE) {
        this(codecParallelism: codecParallelism, codecBuffer: codecBuffer, taskBuffer: taskBuffer, 
             writeParallelism: writeParallelism, writeBuffer: writeBuffer,
             server: serverCreater(), encoder: encoder, decoder: decoder, executor: executor)
    }
    public init(codecParallelism!: Int64 = 8, codecBuffer!: Int64 = 1024, taskBuffer!: Int64 = 1024, 
        writeParallelism!: Int64 = 8, writeBuffer!: Int64 = 1024,
        serverCreater!: ()->TcpServerSocket, codec: Codec<EN, DE>, executor!: (EN) -> DE) {
        this(codecParallelism: codecParallelism, codecBuffer: codecBuffer, taskBuffer: taskBuffer, 
             writeParallelism: writeParallelism, writeBuffer: writeBuffer,
             server: serverCreater(), encoder: codec, decoder: codec, executor: executor)
    }
    public init(codecParallelism!: Int64 = 8, codecBuffer!: Int64 = 1024, taskBuffer!: Int64 = 1024, 
        writeParallelism!: Int64 = 8, writeBuffer!: Int64 = 1024,
        port!: UInt16, encoder!: Encoder<EN>, decoder!: Decoder<DE>, executor!: (EN) -> DE) {
        this(codecParallelism: codecParallelism, codecBuffer: codecBuffer, taskBuffer: taskBuffer, 
             writeParallelism: writeParallelism, writeBuffer: writeBuffer,
             server: TcpServerSocket(bindAt: port), encoder: encoder, decoder: decoder, executor: executor)
    }
    public init(codecParallelism!: Int64 = 8, codecBuffer!: Int64 = 1024, taskBuffer!: Int64 = 1024, 
        writeParallelism!: Int64 = 8, writeBuffer!: Int64 = 1024,
        port!: UInt16, codec!: Codec<EN, DE>, executor!: (EN) -> DE): PipelineServer<EN, DE, E, D> {
        this(codecParallelism: codecParallelism, codecBuffer: codecBuffer, taskBuffer: taskBuffer, 
             writeParallelism: writeParallelism, writeBuffer: writeBuffer,
             server: TcpServerSocket(bindAt: port), encoder: codec, decoder: codec, executor: executor)
    }
    private func startConsume(): Unit {
        for(q in codecQueues){
            spawn{
                while(let task <- q.dequeue()){
                    task()
                }
            }
        }
        for(q in writeQueues){
            spawn{
                while(let w <- q.dequeue()){
                    w()
                }
            }
        }
        spawn{
            while(let task in taskQueue){
                spawn{
                    task()
                }
            }
        }
    }
    private func start(): Unit {
        spawn{
            while(!closed.load() && let socket <- server.accept()){
                let decoder = this.decoder.newDecoder()
                let serial = this.serial.fetchAdd(1) % codecQueues.size
                spawn{
                    while(!(closed.load() || socket.isClosed())){
                        let buf = Array<Byte>(128, repeat: 0)
                        let len = try{
                            socket.read(buf)
                        }catch(e: Exception){
                            LOG.warn('socket {} read': e, socket.remoteAddress)
                            continue
                        }
                        codecQueues[serial].enqueue({=>
                            if(let Some(d) <- decoder.decode(buf[0 .. len])){
                                if(d.isToClose){
                                    try{
                                        socket.close()
                                    }catch(e: Exception){
                                        LOG.warn('socket {} close', e, socket.remoteAddress)
                                    }
                                }else{
                                    taskQueue.enqueue({=>
                                        try{
                                            let r = executeor(d)
                                            codecQueues[serial].enqueue({=> 
                                                let bytes = encoder.newEncoder().encode(r)
                                                writeQueues[serial].enqueue({=>
                                                    socket.write(bytes)
                                                })
                                            })
                                        }catch(e: Exception){
                                            LOG.warn('task execute', e)
                                        }
                                    })
                                }
                            }
                        })
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