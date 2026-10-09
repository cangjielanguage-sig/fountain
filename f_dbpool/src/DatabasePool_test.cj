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
package fountain::f_dbpool

import std.unittest.*
import std.unittest.testmacro.*
import std.collection.ArrayList
import std.database.sql.*
import fountain::f_mockdb.*

/**
 * 连接池冒烟用例。
 *
 * 原来这里是调试脚手架：用了已不存在的构造参数（driver/initSize/creator/connectTimeout）、
 * 起了 10 个无限循环的 spawn 并 `sleep(30s)`，测试套件因此编译不过、跑起来也永不结束。
 * 现改为按当前构造签名建池、借还一次连接。
 *
 * 随 `DatabasePool` 从 `fountain::f_orm.wrap` 迁到 `fountain::f_dbpool` 时同步搬来：原用的
 * `DatabasePool(driver, ds)`（参数取自 `ORMConfig`）已删除，改用 `ds` + 显式参数的构造器。
 */
@Test
public class DatabasePoolTest {
    @TestCase
    public func testDatabasePool(): Unit {
        MOCKDB.execution = {_: String, _: ArrayList<Any> =>
            MOCKDB.addQueryResultColumnInfo(name: '1', nullable: false, typeName: 'SqlBigInt')
            MOCKDB.addQueryResultRow([1])
        }
        let driver: Driver = DriverManager.getDriver('mockdb').getOrThrow()
        let ds = driver.open('mockdb://')
        let pool = DatabasePool(ds)
        try(c = pool.connect()){
            @Assert(false, c.isClosed())
        }
        pool.close()
    }
}
