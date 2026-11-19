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
package fountain::f_llm.store.mysql

import fountain::f_llm.store.*

import std.collection.*
import std.database.sql.*
import std.unittest.*
import std.unittest.testmacro.*

import fountain::f_orm.*

import mysql_driver.registerMysqlDriver

@Test
public class MySqlMemoryRepositoryTest {
    private static let URL = 'mysql://fllm_test:fllm_test@127.0.0.1:3306/fllm_test'

    private func executor(): SqlExecutor {
        registerMysqlDriver()
        let driver = DriverManager.getDriver('mysql').getOrThrow()
        ORM.register(driver, URL, default: true)
        ORM.executor('mysql')
    }

    private func prepare(executor: SqlExecutor): Unit {
        executor.setSql('DROP TABLE IF EXISTS llm_memory_token').update
        executor.setSql('DROP TABLE IF EXISTS llm_memory').update
        executor.setSql('''
            CREATE TABLE llm_memory (
              id BIGINT AUTO_INCREMENT PRIMARY KEY,
              user_id BIGINT NOT NULL,
              namespace VARCHAR(32) NOT NULL,
              title VARCHAR(128) NOT NULL,
              content TEXT,
              kind VARCHAR(32) NOT NULL DEFAULT 'note',
              title_vec MYVECTOR(type=HNSW,dim=1024,size=1000,dist=COSINE,m=16,ef=100),
              content_vec MYVECTOR(type=HNSW,dim=1024,size=1000,dist=COSINE,m=16,ef=100),
              title_colbert LONGBLOB NULL,
              content_colbert LONGBLOB NULL,
              save_time DATETIME NOT NULL DEFAULT (UTC_TIMESTAMP()),
              update_time DATETIME NOT NULL DEFAULT (UTC_TIMESTAMP()),
              UNIQUE KEY uk_memory (user_id, namespace, title)
            )
        ''').update
        executor.setSql('''
            CREATE TABLE llm_memory_token (
              memory_id BIGINT NOT NULL,
              user_id BIGINT NOT NULL,
              namespace VARCHAR(32) NOT NULL,
              field CHAR(1) NOT NULL,
              token BIGINT NOT NULL,
              weight DOUBLE NOT NULL,
              PRIMARY KEY (memory_id, field, token)
            )
        ''').update
    }

    private func vector(seed: Float64): Array<Float64> {
        let values = Array<Float64>(1024, repeat: 0.0f64)
        for(index in 0..1024){
            values[index] = seed + Float64(index) * 0.0001f64
        }
        values
    }

    /** 库不可达时打印 SKIP 并跳过；断言失败仍会正常暴露 */
    private func available(): Bool {
        try{
            executor()
            true
        }catch(e: Exception){
            println("SKIP MySqlMemoryRepositoryTest: ${e.message}")
            false
        }
    }

    @TestCase
    func testUpsertAndAnnSearch(): Unit {
        if(!available()){
            return
        }
        runUpsertAndAnnSearch()
    }

    private func runUpsertAndAnnSearch(): Unit {
        let executor = executor()
        prepare(executor)
        let repo = MySqlMemoryRepository(database: 'fllm_test')

        let id = repo.upsert(MemoryWrite(1, 'global', '标题', '正文', 'note'),
                             vector(0.01f64), vector(0.01f64))
        @Expect(id > 0, true)

        // MyVector 需要显式建索引（后续由写入后调用）
        executor.setSql("CALL mysql.myvector_index_build('fllm_test.llm_memory.title_vec','id')").mapList()

        let hits = repo.searchDense(MemoryQuery(1, ['global'], [], 'q', topK: 5), vector(0.0101f64), 5)
        @Expect(hits.size, 1)
        @Expect(hits[0].record.id, id)
        @Expect(hits[0].score > 0.0f64, true)
    }

    @TestCase
    func testUpsertOverwritesSameTitle(): Unit {
        if(!available()){
            return
        }
        runUpsertOverwritesSameTitle()
    }

    private func runUpsertOverwritesSameTitle(): Unit {
        let executor = executor()
        prepare(executor)
        let repo = MySqlMemoryRepository(database: 'fllm_test')
        let first = repo.upsert(MemoryWrite(1, 'global', '同标题', 'v1', 'note'),
                                vector(0.02f64), vector(0.02f64))
        let second = repo.upsert(MemoryWrite(1, 'global', '同标题', 'v2', 'note'),
                                 vector(0.03f64), vector(0.03f64))
        @Expect(first, second)
        @Expect(repo.get(1, first).getOrThrow().content, 'v2')
    }
}
