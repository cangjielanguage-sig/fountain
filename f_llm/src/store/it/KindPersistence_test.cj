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

/** P1/P2：预定义补种幂等、自定义 kind 落库并能在重新 attach 后恢复。 */
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

    private func pgExecutor(): ?SqlExecutor {
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
            Some(executor)
        }catch(e: Exception){
            println("SKIP KindPersistenceTest(PG): ${e.message}")
            None
        }
    }

    private func mysqlExecutor(): ?SqlExecutor {
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
            Some(executor)
        }catch(e: Exception){
            println("SKIP KindPersistenceTest(MySQL): ${e.message}")
            None
        }
    }

    @TestCase
    func testPostgresSeedIsIdempotent(): Unit {
        match(pgExecutor()){
            case Some(executor) =>
                let persistence = PostgresKindPersistence()
                MemoryKinds.seed(persistence)
                MemoryKinds.seed(persistence)
                @Expect(countOf(executor), Int64(MemoryKinds.predefined().size))
                @Expect(persistence.has('fact'), true)
                @Expect(persistence.has('not-exist'), false)
            case None => ()
        }
    }

    @TestCase
    func testMySqlSeedIsIdempotent(): Unit {
        match(mysqlExecutor()){
            case Some(executor) =>
                let persistence = MySqlKindPersistence()
                MemoryKinds.seed(persistence)
                MemoryKinds.seed(persistence)
                @Expect(countOf(executor), Int64(MemoryKinds.predefined().size))
                @Expect(persistence.has('session'), true)
                @Expect(persistence.has('not-exist'), false)
            case None => ()
        }
    }

    @TestCase
    func testPostgresCustomKindPersists(): Unit {
        match(pgExecutor()){
            case Some(_) =>
                let persistence = PostgresKindPersistence()
                MemoryKinds.resetForTest()
                MemoryKinds.attach(persistence)

                @Expect(MemoryKinds.register(42, 'pg-custom'), true)
                @Expect(persistence.allCustom().get(42).getOrThrow().size, 1)

                // 重新 attach = 从库里重载，内存清空后仍应恢复
                MemoryKinds.attach(persistence)
                @Expect(MemoryKinds.validate(42, 'pg-custom'), true)

                @Expect(MemoryKinds.remove(42, 'pg-custom'), true)
                MemoryKinds.attach(persistence)
                @Expect(MemoryKinds.validate(42, 'pg-custom'), false)
            case None => ()
        }
    }

    @TestCase
    func testMySqlCustomKindPersists(): Unit {
        match(mysqlExecutor()){
            case Some(_) =>
                let persistence = MySqlKindPersistence()
                MemoryKinds.resetForTest()
                MemoryKinds.attach(persistence)

                @Expect(MemoryKinds.register(43, 'my-custom'), true)
                MemoryKinds.attach(persistence)
                @Expect(MemoryKinds.validate(43, 'my-custom'), true)

                @Expect(MemoryKinds.remove(43, 'my-custom'), true)
                MemoryKinds.attach(persistence)
                @Expect(MemoryKinds.validate(43, 'my-custom'), false)
            case None => ()
        }
    }
}
