/*
    Copyright (c) [2022] [WuJingrun（吴京润）]
    fountain is licensed under Mulan PSL v2.
    You can use this software according to the terms and conditions of the Mulan PSL v2.
    You may obtain a copy of Mulan PSL v2 at:
            http://license.coscl.org.cn/MulanPSL2
    THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
    See the Mulan PSL v2 for more details.
 */
package f_orm

import std.unittest.*
import std.unittest.testmacro.*

@Test
public class SqlArgsTest {
    @TestCase
    public func test1(): Unit {
        let args = SqlArgs()
        var arg = args.meet(true, DataType.int64, "user_id =", 1).trimAscii()
        println(arg)
        @Assert(arg, "user_id = ?")
        arg = args.meet(true, DataType.string, "order_id =", "asdf", prefix: "and").trimAscii()
        println(arg)
        @Assert(arg, "and order_id = ?")
        arg = args.meet(false, DataType.string, "save_time =", "asdf", prefix: "and").trimAscii()
        println(arg)
        @Assert(arg, "")
        let namePrefix = "s"
        arg = args.meet(!namePrefix.isEmpty(), "username like", "${namePrefix}%", prefix: "where").trimAscii()
        println(arg)
        @Assert(arg, "where username like ?")

        let argsstr = args.toString().trimAscii()
        println(argsstr)
        @Assert(argsstr, "[(int64, 1), (string, asdf), (string, s%)]")
    }
    @TestCase
    public func test2(): Unit {
        let args = SqlArgs()
        let argstr = args.meeter(prefix: "where", trimTail: "and").meet(true, DataType.int64, "user_id =", 1,
            delimiter: "and").meet(true, DataType.string, "order_id =", "asdf", delimiter: "and").meet(false,
            DataType.datetime, "save_time =", "asdf", delimiter: "and").end.trimAscii()
        println(argstr)
        @Assert(argstr, "where user_id = ? and  order_id = ?")
        @Assert(args.toString(), "[(int64, 1), (string, asdf)]")
    }
}
