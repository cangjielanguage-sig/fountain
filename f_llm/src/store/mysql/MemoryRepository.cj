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

import std.collection.*
import std.time.DateTime

import fountain::f_bean.*
import fountain::f_bean.macros.*
import fountain::f_orm.*

import fountain::f_llm.store.*

import fountain::f_llm.dao.mysql.*

/**
 * MySQL 记忆仓库（0.2）：SQL 全部在 `MySqlMemoryDAO`。
 *
 * 唯一保留的构造参数是库名——MyVector 的 ANN 需要 `{db}.llm_memory.title_vec`；
 * 不传时从 `llm_contentStoreUrl` 解析。
 */
@Bean
@BeanMeta[condition: ConfCond.Value('llm_contentStore', StringCond.Exactly('mysql'))]
public class MySqlMemoryRepository <: MemoryRepository & RootService {
    private static let DRIVER = 'mysql'

    private let database: String

    public init(database!: String = '') {
        this.database = if(database.isEmpty()){ parseDatabase(StoreSettings.load().contentStoreUrl) }else{ database }
    }

    public func upsert(write: MemoryWrite, titleVector: Array<Float64>,
                       contentVector: Array<Float64>): Int64 {
        memoryDao().myUpsertMemory(write.userId, write.namespace, write.title, write.content, write.kind,
                                 vectorLiteral(titleVector), vectorLiteral(contentVector))
    }

    public func searchDense(query: MemoryQuery, vector: Array<Float64>, limit: Int64): ArrayList<MemoryHit> {
        hits(memoryDao().mySearchDense(query.userId, query.namespaces, vectorLiteral(vector),
                                     '${database}.llm_memory.title_vec', limit))
    }

    public func upsertSparse(memoryId: Int64, userId: Int64, namespace: String,
                             tokens: HashMap<Int64, Float64>): Unit {
        // DAO 宏对「纯 DELETE」方法生成有缺陷，这里用执行器直接执行（仍是占位符绑定）
        executor(DRIVER).setSql('DELETE FROM llm_memory_token WHERE memory_id = ?')
            .add(memoryId)
            .update
        for((token, weight) in tokens){
            memoryDao().myInsertToken(memoryId, userId, namespace, token, weight)
        }
    }

    public func upsertColbert(memoryId: Int64, titleVectors: Array<Array<Float64>>,
                              contentVectors: Array<Array<Float64>>): Unit {
        memoryDao().myUpdateColbert(memoryId,
            ColbertCodec.encode(titleVectors),
            ColbertCodec.encode(contentVectors))
    }

    public func searchSparse(query: MemoryQuery, tokens: HashMap<Int64, Float64>,
                             limit: Int64): ArrayList<MemoryHit> {
        if(tokens.isEmpty()){
            return ArrayList<MemoryHit>()
        }
        let tokenIds = ArrayList<Int64>()
        for((token, _) in tokens){
            tokenIds.add(token)
        }
        hits(memoryDao().mySearchSparse(query.userId, query.namespaces, tokenIds.toArray(), limit))
    }

    public func colbert(recordId: Int64): ?ColbertVectors {
        match(memoryDao().mySelectColbert(recordId)){
            case Some(row) =>
                let title = bytesOf(row.get('title_colbert'))
                let content = bytesOf(row.get('content_colbert'))
                if(title.size == 0 && content.size == 0){
                    None
                }else{
                    Some(ColbertVectors(ColbertCodec.decode(title), ColbertCodec.decode(content)))
                }
            case None => None
        }
    }

    public func get(userId: Int64, id: Int64): ?MemoryRecord {
        match(memoryDao().myGet(userId, id)){
            case Some(row) => Some(recordOf(row))
            case None => None
        }
    }

    public func list(userId: Int64, namespace: String, offset: Int64, limit: Int64): ArrayList<MemoryRecord> {
        let records = ArrayList<MemoryRecord>()
        for(row in memoryDao().myList(userId, namespace, offset, limit)){
            records.add(recordOf(row))
        }
        records
    }

    public func remove(userId: Int64, id: Int64): Bool {
        executor(DRIVER).setSql('DELETE FROM llm_memory_token WHERE memory_id = ?')
            .add(id)
            .update
        memoryDao().myRemoveMemory(userId, id) > 0
    }

    private func memoryDao(): MySqlMemoryDAO {
        dao<MySqlMemoryDAO>(DRIVER)
    }

    private func hits(rows: ArrayList<HashMap<String, Any>>): ArrayList<MemoryHit> {
        let results = ArrayList<MemoryHit>()
        for(row in rows){
            // ANN 查询返回 dist（COSINE 距离），稀疏查询返回 score（权重和）
            let score = match(row.get('dist')){
                case Some(value) => 1.0f64 - floatOf(value)
                case None => floatOf(row.get('score') ?? 0.0f64)
            }
            results.add(MemoryHit(recordOf(row), score))
        }
        results
    }

    private static func parseDatabase(url: String): String {
        if(url.isEmpty()){
            return ''
        }
        let parts = url.split('/')
        if(parts.size == 0){
            return ''
        }
        let last = parts[parts.size - 1]
        match(last.indexOf('?')){
            case Some(index) => last[0..index]
            case None => last
        }
    }

    private static func bytesOf(value: ?Any): Array<Byte> {
        match(value){
            case Some(raw) =>
                match(raw){
                    case bytes: Array<Byte> => bytes
                    case _ => Array<Byte>()
                }
            case None => Array<Byte>()
        }
    }

    private func recordOf(row: Map<String, Any>): MemoryRecord {
        MemoryRecord(
            intOf(row.get('id') ?? 0),
            intOf(row.get('user_id') ?? 0),
            textOf(row.get('namespace') ?? ''),
            textOf(row.get('title') ?? ''),
            textOf(row.get('content') ?? ''),
            textOf(row.get('kind') ?? ''),
            DateTime.now()
        )
    }

    private static func intOf(value: Any): Int64 {
        match(value){
            case number: Int64 => number
            case number: Int32 => Int64(number)
            case number: Int16 => Int64(number)
            case number: Int8 => Int64(number)
            case number: UInt64 => Int64(number)
            case _ => 0
        }
    }

    private static func floatOf(value: Any): Float64 {
        match(value){
            case number: Float64 => number
            case number: Float32 => Float64(number)
            case number: Int64 => Float64(number)
            case _ => 0.0f64
        }
    }

    private static func textOf(value: Any): String {
        match(value){
            case text: String => text
            case _ => ''
        }
    }

    private static func vectorLiteral(vector: Array<Float64>): String {
        var text = '['
        for(index in 0..vector.size){
            if(index > 0){
                text += ','
            }
            text += '${vector[index]}'
        }
        text += ']'
        text
    }
}


let _mysqlRepoRegistered = MemoryRepositories.register('mysql', { => MySqlMemoryRepository() })
