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
