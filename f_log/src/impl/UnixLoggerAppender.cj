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
import log.LogLevel

let _ = UnixLoggerAppender.register()
private class UnixLoggerAppender <: AsyncLogger {
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
        super(name, level, pattern, createSocket(path, writeTimeout, bufSize), path)
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
        LoggerAppenderCreator.register("socket") {
            name =>
            let appenders = LoggerConfig.getAppenders("socket")
            if(appenders.isEmpty()){
                [NoneLogAppender.instance]
            }else{
                Array<AbstractLogger>(appenders.size){i =>
                    let appender = appenders[i]
                    var path = "/tmp/log/unix.log"
                    if (let Some(h) <- LoggerConfig.getString(appender, "path")) {
                        if (h != String.empty) {
                            path = h
                        }
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
    protected func doAppend(level: LogLevel, message: String, now: DateTime, ex: Option<Exception>): Unit {
        var sock = (super.output as UnixSocket).getOrThrow()
        if (sock.isClosed()) {
            sock = createSocket(path, writeTimeout, bufSize)
            super.output = sock
        }
        super.doAppend(level, message, now, ex)
    }
}
