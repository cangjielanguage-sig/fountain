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

/**
 * MySQL 记忆仓库（4.3）：向量列用 MyVector 的 `MYVECTOR` 伪类型，ANN 走
 * `MYVECTOR_IS_ANN`；隔离条件必须放第五参数（JSON_ARRAYAGG），不能放 WHERE。
 */
public class MySqlMemoryRepository <: MemoryRepository {
    private static let MEMORY_COLUMNS = 'id, user_id, namespace, title, content, kind'

    private let executor: SqlExecutor
    private let annPath: String

    public init(executor: SqlExecutor, database: String) {
        this.executor = executor
        this.annPath = '${database}.llm_memory.title_vec'
    }

    public func upsert(write: MemoryWrite, titleVector: Array<Float64>,
                       contentVector: Array<Float64>): Int64 {
        executor.setSql('''
            INSERT INTO llm_memory
                (user_id, namespace, title, content, kind, title_vec, content_vec, save_time, update_time)
            VALUES (?, ?, ?, ?, ?, myvector_construct(?), myvector_construct(?), UTC_TIMESTAMP(), UTC_TIMESTAMP())
            ON DUPLICATE KEY UPDATE
                id = LAST_INSERT_ID(id),
                content = VALUES(content),
                kind = VALUES(kind),
                title_vec = VALUES(title_vec),
                content_vec = VALUES(content_vec),
                update_time = UTC_TIMESTAMP()
        ''')
            .add(write.userId)
            .add(write.namespace)
            .add(write.title)
            .add(write.content)
            .add(write.kind)
            .add(vectorLiteral(titleVector))
            .add(vectorLiteral(contentVector))
            .update
        // 原生 LAST_INSERT_ID() 被驱动映射为 UInt64，QueryResultWrap 不支持；显式转 SIGNED
        let row = executor.setSql('SELECT CAST(LAST_INSERT_ID() AS SIGNED) AS id').firstToMap()
        intOf(row.get('id') ?? 0)
    }

    public func searchDense(query: MemoryQuery, vector: Array<Float64>, limit: Int64): ArrayList<MemoryHit> {
        let filter = filterLiteral(query)
        // MyVector 的查询改写不认占位符（k 与过滤子查询都会导致 prepare 1064），
        // 因此整条 SQL 用字面量拼接：向量只含数字，k 是整数，namespace 做引号转义。
        let queryVector = vectorLiteral(vector)
        let sql = '''
            SELECT m.id, m.user_id, m.namespace, m.title, m.content, m.kind,
                   myvector_distance(m.title_vec, myvector_construct('${queryVector}')) AS dist
            FROM llm_memory m
            WHERE MYVECTOR_IS_ANN('${annPath}', 'id', myvector_construct('${queryVector}'), ${limit}, (${filter}))
        '''
        let statement = executor.setSql(sql)

        let hits = ArrayList<MemoryHit>()
        for(row in statement.mapList()){
            // MyVector 的 COSINE 距离是 1 - cosine，这里换算回相似度
            let distance = floatOf(row.get('dist') ?? 0.0f64)
            hits.add(MemoryHit(recordOf(row), 1.0f64 - distance))
        }
        hits
    }

    public func searchSparse(query: MemoryQuery, tokens: HashMap<Int64, Float64>,
                             limit: Int64): ArrayList<MemoryHit> {
        if(tokens.isEmpty()){
            return ArrayList<MemoryHit>()
        }
        let tokenPlaceholders = ArrayList<String>()
        for(_ in tokens.keys()){
            tokenPlaceholders.add('?')
        }
        let sql = '''
            SELECT m.id, m.user_id, m.namespace, m.title, m.content, m.kind,
                   SUM(t.weight) AS score
            FROM llm_memory_token t
            JOIN llm_memory m ON m.id = t.memory_id
            WHERE t.user_id = ? AND t.token IN (${join(tokenPlaceholders)})
            GROUP BY m.id, m.user_id, m.namespace, m.title, m.content, m.kind
            ORDER BY score DESC
            LIMIT ?
        '''
        var statement = executor.setSql(sql).add(query.userId)
        for((token, _) in tokens){
            statement = statement.add(token)
        }
        statement = statement.add(limit)

        let hits = ArrayList<MemoryHit>()
        for(row in statement.mapList()){
            hits.add(MemoryHit(recordOf(row), floatOf(row.get('score') ?? 0.0f64)))
        }
        hits
    }

    public func upsertSparse(memoryId: Int64, userId: Int64, namespace: String,
                             tokens: HashMap<Int64, Float64>): Unit {
        executor.setSql('DELETE FROM llm_memory_token WHERE memory_id = ?').add(memoryId).update
        for((token, weight) in tokens){
            executor.setSql('''
                INSERT INTO llm_memory_token (memory_id, user_id, namespace, field, token, weight)
                VALUES (?, ?, ?, 'm', ?, ?)
            ''')
                .add(memoryId)
                .add(userId)
                .add(namespace)
                .add(token)
                .add(weight)
                .update
        }
    }

    public func upsertColbert(memoryId: Int64, titleVectors: Array<Array<Float64>>,
                              contentVectors: Array<Array<Float64>>): Unit {
        executor.setSql('''
            UPDATE llm_memory
            SET title_colbert = ?, content_colbert = ?
            WHERE id = ?
        ''')
            .add(ColbertCodec.encode(titleVectors))
            .add(ColbertCodec.encode(contentVectors))
            .add(memoryId)
            .update
    }

    public func colbert(recordId: Int64): ?ColbertVectors {
        let row = executor.setSql(
            'SELECT title_colbert, content_colbert FROM llm_memory WHERE id = ?'
        ).add(recordId).firstToMap()
        if(row.isEmpty()){
            return None
        }
        let title = bytesOf(row.get('title_colbert'))
        let content = bytesOf(row.get('content_colbert'))
        if(title.size == 0 && content.size == 0){
            return None
        }
        Some(ColbertVectors(ColbertCodec.decode(title), ColbertCodec.decode(content)))
    }

    public func get(userId: Int64, id: Int64): ?MemoryRecord {
        let row = executor.setSql(
            'SELECT ${MEMORY_COLUMNS} FROM llm_memory WHERE user_id = ? AND id = ?'
        ).add(userId).add(id).firstToMap()
        if(row.isEmpty()){
            None
        }else{
            Some(recordOf(row))
        }
    }

    public func list(userId: Int64, namespace: String, offset: Int64, limit: Int64): ArrayList<MemoryRecord> {
        let records = ArrayList<MemoryRecord>()
        for(row in executor.setSql('''
            SELECT ${MEMORY_COLUMNS} FROM llm_memory
            WHERE user_id = ? AND namespace = ?
            ORDER BY save_time DESC
            LIMIT ?, ?
        ''').add(userId).add(namespace).add(offset).add(limit).mapList()){
            records.add(recordOf(row))
        }
        records
    }

    public func remove(userId: Int64, id: Int64): Bool {
        executor.setSql('DELETE FROM llm_memory_token WHERE memory_id = ?').add(id).update
        executor.setSql('DELETE FROM llm_memory WHERE user_id = ? AND id = ?')
            .add(userId)
            .add(id)
            .delete > 0
    }

    private func filterLiteral(query: MemoryQuery): String {
        var sql = 'SELECT JSON_ARRAYAGG(id) FROM llm_memory WHERE user_id = ${query.userId}'
        if(query.namespaces.size > 0){
            let quoted = ArrayList<String>()
            for(namespace in query.namespaces){
                quoted.add("'${escape(namespace)}'")
            }
            sql += ' AND namespace IN (${join(quoted)})'
        }
        sql
    }

    private static func escape(text: String): String {
        text.replace("'", "''")
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

    private static func join(values: ArrayList<String>): String {
        var text = ''
        for(index in 0..values.size){
            if(index > 0){
                text += ','
            }
            text += values[index]
        }
        text
    }
}
