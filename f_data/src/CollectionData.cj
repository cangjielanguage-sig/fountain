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

extend<T> Array<T> <: DataFields<Array<T>> where T <: DataFields<T> {
    public func toData(): Data {
        match(this){
            case x: Array<Byte> => 
                toBase64String(x).toData()
            case _ =>
                let list = ArrayList<Data>()
                for (v in this) {
                    list.append(v.toData())
                }
                DataSequence(list)
        }
    }
    public static func tryFromData(data: Data, flag!: DataConversionFlag = SILENCE): Any {
        match (data) {
            case x: DataSequence =>
                let list = ArrayList<T>()
                for (v in x) {
                    match (convert<T>(v, flag: flag)) {
                        case Some(x: T) => list.append(x)
                        case _ where (flag & IGNORE_FIELD_NOT_CONVERTABLE) == 0 => throw DataException('${v} cannot be converted to ${TypeInfos.get<T>()}')
                        case _ => continue
                    }
                }
                unsafe{list.getRawArray()} as Array<T>
            case x: DataString where TypeInfos.get<T>() == TypeInfos.get<Byte>() && Regex.BASE64.matched(x.toString()) =>
                fromBase64String(x.toString())
            case _ where (flag & IGNORE_FIELD_TYPE_NOT_MATCH) == 0 => throw DataException('${data} does not match ${TypeInfos.get<Array<T>>()}')
            case x => match (convert<T>(x, flag: flag)) {
                case Some(x: T) => [x]
                case _ where (flag & IGNORE_FIELD_NOT_CONVERTABLE) == 0 => throw DataException('${data} cannot be converted to ${TypeInfos.get<Array<T>>()}')
                case _ => None<T>
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
    public static func tryFromData(data: Data, flag!: DataConversionFlag = SILENCE): Any {
        match (data) {
            case x: DataSequence =>
                let list = ArrayList<T>()
                for (v in x) {
                    match (convert<T>(v, flag: flag)) {
                        case Some(x: T) => list.append(x)
                        case _ where (flag & IGNORE_FIELD_NOT_CONVERTABLE) == 0 => throw DataException('${v} cannot be converted to ${TypeInfos.get<T>()}')
                        case _ => continue
                    }
                }
                list
            case _ where (flag & IGNORE_FIELD_TYPE_NOT_MATCH) == 0 => throw DataException('${data} does not match ${TypeInfos.get<ArrayList<T>>()}')
            case x => match (convert<T>(x, flag: flag)) {
                case Some(x: T) => ArrayList<T>([x])
                case _ where (flag & IGNORE_FIELD_NOT_CONVERTABLE) == 0 => throw DataException('${data} cannot be converted to ${TypeInfos.get<ArrayList<T>>()}')
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
    public static func tryFromData(data: Data, flag!: DataConversionFlag = SILENCE): Any {
        match (data) {
            case x: DataSequence =>
                let set = HashSet<T>()
                for (v in x) {
                    match (convert<T>(v, flag: flag)) {
                        case Some(x: T) => set.put(x)
                        case _ where (flag & IGNORE_FIELD_NOT_CONVERTABLE) == 0 => throw DataException('${v} cannot be converted to ${TypeInfos.get<T>()}')
                        case _ => continue
                    }
                }
                set
            case _ where (flag & IGNORE_FIELD_TYPE_NOT_MATCH) == 0 => throw DataException('${data} does not match ${TypeInfos.get<HashSet<T>>()}')
            case x => match (convert<T>(x, flag: flag)) {
                case Some(x: T) => HashSet<T>([x])
                case _ where (flag & IGNORE_FIELD_NOT_CONVERTABLE) == 0 => throw DataException('${data} cannot be converted to ${TypeInfos.get<HashSet<T>>()}')
                case _ => None<HashSet<T>>
            }
            case _ => None<HashSet<T>>
        }
    }
}
extend<T> TreeSet<T> <: DataFields<TreeSet<T>> where T <: DataFields<T> & Comparable<T> {
    public func toData(): Data {
        let list = ArrayList<Data>()
        for (v in this) {
            list.append(v.toData())
        }
        DataSequence(list)
    }
    public static func tryFromData(data: Data, flag!: DataConversionFlag = SILENCE): Any {
        match (data) {
            case x: DataSequence =>
                let set = TreeSet<T>()
                for (v in x) {
                    match (convert<T>(v, flag: flag)) {
                        case Some(x: T) => set.put(x)
                        case _ where (flag & IGNORE_FIELD_NOT_CONVERTABLE) == 0 => throw DataException('${v} cannot be converted to ${TypeInfos.get<T>()}')
                        case _ => continue
                    }
                }
                set
            case _ where (flag & IGNORE_FIELD_TYPE_NOT_MATCH) == 0 => throw DataException('${data} does not match ${TypeInfos.get<TreeSet<T>>()}')
            case x => match (convert<T>(x, flag: flag)) {
                case Some(x: T) => TreeSet<T>([x])
                case _ where (flag & IGNORE_FIELD_NOT_CONVERTABLE) == 0 => throw DataException('${data} cannot be converted to ${TypeInfos.get<TreeSet<T>>()}')
                case _ => None<TreeSet<T>>
            }
            case _ => None<TreeSet<T>>
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
    public static func tryFromData(data: Data, flag!: DataConversionFlag = SILENCE): Any {
        match (data) {
            case x: DataSequence =>
                let map = HashMap<K, V>()
                for (v in x) {
                    match (v) {
                        case x: DataTuple => match ((convert<K>(x.key, flag: flag), convert<V>(x.value, flag: flag))) {
                            case (Some(k: K), Some(v: V)) => map.put(k, v)
                            case (Some(_), _) where (flag & IGNORE_FIELD_NOT_CONVERTABLE) == 0 => throw DataException('${x.value} cannot be converted to ${TypeInfos.get<V>()}')
                            case (_, Some(_)) where (flag & IGNORE_FIELD_NOT_CONVERTABLE) == 0 => throw DataException('${x.key} cannot be converted to ${TypeInfos.get<K>()}')
                            case _ where (flag & IGNORE_FIELD_NOT_CONVERTABLE) == 0 => throw DataException('tuple (${x.key}, ${x.value}) cannot be converted to (${TypeInfos.get<K>()}, ${TypeInfos.get<V>()})')
                            case _ => continue
                        }
                        case _ where (flag & IGNORE_FIELD_NOT_CONVERTABLE) == 0 => throw DataException('tuple ${x} cannot be converted to (${TypeInfos.get<K>()}, ${TypeInfos.get<V>()})')
                        case _ => continue
                    }
                }
                map
            case _ where (flag & IGNORE_FIELD_NOT_CONVERTABLE) == 0 => throw DataException('(${data}) cannot be converted to ${TypeInfos.get<HashMap<K, V>>()}')
            case x: DataTuple => match ((convert<K>(x.key, flag: flag), convert<V>(x.value, flag: flag))) {
                case (Some(k: K), Some(v: V)) =>
                    let map = HashMap<K, V>()
                    map.put(k, v)
                    map
                case (Some(_), _) where (flag & IGNORE_FIELD_NOT_CONVERTABLE) == 0 => throw DataException('${x.value} cannot be converted to ${TypeInfos.get<V>()}')
                case (_, Some(_)) where (flag & IGNORE_FIELD_NOT_CONVERTABLE) == 0 => throw DataException('${x.key} cannot be converted to ${TypeInfos.get<K>()}')
                case _ where (flag & IGNORE_FIELD_NOT_CONVERTABLE) == 0 => throw DataException('tuple (${x.key}, ${x.value}) cannot be converted to (${TypeInfos.get<K>()}, ${TypeInfos.get<V>()})')
                case _ => return None<HashMap<K, V>>
            }
            case x =>
                let dataType = TypeInfo.of(x)
                if (dataType.qualifiedName.startsWith("f_data.ObjectData")) {
                    let map = HashMap<K, V>()
                    let raw = ((dataType as ClassTypeInfo).getOrThrow().getInstanceVariable("data").getValue(x) as Object).
                        getOrThrow()
                    let iterator = (dataType.getInstanceFunction("fields").apply(x) as Iterator<ReadableField>).
                        getOrThrow()
                    for (f in iterator) {
                        match ((convert<K>(f.name.toData(), flag: flag), convert<V>(f.get(raw), flag: flag))) {
                            case (Some(k: K), Some(v: V)) => map[k] = v
                            case (Some(_), _) where (flag & IGNORE_FIELD_NOT_CONVERTABLE) == 0 => throw DataException('${f.get(raw)} cannot be converted to ${TypeInfos.get<V>()}')
                            case (_, Some(_)) where (flag & IGNORE_FIELD_NOT_CONVERTABLE) == 0 => throw DataException('${f.name} cannot be converted to ${TypeInfos.get<K>()}')
                            case _ where (flag & IGNORE_FIELD_NOT_CONVERTABLE) == 0 => throw DataException('tuple (${f.name}, ${f.get(raw)}) cannot be converted to (${TypeInfos.get<K>()}, ${TypeInfos.get<V>()})')            
                            case _ => continue
                        }
                    }
                    map
                } else if ((flag & IGNORE_FIELD_NOT_CONVERTABLE) == 0) {
                    throw DataException('${x} cannot be converted to ${TypeInfos.get<HashMap<K, V>>()}')
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
    public static func tryFromData(data: Data, flag!: DataConversionFlag = SILENCE): Any {
        match (data) {
            case x: DataSequence =>
                let map = TreeMap<K, V>()
                for (v in x) {
                    match (v) {
                        case x: DataTuple => match ((convert<K>(x.key, flag: flag), convert<V>(x.value, flag: flag))) {
                            case (Some(k: K), Some(v: V)) => map.put(k, v)
                            case (Some(_), _) where (flag & IGNORE_FIELD_NOT_CONVERTABLE) == 0 => throw DataException('${x.value} cannot be converted to ${TypeInfos.get<V>()}')
                            case (_, Some(_)) where (flag & IGNORE_FIELD_NOT_CONVERTABLE) == 0 => throw DataException('${x.key} cannot be converted to ${TypeInfos.get<K>()}')
                            case _ where (flag & IGNORE_FIELD_NOT_CONVERTABLE) == 0 => throw DataException('tuple (${x.key}, ${x.value}) cannot be converted to (${TypeInfos.get<K>()}, ${TypeInfos.get<V>()})')
                            case _ => continue
                        }
                        case _ where (flag & IGNORE_FIELD_NOT_CONVERTABLE) == 0 => throw DataException('tuple ${x} cannot be converted to (${TypeInfos.get<K>()}, ${TypeInfos.get<V>()})')
                        case _ => continue
                    }
                }
                map
            case _ where (flag & IGNORE_FIELD_NOT_CONVERTABLE) == 0 => throw DataException('(${data}) cannot be converted to ${TypeInfos.get<TreeMap<K, V>>()}')
            case x: DataTuple => match ((convert<K>(x.key, flag: flag), convert<V>(x.value, flag: flag))) {
                case (Some(k: K), Some(v: V)) =>
                    let map = TreeMap<K, V>()
                    map.put(k, v)
                    map
                case (Some(_), _) where (flag & IGNORE_FIELD_NOT_CONVERTABLE) == 0 => throw DataException('${x.value} cannot be converted to ${TypeInfos.get<V>()}')
                case (_, Some(_)) where (flag & IGNORE_FIELD_NOT_CONVERTABLE) == 0 => throw DataException('${x.key} cannot be converted to ${TypeInfos.get<K>()}')
                case _ where (flag & IGNORE_FIELD_NOT_CONVERTABLE) == 0 => throw DataException('tuple (${x.key}, ${x.value}) cannot be converted to (${TypeInfos.get<K>()}, ${TypeInfos.get<V>()})')
                case _ => return None<TreeMap<K, V>>
            }
            case x =>
                let dataType = TypeInfo.of(x)
                if (dataType.qualifiedName.startsWith("f_data.ObjectData")) {
                    let map = TreeMap<K, V>()
                    let raw = ((dataType as ClassTypeInfo).getOrThrow().getInstanceVariable("data").getValue(x) as Object).
                        getOrThrow()
                    let iterator = (dataType.getInstanceFunction("fields").apply(x) as Iterator<ReadableField>).
                        getOrThrow()
                    for (f in iterator) {
                        match ((convert<K>(f.name.toData(), flag: flag), convert<V>(f.get(raw), flag: flag))) {
                            case (Some(k: K), Some(v: V)) => map[k] = v
                            case (Some(_), _) where (flag & IGNORE_FIELD_NOT_CONVERTABLE) == 0 => throw DataException('${f.get(raw)} cannot be converted to ${TypeInfos.get<V>()}')
                            case (_, Some(_)) where (flag & IGNORE_FIELD_NOT_CONVERTABLE) == 0 => throw DataException('${f.name} cannot be converted to ${TypeInfos.get<K>()}')
                            case _ where (flag & IGNORE_FIELD_NOT_CONVERTABLE) == 0 => throw DataException('tuple (${f.name}, ${f.get(raw)}) cannot be converted to (${TypeInfos.get<K>()}, ${TypeInfos.get<V>()})')
                            case _ => continue
                        }
                    }
                    map
                } else if ((flag & IGNORE_FIELD_NOT_CONVERTABLE) == 0) {
                    throw DataException('${x} cannot be converted to ${TypeInfos.get<TreeMap<K, V>>()}')
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
    public static func tryFromData(data: Data, flag!: DataConversionFlag = SILENCE): Any {
        match (data) {
            case x: DataSequence =>
                let map = ConcurrentHashMap<K, V>()
                for (v in x) {
                    match (v) {
                        case x: DataTuple => match ((convert<K>(x.key, flag: flag), convert<V>(x.value, flag: flag))) {
                            case (Some(k: K), Some(v: V)) => map.put(k, v)
                            case (Some(_), _) where (flag & IGNORE_FIELD_NOT_CONVERTABLE) == 0 => throw DataException('${x.value} cannot be converted to ${TypeInfos.get<V>()}')
                            case (_, Some(_)) where (flag & IGNORE_FIELD_NOT_CONVERTABLE) == 0 => throw DataException('${x.key} cannot be converted to ${TypeInfos.get<K>()}')
                            case _ where (flag & IGNORE_FIELD_NOT_CONVERTABLE) == 0 => throw DataException('tuple (${x.key}, ${x.value}) cannot be converted to (${TypeInfos.get<K>()}, ${TypeInfos.get<V>()})')
                            case _ => continue
                        }
                        case _ where (flag & IGNORE_FIELD_NOT_CONVERTABLE) == 0 => throw DataException('tuple ${x} cannot be converted to (${TypeInfos.get<K>()}, ${TypeInfos.get<V>()})')
                        case _ => continue
                    }
                }
                map
            case _ where (flag & IGNORE_FIELD_NOT_CONVERTABLE) == 0 => throw DataException('(${data}) cannot be converted to ${TypeInfos.get<ConcurrentHashMap<K, V>>()}')
            case x: DataTuple => match ((convert<K>(x.key, flag: flag), convert<V>(x.value, flag: flag))) {
                case (Some(k: K), Some(v: V)) =>
                    let map = ConcurrentHashMap<K, V>()
                    map.put(k, v)
                    map
                case (Some(_), _) where (flag & IGNORE_FIELD_NOT_CONVERTABLE) == 0 => throw DataException('${x.value} cannot be converted to ${TypeInfos.get<V>()}')
                case (_, Some(_)) where (flag & IGNORE_FIELD_NOT_CONVERTABLE) == 0 => throw DataException('${x.key} cannot be converted to ${TypeInfos.get<K>()}')
                case _ where (flag & IGNORE_FIELD_NOT_CONVERTABLE) == 0 => throw DataException('tuple (${x.key}, ${x.value}) cannot be converted to (${TypeInfos.get<K>()}, ${TypeInfos.get<V>()})')
                case _ => return None<ConcurrentHashMap<K, V>>
            }
            case x =>
                let dataType = TypeInfo.of(x)
                if (dataType.qualifiedName.startsWith("f_data.ObjectData")) {
                    let map = ConcurrentHashMap<K, V>()
                    let raw = ((dataType as ClassTypeInfo).getOrThrow().getInstanceVariable("data").getValue(x) as Object).
                        getOrThrow()
                    let iterator = (dataType.getInstanceFunction("fields").apply(x) as Iterator<ReadableField>).
                        getOrThrow()
                    for (f in iterator) {
                        match ((convert<K>(f.name.toData(), flag: flag), convert<V>(f.get(raw), flag: flag))) {
                            case (Some(k: K), Some(v: V)) => map[k] = v
                            case (Some(_), _) where (flag & IGNORE_FIELD_NOT_CONVERTABLE) == 0 => throw DataException('${f.get(raw)} cannot be converted to ${TypeInfos.get<V>()}')
                            case (_, Some(_)) where (flag & IGNORE_FIELD_NOT_CONVERTABLE) == 0 => throw DataException('${f.name} cannot be converted to ${TypeInfos.get<K>()}')
                            case _ where (flag & IGNORE_FIELD_NOT_CONVERTABLE) == 0 => throw DataException('tuple (${f.name}, ${f.get(raw)}) cannot be converted to (${TypeInfos.get<K>()}, ${TypeInfos.get<V>()})')
                            case _ => continue
                        }
                    }
                    map
                } else if ((flag & IGNORE_FIELD_NOT_CONVERTABLE) == 0) {
                    throw DataException('${x} cannot be converted to ${TypeInfos.get<ConcurrentHashMap<K, V>>()}')
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
    public static func tryFromData(data: Data, flag!: DataConversionFlag = SILENCE): Any {
        match (data) {
            case x: DataSequence =>
                let map = LinkedHashMap<K, V>()
                for (v in x) {
                    match (v) {
                        case x: DataTuple => match ((convert<K>(x.key, flag: flag), convert<V>(x.value, flag: flag))) {
                            case (Some(k: K), Some(v: V)) => map.put(k, v)
                            case (Some(_), _) where (flag & IGNORE_FIELD_NOT_CONVERTABLE) == 0 => throw DataException('${x.value} cannot be converted to ${TypeInfos.get<V>()}')
                            case (_, Some(_)) where (flag & IGNORE_FIELD_NOT_CONVERTABLE) == 0 => throw DataException('${x.key} cannot be converted to ${TypeInfos.get<K>()}')
                            case _ where (flag & IGNORE_FIELD_NOT_CONVERTABLE) == 0 => throw DataException('tuple (${x.key}, ${x.value}) cannot be converted to (${TypeInfos.get<K>()}, ${TypeInfos.get<V>()})')
                            case _ => continue
                        }
                        case _ where (flag & IGNORE_FIELD_NOT_CONVERTABLE) == 0 => throw DataException('tuple ${x} cannot be converted to (${TypeInfos.get<K>()}, ${TypeInfos.get<V>()})')
                        case _ => continue
                    }
                }
                map
            case _ where (flag & IGNORE_FIELD_NOT_CONVERTABLE) == 0 => throw DataException('(${data}) cannot be converted to ${TypeInfos.get<LinkedHashMap<K, V>>()}')
            case x: DataTuple => match ((convert<K>(x.key, flag: flag), convert<V>(x.value, flag: flag))) {
                case (Some(k: K), Some(v: V)) =>
                    let map = LinkedHashMap<K, V>()
                    map.put(k, v)
                    map
                case (Some(_), _) where (flag & IGNORE_FIELD_NOT_CONVERTABLE) == 0 => throw DataException('${x.value} cannot be converted to ${TypeInfos.get<V>()}')
                case (_, Some(_)) where (flag & IGNORE_FIELD_NOT_CONVERTABLE) == 0 => throw DataException('${x.key} cannot be converted to ${TypeInfos.get<K>()}')
                case _ where (flag & IGNORE_FIELD_NOT_CONVERTABLE) == 0 => throw DataException('tuple (${x.key}, ${x.value}) cannot be converted to (${TypeInfos.get<K>()}, ${TypeInfos.get<V>()})')
                case _ => return None<LinkedHashMap<K, V>>
            }
            case x =>
                let dataType = TypeInfo.of(x)
                if (dataType.qualifiedName.startsWith("f_data.ObjectData")) {
                    let map = LinkedHashMap<K, V>()
                    let raw = ((dataType as ClassTypeInfo).getOrThrow().getInstanceVariable("data").getValue(x) as Object).
                        getOrThrow()
                    let iterator = (dataType.getInstanceFunction("fields").apply(x) as Iterator<ReadableField>).
                        getOrThrow()
                    for (f in iterator) {
                        match ((convert<K>(f.name.toData(), flag: flag), convert<V>(f.get(raw), flag: flag))) {
                            case (Some(k: K), Some(v: V)) => map[k] = v
                            case (Some(_), _) where (flag & IGNORE_FIELD_NOT_CONVERTABLE) == 0 => throw DataException('${f.get(raw)} cannot be converted to ${TypeInfos.get<V>()}')
                            case (_, Some(_)) where (flag & IGNORE_FIELD_NOT_CONVERTABLE) == 0 => throw DataException('${f.name} cannot be converted to ${TypeInfos.get<K>()}')
                            case _ where (flag & IGNORE_FIELD_NOT_CONVERTABLE) == 0 => throw DataException('tuple (${f.name}, ${f.get(raw)}) cannot be converted to (${TypeInfos.get<K>()}, ${TypeInfos.get<V>()})')
                            case _ => continue
                        }
                    }
                    map
                }  else if ((flag & IGNORE_FIELD_NOT_CONVERTABLE) == 0) {
                    throw DataException('${x} cannot be converted to ${TypeInfos.get<LinkedHashMap<K, V>>()}')
                } else {
                    None<LinkedHashMap<K, V>>
                }
        }
    }
}
