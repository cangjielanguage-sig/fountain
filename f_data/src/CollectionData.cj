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
    public static func fromData(data: Data): Array<T> {
        tryFromData(data).getOrThrow {DataException("${data} cannot be converted to ${TypeInfos<Array<T>>.instance}")}
    }
    public static func tryFromData(data: Data): ?Array<T> {
        match (data) {
            case x: DataSequence =>
                let list = ArrayList<T>()
                for (v in x) {
                    match (T.tryFromData(v)) {
                        case Some(x) => list.append(x)
                        case _ => return None<Array<T>>
                    }
                }
                list.toArray()
            case x => match (T.tryFromData(x)) {
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
    public static func fromData(data: Data): ArrayList<T> {
        tryFromData(data).getOrThrow {DataException("${data} cannot be converted to ${TypeInfos<ArrayList<T>>.instance}")}
    }
    public static func tryFromData(data: Data): ?ArrayList<T> {
        match (data) {
            case x: DataSequence =>
                let list = ArrayList<T>()
                for (v in x) {
                    match (T.tryFromData(v)) {
                        case Some(x) => list.append(x)
                        case _ => return None<ArrayList<T>>
                    }
                }
                list
            case x => match (T.tryFromData(x)) {
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
    public static func fromData(data: Data): HashSet<T> {
        tryFromData(data).getOrThrow {DataException("${data} cannot be converted to ${TypeInfos<HashSet<T>>.instance}")}
    }
    public static func tryFromData(data: Data): ?HashSet<T> {
        match (data) {
            case x: DataSequence =>
                let set = HashSet<T>()
                for (v in x) {
                    match (T.tryFromData(v)) {
                        case Some(x) => set.put(x)
                        case _ => return None<HashSet<T>>
                    }
                }
                set
            case x => match (T.tryFromData(x)) {
                case Some(x) => HashSet<T>([x])
                case _ => None<HashSet<T>>
            }
            case _ => None<HashSet<T>>
        }
    }
}

extend<T> SyncSet<T> <: DataFields<SyncSet<T>> where T <: DataFields<T> & Hashable & Equatable<T> {
    public func toData(): Data {
        let list = ArrayList<Data>()
        for (v in this) {
            list.append(v.toData())
        }
        DataSequence(list)
    }
    public static func fromData(data: Data): SyncSet<T> {
        tryFromData(data).getOrThrow {DataException("${data} cannot be converted to ${TypeInfos<SyncSet<T>>.instance}")}
    }
    public static func tryFromData(data: Data): ?SyncSet<T> {
        match (data) {
            case x: DataSequence =>
                let set = SyncSet<T>.createHashSet<T>()
                for (v in x) {
                    match (T.tryFromData(v)) {
                        case Some(x) => set.put(x)
                        case _ => return None<SyncSet<T>>
                    }
                }
                set
            case x => match (T.tryFromData(x)) {
                case Some(x) =>
                    let set = SyncSet<T>.createHashSet<T>()
                    set.put(x)
                    set
                case _ => None<SyncSet<T>>
            }
            case _ => None<SyncSet<T>>
        }
    }
}

extend<T> SealableSet<T> <: DataFields<SealableSet<T>> where T <: DataFields<T> & Hashable & Equatable<T> {
    public func toData(): Data {
        let list = ArrayList<Data>()
        for (v in this) {
            list.append(v.toData())
        }
        DataSequence(list)
    }
    public static func fromData(data: Data): SealableSet<T> {
        tryFromData(data).getOrThrow {DataException("${data} cannot be converted to ${TypeInfos<SyncSet<T>>.instance}")}
    }
    public static func tryFromData(data: Data): ?SealableSet<T> {
        match (data) {
            case x: DataSequence =>
                let set = SealableSet<T>.createHashSet<T>()
                for (v in x) {
                    match (T.tryFromData(v)) {
                        case Some(x) => set.put(x)
                        case _ => return None<SealableSet<T>>
                    }
                }
                set.seal()
                set
            case x => match (T.tryFromData(x)) {
                case Some(x) =>
                    let set = SealableSet<T>.createHashSet<T>()
                    set.put(x)
                    set.seal()
                    set
                case _ => None<SealableSet<T>>
            }
            case _ => None<SealableSet<T>>
        }
    }
}

extend<T> HashMap<K, V> <: DataFields<HashMap<K, V>> where K <: DataFields<K> & Hashable & Equatable<K>, V <: DataFields<V> {
    public func toData(): Data {
        let list = ArrayList<DataTuple>()
        for ((k, v) in this) {
            list.append(DataTuple.create<K, V>(k, v))
        }
        DataTuples(list)
    }
    public static func fromData(data: Data): HashMap<K, V> {
        tryFromData(data).getOrThrow {DataException("${data} cannot be converted to ${TypeInfos<HashMap<K, V>>.instance}")}
    }
    public static func tryFromData(data: Data): ?HashMap<K, V> {
        match (data) {
            case x: DataSequence =>
                let map = HashMap<K, V>()
                for (v in x) {
                    match (v) {
                        case x: DataTuple => match ((K.tryFromData(x.key), V.tryFromData(x.value))) {
                            case (Some(k), Some(v)) => map.put(k, v)
                            case _ => return None<HashMap<K, V>>
                        }
                        case _ => return None<HashMap<K, V>>
                    }
                }
                map
            case x: DataTuple => match ((K.tryFromData(x.key), V.tryFromData(x.value))) {
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
                        match ((K.tryFromData(f.name.toData()), V.tryFromData(f.get(raw)))) {
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

extend<T> TreeMap<K, V> <: DataFields<TreeMap<K, V>> where K <: DataFields<K> & Comparable<K>, V <: DataFields<V> {
    public func toData(): Data {
        let list = ArrayList<DataTuple>()
        for ((k, v) in this) {
            list.append(DataTuple.create<K, V>(k, v))
        }
        DataTuples(list)
    }
    public static func fromData(data: Data): TreeMap<K, V> {
        tryFromData(data).getOrThrow {DataException("${data} cannot be converted to ${TypeInfos<TreeMap<K, V>>.instance}")}
    }
    public static func tryFromData(data: Data): ?TreeMap<K, V> {
        match (data) {
            case x: DataSequence =>
                let map = TreeMap<K, V>()
                for (v in x) {
                    match (v) {
                        case x: DataTuple => match ((K.tryFromData(x.key), V.tryFromData(x.value))) {
                            case (Some(k), Some(v)) => map.put(k, v)
                            case _ => return None<TreeMap<K, V>>
                        }
                        case _ => return None<TreeMap<K, V>>
                    }
                }
                map
            case x: DataTuple => match ((K.tryFromData(x.key), V.tryFromData(x.value))) {
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
                        match ((K.tryFromData(f.name.toData()), V.tryFromData(f.get(raw)))) {
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

extend<T> ConcurrentHashMap<K, V> <: DataFields<ConcurrentHashMap<K, V>> where K <: DataFields<K> & Hashable & Equatable<K>,
    V <: DataFields<V> {
    public func toData(): Data {
        let list = ArrayList<DataTuple>()
        for ((k, v) in this) {
            list.append(DataTuple.create<K, V>(k, v))
        }
        DataTuples(list)
    }
    public static func fromData(data: Data): ConcurrentHashMap<K, V> {
        tryFromData(data).getOrThrow {DataException(
                "${data} cannot be converted to ${TypeInfos<ConcurrentHashMap<K, V>>.instance}")}
    }
    public static func tryFromData(data: Data): ?ConcurrentHashMap<K, V> {
        match (data) {
            case x: DataSequence =>
                let map = ConcurrentHashMap<K, V>()
                for (v in x) {
                    match (v) {
                        case x: DataTuple => match ((K.tryFromData(x.key), V.tryFromData(x.value))) {
                            case (Some(k), Some(v)) => map.put(k, v)
                            case _ => return None<ConcurrentHashMap<K, V>>
                        }
                        case _ => return None<ConcurrentHashMap<K, V>>
                    }
                }
                map
            case x: DataTuple => match ((K.tryFromData(x.key), V.tryFromData(x.value))) {
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
                        match ((K.tryFromData(f.name.toData()), V.tryFromData(f.get(raw)))) {
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

extend<T> SyncMap<K, V> <: DataFields<SyncMap<K, V>> where K <: DataFields<K> & Hashable & Equatable<K>, V <: DataFields<V> {
    public func toData(): Data {
        let list = ArrayList<DataTuple>()
        for ((k, v) in this) {
            list.append(DataTuple.create<K, V>(k, v))
        }
        DataTuples(list)
    }
    public static func fromData(data: Data): SyncMap<K, V> {
        tryFromData(data).getOrThrow {DataException("${data} cannot be converted to ${TypeInfos<SyncMap<K, V>>.instance}")}
    }
    public static func tryFromData(data: Data): ?SyncMap<K, V> {
        match (data) {
            case x: DataSequence =>
                let map = SyncMap<K, V>.createByHashEq<K>()
                for (v in x) {
                    match (v) {
                        case x: DataTuple => match ((K.tryFromData(x.key), V.tryFromData(x.value))) {
                            case (Some(k), Some(v)) => map.put(k, v)
                            case _ => return None<SyncMap<K, V>>
                        }
                        case _ => return None<SyncMap<K, V>>
                    }
                }
                map
            case x: DataTuple => match ((K.tryFromData(x.key), V.tryFromData(x.value))) {
                case (Some(k), Some(v)) =>
                    let map = SyncMap<K, V>.createByHashEq<K>()
                    map.put(k, v)
                    map
                case _ => return None<SyncMap<K, V>>
            }
            case x =>
                let dataType = TypeInfo.of(x)
                if (dataType.qualifiedName.startsWith("fountain/data.ObjectData")) {
                    let map = SyncMap<K, V>.createByHashEq<K>()
                    let raw = ((dataType as ClassTypeInfo).getOrThrow().getInstanceVariable("data").getValue(x) as Object).
                        getOrThrow()
                    let iterator = (dataType.getInstanceFunction("fields").apply(x) as Iterator<ReadableField>).
                        getOrThrow()
                    for (f in iterator) {
                        match ((K.tryFromData(f.name.toData()), V.tryFromData(f.get(raw)))) {
                            case (Some(k), Some(v)) => map[k] = v
                            case _ => continue
                        }
                    }
                    map
                } else {
                    None<SyncMap<K, V>>
                }
        }
    }
}

extend<T> LinkedMap<K, V> <: DataFields<LinkedMap<K, V>> where K <: DataFields<K> & Hashable & Equatable<K>,
    V <: DataFields<V> {
    public func toData(): Data {
        let list = ArrayList<DataTuple>()
        for ((k, v) in this) {
            list.append(DataTuple.create<K, V>(k, v))
        }
        DataTuples(list)
    }
    public static func fromData(data: Data): LinkedMap<K, V> {
        tryFromData(data).getOrThrow {DataException("${data} cannot be converted to ${TypeInfos<LinkedMap<K, V>>.instance}")}
    }
    public static func tryFromData(data: Data): ?LinkedMap<K, V> {
        match (data) {
            case x: DataSequence =>
                let map = LinkedMap<K, V>()
                for (v in x) {
                    match (v) {
                        case x: DataTuple => match ((K.tryFromData(x.key), V.tryFromData(x.value))) {
                            case (Some(k), Some(v)) => map.put(k, v)
                            case _ => return None<LinkedMap<K, V>>
                        }
                        case _ => return None<LinkedMap<K, V>>
                    }
                }
                map
            case x: DataTuple => match ((K.tryFromData(x.key), V.tryFromData(x.value))) {
                case (Some(k), Some(v)) =>
                    let map = LinkedMap<K, V>()
                    map.put(k, v)
                    map
                case _ => return None<LinkedMap<K, V>>
            }
            case x =>
                let dataType = TypeInfo.of(x)
                if (dataType.qualifiedName.startsWith("fountain/data.ObjectData")) {
                    let map = LinkedMap<K, V>()
                    let raw = ((dataType as ClassTypeInfo).getOrThrow().getInstanceVariable("data").getValue(x) as Object).
                        getOrThrow()
                    let iterator = (dataType.getInstanceFunction("fields").apply(x) as Iterator<ReadableField>).
                        getOrThrow()
                    for (f in iterator) {
                        match ((K.tryFromData(f.name.toData()), V.tryFromData(f.get(raw)))) {
                            case (Some(k), Some(v)) => map[k] = v
                            case _ => continue
                        }
                    }
                    map
                } else {
                    None<LinkedMap<K, V>>
                }
        }
    }
}
