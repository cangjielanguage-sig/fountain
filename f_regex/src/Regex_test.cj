/*
    Copyright (c) [2022] [WuJingrun（吴京润）]
    fountain is licensed under Mulan PSL v2.
    You can use this software according to the terms and conditions of the Mulan PSL v2.
    You may obtain a copy of Mulan PSL v2 at:
            http://license.coscl.org.cn/MulanPSL2
    THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
    See the Mulan PSL v2 for more details.
 */
package f_regex

import std.unittest.*
import std.unittest.testmacro.*
import std.time.DateTime
import std.sync.{AtomicInt64, SyncCounter}

@Test
public class Regex_test {
    @TestCase
    public func test(): Unit {
        var reg = Regex.builder().start.lsquare.notIn.whitespace.digit.rsquare.oneOrMore.end.build()
        println(reg.string())
        @Assert(reg.string(), #"^[^ \d]+$"#)
        reg = Regex.builder().start.lparan.notDigit.or.notBlank.or.notAlpha.rparan.zeroOrMore.end.build()
        println(reg.string())
        @Assert(reg.string(), #"^(\D|\S|[^a-zA-Z])*$"#)
    }
    @TestCase
    public func test2(): Unit {
        var current = DateTime.now()
        let reg1 = #"^\d+$"#.regex(solid: true)
        println(Duration.since(current))
        current = DateTime.now()
        let reg2 = #"^\d+$"#.regex(solid: true)
        println(Duration.since(current))
        current = DateTime.now()
        let reg3 = Regex(#"^\d+$"#)
        println(Duration.since(current))
    }
    @TestCase
    public func test3(): Unit {
        let consumed = AtomicInt64(0)
        let latch = SyncCounter(20)
        var i = 0
        while (i < 20) {
            spawn {
                var reg1 = Regex("^$")
                var j = 0
                while (j < 1000) {
                    var current = DateTime.now()
                    reg1 = #"^\d+$"#.regex()
                    consumed.fetchAdd(Duration.since(current).toNanoseconds())
                    j++
                }
                println(reg1.string())
                latch.dec()
            }
            i++
        }
        latch.waitUntilZero()
        println(consumed.load())
        consumed.store(0)
        let latch2 = SyncCounter(20)
        i = 0
        while (i < 20) {
            spawn {
                var reg1 = Regex("^$")
                var j = 0
                while (j < 1000) {
                    var current = DateTime.now()
                    reg1 = Regex(#"^\d+$"#)
                    consumed.fetchAdd(Duration.since(current).toNanoseconds())
                    j++
                }
                println(reg1.string())
                latch2.dec()
            }
            i++
        }
        latch2.waitUntilZero()
        println(consumed.load())
    }
}
