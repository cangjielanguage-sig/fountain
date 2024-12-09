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
    private static let LOG = LoggerFactory.getLogger<AsyncServer<EN, DE>>()
    private let closed = AtomicBool(false)
    public AsyncServer(
        private let overload!: EN,
        private let execError!: EN,
        private let encodeError!: EN = execError,
        private let codecQueues!: Array<ArrayBlockingQueue<()->Unit>> = initQueues(8, 1024),
        private let taskQueues!: Array<ArrayBlockingQueue<()->Unit>> = codecQueues,
        private let writeQueues!: Array<ArrayBlockingQueue<()->Unit>> = codecQueues,
        private let rateLimiter!: RateLimiter<EN> = UnlimitedRateLimiter<EN>.INSTANCE,
        private let server!: TcpServerSocket, 
        private let encoder!: Encoder<EN>,
        private let decoder!: Decoder<DE>,
        private let executor!: (DE) -> EN
    ){
        startConsume()
        server.bind()
        start()
        Process.current.atExit(close)
    }
    public init(
        overload!: EN,
        execError!: EN,
        encodeError!: EN = execError,
        codecQueues!: Array<ArrayBlockingQueue<()->Unit>> = initQueues(8, 1024),
        taskQueues!: Array<ArrayBlockingQueue<()->Unit>> = codecQueues,
        writeQueues!: Array<ArrayBlockingQueue<()->Unit>> = codecQueues,
        rateLimiter!: RateLimiter<EN> = UnlimitedRateLimiter<EN>.INSTANCE,
        server!: TcpServerSocket, 
        codec!: Codec<EN, DE>,
        executor!: (DE) -> EN
    ){
        this(overload: overload, 
             execError: execError,
             encodeError: encodeError,
             codecQueues: codecQueues,
             taskQueues: taskQueues,
             writeQueues: writeQueues,
             rateLimiter: rateLimiter,
             server: server,
             encoder: codec,
             decoder: codec,
             executor: executor)
    }
    public static func initQueues(parallelism: Int64, bufferSize: Int64){
        let p = if(((parallelism - 1) & parallelism) == 0){
            parallelism
        }else{
            var p = 1
            while(p < parallelism){
                p <<= 1
            }
            p
        }
        Array<ArrayBlockingQueue<()->Unit>>(p){i => 
            ArrayBlockingQueue<()->Unit>(bufferSize)
        }
    }
    
    private func startConsume(): Unit {
        func startTasks(queues: Array<ArrayBlockingQueue<()->Unit>>){
            for(q in queues){
                spawn{
                    while(let task <- q.dequeue()){
                        task()
                    }
                }
            }
        }
        startTasks(codecQueues)
        startTasks(taskQueues)
        startTasks(writeQueues)
    }
    private func start(): Unit {
        while(!closed.load() && let socket <- server.accept()){
            execSocket(socket)
        }
    }
    private func execSocket(socket: TcpSocket){
        let decoder = this.decoder.decoder()
        spawnSocket(socket, decoder)
    }
    private func spawnSocket(socket: TcpSocket, decoder: Decoder<DE>){
        spawn{
            loopSocket(socket, decoder)
        }
    }
    private func loopSocket(socket: TcpSocket, decoder: Decoder<DE>){
        while(!(closed.load() || socket.isClosed())){
            let buf = Array<Byte>(128, repeat: 0)
            let len = try{
                socket.read(buf)
            }catch(e: Exception){
                LOG.warn<SocketAddress>('socket {} read', e, [socket.remoteAddress])
                continue
            }
            enqueueDecode(socket, buf[0 .. len], decoder)
        }
    }
    private func enqueueDecode(socket: TcpSocket, buf: Array<Byte>, decoder: Decoder<DE>){
        codecQueues[calidx(socket, codecQueues.size)].enqueue({=>
            if(let Some(d) <- decoder.decode(buf)){
                if(d.isToClose){
                    try{
                        socket.close()
                    }catch(e: Exception){
                        LOG.warn<SocketAddress>('socket {} close', e, [socket.remoteAddress])
                    }
                }else{
                    enqueueTask(socket, d)
                }
            }
        })
    }
    private func enqueueTask(socket: TcpSocket, d: DE){
        taskQueues[calidx(socket, taskQueues.size)].enqueue({=>
            let r = rateLimiter.exec(overload){
                try{
                    executor(d)
                }catch(e: Exception){
                    LOG.warn<SocketAddress>('task execute', e, [socket.remoteAddress])
                    execError
                }
            }.getOrThrow()
            enqueueEncoding(socket, r)
        })
    }
    private func enqueueEncoding(socket: TcpSocket, r: EN){
        codecQueues[calidx(socket, codecQueues.size)].enqueue({=> 
            let bytes = try {
                encoder.encoder().encode(r)
            }catch(e: Exception){
                LOG.warn<SocketAddress>('async socket encode {}', e, [socket.remoteAddress])
                encoder.encoder().encode(encodeError)
            }
            enqueueWrite(socket, bytes)
        })
    }
    private func enqueueWrite(socket: TcpSocket, bytes: Array<Byte>){
        writeQueues[calidx(socket, writeQueues.size)].enqueue({=>
            try{
                socket.write(bytes)
            }catch(e: Exception){
                LOG.warn<SocketAddress>('async socket write {}', e, [socket.remoteAddress])
            }
        })
    }
    private func calidx(socket: TcpSocket, size: Int64){
        socket.hashCode() & (size - 1)
    }
    public func isClosed(): Bool {
        server.isClosed()
    }
    public func close(): Unit {
        closed.store(true)
        server.close()
    }
}