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

public class NestQueryMapper<T, O> <: QueryMapper<O> where O <: QueryMappersInit<O>, T <: QueryMappersInit<T> {
    public NestQueryMapper(
        private let nested!: QueryMappers<T>,
        private let nestPutter!: (O, T) -> Unit
    ) {
        super(putter: {o, v =>}, dataType: UnknownDataType(true, ''))
    }
    func newNest<SUB>(): QueryMapper<SUB> where SUB <: QueryMappersInit<SUB> {
        NestQueryMapper<T, SUB>(
            nested: nested,
            nestPutter: {sub, nest => nestPutter((sub as O).getOrThrow(), nest)}
        )
    }
    public func populate(result: QueryResultWrap, o: O): O {
        let n = nested.map(result)
        nestPutter(o, n)
        o
    }
}

public class NullableNestQueryMapper<T, O> <: QueryMapper<O> {
    public NullableNestQueryMapper(
        private let nested!: QueryMappers<T>,
        private let nestGetter!: (O) -> Option<T>,
        private let nestPutter!: (O, T) -> Unit
    ) {
        super(putter: {o, v =>}, dataType: UnknownDataType(true, ''))
    }
    func newNullableNest<SUB>(): QueryMapper<SUB> {
        NullableNestQueryMapper<T, SUB>(
            nested: nested,
            nestGetter: {sub => nestGetter((sub as O).getOrThrow())},
            nestPutter: {sub, nest => nestPutter((sub as O).getOrThrow(), nest)}
        )
    }
    public func populate(result: QueryResultWrap, o: O): O {
        let n = nested.map(result)
        nestPutter(o, n)
        o
    }
}
