/*
    Copyright (c) [2022] [WuJingrun（吴京润）]
    utility is licensed under Mulan PSL v2.
    You can use this software according to the terms and conditions of the Mulan PSL v2.
    You may obtain a copy of Mulan PSL v2 at:
            http://license.coscl.org.cn/MulanPSL2
    THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
    See the Mulan PSL v2 for more details.
*/
package f_jwt

import std.unittest.*
import std.unittest.testmacro.*

@Test
public class JWTTest {
    @TestCase
    public func test() {
        let jwt = JWT().hmacSHA1('1234567890'.toArray())
        let sign = jwt.keyId('1234567890').expire(Duration.minute).addPayload('name', 'Bob').encoder().sign()
        println(sign)
        @Expect(jwt.verifier(sign).verify(), true)
    }
}
