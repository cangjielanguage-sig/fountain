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

import std.collection.ArrayList

public class GroupedQueryMapper<T, O> <: QueryMapper<O> {
    public GroupedQueryMapper(
        private let grouped!: QueryMappers<T>,
        private let groupedGetter!: (O) -> ArrayList<T>
    ) {
        super(putter: {o, v =>}, dataType: UnknownDataType(true, ''))
    }
    func newGrouped<SUB>(): QueryMapper<SUB> where SUB <: QueryMappersInit<SUB> {
        GroupedQueryMapper<T, SUB>(
            grouped: grouped,
            groupedGetter: {sub => groupedGetter((sub as O).getOrThrow())}
        )
    }
    protected prop isGrouped: Bool {
        get() {
            true
        }
    }
    public func populate(result: QueryResultWrap, o: O): O {
        let grouped = this.grouped.map(result)
        groupedGetter(o).add(grouped)
        o
    }
}

public class GroupedSingleQueryMapper<T, O> <: QueryMapper<O> {
    public GroupedSingleQueryMapper(
        private let name!: String,
        private let groupedGetter!: (O) -> ArrayList<T>
    ) {
        super(putter: {o, v =>}, dataType: UnknownDataType(false, name))
    }
    func newGroupedSingle<SUB>(): QueryMapper<SUB> where SUB <: QueryMappersInit<SUB> {
        GroupedSingleQueryMapper<T, SUB>(
            name: name,
            groupedGetter: {sub => groupedGetter((sub as O).getOrThrow())}
        )
    }
    protected prop isGrouped: Bool {
        get() {
            true
        }
    }
    public func populate(result: QueryResultWrap, o: O): O {
        let list = groupedGetter(o)
        list.add(convert<T>(result.getOrNull<T>(name)))
        o
    }
}

public class NullableGroupedQueryMapper<T, O> <: QueryMapper<O> {
    public NullableGroupedQueryMapper(
        private let ignoreNone!: Bool = true,
        private let grouped!: QueryMappers<T>,
        private let groupedGetter!: (O) -> ArrayList<Option<T>>
    ) {
        super(putter: {o, v =>}, dataType: UnknownDataType(true, ''))
    }
    func newNullableGrouped<SUB>(): QueryMapper<SUB> {
        NullableGroupedQueryMapper<T, SUB>(
            ignoreNone: ignoreNone,
            grouped: grouped,
            groupedGetter: {sub => groupedGetter((sub as O).getOrThrow())}
        )
    }
    protected prop isGrouped: Bool {
        get() {
            true
        }
    }
    public func populate(result: QueryResultWrap, o: O): O {
        let list = groupedGetter(o)
        let prevSize = list.size
        let mappers = grouped.mappers
        let groupedValue = grouped.creator()
        list.add(groupedValue)
        for (mapper in mappers) {
            let value = mapper.dataType.get(result)
            mapper.putter(groupedValue, value)
        }
        if (!ignoreNone && prevSize == list.size) {
            list.add(Option<T>.None)
        }
        o
    }
}
