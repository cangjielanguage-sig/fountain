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
package f_log

import std.io.OutputStream
import std.sync.{AtomicBool, Mutex}
import std.time.DateTime
import stdx.log.{LogLevel, Attr, LogRecord, LogWriter}
import f_base.{OS, BaseException, printStackTrace}
import f_exception.UnsupportedAccessException
import f_log.exception.LogException
import f_log.output.LogWriterImpl

public abstract class AbstractLogger <: Logger & Resource {
    private let lock = Mutex()
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
                doLock {
                    append(record.level, record.message, record.time, None<Exception>)
                    func writeAttrs(attrs: Array<Attr>) {
                        if (attrs.isEmpty()) {
                            return
                        }
                        writer.startObject()
                        for (i in 0..attrs.size) {
                            if (i > 0) {
                                writer.writeString(',')
                            }
                            let attr = attrs[i]
                            writer.writeString('${attr[0]}:')
                            attr[1].writeTo(writer)
                        }
                        writer.endObject()
                        writer.writeString(OS.current.nextLine)
                    }
                    writeAttrs(globalAttrMap.get(name) ?? [])
                    writeAttrs(this.attrs.get() ?? [])
                    writeAttrs(record.attrs)
                }
            }
        } finally {
            attrs.set(None<Array<Attr>>)
        }
    }

    protected func append(level: LogLevel, message: () -> String, ex: Option<Exception>): Unit {
        if (logLevelEnabled(level)) {
            doLock {
                let now = DateTime.now()
                append(level, message(), now, ex)
            }
        }
    }

    protected func appendException(ex: ?Exception, output: LogWriter): Unit {
        if (let Some(e) <- ex) {
            output.writeException(e)
        }
    }
    protected open func append(level: LogLevel, message: String, now: DateTime, ex: Option<Exception>): Unit {
        pattern.generate(name, level, message, now, writer)
        appendException(ex, writer)
    }
    protected func doLock<T>(callback: () -> T): T {
        synchronized(lock) {
            callback()
        }
    }

    public open prop closable: Bool {
        get() {
            true
        }
    }
}
