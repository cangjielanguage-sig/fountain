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
protected import std.net.{UnixDatagramSocket, SocketAddress, UnixSocketAddress}
import std.process.Process
import std.sync.AtomicUInt64

protected class UnixDatagramOutputStream <: OutputStream & Resource{
    private static let SERIAL = AtomicUInt64(0)
    private static func newSocket(sendTimeout: ?Duration){
        let sock = UnixDatagramSocket(bindAt: Process.current.tempDirectory.join('${SERIAL.fetchAdd(1)}').toString())
        sock.bind()
        sock.sendTimeout = sendTimeout
        sock
    }
    public UnixDatagramOutputStream(private let sock: UnixDatagramSocket, private let addr: UnixSocketAddress){}
    public init(addr: UnixSocketAddress, sendTimeout!: ?Duration = None){
        this(newSocket(sendTimeout), addr)
    }
    public init(path: String, sendTimeout!: ?Duration = None){
        this(UnixSocketAddress(path), sendTimeout: sendTimeout)
    }
    public func write(buffer: Array<Byte>): Unit {
        sock.sendTo(addr, buffer)
    }
    public func flush(): Unit {}
    public func isClosed(): Bool {
        sock.isClosed()
    }
    public func close(): Unit {
        sock.close()
    }
}