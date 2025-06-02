/*
    Copyright (c) [2022] [WuJingrun（吴京润）]
    fountain is licensed under Mulan PSL v2.
    You can use this software according to the terms and conditions of the Mulan PSL v2.
    You may obtain a copy of Mulan PSL v2 at:
            http://license.coscl.org.cn/MulanPSL2
    THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
    See the Mulan PSL v2 for more details.  
*/
package f_data.json

import std.collection.concurrent.ConcurrentMap

public interface ToJsonString {
    func toJsonString(): String
}
extend DataBool <: ToJsonString{
    public func toJsonString(): String{
        toString()
    }
}
extend DataDateTime <: ToJsonString{
    public func toJsonString(): String {
        '"${toString()}"'
    }
}
extend DataDuration <: ToJsonString {
    public func toJsonString(): String {
        '"${toString()}"'
    }
}
extend DataNone <: ToJsonString {
    public func toJsonString(): String {
        'null'
    }
}
extend DataString <: ToJsonString {
    public func toJsonString(): String {
        '"${toString()}"'
    }
}
extend DataReal <: ToJsonString {
    public func toJsonString(): String {
        toString()
    }
}
extend<T> DataObject<T> <: ToJsonString where T <: ObjectData<T> {
    public func toJsonString(): String {
        let builder = StringGenerator('{')
        for((name, value) in this){
            let valStr = 
            match(value){
                case x: ToJsonString => x.toJsonString()
                case _ => continue
            }
            if(builder.size > 1){
                builder.append(',')
            }
            builder.append('"${name}"')
            builder.append(':')
            builder.append(valStr)
        }
        builder.append('}')
        builder.toString()
    }
}
extend<C, T> DataCollection<C, T> <: ToJsonString where T <: DataFields<T>,C <: DataFields<C> & Collection<T> {
    public func toJsonString(): String {
        let builder = StringGenerator('[')
        for(d in this){
            let valStr = 
            match(d){
                case x: ToJsonString => x.toJsonString()
                case _ => continue
            }
            if(builder.size > 1){
                builder.append(',')
            }
            builder.append(valStr)
        }
        builder.append(']')
        builder.toString()
    }
}
extend<M, K, V> DataMap<M, K, V> <: ToJsonString where K <: DataFields<K>, V <: DataFields<V>, M <: DataFields<M> & Map<K, V> {
    public func toJsonString(): String {
        let builder = StringGenerator('{')
        for((k, v) in this){
            let (ks, vs) = 
            match((k, v)){
                case (x: ToJsonString, y: ToJsonString) => (x.toJsonString(), y.toJsonString())
                case _ => continue
            }
            if(builder.size > 1){
                builder.append(',')
            }
            if(ks.startsWith('"') && ks.endsWith('"')){
                builder.append(ks)
            }else{
                builder.append('"${ks}"')
            }
            builder.append(':')
            builder.append(vs)
        }
        builder.append('}')
        builder.toString()
    }
}
extend<M, K, V> DataConcurrentMap<M, K, V> <: ToJsonString where K <: DataFields<K>, V <: DataFields<V>, M <: DataFields<M> & ConcurrentMap<K, V> {
    public func toJsonString(): String {
        let builder = StringGenerator('{')
        for((k, v) in this){
            let (ks, vs) = 
            match((k, v)){
                case (x: ToJsonString, y: ToJsonString) => (x.toJsonString(), y.toJsonString())
                case _ => continue
            }
            if(builder.size > 1){
                builder.append(',')
            }
            if(ks.startsWith('"') && ks.endsWith('"')){
                builder.append(ks)
            }else{
                builder.append('"${ks}"')
            }
            builder.append(':')
            builder.append(vs)
        }
        builder.append('}')
        builder.toString()
    }
}