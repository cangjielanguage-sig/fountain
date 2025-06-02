/*
    Copyright (c) [2022] [WuJingrun（吴京润）]
    fountain is licensed under Mulan PSL v2.
    You can use this software according to the terms and conditions of the Mulan PSL v2.
    You may obtain a copy of Mulan PSL v2 at:
            http://license.coscl.org.cn/MulanPSL2
    THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
    See the Mulan PSL v2 for more details.
 */
package f_data

import std.collection.concurrent.{ConcurrentHashMap, ConcurrentMap}

public class DataConcurrentMapIterator<K, V> <: Iterator<(Data, Data)> where K <: Hashable & Equatable<K> & DataFields<K>, V <: DataFields<V> {
    public DataConcurrentMapIterator(private let itr: Iterator<(K, V)>) {}
    public func next(): ?(Data, Data) {
        for((k, v) in itr){
            return (k.toData(), v.toData())
        }
        return None
    }
}

public class DataConcurrentMap<M, K, V> <: Data & Collection<(Data, Data)> where K <: Hashable & Equatable<K> & DataFields<K>, V <: DataFields<V>, M <: DataFields<M> & ConcurrentMap<K, V> & Collection<(K, V)> {
    public DataConcurrentMap(public let data: M) {}
    public func iterator(): Iterator<(Data, Data)> {
        DataConcurrentMapIterator<K, V>(data.iterator())
    }
    public prop size: Int64 {
        get() {
            data.size
        }
    }
    public func isEmpty(): Bool {
        data.isEmpty()
    }
    public func toString(): String {
        let b = StringGenerator('{')
        for (d in this) {
            if (b.size > 1) {
                b.append(',')
            }
            b.append('${d[0]},${d[1]}')
        }
        b.append('}')
        b.toString()
    }
    public static func tryParse(s: String): ?Data {
        None<Data>
    }
    public static func parse(s: String): Data {
        throw DataParsableException('${s} cannot be parsed to ${TypeInfos.get<DataConcurrentMap<M, K, V>>()}')
    }
}

public interface ConcurrentMapData<M, K, V> <: DataFields<M> & MapRawType where K <: Equatable<K> & DataFields<K>, V <: DataFields<V>, M <: DataFields<M> & ConcurrentMap<K, V> {
    func toData(): Data
    static func tryFromData(data: Data, flag: DataConversionFlag): Any
    prop rawType: (TypeInfo, TypeInfo){
        get(){
            (TypeInfos.get<K>(), TypeInfos.get<V>())
        }
    }
}
extend<K, V> ConcurrentHashMap<K, V> <: ConcurrentMapData<ConcurrentHashMap<K, V>, K, V> where K <: Hashable & Equatable<K> & DataFields<K>, V <: DataFields<V> {
    public func toData(): Data {
        DataConcurrentMap(this)
    }
    public static func tryFromData(data: Data, flag: DataConversionFlag): Any {
        var map = ConcurrentHashMap<K, V>()
        match(data){
            case x: DataConcurrentMap<ConcurrentHashMap<K, V>, K, V> where (flag & DEEP) == 0 => x.data
            case itr: Iterable<(Data, Data)> => 
                for((dk, dv) in itr){
                    if(let (Some(k: K), Some(v: V)) <- (internal_f_data_tryFromData<K>(dk, flag), internal_f_data_tryFromData<V>(dv, flag))){
                        map.add(k, v)
                    }else if((flag & IGNORE_FIELD_NOT_CONVERTABLE) == 0){
                        throw DataException('data cannot be converted to tuple for ${TypeInfos.get<ConcurrentHashMap<K, V>>()} ')
                    }
                }
            case itr: Iterable<(String, Data)> =>
                for((k, v) in itr){
                    match(k){
                        case mk: K => if(let Some(mv: V) <- internal_f_data_tryFromData<V>(v, flag)){
                            map.add(mk, mv)
                        }else if((flag & IGNORE_FIELD_NOT_CONVERTABLE) == 0){
                            throw DataException('data cannot be converted to tuple for ${TypeInfos.get<ConcurrentHashMap<K, V>>()}, current tuple is (${k}, ${v})')
                        }
                        case _ => if(let (Some(mk: K), Some(mv: V)) <- (internal_f_data_tryFromData<K>(k.toData(), flag), internal_f_data_tryFromData<V>(v, flag))){
                            map.add(mk, mv)
                        }else if((flag & IGNORE_FIELD_NOT_CONVERTABLE) == 0){
                            throw DataException('data cannot be converted to tuple for ${TypeInfos.get<ConcurrentHashMap<K, V>>()}, current tuple is (${k}, ${v})')
                        }
                    }
                }
            case _ where (flag & IGNORE_FIELD_TYPE_NOT_MATCH) == 0 => throw DataException('data cannot be converted to tuple for ${TypeInfos.get<ConcurrentHashMap<K, V>>()}, data is ${data}')
            case _ => ()
        }
        map
    }
}