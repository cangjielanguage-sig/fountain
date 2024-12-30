/*
    Copyright (c) [2022] [WuJingrun（吴京润）]
    fountain is licensed under Mulan PSL v2.
    You can use this software according to the terms and conditions of the Mulan PSL v2.
    You may obtain a copy of Mulan PSL v2 at:
            http://license.coscl.org.cn/MulanPSL2
    THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
    See the Mulan PSL v2 for more details.  
*/
package f_data.path

import std.ast.{cangjieLex, TokenKind}

internal interface DataFilter {
    func check(data: Data): Bool

    operator func &(right: DataFilter): DataFilter {
        AndFilter(this, right)
    }
    operator func |(right: DataFilter): DataFilter {
        OrFilter(this, right)
    }
    operator func !(): DataFilter {
        NotFilter(this)
    }
    static func compilePath(path: String, solid: String){
        if(Bool.parse(solid)){
            DataPath.solid(path)
        }else{
            DataPath.cache(path)
        }
    }
    static func parse<T>(value: String): T {
        let t = TypeInfos.get<T>()
        let any: Any = 
        if(t == TypeInfos.get<String>()){
            value
        }else if(t == TypeInfos.get<Int64>()){
            Int64.parse(value)
        }else if(t == TypeInfos.get<Float64>()){
            Float64.parse(value)
        }else if(t == TypeInfos.get<Bool>()){
            Bool.parse(value)
        }else {
            throw DataException('unsupported for comparing type ${t}')
        }
        (any as T).getOrThrow()
    }
    static func parseArrayList<T>(value: String): ArrayList<T> {
        let list = ArrayList<T>()
        for(t in cangjieLex(value, true)){
            match(t.kind){
                case COMMA => continue
                case STRING_LITERAL | INT64 | FLOAT64 | BOOL_LITERAL => list.append(parse<T>(t.value))
                case _ => throw DataException('illegal token for set filter ${value}')
            }
        }
        list
    }
    static func parseHashSet<T>(value: String): HashSet<T> where T <: Hashable & Equatable<T> {
        let set = HashSet<T>()
        for(t in cangjieLex(value, true)){
            match(t.kind){
                case COMMA => continue
                case STRING_LITERAL | INT64 | FLOAT64 | BOOL_LITERAL => set.put(parse<T>(t.value))
                case _ => throw DataException('illegal token for set filter ${value}')
            }
        }
        set
    }
}
