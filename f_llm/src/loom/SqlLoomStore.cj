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
package fountain::f_llm.loom

import std.collection.*
import std.convert.*

import fountain::f_orm.*

import fountain::f_llm.dao.mysql.*
import fountain::f_llm.dao.postgres.*

/**
 * `step_sources` 列的编码：`id\u0001source` 以 `\u0002` 分隔。
 *
 * 之所以不用 JSON：源码里有引号与换行，JSON 需要完整转义/反转义；这里只需要无损往返，
 * 控制字符在仓颉源码里不会出现，比 JSON 更省事，也不会因为转义 bug 丢数据。
 */
class StepSourceCodec {
    private static let FIELDS = String.fromUtf8([1u8])
    private static let RECORDS = String.fromUtf8([2u8])

    private init() {
    }

    public static func encode(sources: HashMap<String, String>): String {
        var text = ''
        for((id, source) in sources){
            if(!text.isEmpty()){
                text += RECORDS
            }
            text += '${id}${FIELDS}${source}'
        }
        text
    }

    public static func decode(text: String): HashMap<String, String> {
        let result = HashMap<String, String>()
        if(text.isEmpty()){
            return result
        }
        for(record in text.split(RECORDS)){
            let parts = record.split(FIELDS)
            if(parts.size < 2){
                continue
            }
            result[parts[0]] = parts[1]
        }
        result
    }
}

/** 共享的行映射：两套 SQL 只差方言 */
class LoomRowMapper {
    private init() {
    }

    public static func toFlow(row: HashMap<String, Any>): LoomFlow {
        let flow = LoomFlow(textOf(row.get('name')), description: textOf(row.get('description')))
        flow.planJson = textOf(row.get('plan_json'))
        flow.flowSource = textOf(row.get('flow_source'))
        flow.stepSources = StepSourceCodec.decode(textOf(row.get('step_sources')))
        flow.status = textOf(row.get('status'))
        flow.round = intOf(row.get('round'))
        flow.questionsJson = textOf(row.get('questions_json'))
        flow.tools = textOf(row.get('tools'))
        flow.mcps = textOf(row.get('mcps'))
        flow
    }

    private static func textOf(value: ?Any): String {
        match(value){
            case Some(raw) =>
                match(raw as String){
                    case Some(text) => text
                    case None =>
                        // PG 驱动可能把 TEXT 回成字节数组
                        match(raw as Array<Byte>){
                            case Some(bytes) => String.fromUtf8(bytes)
                            case None =>
                                // Any 不实现 ToString：剩余只可能是数值列，逐个收敛
                                match(raw as Int64){
                                    case Some(number) => number.toString()
                                    case None =>
                                        match(raw as Int32){
                                            case Some(number) => Int64(number).toString()
                                            case None => ''
                                        }
                                }
                        }
                }
            case None => ''
        }
    }

    private static func intOf(value: ?Any): Int64 {
        match(value){
            case Some(raw) =>
                match(raw){
                    case number: Int64 => number
                    case number: Int32 => Int64(number)
                    case text: String => Int64.tryParse(text) ?? 0
                    case _ => 0
                }
            case None => 0
        }
    }
}

/** PG 版 loom 存储 */
public class PostgresLoomStore <: LoomStore & RootService {
    public init() {
    }

    public func save(flow: LoomFlow): Unit {
        dao<PostgresLoomDAO>('postgres').loomUpsert(flow.name, flow.description, flow.planJson,
            flow.flowSource, StepSourceCodec.encode(flow.stepSources), flow.status, flow.round,
            flow.questionsJson, flow.tools, flow.mcps)
    }

    public func get(name: String): ?LoomFlow {
        let rows = dao<PostgresLoomDAO>('postgres').loomGet(name)
        if(rows.isEmpty()){
            return None
        }
        Some(LoomRowMapper.toFlow(rows[0]))
    }

    public func list(offset: Int64, limit: Int64): ArrayList<LoomFlow> {
        let result = ArrayList<LoomFlow>()
        for(row in dao<PostgresLoomDAO>('postgres').loomList(offset, limit)){
            result.add(LoomRowMapper.toFlow(row))
        }
        result
    }

    public func remove(name: String): Bool {
        let existed = get(name).isSome()
        dao<PostgresLoomDAO>('postgres').loomRemove(name)
        existed
    }
}

/** MySQL 版 loom 存储 */
public class MySqlLoomStore <: LoomStore & RootService {
    public init() {
    }

    public func save(flow: LoomFlow): Unit {
        dao<MySqlLoomDAO>('mysql').loomUpsert(flow.name, flow.description, flow.planJson,
            flow.flowSource, StepSourceCodec.encode(flow.stepSources), flow.status, flow.round,
            flow.questionsJson, flow.tools, flow.mcps)
    }

    public func get(name: String): ?LoomFlow {
        let rows = dao<MySqlLoomDAO>('mysql').loomGet(name)
        if(rows.isEmpty()){
            return None
        }
        Some(LoomRowMapper.toFlow(rows[0]))
    }

    public func list(offset: Int64, limit: Int64): ArrayList<LoomFlow> {
        let result = ArrayList<LoomFlow>()
        for(row in dao<MySqlLoomDAO>('mysql').loomList(offset, limit)){
            result.add(LoomRowMapper.toFlow(row))
        }
        result
    }

    public func remove(name: String): Bool {
        let existed = get(name).isSome()
        dao<MySqlLoomDAO>('mysql').loomRemove(name)
        existed
    }
}
