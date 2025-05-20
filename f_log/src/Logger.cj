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

import stdx.log.LogLevel
import stdx.log.Logger as StdLogger

public abstract class Logger <: StdLogger {
    public mut prop level: LogLevel
    public open func logLevelEnabled(level: LogLevel): Bool {
        enabled(level)
    }
    public func append(level: LogLevel, message: String, ex: Option<Exception>): Unit
    public func error(message: String, ex: Exception): Unit
    public func warn(message: String, ex: Exception): Unit
    public func info(message: String, ex: Exception): Unit
    public func debug(message: String, ex: Exception): Unit
    public func trace(message: String, ex: Exception): Unit
    public func error(ex: Exception): Unit
    public func warn(ex: Exception): Unit
    public func info(ex: Exception): Unit
    public func debug(ex: Exception): Unit
    public func trace(ex: Exception): Unit
    public func error(message: String): Unit
    public func warn(message: String): Unit
    public func info(message: String): Unit
    public func debug(message: String): Unit
    public func trace(message: String): Unit

    public func error(ex: Exception, message: () -> String): Unit
    public func warn(ex: Exception, message: () -> String): Unit
    public func info(ex: Exception, message: () -> String): Unit
    public func debug(ex: Exception, message: () -> String): Unit
    public func trace(ex: Exception, message: () -> String): Unit

    public func error(message: () -> String, ex: Exception): Unit
    public func warn(message: () -> String, ex: Exception): Unit
    public func info(message: () -> String, ex: Exception): Unit
    public func debug(message: () -> String, ex: Exception): Unit
    public func trace(message: () -> String, ex: Exception): Unit
    public func error(message: () -> String): Unit
    public func warn(message: () -> String): Unit
    public func info(message: () -> String): Unit
    public func debug(message: () -> String): Unit
    public func trace(message: () -> String): Unit

    public prop traceEnabled: Bool {
        get() {
            logLevelEnabled(LogLevel.TRACE)
        }
    }
    public prop debugEnabled: Bool {
        get() {
            logLevelEnabled(LogLevel.DEBUG)
        }
    }
    public prop infoEnabled: Bool {
        get() {
            logLevelEnabled(LogLevel.INFO)
        }
    }
    public prop warnEnabled: Bool {
        get() {
            logLevelEnabled(LogLevel.WARN)
        }
    }
    public prop errorEnabled: Bool {
        get() {
            logLevelEnabled(LogLevel.ERROR)
        }
    }
}
