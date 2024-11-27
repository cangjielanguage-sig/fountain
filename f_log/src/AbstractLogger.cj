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
import std.io.OutputStream
import std.sync.{AtomicBool, ReentrantMutex}
import std.time.DateTime
import log.{LogLevel, Attr, LogRecord, LogWriter}
import f_base.OS
import f_collection.LinkedHashMap
import f_data.DataObject
import f_exception.{BaseException, UnsupportedAccessException, printStackTrace}
import f_log.exception.LogException
import f_log.output.LogWriterImpl
import f_util.{TextTemplate, TextTemplateKey, TextTemplateObject}

public abstract class AbstractLogger <: Logger & Resource {
    private let lock = ReentrantMutex()
    protected let name: String
    protected var level_: LogLevel
    protected let pattern: LogPattern
    private var output_: OutputStream
    private var writer: LogWriter
    protected init(name: String, level: LogLevel, pattern: LogPattern, output: OutputStream) {
        this.name = name
        this.level_ = level
        this.pattern = pattern
        this.output_ = output
        this.writer = LogWriterImpl(output)
    }
    protected mut prop output: OutputStream {
        get() {
            output_
        }
        set(value) {
            output_ = value
            writer = LogWriterImpl(value)
        }
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
        get() {
            level_
        }
        set(value) {
            level_ = value
        }
    }
    private let attrs = ThreadLocal<Array<Attr>>()
    public func withAttrs(attrs: Array<Attr>): Logger {
        this.attrs.set(attrs)
        this
    }
    public open func log(record: LogRecord): Unit {
        try {
            if (logLevelEnabled(record.level)) {
                doAppend(record.level, record.message, record.time, None<Exception>)
                func writeAttrs(attrs: Array<Attr>) {
                    if (attrs.isEmpty()) {
                        return
                    }
                    writer.startObject()
                    for(i in 0 .. attrs.size) {
                        if(i > 0){
                            writer.writeString(',')
                        }
                        let attr = attrs[i]
                        writer.writeString('${attr[0]}:')
                        attr[1].writeTo(writer)
                    }
                    writer.endObject()
                    writer.writeString(OS.current.nextLine)
                }
                func writeAttrs(attrs: ?Array<Attr>) {
                    if (let Some(attrs) <- attrs) {
                        writeAttrs(attrs)
                    }
                }
                writeAttrs(globalAttrMap.get(name))
                writeAttrs(this.attrs.get())
                writeAttrs(record.attrs)
            }
        } finally {
            attrs.set(None<Array<Attr>>)
        }
    }

    protected func append(level: LogLevel, message: () -> String, ex: Option<Exception>): Unit {
        if(logLevelEnabled(level)){
            doLock {
                let now = DateTime.now()
                append(level, message(), now, ex)
            }
        }
    }

    protected func append(level: LogLevel, message: String): Unit {
        append(level, message, None<Exception>)
    }
    protected func append(msg: String, ex: ?Exception, output: LogWriter): Unit {
        output.writeString(msg)
        appendException(ex, output)
    }
    protected func appendException(ex: ?Exception, output: LogWriter): Unit {
        if (let Some(e) <- ex) {
            output.writeException(e)
        }
    }
    private func doAppend(level: LogLevel, message: String, now: DateTime, ex: Option<Exception>): Unit {
        let msg = pattern.generate(name, level, message, now)
        append(msg, ex, writer)
    }
    protected open func append(level: LogLevel, message: String, now: DateTime, ex: Option<Exception>): Unit {
        if(logLevelEnabled(level)){
            doAppend(level, message, now, ex)
        }
    }
    protected func doLock<T>(callback: () -> T): T {
        synchronized(lock) {
            callback()
        }
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
    public func append<T>(level: LogLevel, message: String, args: T, ex: ?Exception): Unit where T <: DataObject<T> {
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
    public func error<T>(message: String, args: T): Unit where T <: DataObject<T> {
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
    public func error<T>(message: String, ex: Exception, args: T): Unit where T <: DataObject<T> {
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
    public func warn<T>(message: String, args: T): Unit where T <: DataObject<T> {
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
    public func warn<T>(message: String, ex: Exception, args: T): Unit where T <: DataObject<T> {
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
    public func info<T>(message: String, args: T): Unit where T <: DataObject<T> {
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
    public func info<T>(message: String, ex: Exception, args: T): Unit where T <: DataObject<T> {
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
    public func debug<T>(message: String, args: T): Unit where T <: DataObject<T> {
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
    public func debug<T>(message: String, ex: Exception, args: T): Unit where T <: DataObject<T> {
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
    public func trace<T>(message: String, args: T): Unit where T <: DataObject<T> {
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
    public func trace<T>(message: String, ex: Exception, args: T): Unit where T <: DataObject<T> {
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
    public open prop closable: Bool {
        get() {
            true
        }
    }
}
