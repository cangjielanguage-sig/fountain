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

public class IdQueryMapper<ID, O> <: FieldQueryMapper<ID, O> where ID <: Hashable & Equatable<ID> {
    public init(
        dataType!: DataType = Int64DataType(false, 'id'),
        putter!: (O, ID) -> Unit
    ) {
        super(dataType: dataType, putter: putter)
    }
    protected prop isId: Bool {
        get() {
            true
        }
    }
    public func populate(result: QueryResultWrap, o: O): O {
        if (let Some(id) <- super.get<ID>(result)) {
            putter(o, id)
        }
        o
    }
    public func id(result: QueryResultWrap): ID {
        super.get<ID>(result).getOrThrow()
    }
}
