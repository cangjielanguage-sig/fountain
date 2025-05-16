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

import std.time.DateTime
import f_log.output.UnixDatagramOutputStream
import stdx.log.LogLevel

private class UnixDatagramLoggerAppender <: AsyncLogger {
    private static const LOGGER_NAME = 'unixDatagram'
    private let path: String
    private let sendTimeout: ?Duration
    public init(
        name!: String,
        pattern!: LogPattern,
        level!: LogLevel = LogLevel.INFO,
        path!: String,
        sendTimeout!: ?Duration
    ) {
        super(name, level, pattern, createSocket(path, sendTimeout), '${LOGGER_NAME}:///${path}')
        this.path = path
        this.sendTimeout = sendTimeout
    }
    private static func createSocket(path: String, sendTimeout: ?Duration) {
        let sock = UnixDatagramOutputStream(path, sendTimeout: sendTimeout)
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
                    var path = "/tmp/log/unixDatagram.log"
                    if (let Some(h) <- LoggerConfig.getString(appender, "path") && !h.isEmpty()) {
                        path = h
                    }
                    let sendTimeout = LoggerConfig.getUnixWriteTimeout(appender)
                    let bufSize = LoggerConfig.getUnixBufSize(appender)
                    UnixDatagramLoggerAppender(
                        name: name,
                        level: LoggerConfig.getLevelConf(appender),
                        pattern: LoggerConfig.getPatternConf(appender),
                        path: path,
                        sendTimeout: sendTimeout
                    )
                }
            }
        }
    }
    protected func append(level: LogLevel, message: String, now: DateTime, ex: Option<Exception>): Unit {
        var sock = (super.output as UnixDatagramOutputStream).getOrThrow()
        if (sock.isClosed()) {
            sock = createSocket(path, sendTimeout)
            super.output = sock
        }
        super.append(level, message, now, ex)
    }
}
let _ = UnixDatagramLoggerAppender.register()