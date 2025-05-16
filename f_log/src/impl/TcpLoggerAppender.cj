/*
   Copyright (c) [2022] [WuJingrun（吴京润）]
   fountain is licensed under Mulan PSL v2.
   You can use this software according to the terms and conditions of the Mulan PSL v2.
   You may obtain a copy of Mulan PSL v2 at:
           http://license.coscl.org.cn/MulanPSL2
   THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
   See the Mulan PSL v2 for more details.
 */

package f_log.impl

import std.convert.*
import std.net.{SocketNet, TcpSocket, SocketKeepAliveConfig}
import stdx.log.LogLevel
import f_data.*
import f_log.exception.*
import f_log.output.UdpOutputStream

private class TcpLoggerAppender <: AsyncLogger {
    private static const LOGGER_NAME = 'tcp'
    private let host: String
    private let port: UInt16
    private let sendBufSize: ?Int64
    public init(
        name!: String,
        pattern!: LogPattern,
        level!: LogLevel = LogLevel.INFO,
        host!: String,
        port!: UInt16,
        sendBufSize!: ?Int64
    ) {
        super(name, level, pattern, createSocket(host, port, sendBufSize), '${LOGGER_NAME}://${host}:${port}')
        this.host = host
        this.port = port
        this.sendBufSize = sendBufSize
    }
    private static func createSocket(host: String, port: UInt16, sendBufSize: ?Int64) {
        let sock = TcpSocket(host, port)
        sock.keepAlive = SocketKeepAliveConfig()
        if(let Some(s) <- sendBufSize){
            sock.sendBufferSize = s
        }
        sock
    }
    public static func register(): Unit {
        LoggerAppenderCreator.register(LOGGER_NAME) {
            name =>
            let appenders = LoggerConfig.getAppenders(LOGGER_NAME)
            if(appenders.isEmpty()){
                [NoneLogAppender.instance]
            }else{
                Array<AbstractLogger>(appenders.size){i =>
                    let appender = appenders[i]
                    var host = "127.0.0.1"
                    var port = 65535u16
                    if (let Some(h) <- LoggerConfig.getString(appender, "host") && !h.isEmpty()) {
                        host = h
                    }
                    if (let Some(p) <- LoggerConfig.getString(appender, "port")) {
                        port = UInt16.tryParse(p).getOrThrow {
                            LogException(
                                "param port of SocketLoggerAppender must be a value of UInt16, however it is ${p}")
                        }
                    }else if(let Some(idx) <- host.indexOf(':')){
                        (host, port) = (host[0 .. idx].trimAscii(), UInt16.parse(host[idx + 1 ..].trimAscii()))
                    }
                    let sendBufSize = LoggerConfig.getTcpSendBufSize(appender)
                    TcpLoggerAppender(
                        name: name,
                        level: LoggerConfig.getLevelConf(appender),
                        pattern: LoggerConfig.getPatternConf(appender),
                        host: host,
                        port: port,
                        sendBufSize: sendBufSize
                    )
                }
            }
        }
    }
    protected func append(level: LogLevel, message: String, now: DateTime, ex: Option<Exception>): Unit {
        var sock = (super.output as TcpSocket).getOrThrow()
        if (sock.isClosed()) {
            sock = createSocket(host, port, sendBufSize)
            super.output = sock
        }
        super.append(level, message, now, ex)
    }
}
let _ = TcpLoggerAppender.register()