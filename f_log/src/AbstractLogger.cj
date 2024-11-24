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

import std.io.OutputStream
import std.sync.{AtomicBool, ReentrantMutex}
import std.time.DateTime

import log.{LogLevel, Attr, LogRecord}

import f_exception.{BaseException, UnsupportedAccessException, printStackTrace}
import f_log.exception.LogException
import f_util.{TextTemplate, TextTemplateKey, TextTemplateObject}

public abstract class AbstractLogger <: Logger & Resource {
    private let lock = ReentrantMutex()
    protected let name: String
    protected var level_: LogLevel
    protected let pattern: LogPattern
    protected var output: OutputStream
    protected init(name: String, level: LogLevel, pattern: LogPattern, output: OutputStream) {
        this.name = name
        this.level_ = level
        this.pattern = pattern
        this.output = output
    }
    public open func isClosed(): Bool {
        match (output) {
            case r: Resource => r.isClosed()
            case _ => false
        }
    }
    public open func close(): Unit {
        match (output) {
            case r: Resource => r.close()
            case _ => ()
        }
    }

    public mut prop level: LogLevel {
        get(){
            level_
        }
        set(value){
            level_ = value
        }
    }
    public func withAttrs(attrs: Array<Attr>): Logger {
        throw LogException('f_log does not support log.Attr and log.Logger.withAttrs(attrs)')
    }
    public func log(record: LogRecord): Unit {
        append(record.level, record.message, record.time, None<Exception>)
    }

    protected open func append(level: LogLevel, message: () -> String, ex: Option<Exception>): Unit {
        append(level, message(), ex)
        //在LoggerWrapper判断日志级别是一个循环操作，
        //需要判断每一个LoggerAppender是否可以记录当前级别的日志，大部分构造日志的逻辑相对简单，
        //所以此处默认不判断日志级别
        //如果构造日志的逻辑比较复杂，可以在构造日志文本之前先主动判断一次
    }

    //
    public func log(level: LogLevel, message: String): Unit {
        append(level, message)
    }
    protected func append(level: LogLevel, message: String): Unit {
        append(level, message, None<Exception>)
    }
    protected func append(msg: String, ex: ?Exception, output: OutputStream): Unit {
        output.write(msg.toArray())
        appendException(ex, output)
    }
    protected func appendException(ex: ?Exception, output: OutputStream): Unit {
        if (let Some(e) <- ex) {
            if (let c: BaseException <- e) {
                c.printStackTrace(output)
            } else {
                printStackTrace(e, output)
            }
        }
    }
    protected open func doAppend(level: LogLevel, message: String, now: DateTime, ex: Option<Exception>): Unit {
        let msg = pattern.generate(name, level, message, now)
        append(msg, ex, output)
    }
    protected open func append(level: LogLevel, message: String, now: DateTime, ex: Option<Exception>): Unit {
        if (enabled(level)) {
            doAppend(level, message, now, ex)
        }
    }
    protected func doLock<T>(callback: () -> T): T {
        synchronized(lock) {
            callback()
        }
    }
    public func append<T>(level: LogLevel, message: String, args: Array<T>, ex: ?Exception): Unit where T <: ToString {
        append(level, {=>
            TextTemplate.compile(message, prefix: "{", suffix: "}").format<T>(args)
        }, ex)
    }
    public func error<T>(message: String, args: Array<T>): Unit where T <: ToString {
        append<T>(LogLevel.ERROR, message, args, None<Exception>)
    }
    public func error<T>(message: String, ex: Exception, args: Array<T>): Unit where T <: ToString {
        append<T>(LogLevel.ERROR, message, args, ex)
    }
    public func warn<T>(message: String, args: Array<T>): Unit where T <: ToString {
        append<T>(LogLevel.WARN, message, args, None<Exception>)
    }
    public func warn<T>(message: String, ex: Exception, args: Array<T>): Unit where T <: ToString {
        append<T>(LogLevel.WARN, message, args, ex)
    }
    public func info<T>(message: String, args: Array<T>): Unit where T <: ToString {
        append<T>(LogLevel.INFO, message, args, None<Exception>)
    }
    public func info<T>(message: String, ex: Exception, args: Array<T>): Unit where T <: ToString {
        append<T>(LogLevel.INFO, message, args, ex)
    }
    public func debug<T>(message: String, args: Array<T>): Unit where T <: ToString {
        append<T>(LogLevel.DEBUG, message, args, None<Exception>)
    }
    public func debug<T>(message: String, ex: Exception, args: Array<T>): Unit where T <: ToString {
        append<T>(LogLevel.DEBUG, message, args, ex)
    }
    public func trace<T>(message: String, args: Array<T>): Unit where T <: ToString {
        append<T>(LogLevel.TRACE, message, args, None<Exception>)
    }
    public func trace<T>(message: String, ex: Exception, args: Array<T>): Unit where T <: ToString {
        append<T>(LogLevel.TRACE, message, args, ex)
    }
    public func append(level: LogLevel, message: String, ex: Option<Exception>): Unit {
        let now = DateTime.now()
        doLock {
            append(level, message, now, ex)
        }
    }
    protected func append(level: LogLevel, message: String, ex: Exception): Unit {
        append(level, message, Some(ex))
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

    protected func append(level: LogLevel, message: () -> String): Unit {
        append(level, message(), None<Exception>)
    }
    protected func append(level: LogLevel, message: () -> String, ex: Exception): Unit {
        append(level, message(), Some(ex))
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
            enabled(LogLevel.TRACE)
        }
    }
    public prop debugEnabled: Bool {
        get() {
            enabled(LogLevel.DEBUG)
        }
    }
    public prop infoEnabled: Bool {
        get() {
            enabled(LogLevel.INFO)
        }
    }
    public prop warnEnabled: Bool {
        get() {
            enabled(LogLevel.WARN)
        }
    }
    public prop errorEnabled: Bool {
        get() {
            enabled(LogLevel.ERROR)
        }
    }
    public open prop closable: Bool {
        get() {
            true
        }
    }
}
