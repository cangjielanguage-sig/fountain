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
import fountain::f_util.UUID
import fountain::f_llm.store.mysql.*
import fountain::f_llm.store.postgres.*

/** 演进报告表的 SQL 实现：写入、列出、按技能过滤 */
@Test
class EvolutionStoreIT_test {
    private static let PG_URL = 'postgres://fllm_test:fllm_test@127.0.0.1:5432/fllm_test'
    private static let MY_URL = 'mysql://fllm_test:fllm_test@127.0.0.1:3306/fllm_test'

    private func postgresReady(): Bool {
        try{
            registerPostgresDriver()
            ORM.register(DriverManager.getDriver('postgres').getOrThrow(), PG_URL, default: true)
            ORM.executor('postgres')
            true
        }catch(e: Exception){
            println("SKIP EvolutionStoreITTest(PG): ${e.message}")
            false
        }
    }

    private func mySqlReady(): Bool {
        try{
            registerMysqlDriver()
            ORM.register(DriverManager.getDriver('mysql').getOrThrow(), MY_URL, default: true)
            ORM.executor('mysql')
            true
        }catch(e: Exception){
            println("SKIP EvolutionStoreITTest(MySQL): ${e.message}")
            false
        }
    }

    @TestCase
    func testPostgresSaveListBySkill(): Unit {
        if(!postgresReady()){
            return
        }
        check(PostgresEvolutionStore(), 'pg')
    }

    @TestCase
    func testMySqlSaveListBySkill(): Unit {
        if(!mySqlReady()){
            return
        }
        check(MySqlEvolutionStore(), 'my')
    }

    /** 演进状态表：更新、读回、水位线 */
    @TestCase
    func testPostgresStateStore(): Unit {
        if(!postgresReady()){
            return
        }
        checkState(PostgresEvolutionStateStore(), 'pg')
    }

    @TestCase
    func testMySqlStateStore(): Unit {
        if(!mySqlReady()){
            return
        }
        checkState(MySqlEvolutionStateStore(), 'my')
    }

    private func checkState(store: EvolutionStateStore, tag: String): Unit {
        // 建表幂等：连续两次不报错
        store.ensureSchema()
        store.ensureSchema()

        let title = 'it-state-${tag}'
        store.save(EvolutionSkillState(title, 1000, true))
        @Expect(store.get(title).getOrThrow().lastEvolvedAt, 1000)
        @Expect(store.get(title).getOrThrow().lastGatePassed, true)

        // 覆盖写：门禁失败要能翻转
        store.save(EvolutionSkillState(title, 2000, false))
        @Expect(store.get(title).getOrThrow().lastGatePassed, false)

        store.markRun(3000)
        @Expect(store.lastRunAt(), 3000)
    }

    /** 同一套断言跑两种实现：写入可读、按技能过滤、id 递增 */
    private func check(store: EvolutionStore, tag: String): Unit {
        // 模拟启动阶段：建表 + 建索引（幂等，重复执行不报错）
        store.ensureSchema()
        store.ensureSchema()

        // 技能名带随机后缀：库里是累积数据，固定名字会被历次运行的行挤满
        let skill = 'it-evolution-${tag}-${UUID.random().toHexString()}'
        let first = store.save(EvolutionEntry(0, skill, 'evolved', 'v1 -> v2', 1_700_000_001))
        let second = store.save(EvolutionEntry(0, skill, 'rejected', 'no samples', 1_700_000_002))
        @Expect(first > 0, true)
        @Expect(second > first, true)

        let listed = store.list(0, 20)
        @Expect(listed.size >= 2, true)
        // 时间倒序：后写的在前
        @Expect(listed[0].at >= listed[1].at, true)

        let bySkill = store.bySkill(skill, 10)
        @Expect(bySkill.size >= 2, true)
        var actions = ArrayList<String>()
        for(item in bySkill){
            actions.add(item.action)
        }
        @Expect(actions.contains('evolved'), true)
        @Expect(actions.contains('rejected'), true)

        // 其它技能不应混进来
        for(item in bySkill){
            @Expect(item.skillTitle, skill)
        }
    }
}
