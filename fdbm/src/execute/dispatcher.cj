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
package fountain::fdbm.execute

import std.collection.HashMap
import fountain::f_data.DataAny
import fountain::f_dbd.common.DbdErrorCode
import fountain::f_dbm.IdGenerator
import fountain::fdbm.config.{BootScriptWriter, IdMakerConfig}
import fountain::fdbm.exception.FdbmException
import fountain::fdbm.resources.NodeAccessor
import fountain::fdbm.route.{GlobalTableRouter, PartitionRouter}
import fountain::fdbm.sql.*

/**
 * 唯一执行入口（设计 §9.2）：`parse → bind → route → 分发`。
 *
 * `sql` 是客户端原文；参数已按 `?` 顺序绑定为字面量。
 */
protected class ExecutorDispatcher {
    private let selectExecutor: SelectExecutor
    private let dmlExecutor: DmlExecutor
    private let insertExecutor: InsertExecutor
    private let showExecutor: ShowExecutor
    private let ddlExecutor: DdlExecutor
    private let sessionExecutor: SessionCtlExecutor
    private let exportExecutor: ExportExecutor

    public init(router: PartitionRouter, globals: GlobalTableRouter, resources: NodeAccessor,
        idmaker: IdMakerConfig, sequenceDatabase: String,
        customIdGenerators: HashMap<String, IdGenerator>, bootScript: ?BootScriptWriter) {
        this.selectExecutor = SelectExecutor(resources, router, globals)
        this.dmlExecutor = DmlExecutor(resources, router)
        this.insertExecutor = InsertExecutor(resources, router, this.selectExecutor, idmaker,
            sequenceDatabase, customIdGenerators)
        this.showExecutor = ShowExecutor(resources)
        this.ddlExecutor = DdlExecutor(resources)
        this.sessionExecutor = SessionCtlExecutor(resources)
        this.exportExecutor = ExportExecutor(bootScript)
    }

    public func execute(session: DbdSession, sql: String, params: Array<DataAny>): ExecutionOutcome {
        let parsed = SqlParser.parse(sql, session.database)
        let statement = ParameterBinder.bind(parsed, params)
        match (statement) {
            case s: SelectStatement => selectExecutor.execute(session, s)
            case s: UpdateStatement => dmlExecutor.execute(session, s)
            case s: DeleteStatement => dmlExecutor.execute(session, s)
            case s: InsertStatement => insertExecutor.execute(session, s)
            case s: ShowStatement => showExecutor.execute(session, s)
            case s: DdlStatement => ddlExecutor.execute(session, s)
            case s: SessionCtlStatement => sessionExecutor.execute(session, s)
            case s: ExportStatement => exportExecutor.execute(s)
            case _ => throw FdbmException(DbdErrorCode.UNSUPPORTED_SQL, 'unsupported statement')
        }
    }
}
