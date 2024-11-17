/*
    Copyright (c) [2022] [WuJingrun（吴京润）]
    fountain is licensed under Mulan PSL v2.
    You can use this software according to the terms and conditions of the Mulan PSL v2.
    You may obtain a copy of Mulan PSL v2 at:
            http://license.coscl.org.cn/MulanPSL2
    THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
    See the Mulan PSL v2 for more details.
 */
package f_random

import std.collection.HashSet
import std.unittest.*
import std.unittest.testmacro.*

@Test
public class RandomString_test {
    private let randStr = RandomString()
    private let rand = Random()
    @TestCase
    public func test0(): Unit {
        for (i in 0..10_000) {
            var r = randStr.randomAscii(1)
            @Assert(r.size, 1)
            let ch = UInt8(UInt32(r[0]))
            @Assert(ch >= 0 && ch <= 127 )
            let len = rand.nextInt64(11)
            r = randStr.randomAscii(len)
            @Assert(r.size, len)
        }
    }
    @TestCase
    public func test1(): Unit {
        let source = "1a,;kpzxcqp081341;k.xz,".toRuneArray()
        let set = HashSet<Char>(source)
        for (i in 0..10_000) {
            var r = randStr.random(1, source).toRuneArray()
            @Assert(r.size, 1)
            let ch = r[0]
            @Assert(set.contains(ch))
            let len = rand.nextInt64(11)
            r = randStr.random(len, source).toRuneArray()
            @Assert(r.size, len)
        }
    }
    @TestCase
    public func test2(): Unit {
        for (i in 0..10_000) {
            var r = randStr.randomLowerLetters(1).toRuneArray()
            @Assert(r.size, 1)
            let ch = r[0]
            @Assert(ch>=r'a' && ch<=r'z')
            let len = rand.nextInt64(11)
            r = randStr.randomLowerLetters(len).toRuneArray()
            @Assert(r.size, len)
        }
    }
    @TestCase
    public func test3(): Unit {
        for (i in 0..10_000) {
            var r = randStr.randomUpperLetters(1).toRuneArray()
            @Assert(r.size, 1)
            let ch = r[0]
            @Assert(ch>=r'A' && ch<=r'Z')
            let len = rand.nextInt64(11)
            r = randStr.randomUpperLetters(len).toRuneArray()
            @Assert(r.size, len)
        }
    }
    @TestCase
    public func test4(): Unit {
        for (i in 0..10_0000) {
            var r = randStr.randomAllLetters(1).toRuneArray()
            @Assert(r.size, 1)
            let ch = r[0]
            @Assert((ch>=r'a' && ch<=r'z') || (ch>=r'A' && ch<=r'Z'))
            let len = rand.nextInt64(11)
            r = randStr.randomAllLetters(len).toRuneArray()
            @Assert(r.size, len)
        }
    }
    @TestCase
    public func test5(): Unit {
        for (i in 0..10_0000) {
            var r = randStr.randomNumbers(1).toRuneArray()
            @Assert(r.size, 1)
            let ch = r[0]
            @Assert(ch>=r'0' && ch<=r'9')
            let len = rand.nextInt64(11)
            r = randStr.randomNumbers(len).toRuneArray()
            @Assert(r.size, len)
        }
    }
}
