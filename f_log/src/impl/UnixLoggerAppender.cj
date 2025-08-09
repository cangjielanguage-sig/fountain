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
        if (let Some(s) <- bufSize) {
            sock.sendBufferSize = s
        }
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
