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

import f_collection.*

public class DataMapIterator<K, V> <: Iterator<(Data, Data)> where K <: Equatable<K> & DataFields<K>, V <: DataFields<V> {
    public DataMapIterator(private let itr: Iterator<(K, V)>) {}
    public func next(): ?(Data, Data) {
        for((k, v) in itr){
            return (k.toData(), v.toData())
        }
        return None
    }
}

public class DataMap<M, K, V> <: Data & Collection<(Data, Data)> where K <: Equatable<K> & DataFields<K>, V <: DataFields<V>, M <: DataFields<M> & Map<K, V> {
    public DataMap(public let data: M) {}
    public func iterator(): Iterator<(Data, Data)> {
        DataMapIterator<K, V>(data.iterator())
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
        let b = StringBuilder('{')
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
}

public interface MapData<M, K, V> <: DataFields<M> where K <: Equatable<K> & DataFields<K>, V <: DataFields<V>, M <: DataFields<M> & Map<K, V> {
    func toData(): Data
    static func tryFromData(data: Data, flag!: DataConversionFlag): Any
}
private func tryFromDataToMap<M, K, V>(data: Data, flag: DataConversionFlag, creator: () -> M): M where K <: Equatable<K> & DataFields<K>, V <: DataFields<V>, M <: DataFields<M> & Map<K, V> {
    let map = creator()
    match(data){
        case x: DataMap<M, K, V> where (flag & DEEP) == 0 => x.data
        case itr: Iterable<(Data, Data)> => 
            for((dk, dv) in itr){
                if(let (Some(k: K), Some(v: V)) <- (internal_f_data_tryFromData<K>(dk, flag), internal_f_data_tryFromData<V>(dv, flag))){
                    map[k] = v
                }else if((flag & IGNORE_FIELD_NOT_CONVERTABLE) == 0){
                    throw DataException('data cannot be converted to tuple for ${TypeInfos.get<M>()} ')
                }
            }
        case itr: Iterable<(String, Data)> =>
            for((k, v) in itr){
                match(k){
                    case mk: K => if(let Some(mv: V) <- internal_f_data_tryFromData<V>(v, flag)){
                        map[mk] = mv
                    }else if((flag & IGNORE_FIELD_NOT_CONVERTABLE) == 0){
                        throw DataException('data cannot be converted to tuple for ${TypeInfos.get<M>()}, current tuple is (${k}, ${v})')
                    }
                    case _ => if(let (Some(mk: K), Some(mv: V)) <- (internal_f_data_tryFromData<K>(k.toData(), flag), internal_f_data_tryFromData<V>(v, flag))){
                        map[mk] = mv
                    }else if((flag & IGNORE_FIELD_NOT_CONVERTABLE) == 0){
                        throw DataException('data cannot be converted to tuple for ${TypeInfos.get<M>()}, current tuple is (${k}, ${v})')
                    }
                }
            }
        case _ where (flag & IGNORE_FIELD_TYPE_NOT_MATCH) == 0 => throw DataException('data cannot be converted to tuple for ${TypeInfos.get<M>()}, data is ${data}')
        case _ => ()
    }
    map
}
extend<K, V> HashMap<K, V> <: MapData<HashMap<K, V>, K, V> where K <: Equatable<K> & DataFields<K>, V <: DataFields<V> {
    public func toData(): Data {
        DataMap(this)
    }
    public static func tryFromData(data: Data, flag!: DataConversionFlag): Any {
        tryFromDataToMap<HashMap<K, V>, K, V>(data, flag){HashMap<K, V>()}
    }
}
extend<K, V> LinkedHashMap<K, V> <: MapData<LinkedHashMap<K, V>, K, V> where K <: Equatable<K> & DataFields<K>, V <: DataFields<V> {
    public func toData(): Data {
        DataMap(this)
    }
    public static func tryFromData(data: Data, flag!: DataConversionFlag): Any {
        tryFromDataToMap<LinkedHashMap<K, V>, K, V>(data, flag){LinkedHashMap<K, V>()}
    }
}
extend<K, V> TreeMap<K, V> <: MapData<TreeMap<K, V>, K, V> where K <: Equatable<K> & DataFields<K>, V <: DataFields<V> {
    public func toData(): Data {
        DataMap(this)
    }
    public static func tryFromData(data: Data, flag!: DataConversionFlag): Any {
        tryFromDataToMap<TreeMap<K, V>, K, V>(data, flag){TreeMap<K, V>()}
    }
}
