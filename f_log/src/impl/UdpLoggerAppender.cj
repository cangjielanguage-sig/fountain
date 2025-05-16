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
import std.time.DateTime
import stdx.log.LogLevel
import f_log.exception.LogException
import f_log.output.UdpOutputStream

private class UdpLoggerAppender <: AsyncLogger {
    private static const LOGGER_NAME = 'udp'
    private let host: String
    private let port: UInt16
    private let sendTimeout: ?Duration

    public init(
        name!: String,
        pattern!: LogPattern,
        level!: LogLevel = LogLevel.INFO,
        host!: String,
        port!: UInt16,
        sendTimeout!: ?Duration
    ) {
        super(name, level, pattern, createSocket(host, port, sendTimeout: sendTimeout), '${LOGGER_NAME}://${host}:${port}')
        this.host = host
        this.port = port
        this.sendTimeout = sendTimeout
    }
    private static func createSocket(host: String, port: UInt16, sendTimeout!: ?Duration) {
        let sock = UdpOutputStream(host, port, sendTimeout: sendTimeout)
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
                    var port = 65534u16
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
                    let sendTimeout = LoggerConfig.getUdpSendTimeout("${appender}")
                    UdpLoggerAppender(
                        name: name,
                        level: LoggerConfig.getLevelConf(appender),
                        pattern: LoggerConfig.getPatternConf(appender),
                        host: host,
                        port: port,
                        sendTimeout: sendTimeout
                    )
                }
            }
        }
    }
    protected func append(level: LogLevel, message: String, now: DateTime, ex: Option<Exception>): Unit {
        var sock = (super.output as UdpOutputStream).getOrThrow()
        if (sock.isClosed()) {
            sock = createSocket(host, port, sendTimeout: sendTimeout)
            super.output = sock
        }
        super.append(level, message, now, ex)
    }
}
let _ = UdpLoggerAppender.register()