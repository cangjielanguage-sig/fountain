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

import std.net.UnixSocket
import std.time.DateTime
import f_log.output.UnixOutputStream
import stdx.log.LogLevel


private class UnixLoggerAppender <: AsyncLogger {
    private static const LOGGER_NAME = 'unix'
    private let path: String
    private let writeTimeout: ?Duration
    private let bufSize: ?Int64
    public init(
        name!: String,
        pattern!: LogPattern,
        level!: LogLevel = LogLevel.INFO,
        path!: String,
        writeTimeout!: ?Duration,
        bufSize!: ?Int64
    ) {
        super(name, level, pattern, createSocket(path, writeTimeout, bufSize), '${LOGGER_NAME}:///${path}')
        this.path = path
        this.writeTimeout = writeTimeout
        this.bufSize = bufSize
    }
    private static func createSocket(path: String, writeTimeout: ?Duration, bufSize: ?Int64) {
        let sock = UnixSocket(path)
        sock.writeTimeout = writeTimeout
        if(let Some(s) <- bufSize){
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
                    var path = "/tmp/log/unix.log"
                    if (let Some(h) <- LoggerConfig.getString(appender, "path") && !h.isEmpty()) {
                        path = h
                    }
                    let writeTimeout = LoggerConfig.getUnixWriteTimeout(appender)
                    let bufSize = LoggerConfig.getUnixBufSize(appender)
                    UnixLoggerAppender(
                        name: name,
                        level: LoggerConfig.getLevelConf(appender),
                        pattern: LoggerConfig.getPatternConf(appender),
                        path: path,
                        writeTimeout: writeTimeout,
                        bufSize: bufSize
                    )
                }
            }
        }
    }
    protected func append(level: LogLevel, message: String, now: DateTime, ex: Option<Exception>): Unit {
        var sock = (super.output as UnixSocket).getOrThrow()
        if (sock.isClosed()) {
            sock = createSocket(path, writeTimeout, bufSize)
            super.output = sock
        }
        super.append(level, message, now, ex)
    }
}
let _ = UnixLoggerAppender.register()