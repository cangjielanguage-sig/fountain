/*
    Copyright (c) [2022] [WuJingrun（吴京润）]
    fountain is licensed under Mulan PSL v2.
    You can use this software according to the terms and conditions of the Mulan PSL v2.
    You may obtain a copy of Mulan PSL v2 at:
            http://license.coscl.org.cn/MulanPSL2
    THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
    See the Mulan PSL v2 for more details.
 */
package f_ticktock

internal import std.unittest.*
internal import std.unittest.testmacro.*
@Test
public class CronCompiler_test {
    @TestCase
    public func test(): Unit {
        let cron = "0/5-30 0-5 1/2 L * 1,3/2-5,7";
        let cdc = CronCompiler.compile(cron);
        for (c in cdc) {
            for (unit in TicktockUnit.values) {
                match (c.get(unit)) {
                    case Some(crons) => for (cron in crons) {
                        println(cron)
                    }
                    case None => throw Exception()
                }
            }
        }
    }
}
