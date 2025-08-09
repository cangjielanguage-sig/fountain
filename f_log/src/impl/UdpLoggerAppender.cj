/*
Copyright (c) 2025 WuJingrun（吴京润）

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
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
        super(name, level, pattern, createSocket(host, port, sendTimeout: sendTimeout),
            '${LOGGER_NAME}://${host}:${port}')
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
            if (appenders.isEmpty()) {
                [NoneLogAppender.instance]
            } else {
                Array<AbstractLogger>(appenders.size) {
                    i =>
                    let appender = appenders[i]
                    var host = "127.0.0.1"
                    var port = 65534u16
                    if (let Some(h) <- LoggerConfig.getString(appender, "host") && !h.isEmpty()) {
                        host = h
                    }
                    if (let Some(p) <- LoggerConfig.getString(appender, "port")) {
                        port = UInt16
                            .tryParse(p)
                            .getOrThrow {
                                LogException(
                                    "param port of SocketLoggerAppender must be a value of UInt16, however it is ${p}")
                            }
                    } else if (let Some(idx) <- host.indexOf(':')) {
                        (host, port) = (host[0..idx].trimAscii(), UInt16.parse(host[idx + 1..].trimAscii()))
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
