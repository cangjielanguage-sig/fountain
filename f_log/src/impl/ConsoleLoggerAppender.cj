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

import std.process.Process
import std.sync.ReentrantMutex
import std.time.DateTime
import log.* 
import f_exception.*
import f_log.exception.*
public import f_log.*

let _ = ConsoleLoggerAppender.register() //将本实现注册到LoggerAppenderCreator
private class ConsoleLoggerAppender <: AsyncLogger {
    public init(name!: String, level!: LogLevel, pattern!: LogPattern) {
        super(name, level, pattern, Process.current.stdOut)
    }

    public static func register(): Unit {
        LoggerAppenderCreator.register("console") {
            name =>
            let appender = LoggerConfig.getAppenders("console")
            if (appender.isEmpty()) {
                [NoneLogAppender.instance]
            } else {
                let logger = appender[0]
                [
                    ConsoleLoggerAppender(
                        name: name,
                        level: LoggerConfig.getLevelConf(logger),
                        pattern: LoggerConfig.getPatternConf(logger)
                    )
                ]
            }
        }
    }
    public prop closable: Bool {
        get() {
            false
        }
    }
}
