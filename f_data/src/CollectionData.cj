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

import std.collection.{ArrayList, HashSet, HashMap, TreeMap}
import std.collection.concurrent.ConcurrentHashMap
import f_collection.LinkedHashMap

extend<T> Array<T> <: DataFields<Array<T>> where T <: DataFields<T> {
    public func toData(): Data {
        let list = ArrayList<Data>()
        for (v in this) {
            list.append(v.toData())
        }
        DataSequence(list)
    }
    public static func fromData(data: Data, flag!: UInt64 = SILENCE): Array<T> {
        tryFromData(data, flag: flag).getOrThrow {DataException("${data} cannot be converted to ${TypeInfos.get<Array<T>>()}")}
    }
    public static func tryFromData(data: Data, flag!: UInt64 = SILENCE): ?Array<T> {
        match (data) {
            case x: DataSequence =>
                let list = ArrayList<T>()
                for (v in x) {
                    match (T.tryFromData(v, flag: flag)) {
                        case Some(x) => list.append(x)
                        case _ => return None<Array<T>>
                    }
                }
                list.toArray()
            case x => match (T.tryFromData(x, flag: flag)) {
                case Some(x) => [x]
                case _ => None<Array<T>>
            }
        }
    }
}

extend<T> ArrayList<T> <: DataFields<ArrayList<T>> where T <: DataFields<T> {
    public func toData(): Data {
        let list = ArrayList<Data>()
        for (v in this) {
            list.append(v.toData())
        }
        DataSequence(list)
    }
    public static func fromData(data: Data, flag!: UInt64 = SILENCE): ArrayList<T> {
        tryFromData(data, flag: flag).getOrThrow {DataException("${data} cannot be converted to ${TypeInfos.get<ArrayList<T>>()}")}
    }
    public static func tryFromData(data: Data, flag!: UInt64 = SILENCE): ?ArrayList<T> {
        match (data) {
            case x: DataSequence =>
                let list = ArrayList<T>()
                for (v in x) {
                    match (T.tryFromData(v, flag: flag)) {
                        case Some(x) => list.append(x)
                        case _ => return None<ArrayList<T>>
                    }
                }
                list
            case x => match (T.tryFromData(x, flag: flag)) {
                case Some(x) => ArrayList<T>([x])
                case _ => None<ArrayList<T>>
            }
            case _ => None<ArrayList<T>>
        }
    }
}

extend<T> HashSet<T> <: DataFields<HashSet<T>> where T <: DataFields<T> & Hashable & Equatable<T> {
    public func toData(): Data {
        let list = ArrayList<Data>()
        for (v in this) {
            list.append(v.toData())
        }
        DataSequence(list)
    }
    public static func fromData(data: Data, flag!: UInt64 = SILENCE): HashSet<T> {
        tryFromData(data, flag: flag).getOrThrow {DataException("${data} cannot be converted to ${TypeInfos.get<HashSet<T>>()}")}
    }
    public static func tryFromData(data: Data, flag!: UInt64 = SILENCE): ?HashSet<T> {
        match (data) {
            case x: DataSequence =>
                let set = HashSet<T>()
                for (v in x) {
                    match (T.tryFromData(v, flag: flag)) {
                        case Some(x) => set.put(x)
                        case _ => return None<HashSet<T>>
                    }
                }
                set
            case x => match (T.tryFromData(x, flag: flag)) {
                case Some(x) => HashSet<T>([x])
                case _ => None<HashSet<T>>
            }
            case _ => None<HashSet<T>>
        }
    }
}

extend<K, V> HashMap<K, V> <: DataFields<HashMap<K, V>> where K <: DataFields<K> & Hashable & Equatable<K>, V <: DataFields<V> {
    public func toData(): Data {
        if(TypeInfos.get<String>() == TypeInfos.get<K>()){
            let map = StringKeyMapTuples()
            for((k, v) in this){
                let s = (k as String).getOrThrow()
                map.add(s, v)
            }
            map
        }else{
            let list = ArrayList<DataTuple>()
            for ((k, v) in this) {
                list.append(DataTuple.create<K, V>(k, v))
            }
            DataTuples(list)
        }
    }
    public static func fromData(data: Data, flag!: UInt64 = SILENCE): HashMap<K, V> {
        tryFromData(data, flag: flag).getOrThrow {DataException("${data} cannot be converted to ${TypeInfos.get<HashMap<K, V>>()}")}
    }
    public static func tryFromData(data: Data, flag!: UInt64 = SILENCE): ?HashMap<K, V> {
        match (data) {
            case x: DataSequence =>
                let map = HashMap<K, V>()
                for (v in x) {
                    match (v) {
                        case x: DataTuple => match ((K.tryFromData(x.key, flag: flag), V.tryFromData(x.value, flag: flag))) {
                            case (Some(k), Some(v)) => map.put(k, v)
                            case _ => return None<HashMap<K, V>>
                        }
                        case _ => return None<HashMap<K, V>>
                    }
                }
                map
            case x: DataTuple => match ((K.tryFromData(x.key, flag: flag), V.tryFromData(x.value, flag: flag))) {
                case (Some(k), Some(v)) =>
                    let map = HashMap<K, V>()
                    map.put(k, v)
                    map
                case _ => return None<HashMap<K, V>>
            }
            case x =>
                let dataType = TypeInfo.of(x)
                if (dataType.qualifiedName.startsWith("fountain/data.ObjectData")) {
                    let map = HashMap<K, V>()
                    let raw = ((dataType as ClassTypeInfo).getOrThrow().getInstanceVariable("data").getValue(x) as Object).
                        getOrThrow()
                    let iterator = (dataType.getInstanceFunction("fields").apply(x) as Iterator<ReadableField>).
                        getOrThrow()
                    for (f in iterator) {
                        match ((K.tryFromData(f.name.toData(), flag: flag), V.tryFromData(f.get(raw), flag: flag))) {
                            case (Some(k), Some(v)) => map[k] = v
                            case _ => continue
                        }
                    }
                    map
                } else {
                    None<HashMap<K, V>>
                }
        }
    }
}

extend<K, V> TreeMap<K, V> <: DataFields<TreeMap<K, V>> where K <: DataFields<K> & Comparable<K>, V <: DataFields<V> {
    public func toData(): Data {
        if(TypeInfos.get<String>() == TypeInfos.get<K>()){
            let map = StringKeyMapTuples()
            for((k, v) in this){
                let s = (k as String).getOrThrow()
                map.add(s, v)
            }
            map
        }else{
            let list = ArrayList<DataTuple>()
            for ((k, v) in this) {
                list.append(DataTuple.create<K, V>(k, v))
            }
            DataTuples(list)
        }
    }
    public static func fromData(data: Data, flag!: UInt64 = SILENCE): TreeMap<K, V> {
        tryFromData(data, flag: flag).getOrThrow {DataException("${data} cannot be converted to ${TypeInfos.get<TreeMap<K, V>>()}")}
    }
    public static func tryFromData(data: Data, flag!: UInt64 = SILENCE): ?TreeMap<K, V> {
        match (data) {
            case x: DataSequence =>
                let map = TreeMap<K, V>()
                for (v in x) {
                    match (v) {
                        case x: DataTuple => match ((K.tryFromData(x.key, flag: flag), V.tryFromData(x.value, flag: flag))) {
                            case (Some(k), Some(v)) => map.put(k, v)
                            case _ => return None<TreeMap<K, V>>
                        }
                        case _ => return None<TreeMap<K, V>>
                    }
                }
                map
            case x: DataTuple => match ((K.tryFromData(x.key, flag: flag), V.tryFromData(x.value, flag: flag))) {
                case (Some(k), Some(v)) =>
                    let map = TreeMap<K, V>()
                    map.put(k, v)
                    map
                case _ => return None<TreeMap<K, V>>
            }
            case x =>
                let dataType = TypeInfo.of(x)
                if (dataType.qualifiedName.startsWith("fountain/data.ObjectData")) {
                    let map = TreeMap<K, V>()
                    let raw = ((dataType as ClassTypeInfo).getOrThrow().getInstanceVariable("data").getValue(x) as Object).
                        getOrThrow()
                    let iterator = (dataType.getInstanceFunction("fields").apply(x) as Iterator<ReadableField>).
                        getOrThrow()
                    for (f in iterator) {
                        match ((K.tryFromData(f.name.toData(), flag: flag), V.tryFromData(f.get(raw), flag: flag))) {
                            case (Some(k), Some(v)) => map[k] = v
                            case _ => continue
                        }
                    }
                    map
                } else {
                    None<TreeMap<K, V>>
                }
        }
    }
}

extend<K, V> ConcurrentHashMap<K, V> <: DataFields<ConcurrentHashMap<K, V>> where K <: DataFields<K> & Hashable & Equatable<K>,
    V <: DataFields<V> {
    public func toData(): Data {
        if(TypeInfos.get<String>() == TypeInfos.get<K>()){
            let map = StringKeyMapTuples()
            for((k, v) in this){
                let s = (k as String).getOrThrow()
                map.add(s, v)
            }
            map
        }else{
            let list = ArrayList<DataTuple>()
            for ((k, v) in this) {
                list.append(DataTuple.create<K, V>(k, v))
            }
            DataTuples(list)
        }
    }
    public static func fromData(data: Data, flag!: UInt64 = SILENCE): ConcurrentHashMap<K, V> {
        tryFromData(data).getOrThrow {DataException(
                "${data} cannot be converted to ${TypeInfos.get<ConcurrentHashMap<K, V>>()}")}
    }
    public static func tryFromData(data: Data, flag!: UInt64 = SILENCE): ?ConcurrentHashMap<K, V> {
        match (data) {
            case x: DataSequence =>
                let map = ConcurrentHashMap<K, V>()
                for (v in x) {
                    match (v) {
                        case x: DataTuple => match ((K.tryFromData(x.key, flag: flag), V.tryFromData(x.value, flag: flag))) {
                            case (Some(k), Some(v)) => map.put(k, v)
                            case _ => return None<ConcurrentHashMap<K, V>>
                        }
                        case _ => return None<ConcurrentHashMap<K, V>>
                    }
                }
                map
            case x: DataTuple => match ((K.tryFromData(x.key, flag: flag), V.tryFromData(x.value, flag: flag))) {
                case (Some(k), Some(v)) =>
                    let map = ConcurrentHashMap<K, V>()
                    map.put(k, v)
                    map
                case _ => return None<ConcurrentHashMap<K, V>>
            }
            case x =>
                let dataType = TypeInfo.of(x)
                if (dataType.qualifiedName.startsWith("fountain/data.ObjectData")) {
                    let map = ConcurrentHashMap<K, V>()
                    let raw = ((dataType as ClassTypeInfo).getOrThrow().getInstanceVariable("data").getValue(x) as Object).
                        getOrThrow()
                    let iterator = (dataType.getInstanceFunction("fields").apply(x) as Iterator<ReadableField>).
                        getOrThrow()
                    for (f in iterator) {
                        match ((K.tryFromData(f.name.toData(), flag: flag), V.tryFromData(f.get(raw), flag: flag))) {
                            case (Some(k), Some(v)) => map[k] = v
                            case _ => continue
                        }
                    }
                    map
                } else {
                    None<ConcurrentHashMap<K, V>>
                }
        }
    }
}

extend<K, V> LinkedHashMap<K, V> <: DataFields<LinkedHashMap<K, V>> where K <: DataFields<K> & Hashable & Equatable<K>,
    V <: DataFields<V> {
    public func toData(): Data {
        if(TypeInfos.get<String>() == TypeInfos.get<K>()){
            let map = StringKeyMapTuples()
            for((k, v) in this){
                let s = (k as String).getOrThrow()
                map.add(s, v)
            }
            map
        }else{
            let list = ArrayList<DataTuple>()
            for ((k, v) in this) {
                list.append(DataTuple.create<K, V>(k, v))
            }
            DataTuples(list)
        }
    }
    public static func fromData(data: Data, flag!: UInt64 = SILENCE): LinkedHashMap<K, V> {
        tryFromData(data, flag: flag).getOrThrow {DataException("${data} cannot be converted to ${TypeInfos.get<LinkedHashMap<K, V>>()}")}
    }
    public static func tryFromData(data: Data, flag!: UInt64 = SILENCE): ?LinkedHashMap<K, V> {
        match (data) {
            case x: DataSequence =>
                let map = LinkedHashMap<K, V>()
                for (v in x) {
                    match (v) {
                        case x: DataTuple => match ((K.tryFromData(x.key, flag: flag), V.tryFromData(x.value, flag: flag))) {
                            case (Some(k), Some(v)) => map.put(k, v)
                            case _ => return None<LinkedHashMap<K, V>>
                        }
                        case _ => return None<LinkedHashMap<K, V>>
                    }
                }
                map
            case x: DataTuple => match ((K.tryFromData(x.key, flag: flag), V.tryFromData(x.value, flag: flag))) {
                case (Some(k), Some(v)) =>
                    let map = LinkedHashMap<K, V>()
                    map.put(k, v)
                    map
                case _ => return None<LinkedHashMap<K, V>>
            }
            case x =>
                let dataType = TypeInfo.of(x)
                if (dataType.qualifiedName.startsWith("fountain/data.ObjectData")) {
                    let map = LinkedHashMap<K, V>()
                    let raw = ((dataType as ClassTypeInfo).getOrThrow().getInstanceVariable("data").getValue(x) as Object).
                        getOrThrow()
                    let iterator = (dataType.getInstanceFunction("fields").apply(x) as Iterator<ReadableField>).
                        getOrThrow()
                    for (f in iterator) {
                        match ((K.tryFromData(f.name.toData(), flag: flag), V.tryFromData(f.get(raw), flag: flag))) {
                            case (Some(k), Some(v)) => map[k] = v
                            case _ => continue
                        }
                    }
                    map
                } else {
                    None<LinkedHashMap<K, V>>
                }
        }
    }
}
