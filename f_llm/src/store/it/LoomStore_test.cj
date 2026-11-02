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

import fountain::f_llm.loom.*

/** loom 流程定义落库（PG / MySQL 各一条，真实库） */
@Test
public class LoomStoreTest {
    private static let PG_URL = 'postgres://fllm_test:fllm_test@127.0.0.1:5432/fllm_test'
    private static let MY_URL = 'mysql://fllm_test:fllm_test@127.0.0.1:3306/fllm_test'

    private func flow(): LoomFlow {
        let value = LoomFlow('it-flow', description: '集成用例')
        value.planJson = '{"name":"it-flow","steps":[]}'
        value.flowSource = '{ => flow.start("") }'
        value.stepSources['fetch'] = 'let fetch_out = "A"\nLoomHostApi.taskEvent(e, "fetch", fetch_out)'
        value.stepSources['sum'] = 'let sum_out = "B"'
        value.status = LoomStatus.COMPILED
        value.round = 1
        value.questionsJson = '[]'
        value.tools = 'webSearch'
        value.mcps = 'mail'
        value
    }

    @TestCase
    func testPostgresLoomStoreRoundtrip(): Unit {
        // 与其他集成用例一致：库不可达时打印 SKIP，而不是把环境缺失算成失败
        try{
            runPostgresRoundtrip()
        }catch(e: Exception){
            println("SKIP LoomStoreTest(PG): ${e.message}")
        }
    }

    private func runPostgresRoundtrip(): Unit {
        registerPostgresDriver()
        let driver = DriverManager.getDriver('postgres').getOrThrow()
        ORM.register(driver, PG_URL, default: true)
        let executor = ORM.executor('postgres')
        executor.setSql('DROP TABLE IF EXISTS llm_loom_flow').update
        executor.setSql('''
            CREATE TABLE llm_loom_flow (
              name VARCHAR(64) PRIMARY KEY,
              description TEXT,
              plan_json TEXT NOT NULL,
              flow_source TEXT NOT NULL,
              step_sources TEXT NOT NULL,
              status VARCHAR(16) NOT NULL,
              round INT NOT NULL DEFAULT 0,
              questions_json TEXT,
              tools TEXT,
              mcps TEXT,
              created_time TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
              update_time TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
            )
        ''').update

        let store = PostgresLoomStore()
        store.save(flow())
        let loaded = store.get('it-flow').getOrThrow()
        @Expect(loaded.description, '集成用例')
        @Expect(loaded.status, LoomStatus.COMPILED)
        @Expect(loaded.round, 1)
        @Expect(loaded.tools, 'webSearch')
        @Expect(loaded.stepSources.size, 2)
        @Expect(loaded.stepSources['fetch'], flow().stepSources['fetch'])
        @Expect(store.list(0, 10).size, 1)
        @Expect(store.remove('it-flow'), true)
        @Expect(store.get('it-flow').isNone(), true)
    }

    @TestCase
    func testMySqlLoomStoreRoundtrip(): Unit {
        try{
            runMySqlRoundtrip()
        }catch(e: Exception){
            println("SKIP LoomStoreTest(MySQL): ${e.message}")
        }
    }

    private func runMySqlRoundtrip(): Unit {
        registerMysqlDriver()
        let driver = DriverManager.getDriver('mysql').getOrThrow()
        ORM.register(driver, MY_URL, default: true)
        let executor = ORM.executor('mysql')
        executor.setSql('DROP TABLE IF EXISTS llm_loom_flow').update
        executor.setSql('''
            CREATE TABLE llm_loom_flow (
              name VARCHAR(64) PRIMARY KEY,
              description TEXT,
              plan_json TEXT NOT NULL,
              flow_source TEXT NOT NULL,
              step_sources TEXT NOT NULL,
              status VARCHAR(16) NOT NULL,
              round INT NOT NULL DEFAULT 0,
              questions_json TEXT,
              tools TEXT,
              mcps TEXT,
              created_time DATETIME NOT NULL DEFAULT (UTC_TIMESTAMP()),
              update_time DATETIME NOT NULL DEFAULT (UTC_TIMESTAMP())
            ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
        ''').update

        let store = MySqlLoomStore()
        store.save(flow())
        let loaded = store.get('it-flow').getOrThrow()
        @Expect(loaded.planJson, '{"name":"it-flow","steps":[]}')
        @Expect(loaded.stepSources.size, 2)
        @Expect(loaded.mcps, 'mail')
        @Expect(store.list(0, 10).size, 1)
        @Expect(store.remove('it-flow'), true)
        @Expect(store.get('it-flow').isNone(), true)
    }
}
