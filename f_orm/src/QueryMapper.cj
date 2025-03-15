/*
   Copyright (c) [2022] [WuJingrun（吴京润）]
   fountain is licensed under Mulan PSL v2.
   You can use this software according to the terms and conditions of the Mulan PSL v2.
   You may obtain a copy of Mulan PSL v2 at:
           http://license.coscl.org.cn/MulanPSL2
   THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
   See the Mulan PSL v2 for more details.
 */

package f_orm

import std.collection.{ArrayList, Map, HashMap, Set, List}
import f_exception.{TypeCastException, OverSizeException}
import f_base.EmptyMap
import f_base.ExtendOption
import f_orm.wrap.*

/* 数据映射类型，把数据库里的值，读出来调用putter，把值填充到指定的对象，
 * 一个数据库列对应一个QueryMapper, 泛型O是要填充的对象类型
 * name: 列名
 * dataType: 列数据类型
 * putter: 第一个参数是当前要映射的实例，第二个参数是要填入的值，本函数会把第二个参数填入映射实例的对应成员。
 * @QueryMappersGenerator 会把公共实例成员变量和公共实例成员属性与数据表列映射
 */
public open class QueryMapper<O> {
    public QueryMapper(
        protected let name!: String,
        protected let dataType!: DataType = unknown,
        protected let putter!: (O, Any) -> Unit
    ) {}

    protected func new<T>(): QueryMapper<T> {
        QueryMapper<T>(
            name: name,
            dataType: dataType,
            putter: {instance, value =>
                putter((instance as O).getOrThrow(), value)
            }
        )
    }

    protected open prop isGrouped: Bool {
        get() {
            false
        }
    }
    protected open prop isId: Bool {
        get() {
            false
        }
    }

    //获取单列的单行的数据
    public func get<T>(result: QueryResult): ?T {
        let wrap = (result as QueryResultWrap).getOrThrow()
        if (let Some(row) <- wrap.next()) {
            (row[name] as T).getOrThrow()
        } else {
            None
        }
    }
    public open func populate(row: Row, o: O): O {
        if (let Some(x) <- row.get(name)) {
            putter(o, x)
        }
        o
    }
}
public open class FieldQueryMapper<T, O> <: QueryMapper<O> {
    public init(
        name!: String,
        dataType!: DataType = unknown,
        putter!: (O, T) -> Unit
    ) {
        super(name: name, dataType: dataType, putter: {o, v => putter(o, convert<T>(v))})
    }
}
