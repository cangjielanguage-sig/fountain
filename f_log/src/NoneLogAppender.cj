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

import f_log.output.DummyOutputStream

public class NoneLogAppender <: AbstractLogger {
    public static let instance = NoneLogAppender()
    private init() {
        super("", LogLevel.OFF, LogPattern.default, DummyOutputStream.instance)
    }

    public static func register(): Unit {
        LoggerAppenderCreator.register("none") {
            name => [instance]
        }
    }
    protected func append(level: LogLevel, message: String, now: DateTime, ex: Option<Exception>): Unit {
        //do nothing
    }
    public prop closable: Bool {
        get() {
            false
        }
    }
}
