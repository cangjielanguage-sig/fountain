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

import std.database.sql.*
import std.time.DateTime
import std.unittest.*
import std.unittest.testmacro.*

import fountain::f_orm.*
import mysql_driver.registerMysqlDriver
import postgres_driver.registerPostgresDriver

import fountain::f_llm.store.*
import fountain::f_llm.store.postgres.*

/**
 * 元数据族 conformance（3.5）：同一套断言分别跑 f_store 与 PG。
 * MySQL 未安装时打印原因跳过。
 */
@Test
public class MetaConformanceTest {

    private func assertMeta(meta: MetaStore): Unit {
        // 人格：覆盖写 + reset
        meta.characters.set(Character(1, 'rigorous', '严谨'))
        meta.characters.set(Character(1, 'whimsical', '鬼灵精怪'))
        @Expect(meta.characters.get(1).getOrThrow().characterKey, 'whimsical')
        meta.characters.reset(1)
        @Expect(meta.characters.get(1).isNone(), true)

        // 技能：version 默认 1
        meta.skills.upsert(Skill(1, 'conf-skill', '步骤', 'tool:webSearch'))
        @Expect(meta.skills.get(1).getOrThrow().version, 1)

        // 提示词：按版本读 + latest
        meta.prompts.put(PromptEntry('conf.prompt', 1, 'v1'))
        meta.prompts.put(PromptEntry('conf.prompt', 2, 'v2'))
        @Expect(meta.prompts.latest('conf.prompt').getOrThrow().content, 'v2')
        @Expect(meta.prompts.get('conf.prompt', 1).getOrThrow().content, 'v1')
        @Expect(meta.prompts.get('missing', 1).isNone(), true)

        // 删除：技能先删索引再删主体；提示词删 latest 后回落到上一版
        @Expect(meta.skills.remove(1), true)
        @Expect(meta.skills.get(1).isNone(), true)
        meta.prompts.put(PromptEntry('conf.prompt', 3, 'v3'))
        @Expect(meta.prompts.remove('conf.prompt', 3), true)
        @Expect(meta.prompts.latest('conf.prompt').getOrThrow().content, 'v2')

        // 配置：过滤 enabled / weight，并验证完整字段往返
        meta.confs.put(LLMConfView('p1', 'conf-llm', 'ok', 10, true,
                                   llmUrl: 'http://llm.local/v1', auth: 'sk-test',
                                   temperature: 0.3f64, alwaysThinking: true))
        meta.confs.put(LLMConfView('p2', 'conf-llm', 'off', 10, false))
        meta.confs.put(LLMConfView('p3', 'conf-llm', 'zero', 0, true))
        let candidates = meta.confs.candidates('conf-llm')
        @Expect(candidates.size, 1)
        @Expect(candidates[0].llmUrl, 'http://llm.local/v1')
        @Expect(candidates[0].auth, 'sk-test')
        @Expect(candidates[0].alwaysThinking, true)
    }

    @TestCase
    func testFStoreConformance(): Unit {
        let path = '/tmp/fllm-conf-${DateTime.now().toUnixTimeStamp().toSeconds()}'
        assertMeta(FStoreMetaStore(path))
    }

    @TestCase
    func testPostgresConformance(): Unit {
        match(postgresMeta()){
            case Some(meta) => assertMeta(meta)
            case None => ()
        }
    }

    @TestCase
    func testMySqlConformance(): Unit {
        match(mysqlMeta()){
            case Some(meta) => assertMeta(meta)
            case None => ()
        }
    }

    private func mysqlMeta(): ?MySqlMetaStore {
        try{
            registerMysqlDriver()
            let driver = DriverManager.getDriver('mysql').getOrThrow()
            ORM.register(driver, 'mysql://fllm_test:fllm_test@127.0.0.1:3306/fllm_test', default: true)
            let executor = ORM.executor('mysql')
            // 每次跑重建，避免上一轮数据把候选数抬高
            for(table in ['llm_character', 'skills', 'llm_prompt', 'llm_conf']){
                executor.setSql('DROP TABLE IF EXISTS ${table}').update
            }
            executor.setSql('''
                CREATE TABLE IF NOT EXISTS llm_character (
                  id BIGINT AUTO_INCREMENT PRIMARY KEY,
                  user_id BIGINT NOT NULL,
                  character_key VARCHAR(32) NOT NULL DEFAULT 'default',
                  prompts TEXT,
                  update_time DATETIME NOT NULL DEFAULT (UTC_TIMESTAMP()),
                  UNIQUE KEY uk_character_user (user_id)
                )
            ''').update
            executor.setSql('''
                CREATE TABLE IF NOT EXISTS skills (
                  id BIGINT AUTO_INCREMENT PRIMARY KEY,
                  agent_id BIGINT NOT NULL DEFAULT 0,
                  accepted_event VARCHAR(64) NOT NULL DEFAULT '',
                  returned_event VARCHAR(64) NOT NULL DEFAULT '',
                  title VARCHAR(256) NOT NULL DEFAULT '',
                  metadata TEXT, details TEXT, functions TEXT,
                  version INT NOT NULL DEFAULT 1,
                  skill_type VARCHAR(32) NOT NULL DEFAULT ''
                )
            ''').update
            executor.setSql('''
                CREATE TABLE IF NOT EXISTS llm_prompt (
                  name VARCHAR(128) NOT NULL,
                  version INT NOT NULL,
                  content LONGTEXT NOT NULL,
                  update_time DATETIME NOT NULL DEFAULT (UTC_TIMESTAMP()),
                  PRIMARY KEY (name, version)
                )
            ''').update
            executor.setSql('''
                CREATE TABLE IF NOT EXISTS llm_conf (
                  id BIGINT AUTO_INCREMENT PRIMARY KEY,
                  provider VARCHAR(64) NOT NULL DEFAULT '',
                  llm_name VARCHAR(128) NOT NULL DEFAULT '',
                  actual_llm_name VARCHAR(128) NOT NULL DEFAULT '',
                  llm_url VARCHAR(512) NOT NULL DEFAULT '',
                  auth VARCHAR(512) NOT NULL DEFAULT '',
                  temperature DOUBLE NOT NULL DEFAULT -1,
                  always_thinking TINYINT(1) NOT NULL DEFAULT 0,
                  conf TEXT,
                  enabled TINYINT(1) NOT NULL DEFAULT 1,
                  weight BIGINT NOT NULL DEFAULT 1
                )
            ''').update
            Some(MySqlMetaStore(executor))
        }catch(e: Exception){
            println("SKIP MetaConformanceTest(MySQL): ${e.message}")
            None
        }
    }

    private func postgresMeta(): ?PostgresMetaStore {
        try{
            registerPostgresDriver()
            let driver = DriverManager.getDriver('postgres').getOrThrow()
            ORM.register(driver, 'postgres://fllm_test:fllm_test@127.0.0.1:5432/fllm_test', default: true)
            let executor = ORM.executor('postgres')
            executor.setSql('''
                CREATE TABLE IF NOT EXISTS llm_character (
                  id BIGINT GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
                  user_id BIGINT NOT NULL,
                  character_key VARCHAR(32) NOT NULL DEFAULT 'default',
                  prompts TEXT,
                  update_time TIMESTAMP NOT NULL DEFAULT (now() AT TIME ZONE 'utc'),
                  CONSTRAINT uk_character_user UNIQUE (user_id)
                )
            ''').update
            executor.setSql('''
                CREATE TABLE IF NOT EXISTS skills (
                  id BIGINT GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
                  agent_id BIGINT NOT NULL DEFAULT 0,
                  accepted_event VARCHAR(64) NOT NULL DEFAULT '',
                  returned_event VARCHAR(64) NOT NULL DEFAULT '',
                  title VARCHAR(256) NOT NULL DEFAULT '',
                  metadata TEXT, details TEXT, functions TEXT,
                  version INT NOT NULL DEFAULT 1,
                  skill_type VARCHAR(32) NOT NULL DEFAULT ''
                )
            ''').update
            executor.setSql('''
                CREATE TABLE IF NOT EXISTS llm_prompt (
                  name VARCHAR(128) NOT NULL,
                  version INT NOT NULL,
                  content TEXT NOT NULL,
                  update_time TIMESTAMP NOT NULL DEFAULT (now() AT TIME ZONE 'utc'),
                  PRIMARY KEY (name, version)
                )
            ''').update
            executor.setSql('''
                CREATE TABLE IF NOT EXISTS llm_conf (
                  id BIGINT GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
                  provider VARCHAR(64) NOT NULL DEFAULT '',
                  llm_name VARCHAR(128) NOT NULL DEFAULT '',
                  actual_llm_name VARCHAR(128) NOT NULL DEFAULT '',
                  llm_url VARCHAR(512) NOT NULL DEFAULT '',
                  auth VARCHAR(512) NOT NULL DEFAULT '',
                  temperature DOUBLE PRECISION NOT NULL DEFAULT -1,
                  always_thinking BOOLEAN NOT NULL DEFAULT FALSE,
                  conf TEXT,
                  enabled BOOLEAN NOT NULL DEFAULT TRUE,
                  weight BIGINT NOT NULL DEFAULT 1
                )
            ''').update
            // 清掉上一轮残留，否则候选数会被历史行抬高
            executor.setSql("DELETE FROM llm_conf WHERE llm_name = 'conf-llm'").update
            executor.setSql("DELETE FROM llm_prompt WHERE name = 'conf.prompt'").update
            executor.setSql('DELETE FROM skills WHERE id = 1').update
            executor.setSql('DELETE FROM llm_character WHERE user_id = 1').update
            Some(PostgresMetaStore())
        }catch(e: Exception){
            println("SKIP MetaConformanceTest(PG): ${e.message}")
            None
        }
    }
}
