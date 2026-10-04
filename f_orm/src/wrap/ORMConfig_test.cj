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
package fountain::f_orm.wrap

import std.unittest.*
import std.unittest.testmacro.*

@Test
public class ORMConfigTest {
    @TestCase
    public func testORMConfig(): Unit {
        ORMConfig.refresh{}
    }
    /**
     * `orm_databasePoolMaxWaiting` 的值按 `Duration.toString()` 解析（如 `30s`、`1m`）：
     * ≤ 0（如 `0s`）表示真无限等待，非法值退回默认 30s。
     */
    @TestCase
    public func testPoolMaxWaiting(): Unit {
        let key = ORMConfig.databasePoolMaxWaiting
        Config.set([(key, '45s')])
        @Expect(ORMConfig.getPoolMaxWaiting(), Duration.second * 45)
        Config.set([(key, '1m')])
        @Expect(ORMConfig.getPoolMaxWaiting(), Duration.minute)
        Config.set([(key, '0s')])
        @Expect(ORMConfig.getPoolMaxWaiting(), Duration.Max)
        Config.set([(key, 'abc')])
        @Expect(ORMConfig.getPoolMaxWaiting(), Duration.second * 30)
        Config.set([(key, '30s')])
        @Expect(ORMConfig.getPoolMaxWaiting(), Duration.second * 30)
    }
}
