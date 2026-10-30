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

import std.collection.*
import std.time.DateTime

import fountain::f_orm.*

import fountain::f_llm.dao.*

/**
 * PostgreSQL 记忆仓库（0.2）：SQL 全部在 `PostgresMemoryDAO`，
 * 本类只做「先主表后向量」这类编排与行映射。
 */
public class PostgresMemoryRepository <: MemoryRepository & RootService {
    private static let DRIVER = 'postgres'

    public init() {
    }

    public func upsert(write: MemoryWrite, titleVector: Array<Float64>,
                       contentVector: Array<Float64>): Int64 {
        let id = memoryDao().upsertMemory(write.userId, write.namespace, write.title,
                                          write.content, write.kind)
        memoryDao().upsertVectors(id, 'bge-m3', vectorLiteral(titleVector), vectorLiteral(contentVector))
        id
    }

    public func searchDense(query: MemoryQuery, vector: Array<Float64>, limit: Int64): ArrayList<MemoryHit> {
        hits(memoryDao().searchDense(query.userId, query.namespaces, vectorLiteral(vector), limit))
    }

    public func upsertSparse(memoryId: Int64, userId: Int64, namespace: String,
                             tokens: HashMap<Int64, Float64>): Unit {
        memoryDao().deleteTokens(memoryId)
        for((token, weight) in tokens){
            memoryDao().insertToken(memoryId, userId, namespace, token, weight)
        }
    }

    public func upsertColbert(memoryId: Int64, titleVectors: Array<Array<Float64>>,
                              contentVectors: Array<Array<Float64>>): Unit {
        memoryDao().updateColbert(memoryId,
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
        hits(memoryDao().searchSparse(query.userId, query.namespaces, tokenIds.toArray(), limit))
    }

    public func colbert(recordId: Int64): ?ColbertVectors {
        match(memoryDao().selectColbert(recordId)){
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
        match(memoryDao().get(userId, id)){
            case Some(row) => Some(recordOf(row))
            case None => None
        }
    }

    public func list(userId: Int64, namespace: String, offset: Int64, limit: Int64): ArrayList<MemoryRecord> {
        let records = ArrayList<MemoryRecord>()
        for(row in memoryDao().list(userId, namespace, offset, limit)){
            records.add(recordOf(row))
        }
        records
    }

    public func remove(userId: Int64, id: Int64): Bool {
        memoryDao().deleteVectors(id)
        memoryDao().deleteMemory(userId, id) > 0
    }

    private func memoryDao(): PostgresMemoryDAO {
        dao<PostgresMemoryDAO>(DRIVER)
    }

    private func hits(rows: ArrayList<HashMap<String, Any>>): ArrayList<MemoryHit> {
        let results = ArrayList<MemoryHit>()
        for(row in rows){
            results.add(MemoryHit(recordOf(row), floatOf(row.get('score') ?? 0.0f64)))
        }
        results
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
