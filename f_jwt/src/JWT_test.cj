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
