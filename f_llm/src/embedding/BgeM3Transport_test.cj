/*
Copyright (c) 2026 WuJingrun（吴京润）

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
package fountain::f_llm.embedding

import std.unittest.*
import std.unittest.testmacro.*

/** 连本机 BGE-M3（127.0.0.1:8000）验证三路真实可用；没有服务时显式跳过。 */
@Test
public class BgeM3TransportTest {

    @TestCase
    func testLiveServiceReturnsThreeRoutes(): Unit {
        let transport = BgeM3Transport()
        try{
            let response = transport.embed('你好，世界')
            @Expect(response.dense.size, 1024)
            @Expect(response.sparse.isEmpty(), false)
            @Expect(response.colbert.size > 0, true)
            @Expect(response.colbert[0].size, 1024)
        }catch(e: AssertException){
            // 断言失败必须冒泡，不能被下面的 SKIP 分支吞掉
            throw e
        }catch(e: Exception){
            println("SKIP BgeM3TransportTest: ${e.message}")
        }
    }
}
