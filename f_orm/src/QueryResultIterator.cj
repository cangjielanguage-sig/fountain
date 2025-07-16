/*
    Copyright (c) 2022 WuJingrun（吴京润）
    fountain is licensed under Mulan PSL v2.
    You can use this software according to the terms and conditions of the Mulan PSL v2.
    You may obtain a copy of Mulan PSL v2 at:
            http://license.coscl.org.cn/MulanPSL2
    THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
    See the Mulan PSL v2 for more details.
 */
package f_orm

public class QueryResultIterator<T> <: Iterator<T> & Resource {
    QueryResultIterator(
        private let result: QueryResultWrap,
        private let mappers: QueryMappers<T>
    ) {}
    public func next(): ?T {
        mappers.doMap(result)
    }
    public func isClosed(): Bool {
        result.isClosed()
    }
    public func close(): Unit {
        result.close()
    }
}

public class SingleColumnIterator<T> <: Iterator<T> & Resource {
    SingleColumnIterator(
        private let result: QueryResultWrap,
        private let index!: Int64 = 0,
        private let column!: String = String.empty
    ) {}
    public func next(): ?T {
        if (column == String.empty) {
            if (result.next()) {
                result.getOrNull<T>(index)
            } else {
                throw ORMException("the first column does not match specified data type")
            }
        } else {
            if (result.next()) {
                result.getOrNull<T>(index)
            } else {
                throw ORMException("the first column does not match specified data type")
            }
        }
    }
    public func isClosed(): Bool {
        result.isClosed()
    }
    public func close(): Unit {
        result.close()
    }
}
