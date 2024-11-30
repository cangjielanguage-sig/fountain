/*
    Copyright (c) [2022] [WuJingrun（吴京润）]
    fountain is licensed under Mulan PSL v2.
    You can use this software according to the terms and conditions of the Mulan PSL v2.
    You may obtain a copy of Mulan PSL v2 at:
            http://license.coscl.org.cn/MulanPSL2
    THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
    See the Mulan PSL v2 for more details.  
*/
package f_log.output

protected import std.io.OutputStream
protected import std.net.{UnixSocket, SocketAddress, UnixSocketAddress}
import std.process.Process
import std.sync.AtomicUInt64

protected class UnixOutputStream <: OutputStream & Resource {
    private static let SERIAL = AtomicUInt64(0)
    private static func newSocket(addr: UnixSocketAddress, writeTimeout: ?Duration){
        let sock = UnixSocket(addr)
        sock.connect()
        sock.writeTimeout = writeTimeout
        sock
    }
    public UnixOutputStream(private let sock: UnixSocket, private let addr: UnixSocketAddress){}
    public init(addr: UnixSocketAddress, writeTimeout!: ?Duration = None){
        this(newSocket(addr, writeTimeout), addr)
    }
    public init(path: String, writeTimeout!: ?Duration = None){
        this(UnixSocketAddress(path), writeTimeout: writeTimeout)
    }
    public func write(buffer: Array<Byte>): Unit {
        sock.write(buffer)
    }
    public func flush(): Unit {
        sock.flush()
    }
    public func isClosed(): Bool {
        sock.isClosed()
    }
    public func close(): Unit {
        sock.close()
    }
}