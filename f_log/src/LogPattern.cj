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
    public operator func ==(that: LogPart): Bool {
        match(that) {
            case x: LogPattern where refEq(this, x) => true
            case x: LogPattern where this.patterns.size != x.patterns.size => false
            case x: LogPattern =>
                for(i in 0..this.patterns.size where this.patterns[i] != x.patterns[i]) {
                    return false
                }
                true
            case _ => false
        }
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
        for (p in patterns) {
            p.generate(name, level, message, current, writer)
        }
        writer.writeString(OS.current.nextLine)
    }
}

public interface LogPart <: Equatable<LogPart> {
    func generate(name: String, level: LogLevel, message: ToString, current: DateTime, writer: LogWriter): Unit
    operator func ==(that: LogPart): Bool{
        true
    }
}

class OriginLogPart <: LogPart {
    OriginLogPart(private let txt: String) {}
    public func generate(_: String, _: LogLevel, _: ToString, _: DateTime, writer: LogWriter): Unit {
        writer.writeString(txt)
    }
    public operator func ==(that: LogPart): Bool{
        match(that) {
            case x: OriginLogPart => refEq(this, x) || this.txt == x.txt
            case _ => false
        }
    }
}

class LevelLogPart <: LogPart {
    init() {}
    public func generate(_: String, level: LogLevel, _: ToString, _: DateTime, writer: LogWriter): Unit {
        writer.writeString(level.text)
    }
}

class NameLogPart <: LogPart {
    init() {}
    public func generate(name: String, _: LogLevel, _: ToString, _: DateTime, writer: LogWriter): Unit {
        writer.writeString(name)
    }
}

class AppLogPart <: LogPart {
    init() {}
    private let app = env.getCommand()
    public func generate(_: String, _: LogLevel, _: ToString, _: DateTime, writer: LogWriter): Unit {
        writer.writeString(app)
    }
    public operator func ==(that: LogPart): Bool{
        match(that) {
            case x: AppLogPart => refEq(this, x) || this.app == x.app
            case _ => false
        }
    }
}

class TimeLogPart <: LogPart {
    TimeLogPart(private let format: String) {}
    init() {
        this('yyyy-MM-dd,HH:mm:ss.SSS')
    }
    public func generate(_: String, _: LogLevel, _: ToString, datetime: DateTime, writer: LogWriter): Unit {
        writer.writeString(datetime.format(format))
    }
    public operator func ==(that: LogPart): Bool{
        match(that) {
            case x: TimeLogPart => refEq(this, x) || this.format == x.format
            case _ => false
        }
    }
}

class MessageLogPart <: LogPart {
    init() {}
    public func generate(_: String, _: LogLevel, message: ToString, _: DateTime, writer: LogWriter): Unit {
        writer.writeString(message.toString())
    }
}
