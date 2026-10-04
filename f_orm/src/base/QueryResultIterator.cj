/*
Copyright (c) 2025 WuJingrun（吴京润）

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
package fountain::f_orm.base

import std.database.sql.*
import fountain::f_log.impl.*

/**
 * 结果集迭代器的公共父类：持有本次查询的 QueryResult、Statement 与它的 executor，负责资源的最终收尾。
 *
 * 持有 Statement 后，「事务中移交出去的语句」不再依赖 `SqlExecutor` 的 `stmt` 槽位——迭代器自己
 * 就是它的唯一持有者，事务里再执行别的 SQL 也不会把它顶掉（见 bug.md §1.5）。
 *
 * close() 的顺序：QueryResult → Statement → executor 收尾（releaseActiveQueryResult）。
 * - Statement 关失败只记日志不抛出（与 `SqlExecutor.close()` 关语句的口径一致）；
 * - 最后一步交给 executor：复位「活动结果集」保护，并走 `SqlExecutor.close()`——不在事务中时
 *   归还连接，在事务中则只复位标记（连接留给事务结束后的 `close()`）。
 *
 * 实现 `Resource`：可放进 `try (it = ...)` 自动关闭；`next()` 读尽时也会自动关闭。
 */
public abstract class AbstractQueryResultIterator<T> <: Iterator<T> & Resource {
    private static let logger = LoggerFactory.getLogger('fountain::f_orm.base.AbstractQueryResultIterator', [])
    private var closed_ = false
    protected AbstractQueryResultIterator(
        protected let result: QueryResultWrap,
        protected let statement: Statement,
        private let executor: SqlExecutor
    ) {}
    public func isClosed(): Bool {
        closed_ || result.isClosed()
    }
    public func close(): Unit {
        if (closed_) {
            return
        }
        closed_ = true
        try {
            result.close()
        } finally {
            try {
                if (!statement.isClosed()) {
                    statement.close()
                }
            } catch (e: Exception) {
                logger.warn(e)
            } finally {
                // 即使前两步失败也要复位「活动结果集」，否则该 executor 之后的查询会一直被拒
                executor.releaseActiveQueryResult()
            }
        }
    }
}

/** 按 `QueryMappers` 逐行映射成对象的迭代器。 */
public class QueryResultIterator<T> <: AbstractQueryResultIterator<T> {
    QueryResultIterator(
        result: QueryResultWrap,
        statement: Statement,
        executor: SqlExecutor,
        private let mappers: QueryMappers<T>
    ) {
        super(result, statement, executor)
    }
    public func next(): ?T {
        if (isClosed()) {
            return None<T>
        }
        let value = mappers.doMap(result)
        if (value.isNone()) {
            // 读尽即释放：调用方用 while 循环读完时无需再显式 close()
            close()
        }
        value
    }
}

/** 读单列的迭代器；`column` 非空时按列名取值，否则按 `index`（默认 0）。 */
public class SingleColumnIterator<T> <: AbstractQueryResultIterator<T> {
    SingleColumnIterator(
        result: QueryResultWrap,
        statement: Statement,
        executor: SqlExecutor,
        private let index!: Int64 = 0,
        private let column!: String = String.empty
    ) {
        super(result, statement, executor)
    }
    public func next(): ?T {
        if (isClosed()) {
            return None<T>
        }
        if (result.next()) {
            if (column.size > 0) {
                result.getOrNull<T>(column)
            } else {
                result.getOrNull<T>(index)
            }
        } else {
            close()
            None<T>
        }
    }
}
