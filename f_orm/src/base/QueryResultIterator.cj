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

/**
 * 结果集迭代器的公共父类：持有结果集与它的 executor，负责资源的最终收尾。
 *
 * executor 同时持有本次查询的 Statement / Connection / Transaction，因此迭代器返回后
 * 底层资源不会被提前回收（`SqlExecutor` 的非事务收尾会跳过移交出去的这次查询）。
 *
 * close() 的顺序与语义：
 * 1. 总是关闭 QueryResult（结果集本身）；
 * 2. 其余交给 `SqlExecutor.close()` —— 它自带 `tx.isNone()` 判断：不在事务中时关闭
 *    Statement 与 Connection；在事务中则不动它们（留给事务结束后的 `close()`）。
 *
 * 实现 `Resource`：可放进 `try (it = ...)` 自动关闭；`next()` 读尽时也会自动关闭。
 */
public abstract class AbstractQueryResultIterator<T> <: Iterator<T> & Resource {
    private var closed_ = false
    protected AbstractQueryResultIterator(
        protected let result: QueryResultWrap,
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
            // 即使关闭结果集失败也要走 executor 收尾，否则该 executor 会一直卡在「活动结果集」保护里
            executor.releaseActiveQueryResult()
        }
    }
}

/** 按 `QueryMappers` 逐行映射成对象的迭代器。 */
public class QueryResultIterator<T> <: AbstractQueryResultIterator<T> {
    QueryResultIterator(
        result: QueryResultWrap,
        executor: SqlExecutor,
        private let mappers: QueryMappers<T>
    ) {
        super(result, executor)
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
        executor: SqlExecutor,
        private let index!: Int64 = 0,
        private let column!: String = String.empty
    ) {
        super(result, executor)
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
