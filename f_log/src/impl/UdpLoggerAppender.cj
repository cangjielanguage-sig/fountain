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
import log.LogLevel
import f_log.exception.LogException
import f_log.output.UdpOutputStream

let _ = UdpLoggerAppender.register()
private class UdpLoggerAppender <: AsyncLogger {
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
        super(name, level, pattern, createSocket(host, port, sendTimeout: sendTimeout), '${host}:${port}')
        this.host = host
        this.port = port
        this.sendTimeout = sendTimeout
    }
    private static func createSocket(host: String, port: UInt16, sendTimeout!: ?Duration) {
        let sock = UdpOutputStream(host, port, sendTimeout: sendTimeout)
        sock
    }
    public static func register(): Unit {
        LoggerAppenderCreator.register("socket") {
            name =>
            let appenders = LoggerConfig.getAppenders("socket")
            if(appenders.isEmpty()){
                [NoneLogAppender.instance]
            }else{
                Array<AbstractLogger>(appenders.size){i =>
                    let appender = appenders[i]
                    var host = "127.0.0.1"
                    var port = 65535u16
                    if (let Some(h) <- LoggerConfig.getString(appender, "host")) {
                        if (h != String.empty) {
                            host = h
                        }
                    }
                    if (let Some(p) <- LoggerConfig.getString(appender, "port")) {
                        port = UInt16.tryParse(p).getOrThrow {
                            LogException(
                                "param port of SocketLoggerAppender must be a value of UInt16, however it is ${p}")
                        }
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
    protected func doAppend(level: LogLevel, message: String, now: DateTime, ex: Option<Exception>): Unit {
        var sock = (super.output as UdpOutputStream).getOrThrow()
        if (sock.isClosed()) {
            sock = createSocket(host, port, sendTimeout: sendTimeout)
            super.output = sock
        }
        super.doAppend(level, message, now, ex)
    }
}
