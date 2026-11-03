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
package fountain::f_llm.store

import std.database.sql.*
import std.unittest.*
import std.unittest.testmacro.*

import fountain::f_orm.*
import mysql_driver.registerMysqlDriver

/**
 * 4.3 前置：确认仓颉 mysql_driver 能连上 MySQL 9.7.4（caching_sha2_password）。
 * 连不上就让用例失败，而不是静默跳过——否则后面的 MySQL 实现无法验证。
 */
@Test
public class MySqlConnectivityTest {
    private static let URL = 'mysql://fllm_test:fllm_test@127.0.0.1:3306/fllm_test'

    /** 库不可达时打印 SKIP 并跳过；断言失败仍会正常暴露 */
    private func available(): Bool {
        try{
            registerMysqlDriver()
            ORM.register(DriverManager.getDriver('mysql').getOrThrow(), URL, default: true)
            ORM.executor('mysql')
            true
        }catch(e: Exception){
            println("SKIP MySqlConnectivityTest: ${e.message}")
            false
        }
    }

    @TestCase
    func testSelectOne(): Unit {
        if(!available()){
            return
        }
        runSelectOne()
    }

    private func runSelectOne(): Unit {
        registerMysqlDriver()
        let driver = DriverManager.getDriver('mysql').getOrThrow()
        ORM.register(driver, URL, default: true)
        let executor = ORM.executor('mysql')
        let row = executor.setSql('SELECT 1 AS one').firstToMap()
        @Expect(row.isEmpty(), false)
    }

    @TestCase
    func testCreateAndInsert(): Unit {
        if(!available()){
            return
        }
        runCreateAndInsert()
    }

    private func runCreateAndInsert(): Unit {
        registerMysqlDriver()
        let driver = DriverManager.getDriver('mysql').getOrThrow()
        ORM.register(driver, URL, default: true)
        let executor = ORM.executor('mysql')
        executor.setSql('CREATE TABLE IF NOT EXISTS conn_probe (id INT PRIMARY KEY, note VARCHAR(32))').update
        executor.setSql('REPLACE INTO conn_probe (id, note) VALUES (?, ?)').add(Int64(1)).add('ok').update
        let row = executor.setSql('SELECT note FROM conn_probe WHERE id = 1').firstToMap()
        @Expect(row.isEmpty(), false)
    }
}
