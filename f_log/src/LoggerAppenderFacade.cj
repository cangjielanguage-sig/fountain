/*
    Copyright (c) [2022] [WuJingrun（吴京润）]
    fountain is licensed under Mulan PSL v2.
    You can use this software according to the terms and conditions of the Mulan PSL v2.
    You may obtain a copy of Mulan PSL v2 at:
            http://license.coscl.org.cn/MulanPSL2
    THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
    See the Mulan PSL v2 for more details.
 */
package f_log

import std.process.Process
import std.time.DateTime
import stdx.log.LogLevel
import f_io.DummyOutputStream

public class LoggerAppenderFacade <: AsyncLogger {
    private var appenders: Array<AbstractLogger>

    public init(name: String, appenders: Array<AbstractLogger>) {
        super(name, LogLevel.ALL, LogPattern.default, DummyOutputStream.THROW_ON_ACCESSING,
            'f_log.LoggerAppenderFacade_${name}')
        this.appenders = appenders
    }

    public func logLevelEnabled(level: LogLevel): Bool {
        for (appender in appenders where appender.logLevelEnabled(level)) {
            return true
        }
        return false
    }

    protected func append(level: LogLevel, message: String, now: DateTime, ex: Option<Exception>): Unit {
        append {
            for (appender in appenders) {
                appender.append(level, message, now, ex)
            }
        }
    }
    public func close(): Unit {
        for (appender in appenders where appender.closable) {
            try {
                appender.close()
            } catch (e: Exception) {
                e.printStackTrace()
            }
        }
    }
}
