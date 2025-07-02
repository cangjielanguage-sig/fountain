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
protected import std.net.{UdpSocket, IPSocketAddress, SocketAddress}

protected class UdpOutputStream <: OutputStream & Resource {
    public UdpOutputStream(private let udp: UdpSocket, private let addr: IPSocketAddress) {}
    public init(addr: String, port: UInt16, sendTimeout!: ?Duration = None<Duration>) {
        let sockAddr = IPSocketAddress(addr, port)
        let sock = UdpSocket(bindAt: 0)
        sock.sendTimeout = sendTimeout
        sock.bind()
        this.udp = sock
        this.addr = sockAddr
    }
    public init(addr: String, sendTimeout!: ?Duration = None<Duration>) {
        let sockAddr = IPSocketAddress.parse(addr)
        let sock = UdpSocket(bindAt: 0)
        sock.sendTimeout = sendTimeout
        sock.bind()
        this.udp = sock
        this.addr = sockAddr
    }
    public func write(buffer: Array<Byte>): Unit {
        udp.sendTo(addr, buffer)
    }
    public func flush(): Unit {}
    public func isClosed(): Bool {
        udp.isClosed()
    }
    public func close(): Unit {
        udp.close()
    }
}
