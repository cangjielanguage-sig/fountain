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

import std.collection.HashMap
import f_base.*
import f_collection.{LinkedHashMap, ExtendMap}

public class QueryMappers<O> {
    private var hasGroup = false
    private var idMapper = None<QueryMapper<O>>
    public QueryMappers(
        protected let mappers!: Array<QueryMapper<O>>, //QueryMapper的集合，每个QueryMaper映射一个字段
        protected let creator!: () -> O //映射对象的创建器
    ) {
        for (m in mappers) {
            if (m.isGrouped) {
                hasGroup = true
            } else if (m.isId) {
                idMapper = m
            }
            if (hasGroup && idMapper.isSome()) {
                break
            }
        }
    }
    public static func create<T>(mappers!: Array<QueryMapper<T>>, creator!: ()->T): ?QueryMappers<T> {
        if(!(TypeInfos.get<O>().isSubtypeOf(TypeInfos.get<Object>()) && TypeInfos.get<T>().isSubtypeOf(TypeInfos.get<O>()))){
            return None<QueryMappers<T>>
        }
        let oType = TypeInfos.get<O>()
        let oMappers = (oType.getStaticFunction("queryMappers").apply(oType) as QueryMappers<O>).getOrThrow().mappers
        QueryMappers<T>(mappers: Array<QueryMapper<T>>(oMappers.size + mappers.size){i =>
            if(i < oMappers.size){
                oMappers[i].new<T>()
            }else{
                mappers[i]
            }
        }, creator: creator)
    }
    /**
     * 映射单个对象
     */
    func doMap(result: QueryResultWrap): Option<O> {
        while (result.next()) {
            return map(result)
        }
        return None
    }

    func map(result: QueryResultWrap): O {
        let o = creator()
        for (mapper in mappers) {
            mapper.populate(result, o)
        }
        o
    }
    //映射全部结果集
    public func list(result: QueryResultWrap): ArrayList<O> {
        let list = ArrayList<O>()
        while (result.next()) {
            list.add(map(result))
        }
        list
    }
    public func groupedList<ID>(result: QueryResultWrap): ArrayList<O> where ID <: Hashable & Equatable<ID> {
        if (hasGroup) {
            let idMapper = (this.idMapper.getOrThrow() as IdQueryMapper<ID, O>).getOrThrow()
            let map = LinkedHashMap<ID, O>()
            while (result.next()) {
                let id = idMapper.id(result)
                match (map.get(id, false)) {
                    case Some(o) => for (mapper in mappers where mapper.isGrouped) {
                        mapper.populate(result, o)
                    }
                    case _ => map[id] = this.map(result)
                }
            }
            ArrayList<O>(map.values())
        } else {
            list(result)
        }
    }
    public func iterator(result: QueryResultWrap): QueryResultIterator<O> {
        QueryResultIterator<O>(result, this)
    }
    public func one(result: QueryResultWrap): Option<O> {
        doMap(result)
    }
}
