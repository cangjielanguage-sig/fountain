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

internal import std.collection.concurrent.{ArrayBlockingQueue, ConcurrentHashMap}
internal import std.net.{TcpSocket, TcpServerSocket, SocketAddress}
internal import std.process.Process
internal import std.sync.AtomicBool
internal import f_concurrent.{RateLimiter, UnlimitedRateLimiter}
internal import f_exception.UnreachableException
internal import f_log.LoggerFactory

public func initTcpServer(port!: UInt16){
    TcpServerSocket(bindAt: port)
}
public func initTcpServer(new: ()->TcpServerSocket){
    new()
}
public func initTcpClient(host!: String, port!: UInt16){
    TcpSocket(host, port)
}
public func initTcpClient(new: ()->TcpSocket){
    new()
}