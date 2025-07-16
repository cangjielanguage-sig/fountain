/*
    Copyright (c) 2022 WuJingrun（吴京润）
    fountain is licensed under Mulan PSL v2.
    You can use this software according to the terms and conditions of the Mulan PSL v2.
    You may obtain a copy of Mulan PSL v2 at:
            http://license.coscl.org.cn/MulanPSL2
    THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
    See the Mulan PSL v2 for more details.
 */
package f_log

import std.unittest.*
import std.unittest.testmacro.*
import std.env
import stdx.log.*
import std.process.Process

public open class TestLogAppender <: AbstractLogger {
    init(name!: String, level!: LogLevel) {
        super(name, level, LogPattern("[%level-%name] %d{yyyy/MM/dd,HH:mm:ss.SSS}|%m"), env.getStdOut())
    }

    public open prop closable: Bool {
        get() {
            false
        }
    }
}

let _ = Test1LogAppender.register(LogLevel.INFO)

public class Test1LogAppender <: TestLogAppender {
    public init(level!: LogLevel) {
        super(name: "test1", level: level)
    }
    public static func register(level: LogLevel): Unit {
        LoggerAppenderCreator.register("test1") {
            name => [Test1LogAppender(level: level)]
        }
    }
}

let _ = Test2LogAppender.register(LogLevel.ERROR)

public class Test2LogAppender <: TestLogAppender {
    public init(level!: LogLevel) {
        super(name: "test2", level: level)
    }
    public static func register(level: LogLevel): Unit {
        LoggerAppenderCreator.register("test2") {
            name => [Test2LogAppender(level: level)]
        }
    }
}

@Test
public class LoggerTest {
    @TestCase
    public func test(): Unit {
        let log = LoggerFactory.getLogger("LoggerTest")
        log.debug("no")
        log.info("all")
        log.warn("warn")
        log.error("err")
    }
}
