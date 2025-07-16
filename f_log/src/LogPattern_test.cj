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

import std.time.DateTime
import std.unittest.*
import std.unittest.testmacro.*
import stdx.log.LogLevel

@Test
public class LogPattern_test {
    @TestCase
    public func test0(): Unit {
        let pattern = LogPattern("[%level%-%name]% %d{yyyy/MM/dd,HH:mm:ss.SSS}|%%m%")
        let now = DateTime.now()
        let level = LogLevel.ERROR
        let logmsg = pattern.generate("test", level, "test message", now)
        println(logmsg)
        let tpl = "[${level.text}%-test]% ${now.format("yyyy/MM/dd,HH:mm:ss.SSS")}|%test message%\n"
        @Assert(tpl, logmsg)
    }
}
