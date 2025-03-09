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
        name!: String,
        private let nested!: QueryMappers<T>,
        private let nestPutter!: (O, T) -> Unit
    ) {
        super(name: name, putter: {o, v => }, dataType: unknown)
    }
    func newNest<SUB>(): QueryMapper<SUB> where SUB <: QueryMappersInit<SUB> {
        NestQueryMapper<T, SUB>(
            name: name,
            nested: nested,
            nestPutter: {sub, nest => nestPutter((sub as O).getOrThrow(), nest)}
        )
    }
    public func populate(row: Row, o: O): O {
        let nest = nested.creator()
        nestPutter(o, nest)
        for (m in nested.mappers) {
            if (let Some(x) <- row.get(m.name)) {
                m.putter(nest, x)
            }
        }
        o
    }
}
public class NullableNestQueryMapper<T, O> <: QueryMapper<O> {
    public NullableNestQueryMapper(
        name!: String,
        private let nested!: QueryMappers<T>,
        private let nestGetter!: (O) -> Option<T>,
        private let nestPutter!: (O, T) -> Unit
    ) {
        super(name: name, putter: {o, v => }, dataType: unknown)
    }
    func newNullableNest<SUB>(): QueryMapper<SUB> {
        NullableNestQueryMapper<T, SUB>(
            name: name,
            nested: nested,
            nestGetter: {sub => nestGetter((sub as O).getOrThrow())},
            nestPutter: {sub, nest => nestPutter((sub as O).getOrThrow(), nest)}
        )
    }
    public func populate(row: Row, o: O): O {
        for (m in nested.mappers) {
            if (let Some(x) <- row.get(m.name)) {
                let nest = match (nestGetter(o)) {
                    case Some(x) => x
                    case _ =>
                        let n = nested.creator()
                        nestPutter(o, n)
                        n
                }
                m.putter(nest, x)
            }
        }
        o
    }
}
