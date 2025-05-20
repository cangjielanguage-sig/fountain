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

import std.collection.{ArrayList, HashMap, TreeMap, Map}
import std.collection.concurrent.ConcurrentHashMap
import stdx.log.LogLevel
import stdx.log.Logger as StdLogger
import f_collection.LinkedHashMap
import f_data.ObjectData
import f_util.{TextTemplate, TextTemplateKey, TextTemplateObject}

public abstract class Logger <: StdLogger {
    public mut prop level: LogLevel
    public open func logLevelEnabled(level: LogLevel): Bool {
        enabled(level)
    }

    protected func append(level: LogLevel, message: () -> String, ex: ?Exception): Unit 
    protected func append(level: LogLevel, message: () -> String): Unit {
        append(level, message, None<Exception>)
    }
    protected func append(level: LogLevel, message: String): Unit {
        append(level, message, None<Exception>)
    }
    
    public func append(level: LogLevel, message: String, ex: Option<Exception>): Unit {
        append(level, {=> message}, ex)
    }
    
    public func append<T>(level: LogLevel, message: String, args: Array<T>, ex: ?Exception): Unit where T <: ToString {
        append(
            level,
            {
                => TextTemplate.compile(message, prefix: "{", suffix: "}").format<T>(args)
            },
            ex
        )
    }
    public func append<T>(level: LogLevel, message: String, args: T, ex: ?Exception): Unit where T <: Object & ObjectData<T> {
        append(
            level,
            {
                => TextTemplate.compile(message, prefix: "{", suffix: "}").format<T>(args)
            },
            ex
        )
    }
    public func append<T>(level: LogLevel, message: String, args: ArrayList<T>, ex: ?Exception): Unit where T <: ToString {
        append(
            level,
            {
                => TextTemplate.compile(message, prefix: "{", suffix: "}").format<T>(args)
            },
            ex
        )
    }
    public func append<T>(level: LogLevel, message: String, args: HashMap<String, T>, ex: ?Exception): Unit where T <: ToString {
        append(
            level,
            {
                => TextTemplate.compile(message, prefix: "{", suffix: "}").format<T>(args)
            },
            ex
        )
    }
    public func append<T>(level: LogLevel, message: String, args: ConcurrentHashMap<String, T>, ex: ?Exception): Unit where T <: ToString {
        append(
            level,
            {
                => TextTemplate.compile(message, prefix: "{", suffix: "}").format<T>(args)
            },
            ex
        )
    }
    public func append<T>(level: LogLevel, message: String, args: TreeMap<String, T>, ex: ?Exception): Unit where T <: ToString {
        append(
            level,
            {
                => TextTemplate.compile(message, prefix: "{", suffix: "}").format<T>(args)
            },
            ex
        )
    }
    public func append<T>(level: LogLevel, message: String, args: LinkedHashMap<String, T>, ex: ?Exception): Unit where T <: ToString {
        append(
            level,
            {
                => TextTemplate.compile(message, prefix: "{", suffix: "}").format<T>(args)
            },
            ex
        )
    }
    public func error<T>(message: String, args: Array<T>): Unit where T <: ToString {
        append<T>(LogLevel.ERROR, message, args, None<Exception>)
    }
    public func error<T>(message: String, ex: Exception, args: Array<T>): Unit where T <: ToString {
        append<T>(LogLevel.ERROR, message, args, ex)
    }

    public func error<T>(message: String, args: ArrayList<T>): Unit where T <: ToString {
        append<T>(LogLevel.ERROR, message, args, None<Exception>)
    }
    public func error<T>(message: String, args: HashMap<String, T>): Unit where T <: ToString {
        append<T>(LogLevel.ERROR, message, args, None<Exception>)
    }
    public func error<T>(message: String, args: ConcurrentHashMap<String, T>): Unit where T <: ToString {
        append<T>(LogLevel.ERROR, message, args, None<Exception>)
    }
    public func error<T>(message: String, args: LinkedHashMap<String, T>): Unit where T <: ToString {
        append<T>(LogLevel.ERROR, message, args, None<Exception>)
    }
    public func error<T>(message: String, args: TreeMap<String, T>): Unit where T <: ToString {
        append<T>(LogLevel.ERROR, message, args, None<Exception>)
    }
    public func error<T>(message: String, args: T): Unit where T <: Object & ObjectData<T> {
        append<T>(LogLevel.ERROR, message, args, None<Exception>)
    }

    public func error<T>(message: String, ex: Exception, args: ArrayList<T>): Unit where T <: ToString {
        append<T>(LogLevel.ERROR, message, args, ex)
    }
    public func error<T>(message: String, ex: Exception, args: HashMap<String, T>): Unit where T <: ToString {
        append<T>(LogLevel.ERROR, message, args, ex)
    }
    public func error<T>(message: String, ex: Exception, args: LinkedHashMap<String, T>): Unit where T <: ToString {
        append<T>(LogLevel.ERROR, message, args, ex)
    }
    public func error<T>(message: String, ex: Exception, args: ConcurrentHashMap<String, T>): Unit where T <: ToString {
        append<T>(LogLevel.ERROR, message, args, ex)
    }
    public func error<T>(message: String, ex: Exception, args: TreeMap<String, T>): Unit where T <: ToString {
        append<T>(LogLevel.ERROR, message, args, ex)
    }
    public func error<T>(message: String, ex: Exception, args: T): Unit where T <: Object & ObjectData<T> {
        append<T>(LogLevel.ERROR, message, args, ex)
    }

    public func warn<T>(message: String, args: Array<T>): Unit where T <: ToString {
        append<T>(LogLevel.WARN, message, args, None<Exception>)
    }
    public func warn<T>(message: String, ex: Exception, args: Array<T>): Unit where T <: ToString {
        append<T>(LogLevel.WARN, message, args, ex)
    }

    public func warn<T>(message: String, args: ArrayList<T>): Unit where T <: ToString {
        append<T>(LogLevel.WARN, message, args, None<Exception>)
    }
    public func warn<T>(message: String, args: HashMap<String, T>): Unit where T <: ToString {
        append<T>(LogLevel.WARN, message, args, None<Exception>)
    }
    public func warn<T>(message: String, args: ConcurrentHashMap<String, T>): Unit where T <: ToString {
        append<T>(LogLevel.WARN, message, args, None<Exception>)
    }
    public func warn<T>(message: String, args: LinkedHashMap<String, T>): Unit where T <: ToString {
        append<T>(LogLevel.WARN, message, args, None<Exception>)
    }
    public func warn<T>(message: String, args: TreeMap<String, T>): Unit where T <: ToString {
        append<T>(LogLevel.WARN, message, args, None<Exception>)
    }
    public func warn<T>(message: String, args: T): Unit where T <: Object & ObjectData<T> {
        append<T>(LogLevel.WARN, message, args, None<Exception>)
    }

    public func warn<T>(message: String, ex: Exception, args: HashMap<String, T>): Unit where T <: ToString {
        append<T>(LogLevel.WARN, message, args, ex)
    }
    public func warn<T>(message: String, ex: Exception, args: LinkedHashMap<String, T>): Unit where T <: ToString {
        append<T>(LogLevel.WARN, message, args, ex)
    }
    public func warn<T>(message: String, ex: Exception, args: ConcurrentHashMap<String, T>): Unit where T <: ToString {
        append<T>(LogLevel.WARN, message, args, ex)
    }
    public func warn<T>(message: String, ex: Exception, args: TreeMap<String, T>): Unit where T <: ToString {
        append<T>(LogLevel.WARN, message, args, ex)
    }
    public func warn<T>(message: String, ex: Exception, args: T): Unit where T <: Object & ObjectData<T> {
        append<T>(LogLevel.WARN, message, args, ex)
    }

    public func info<T>(message: String, args: Array<T>): Unit where T <: ToString {
        append<T>(LogLevel.INFO, message, args, None<Exception>)
    }
    public func info<T>(message: String, ex: Exception, args: Array<T>): Unit where T <: ToString {
        append<T>(LogLevel.INFO, message, args, ex)
    }

    public func info<T>(message: String, args: ArrayList<T>): Unit where T <: ToString {
        append<T>(LogLevel.INFO, message, args, None<Exception>)
    }
    public func info<T>(message: String, args: HashMap<String, T>): Unit where T <: ToString {
        append<T>(LogLevel.INFO, message, args, None<Exception>)
    }
    public func info<T>(message: String, args: ConcurrentHashMap<String, T>): Unit where T <: ToString {
        append<T>(LogLevel.INFO, message, args, None<Exception>)
    }
    public func info<T>(message: String, args: LinkedHashMap<String, T>): Unit where T <: ToString {
        append<T>(LogLevel.INFO, message, args, None<Exception>)
    }
    public func info<T>(message: String, args: TreeMap<String, T>): Unit where T <: ToString {
        append<T>(LogLevel.INFO, message, args, None<Exception>)
    }
    public func info<T>(message: String, args: T): Unit where T <: Object & ObjectData<T> {
        append<T>(LogLevel.INFO, message, args, None<Exception>)
    }

    public func info<T>(message: String, ex: Exception, args: ArrayList<T>): Unit where T <: ToString {
        append<T>(LogLevel.INFO, message, args, ex)
    }
    public func info<T>(message: String, ex: Exception, args: HashMap<String, T>): Unit where T <: ToString {
        append<T>(LogLevel.INFO, message, args, ex)
    }
    public func info<T>(message: String, ex: Exception, args: LinkedHashMap<String, T>): Unit where T <: ToString {
        append<T>(LogLevel.INFO, message, args, ex)
    }
    public func info<T>(message: String, ex: Exception, args: ConcurrentHashMap<String, T>): Unit where T <: ToString {
        append<T>(LogLevel.INFO, message, args, ex)
    }
    public func info<T>(message: String, ex: Exception, args: TreeMap<String, T>): Unit where T <: ToString {
        append<T>(LogLevel.INFO, message, args, ex)
    }
    public func info<T>(message: String, ex: Exception, args: T): Unit where T <: Object & ObjectData<T> {
        append<T>(LogLevel.INFO, message, args, ex)
    }

    public func debug<T>(message: String, args: Array<T>): Unit where T <: ToString {
        append<T>(LogLevel.DEBUG, message, args, None<Exception>)
    }
    public func debug<T>(message: String, ex: Exception, args: Array<T>): Unit where T <: ToString {
        append<T>(LogLevel.DEBUG, message, args, ex)
    }

    public func debug<T>(message: String, args: ArrayList<T>): Unit where T <: ToString {
        append<T>(LogLevel.DEBUG, message, args, None<Exception>)
    }
    public func debug<T>(message: String, args: HashMap<String, T>): Unit where T <: ToString {
        append<T>(LogLevel.DEBUG, message, args, None<Exception>)
    }
    public func debug<T>(message: String, args: ConcurrentHashMap<String, T>): Unit where T <: ToString {
        append<T>(LogLevel.DEBUG, message, args, None<Exception>)
    }
    public func debug<T>(message: String, args: LinkedHashMap<String, T>): Unit where T <: ToString {
        append<T>(LogLevel.DEBUG, message, args, None<Exception>)
    }
    public func debug<T>(message: String, args: TreeMap<String, T>): Unit where T <: ToString {
        append<T>(LogLevel.DEBUG, message, args, None<Exception>)
    }
    public func debug<T>(message: String, args: T): Unit where T <: Object & ObjectData<T> {
        append<T>(LogLevel.DEBUG, message, args, None<Exception>)
    }

    public func debug<T>(message: String, ex: Exception, args: ArrayList<T>): Unit where T <: ToString {
        append<T>(LogLevel.DEBUG, message, args, ex)
    }
    public func debug<T>(message: String, ex: Exception, args: HashMap<String, T>): Unit where T <: ToString {
        append<T>(LogLevel.DEBUG, message, args, ex)
    }
    public func debug<T>(message: String, ex: Exception, args: LinkedHashMap<String, T>): Unit where T <: ToString {
        append<T>(LogLevel.DEBUG, message, args, ex)
    }
    public func debug<T>(message: String, ex: Exception, args: ConcurrentHashMap<String, T>): Unit where T <: ToString {
        append<T>(LogLevel.DEBUG, message, args, ex)
    }
    public func debug<T>(message: String, ex: Exception, args: TreeMap<String, T>): Unit where T <: ToString {
        append<T>(LogLevel.DEBUG, message, args, ex)
    }
    public func debug<T>(message: String, ex: Exception, args: T): Unit where T <: Object & ObjectData<T> {
        append<T>(LogLevel.DEBUG, message, args, ex)
    }

    public func trace<T>(message: String, args: Array<T>): Unit where T <: ToString {
        append<T>(LogLevel.TRACE, message, args, None<Exception>)
    }
    public func trace<T>(message: String, ex: Exception, args: Array<T>): Unit where T <: ToString {
        append<T>(LogLevel.TRACE, message, args, ex)
    }

    public func trace<T>(message: String, args: ArrayList<T>): Unit where T <: ToString {
        append<T>(LogLevel.TRACE, message, args, None<Exception>)
    }
    public func trace<T>(message: String, args: HashMap<String, T>): Unit where T <: ToString {
        append<T>(LogLevel.TRACE, message, args, None<Exception>)
    }
    public func trace<T>(message: String, args: ConcurrentHashMap<String, T>): Unit where T <: ToString {
        append<T>(LogLevel.TRACE, message, args, None<Exception>)
    }
    public func trace<T>(message: String, args: LinkedHashMap<String, T>): Unit where T <: ToString {
        append<T>(LogLevel.TRACE, message, args, None<Exception>)
    }
    public func trace<T>(message: String, args: TreeMap<String, T>): Unit where T <: ToString {
        append<T>(LogLevel.TRACE, message, args, None<Exception>)
    }
    public func trace<T>(message: String, args: T): Unit where T <: Object & ObjectData<T> {
        append<T>(LogLevel.TRACE, message, args, None<Exception>)
    }

    public func trace<T>(message: String, ex: Exception, args: ArrayList<T>): Unit where T <: ToString {
        append<T>(LogLevel.TRACE, message, args, ex)
    }
    public func trace<T>(message: String, ex: Exception, args: HashMap<String, T>): Unit where T <: ToString {
        append<T>(LogLevel.TRACE, message, args, ex)
    }
    public func trace<T>(message: String, ex: Exception, args: LinkedHashMap<String, T>): Unit where T <: ToString {
        append<T>(LogLevel.TRACE, message, args, ex)
    }
    public func trace<T>(message: String, ex: Exception, args: ConcurrentHashMap<String, T>): Unit where T <: ToString {
        append<T>(LogLevel.TRACE, message, args, ex)
    }
    public func trace<T>(message: String, ex: Exception, args: TreeMap<String, T>): Unit where T <: ToString {
        append<T>(LogLevel.TRACE, message, args, ex)
    }
    public func trace<T>(message: String, ex: Exception, args: T): Unit where T <: Object & ObjectData<T> {
        append<T>(LogLevel.TRACE, message, args, ex)
    }

    public func error(message: String, ex: Exception): Unit {
        append(LogLevel.ERROR, message, ex)
    }
    public func warn(message: String, ex: Exception): Unit {
        append(LogLevel.WARN, message, ex)
    }
    public func info(message: String, ex: Exception): Unit {
        append(LogLevel.INFO, message, ex)
    }
    public func debug(message: String, ex: Exception): Unit {
        append(LogLevel.DEBUG, message, ex)
    }
    public func trace(message: String, ex: Exception): Unit {
        append(LogLevel.TRACE, message, ex)
    }
    public func error(ex: Exception, message: () -> String): Unit {
        append(LogLevel.ERROR, message, ex)
    }
    public func warn(ex: Exception, message: () -> String): Unit {
        append(LogLevel.WARN, message, ex)
    }
    public func info(ex: Exception, message: () -> String): Unit {
        append(LogLevel.INFO, message, ex)
    }
    public func debug(ex: Exception, message: () -> String): Unit {
        append(LogLevel.DEBUG, message, ex)
    }
    public func trace(ex: Exception, message: () -> String): Unit {
        append(LogLevel.TRACE, message, ex)
    }

    public func error(ex: Exception): Unit {
        append(LogLevel.ERROR, String.empty, ex)
    }
    public func warn(ex: Exception): Unit {
        append(LogLevel.WARN, String.empty, ex)
    }
    public func info(ex: Exception): Unit {
        append(LogLevel.INFO, String.empty, ex)
    }
    public func debug(ex: Exception): Unit {
        append(LogLevel.DEBUG, String.empty, ex)
    }
    public func trace(ex: Exception): Unit {
        append(LogLevel.TRACE, String.empty, ex)
    }

    public func error(message: String): Unit {
        append(LogLevel.ERROR, message)
    }
    public func warn(message: String): Unit {
        append(LogLevel.WARN, message)
    }
    public func info(message: String): Unit {
        append(LogLevel.INFO, message)
    }
    public func debug(message: String): Unit {
        append(LogLevel.DEBUG, message)
    }
    public func trace(message: String): Unit {
        append(LogLevel.TRACE, message)
    }

    public func error(message: () -> String, ex: Exception): Unit {
        append(LogLevel.ERROR, message, ex)
    }
    public func warn(message: () -> String, ex: Exception): Unit {
        append(LogLevel.WARN, message, ex)
    }
    public func info(message: () -> String, ex: Exception): Unit {
        append(LogLevel.INFO, message, ex)
    }
    public func debug(message: () -> String, ex: Exception): Unit {
        append(LogLevel.DEBUG, message, ex)
    }
    public func trace(message: () -> String, ex: Exception): Unit {
        append(LogLevel.TRACE, message, ex)
    }

    public func error(message: () -> String): Unit {
        append(LogLevel.ERROR, message)
    }
    public func warn(message: () -> String): Unit {
        append(LogLevel.WARN, message)
    }
    public func info(message: () -> String): Unit {
        append(LogLevel.INFO, message)
    }
    public func debug(message: () -> String): Unit {
        append(LogLevel.DEBUG, message)
    }
    public func trace(message: () -> String): Unit {
        append(LogLevel.TRACE, message)
    }

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
