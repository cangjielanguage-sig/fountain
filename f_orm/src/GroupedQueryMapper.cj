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

public class GroupedQueryMapper<T, O> <: QueryMapper<O> {
    public GroupedQueryMapper(
        name!: String,
        private let grouped!: QueryMappers<T>,
        private let groupedGetter!: (O) -> ArrayList<T>
    ) {
        super(name: name, putter: {o, v => }, dataType: unknown)
    }
    func newGrouped<SUB>(): QueryMapper<SUB> where SUB <: QueryMappersInit<SUB> {
        GroupedQueryMapper<T, SUB>(
            name: name,
            grouped: grouped,
            groupedGetter: {sub => groupedGetter((sub as O).getOrThrow())}
        )
    }
    protected prop isGrouped: Bool {
        get() {
            true
        }
    }
    public func populate(row: Row, o: O): O {
        let groupedValue = grouped.creator()
        let list = groupedGetter(o)
        list.append(groupedValue)
        for (m in grouped.mappers) {
            if (let Some(value) <- row.get(m.name)) {
                m.putter(groupedValue, value)
            }
        }
        o
    }
}
public class GroupedSingleQueryMapper<T, O> <: QueryMapper<O> {
    public GroupedSingleQueryMapper(
        name!: String,
        private let groupedGetter!: (O) -> ArrayList<T>
    ) {
        super(name: name, putter: {o, v => }, dataType: unknown)
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
    public func populate(row: Row, o: O): O {
        let list = groupedGetter(o)
        if (let Some(value) <- row.get(name)) {
            list.append(orm.convert<T>(value))
        }
        o
    }
}
public class NullableGroupedQueryMapper<T, O> <: QueryMapper<O> {
    public NullableGroupedQueryMapper(
        name!: String,
        private let ignoreNone!: Bool = true,
        private let grouped!: QueryMappers<T>,
        private let groupedGetter!: (O) -> ArrayList<Option<T>>
    ) {
        super(name: name, putter: {o, v => }, dataType: unknown)
    }
    func newNullableGrouped<SUB>(): QueryMapper<SUB> {
        NullableGroupedQueryMapper<T, SUB>(
            name: name,
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
    public func populate(row: Row, o: O): O {
        let list = groupedGetter(o)
        let prevSize = list.size
        let mappers = grouped.mappers
        var i = 0
        while (i < mappers.size) {
            let mapper = mappers[i]
            if (let Some(value) <- row.get(mapper.name)) {
                let groupedValue = if (prevSize == list.size) {
                    let groupedValue = grouped.creator()
                    list.append(groupedValue)
                    groupedValue
                } else {
                    list[prevSize].getOrThrow()
                }
                mapper.putter(groupedValue, value)
            }
            i++
        }
        if (!ignoreNone && prevSize == list.size) {
            list.append(Option<T>.None)
        }
        o
    }
}
