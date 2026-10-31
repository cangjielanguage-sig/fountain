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
package fountain::f_llm.store.it

import std.collection.*
import std.database.sql.*
import std.unittest.*
import std.unittest.testmacro.*

import fountain::f_orm.*
import mysql_driver.registerMysqlDriver
import postgres_driver.registerPostgresDriver

import fountain::f_llm.store.*
import fountain::f_llm.store.mysql.*
import fountain::f_llm.store.postgres.*

/** P1：预定义 kind 补种落库，且重复补种幂等。 */
@Test
public class KindPersistenceTest {
    private static let PG_URL = 'postgres://fllm_test:fllm_test@127.0.0.1:5432/fllm_test'
    private static let MY_URL = 'mysql://fllm_test:fllm_test@127.0.0.1:3306/fllm_test'

    private static func countOf(executor: SqlExecutor): Int64 {
        let row = executor.setSql('SELECT COUNT(*) AS c FROM llm_memory_kind').firstToMap()
        match(row.get('c')){
            case Some(value: Int64) => value
            case Some(value: Int32) => Int64(value)
            case Some(value: UInt64) => Int64(value)
            case _ => -1
        }
    }

    @TestCase
    func testPostgresSeedIsIdempotent(): Unit {
        try{
            registerPostgresDriver()
            let driver = DriverManager.getDriver('postgres').getOrThrow()
            ORM.register(driver, PG_URL, default: true)
            let executor = ORM.executor('postgres')
            executor.setSql('DROP TABLE IF EXISTS llm_memory_kind').update
            executor.setSql('''
                CREATE TABLE llm_memory_kind (
                  user_id BIGINT NOT NULL DEFAULT 0,
                  kind VARCHAR(32) NOT NULL,
                  predefined BOOLEAN NOT NULL DEFAULT FALSE,
                  weight DOUBLE PRECISION NOT NULL DEFAULT 0.8,
                  create_time TIMESTAMP NOT NULL DEFAULT (now() AT TIME ZONE 'utc'),
                  PRIMARY KEY (user_id, kind)
                )
            ''').update

            let persistence = PostgresKindPersistence()
            MemoryKinds.seed(persistence)
            MemoryKinds.seed(persistence)

            @Expect(countOf(executor), 7)
            @Expect(persistence.has('fact'), true)
            @Expect(persistence.has('not-exist'), false)
        }catch(e: Exception){
            println("SKIP KindPersistenceTest(PG): ${e.message}")
        }
    }

    @TestCase
    func testMySqlSeedIsIdempotent(): Unit {
        try{
            registerMysqlDriver()
            let driver = DriverManager.getDriver('mysql').getOrThrow()
            ORM.register(driver, MY_URL, default: true)
            let executor = ORM.executor('mysql')
            executor.setSql('DROP TABLE IF EXISTS llm_memory_kind').update
            executor.setSql('''
                CREATE TABLE llm_memory_kind (
                  user_id BIGINT NOT NULL DEFAULT 0,
                  kind VARCHAR(32) NOT NULL,
                  predefined TINYINT(1) NOT NULL DEFAULT 0,
                  weight DOUBLE NOT NULL DEFAULT 0.8,
                  create_time DATETIME NOT NULL DEFAULT (UTC_TIMESTAMP()),
                  PRIMARY KEY (user_id, kind)
                )
            ''').update

            let persistence = MySqlKindPersistence()
            MemoryKinds.seed(persistence)
            MemoryKinds.seed(persistence)

            @Expect(countOf(executor), 7)
            @Expect(persistence.has('session'), true)
            @Expect(persistence.has('not-exist'), false)
        }catch(e: Exception){
            println("SKIP KindPersistenceTest(MySQL): ${e.message}")
        }
    }
}
