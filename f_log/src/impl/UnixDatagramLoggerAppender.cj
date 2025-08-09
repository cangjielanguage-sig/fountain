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

import std.time.DateTime
import f_log.output.UnixDatagramOutputStream
import stdx.log.LogLevel

private class UnixDatagramLoggerAppender <: AsyncLogger {
    private static const LOGGER_NAME = 'unixDatagram'
    public UnixDatagramLoggerAppender(
        name!: String,
        pattern!: LogPattern,
        level!: LogLevel = LogLevel.INFO,
        private let path!: String,
        private let sendTimeout!: ?Duration,
        private let bufSize!: ?Int64 = None
    ) {
        super(name, level, pattern, createSocket(path, sendTimeout, bufSize), '${LOGGER_NAME}:///${path}')
    }
    private static func createSocket(path: String, sendTimeout: ?Duration, bufSize: ?Int64) {
        let sock = UnixDatagramOutputStream(path, sendTimeout: sendTimeout, bufSize: bufSize)
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
                        sendTimeout: sendTimeout,
                        bufSize: bufSize
                    )
                }
            }
        }
    }
    protected func append(level: LogLevel, message: String, now: DateTime, ex: Option<Exception>): Unit {
        var sock = (super.output as UnixDatagramOutputStream).getOrThrow()
        if (sock.isClosed()) {
            sock = createSocket(path, sendTimeout, bufSize)
            super.output = sock
        }
        super.append(level, message, now, ex)
    }
}

let _ = UnixDatagramLoggerAppender.register()
