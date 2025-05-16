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

import std.collection.ArrayList
import std.env
import std.process.Process
import std.time.{DateTime, DateTimeFormat}
import stdx.log.{LogLevel, LogWriter}
import f_base.OS

public class LogPattern <: LogPart {
    private static let appLogPart = AppLogPart()
    private static let levelLogPart = LevelLogPart()
    private static let nameLogPart = NameLogPart()
    private static let messageLogPart = MessageLogPart()
    public static let default = LogPattern("[%level-%name] %d{yyyy/MM/dd,HH:mm:ss.SSS}|%m") //pattern共44个字符
    private let patterns: ArrayList<LogPart>
    public init(pattern: String) {
        patterns = compile(pattern)
    }
    private static func compile(pattern: String): ArrayList<LogPart> {
        let patterns = ArrayList<LogPart>()
        let origin = ArrayList<Byte>()
        func appendOrigin() {
            if (origin.size > 0) {
                patterns.add(OriginLogPart(String.fromUtf8(origin.toArray())))
                origin.clear()
            }
        }
        var i = 0
        let size = pattern.size
        while (i < size) {
            let c = pattern[i]
            if (c == b'%') {
                if (i + 5 < size && pattern[i + 1..=i + 5] == "level") {
                    appendOrigin()
                    patterns.add(levelLogPart)
                    i += 6
                } else if (i + 3 < size && pattern[i + 1..=i + 3] == "app") {
                    appendOrigin()
                    patterns.add(appLogPart)
                    i += 4
                } else if (i + 4 < size && pattern[i + 1..=i + 4] == "name") {
                    appendOrigin()
                    patterns.add(nameLogPart)
                    i += 5
                } else if (i + 3 < size && pattern[i + 1] == b'd') {
                    if (pattern[i + 2] == b'{') {
                        let ds = i + 3
                        var di = ds
                        while (di < size && pattern[di] != b'}') {
                            di++
                        }
                        if (di < size) {
                            appendOrigin()
                            patterns.add(TimeLogPart(pattern[ds..di]))
                            i = di + 1
                        } else {
                            origin.add(c)
                            i++
                        }
                    } else {
                        appendOrigin()
                        patterns.add(TimeLogPart())
                        i += 2
                    }
                } else if (i + 1 < size && pattern[i + 1] == b'm') {
                    appendOrigin()
                    patterns.add(messageLogPart)
                    i += 2
                } else {
                    origin.add(c)
                    i++
                }
            } else {
                origin.add(c)
                i++
            }
        }
        appendOrigin()
        patterns
    }

    public func generate(name: String, level: LogLevel, message: ToString, current: DateTime, writer: LogWriter): Unit {
        for(p in patterns){
            p.generate(name, level, message, current, writer)
        }
        writer.writeString(OS.current.nextLine)
    }
}

public interface LogPart {
    func generate(name: String, level: LogLevel, message: ToString, current: DateTime, writer: LogWriter): Unit
}

class OriginLogPart <: LogPart {
    OriginLogPart(private let txt: String) {}
    public func generate(name: String, level: LogLevel, message: ToString, current: DateTime, writer: LogWriter): Unit {
        writer.writeString(txt)
    }
}

class LevelLogPart <: LogPart {
    init() {}
    public func generate(name: String, level: LogLevel, message: ToString, current: DateTime, writer: LogWriter): Unit {
        writer.writeString(level.text)
    }
}

class NameLogPart <: LogPart {
    init() {}
    public func generate(name: String, level: LogLevel, message: ToString, current: DateTime, writer: LogWriter): Unit {
        writer.writeString(name)
    }
}

class AppLogPart <: LogPart {
    init() {}
    private let app = env.getCommand()
    public func generate(name: String, level: LogLevel, message: ToString, current: DateTime, writer: LogWriter): Unit {
        writer.writeString(app)
    }
}

class TimeLogPart <: LogPart {
    TimeLogPart(private let format: DateTimeFormat) {}
    init(format: String) {
        this(DateTimeFormat.of(format))
    }
    init() {
        this('yyyy-MM-dd,HH:mm:ss.SSS')
    }
    public func generate(name: String, level: LogLevel, message: ToString, datetime: DateTime, writer: LogWriter): Unit {
        writer.writeString(datetime.toString(format))
    }
}

class MessageLogPart <: LogPart {
    init() {}
    public func generate(name: String, level: LogLevel, message: ToString, current: DateTime, writer: LogWriter): Unit {
        writer.writeString(message.toString())
    }
}
