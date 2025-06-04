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

public open class SocketClient<T, R> <: Resource where T <: ProtocolData<T>, R <: ProtocolData<R> {
    public SocketClient(
        private let socket!: TcpSocket,
        private let encoder!: Encoder<T>,
        private let decoder!: Decoder<R>
    ){
        socket.connect()
    }
    public init(socket!: TcpSocket, codec!: Codec<T, R>){
        this(socket: socket, encoder: codec, decoder: codec)
    }
    public func isClosed(): Bool {
        socket.isClosed()
    }
    public func close(): Unit {
        socket.close()
    }
    public open func transfer(data: T): ?R {
        socket.write(encoder.encode(data))
        while(true){
            let buf = Array<Byte>(128, repeat: 0)
            let len = socket.read(buf)
            if(let Some(x) <- decoder.decode(buf[0 .. len])){
                return x
            }
        }
        None<R>
    }
}
public class AsyncSocketClient<T, K, R> <: SocketClient<T, R> where K <: Hashable & Equatable<K>, T <: KeyedData<K, T>, R <: KeyedData<K, R> {
    public init(socket!: TcpSocket, encoder!: Encoder<T>, decoder!: Decoder<R>){
        super(socket: socket, encoder: encoder, decoder: decoder)
    }
    public init(socket!: TcpSocket, codec!: Codec<T, R>){
        super(socket: socket, codec: codec)
    }
    private let dataMap = ConcurrentHashMap<K, SocketClientFuture<K, R>>()
    public func transfer(data: T): ?R {
        throw UnsupportedException('')
    }
    public func asyncTransfer(data: T): SocketClientFuture<K, R> {
        let future = SocketClientFuture<K, R>(dataMap)
        dataMap[data.key] = future
        spawn{
            if(let Some(d) <- super.transfer(data)){
                dataMap.remove(d.key)?.set(d)
            }else{
                throw UnreachableException()
            }
        }
        future
    }
}
public class SocketClientFuture<K, T> where K <: Hashable & Equatable<K>, T <: KeyedData<K, T> {
    private let q = ArrayBlockingQueue<?T>(1)
    SocketClientFuture(private let map: ConcurrentHashMap<K, SocketClientFuture<K, T>>){}
    func set(data: ?T){
        q.add(data)
    }
    public func get(timeout!: Duration = Duration.Max): ?T {
        if(let Some(x) <- q.remove(timeout) && let Some(v) <- x) {
            map.remove(v.key)
            x
        }else{
            None<T>
        }
    }
}