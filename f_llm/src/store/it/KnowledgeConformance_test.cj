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
import std.unittest.*
import std.unittest.testmacro.*

import fountain::f_orm.*
import mysql_driver.registerMysqlDriver
import postgres_driver.registerPostgresDriver

import fountain::f_llm.store.*
import fountain::f_llm.store.mysql.*
import fountain::f_llm.store.postgres.*

/** 3.x：知识文档 conformance（先跑 PG，MySQL 随后补）。 */
@Test
public class KnowledgeConformanceTest {
    private static let URL = 'postgres://fllm_test:fllm_test@127.0.0.1:5432/fllm_test'

    private func postgresKnowledge(): ?PostgresKnowledgeStore {
        try{
            registerPostgresDriver()
            let driver = DriverManager.getDriver('postgres').getOrThrow()
            ORM.register(driver, URL, default: true)
            let executor = ORM.executor('postgres')
            executor.setSql('''
                CREATE TABLE IF NOT EXISTS llm_document (
                  doc_id VARCHAR(128) PRIMARY KEY,
                  title VARCHAR(256) NOT NULL DEFAULT '',
                  content TEXT NOT NULL,
                  update_time TIMESTAMP NOT NULL DEFAULT (now() AT TIME ZONE 'utc')
                )
            ''').update
            Some(PostgresKnowledgeStore())
        }catch(e: Exception){
            println("SKIP KnowledgeConformanceTest(PG): ${e.message}")
            None
        }
    }

    @TestCase
    func testUpsertOverwritesSameDoc(): Unit {
        match(postgresKnowledge()){
            case Some(store) =>
                store.upsert(KnowledgeDoc('doc-1', '标题1', '正文1'))
                store.upsert(KnowledgeDoc('doc-1', '标题2', '正文2'))
                let doc = store.get('doc-1').getOrThrow()
                @Expect(doc.title, '标题2')
                @Expect(doc.content, '正文2')
            case None => ()
        }
    }

    @TestCase
    func testRemoveAndMissing(): Unit {
        match(postgresKnowledge()){
            case Some(store) =>
                store.upsert(KnowledgeDoc('doc-2', 't', 'c'))
                @Expect(store.remove('doc-2'), true)
                @Expect(store.get('doc-2').isNone(), true)
                @Expect(store.remove('doc-2'), false)
            case None => ()
        }
    }

    private func mysqlKnowledge(): ?MySqlKnowledgeStore {
        try{
            registerMysqlDriver()
            let driver = DriverManager.getDriver('mysql').getOrThrow()
            ORM.register(driver, 'mysql://fllm_test:fllm_test@127.0.0.1:3306/fllm_test', default: true)
            let executor = ORM.executor('mysql')
            executor.setSql('''
                CREATE TABLE IF NOT EXISTS llm_document (
                  doc_id VARCHAR(128) PRIMARY KEY,
                  title VARCHAR(256) NOT NULL DEFAULT '',
                  content LONGTEXT NOT NULL,
                  update_time DATETIME NOT NULL DEFAULT (UTC_TIMESTAMP())
                )
            ''').update
            Some(MySqlKnowledgeStore())
        }catch(e: Exception){
            println("SKIP KnowledgeConformanceTest(MySQL): ${e.message}")
            None
        }
    }

    @TestCase
    func testMySqlUpsertOverwritesSameDoc(): Unit {
        match(mysqlKnowledge()){
            case Some(store) =>
                store.upsert(KnowledgeDoc('m-doc-1', '标题1', '正文1'))
                store.upsert(KnowledgeDoc('m-doc-1', '标题2', '正文2'))
                @Expect(store.get('m-doc-1').getOrThrow().title, '标题2')
            case None => ()
        }
    }

    @TestCase
    func testMySqlRemoveAndMissing(): Unit {
        match(mysqlKnowledge()){
            case Some(store) =>
                store.upsert(KnowledgeDoc('m-doc-2', 't', 'c'))
                @Expect(store.remove('m-doc-2'), true)
                @Expect(store.get('m-doc-2').isNone(), true)
            case None => ()
        }
    }
}
