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
package fountain::fdbm.server

import std.database.sql.SqlException
import fountain::f_data.{DataBool, ToData}
import fountain::f_dbd.common.{DbdErrorCode, DbdErrorPayload, NEXT_ROW, QueryResultClosePayload,
    QueryResultColumnPayload, QueryResultServerPayload, SqlPayload, decodeStrict}
import fountain::f_net.SocketBuffer
import fountain::f_protocol.default.*
import fountain::f_dbm.IdGeneratorException
import fountain::fdbm.exception.FdbmException
import fountain::fdbm.execute.{DbdSession, ExecutionOutcome, QueryCursor}

/**
 * 协议契约层（设计 §10.2）：判别请求种类 → 执行 → 组织响应；**任何分支都回包**。
 *
 * 三种请求（与 f_dbd 文档 §7 一一对应）：
 * 1. `CONSUME(SqlPayload)` → 执行 SQL，回 `RESP(QueryResultServerPayload | UpdateResultPayload)`；
 * 2. `CONSUME(QueryResultColumnPayload)` → 列读 `Data` / `NEXT_ROW` `DataBool`；
 * 3. `UNSUBSCRIBE(QueryResultClosePayload)` → 幂等 `ACK`。
 */
protected struct FdbmHandler {
    public static func handle(context: ServerContext, buffer: SocketBuffer,
        message: Message): Message {
        InFlight.enter()
        try {
            return dispatch(context, buffer, message)
        } catch (e: FdbmException) {
            errorOf(message.id, e.code, e.message)
        } catch (e: IdGeneratorException) {
            // 扩展直接抛出时也要映射 ID_GENERATOR，不能落到 INTERNAL（D11）
            errorOf(message.id, DbdErrorCode.ID_GENERATOR, e.message)
        } catch (e: SqlException) {
            errorOf(message.id, DbdErrorCode.DB_ERROR, e.message, sqlState: e.sqlState)
        } catch (e: Exception) {
            context.logger.error('unhandled failure on request ${message.id}: ${e.message}', e)
            errorOf(message.id, DbdErrorCode.INTERNAL, e.message)
        } finally {
            InFlight.leave()
        }
    }

    private static func dispatch(context: ServerContext, buffer: SocketBuffer,
        message: Message): Message {
        let session = context.sessions.of(buffer)
        match (message.command) {
            case Command.CONSUME(_) =>
                match (decodeStrict<SqlPayload>(message.data)) {
                    case Some(payload) => executeSql(context, session, message, payload)
                    case None =>
                        match (decodeStrict<QueryResultColumnPayload>(message.data)) {
                            case Some(payload) => cursorOperation(session, message, payload)
                            case None => protocolError(context, message, 'unrecognized CONSUME payload')
                        }
                }
            case Command.UNSUBSCRIBE => closeCursor(context, session, message)
            case other => protocolError(context, message,
                'unsupported command ${other}: expect CONSUME or UNSUBSCRIBE')
        }
    }

    // ==================== SQL ====================

    private static func executeSql(context: ServerContext, session: DbdSession, message: Message,
        payload: SqlPayload): Message {
        // 防御：正常客户端按连接级独占拦截，服务端仍先关旧游标
        closeSessionCursor(context, session)
        let outcome = context.dispatcher.execute(session, payload.sql, payload.params.toArray())
        match (outcome.cursor) {
            case Some(cursor) =>
                cursor.qid = message.id.toString()
                // 会话已关闭/已摘除 → 新游标立即关闭，回 CURSOR_STATE（G16）
                if (!session.installCursor(cursor)) {
                    throw FdbmException(DbdErrorCode.CURSOR_STATE,
                        'the session is closed; the query cursor has been released')
                }
                resp(message.id, QueryResultServerPayload(outcome.columns))
            case None =>
                match (session.takeCursor()) {
                    case Some(previous) =>
                        try {
                            previous.close()
                        } catch (_: Exception) {
                            ()
                        }
                    case None => ()
                }
                match (outcome.update) {
                    case Some(update) => resp(message.id, update)
                    case None => throw FdbmException(DbdErrorCode.INTERNAL,
                        'execution produced neither a cursor nor an update result')
                }
        }
    }

    // ==================== 游标 ====================

    private static func cursorOperation(session: DbdSession, message: Message,
        payload: QueryResultColumnPayload): Message {
        let cursor = requireCursor(session)
        if (payload.index == NEXT_ROW) {
            resp(message.id, if (cursor.next()) { DataBool.TRUE } else { DataBool.FALSE })
        } else {
            resp(message.id, cursor.cell(payload.index, payload.bufSize))
        }
    }

    private static func closeCursor(context: ServerContext, session: DbdSession,
        message: Message): Message {
        let payload = match (decodeStrict<QueryResultClosePayload>(message.data)) {
            case Some(value) => value
            case None => throw FdbmException(DbdErrorCode.PROTOCOL,
                'UNSUBSCRIBE carries no QueryResultClosePayload')
        }
        let current = match (session.currentCursor()) {
            case Some(value) => value
            case None => return ack(message.id)
        }
        // 无游标 / 已关闭 / qid 不匹配：幂等 ACK，绝不关掉别的游标（设计 §10.2）
        if (current.isClosed() || current.qid != payload.qid) {
            return ack(message.id)
        }
        let cursor = match (session.takeCursor()) {
            case Some(value) => value
            case None => return ack(message.id)
        }
        try {
            // 清空当前行缓冲 → 读尽物理结果集 → 关闭段（归还连接）
            cursor.drain()
        } catch (e: Exception) {
            context.logger.error('failed to drain query cursor ${payload.qid}: ${e.message}', e)
        } finally {
            try {
                cursor.close()
            } catch (e: Exception) {
                context.logger.error('failed to close query cursor ${payload.qid}: ${e.message}', e)
            }
        }
        ack(message.id)
    }

    private static func requireCursor(session: DbdSession): QueryCursor {
        match (session.currentCursor()) {
            case Some(value) =>
                if (value.isClosed()) {
                    throw FdbmException(DbdErrorCode.CURSOR_STATE,
                        'the query cursor of this session is already closed')
                }
                value
            case None => throw FdbmException(DbdErrorCode.CURSOR_STATE,
                'no query cursor is open on this session')
        }
    }

    private static func closeSessionCursor(context: ServerContext, session: DbdSession): Unit {
        match (session.takeCursor()) {
            case Some(cursor) =>
                try {
                    cursor.close()
                } catch (e: Exception) {
                    context.logger.warn('failed to close the previous query cursor: ${e.message}')
                }
            case None => ()
        }
    }

    // ==================== 响应 ====================

    private static func resp<T>(id: MessageID, data: T): Message where T <: ToData {
        Message.resp(id, qos: QoS.AtMostOnce, ack: false, data: data)
    }

    private static func ack(id: MessageID): Message {
        Message.ack(id)
    }

    private static func protocolError(context: ServerContext, message: Message,
        reason: String): Message {
        context.logger.warn('${reason} (command=${message.command}, payload=${message.data})')
        errorOf(message.id, DbdErrorCode.PROTOCOL, reason)
    }

    private static func errorOf(id: MessageID, code: DbdErrorCode, message: String,
        sqlState!: String = ''): Message {
        Message.error(id, data: DbdErrorPayload(code, message, sqlState: sqlState))
    }
}
