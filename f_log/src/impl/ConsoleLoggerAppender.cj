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

import std.env
import std.process.Process
import std.sync.Mutex
import std.time.DateTime
import stdx.log.*
import f_exception.*
import f_log.exception.*
public import f_log.*

private class ConsoleLoggerAppender <: AsyncLogger {
    private static const LOGGER_NAME = 'console'
    public init(name!: String, level!: LogLevel, pattern!: LogPattern) {
        super(name, level, pattern, env.getStdOut(), '${LOGGER_NAME}://')
    }

    public static func register(): Unit {
        LoggerAppenderCreator.register(LOGGER_NAME) {
            name =>
            let appender = LoggerConfig.getAppenders(LOGGER_NAME)
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

let _ = ConsoleLoggerAppender.register() //将本实现注册到LoggerAppenderCreator
