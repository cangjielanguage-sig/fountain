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

public interface ObjectData<T> <: DataFields<T> where T <: Object & ObjectData<T> {
    static func dataFields(): ObjectFields<T>

    func toData(): Data

    static func tryFromData(data: Data, flag!: DataConversionFlag): Any
}

class FieldIterator<T> <: Iterator<(String, Data)> where T <: Object & ObjectData<T> {
    public FieldIterator(private let data: T, private let itr: Iterator<ReadableField>) {}

    public func next(): ?(String, Data) {
        for (f in itr) {
            return (f.name, f.get(data))
        }
        None
    }
}

public class DataObject<T> <: Data & Iterable<(String, Data)> where T <: Object & ObjectData<T> {
    public DataObject(public let data: T) {
    }
    public func iterator(): Iterator<(String, Data)> {
        let fields = fields()
        FieldIterator<T>(data, fields)
    }
    public func fields(): Iterator<ReadableField> {
        T.dataFields().iterator()
    }
    public operator func [](name: String): Data {
        (T.dataFields().readableField(name)?.get(data)).getOrThrow{DataException('field ${name} is not found in ${TypeInfos.get<T>()}')}
    }
    public operator func [](name: String, value!: Data): Unit {
        set(name, value)
    }
    public func set<V>(name: String, value: V, flag!: DataConversionFlag = SILENCE): Unit where V <: DataFields<V>{
        set(name, value.toData(), flag: flag)
    }
    public func set(name: String, value: Data, flag!: DataConversionFlag = SILENCE): Unit {
        match(T.dataFields().mutableField(name)){
            case Some(f) where f.set(data, value, flag: flag) => ()
            case Some(_) where (flag & IGNORE_FIELD_NOT_CONVERTABLE) != 0 => ()  
            case Some(_) => throw DataException("source field ${name} in ${TypeInfos.get<T>()} connot be converted")
            case _ where (flag & IGNORE_FIELD_NOT_FOUND) == 0 => ()
            case _ => throw DataException("field name ${name} is not found from ${TypeInfos.get<T>()}")
        }
    }
    public func get<V>(name: String, flag!: DataConversionFlag = SILENCE): ?V where V <: DataFields<V> {
        match(T.dataFields().readableField(name)?.get(data)){
            case Some(x) => match(V.tryFromData(x, flag: flag)){
                case x: ?V => x
                case x: V => x
                case _ where (flag & IGNORE_FIELD_NOT_FOUND) == 0 => None
                case _ => throw DataException('field ${name} is not found in ${TypeInfos.get<T>()}')
            }
            case _ where (flag & IGNORE_FIELD_NOT_FOUND) == 0 => None
            case _ => throw DataException('field ${name} is not found in ${TypeInfos.get<T>()}')
        }
    }
    public func toString(): String {
        match (data) {
            case x: ToString => x.toString()
            case x =>
                let s = StringBuilder()
                s.append("{")
                var i = 0
                for ((k, v) in this) {
                    if (i > 0) {
                        s.append(",")
                    }
                    s.append(k)
                    s.append(":")
                    s.append(v.toString())
                }
                s.append("}")
                s.toString()
        }
    }
    public static func tryParse(string: String): ?Data {
        let typeInfo = TypeInfos.get<T>()
        if (typeInfo.isSubtypeOf(TypeInfos.get<Parsable<T>>())) {
            let data = typeInfo.getStaticFunction("parse", TypeInfos.get<String>()).apply([string])
            DataObject<T>((data as T).getOrThrow())
        } else {
            None<Data>
        }
    }
    public static func parse(string: String): Data {
        tryParse(string).getOrThrow {DataException("current type ${TypeInfos.get<T>()} is not Parsable")}
    }
    public static func populate(src: Data, target: T, flag!: DataConversionFlag = SILENCE): ?T {
        let targetData = DataObject<T>(target)
        let srcDataType = TypeInfo.of(src)
        func isDataObject() {
            srcDataType.qualifiedName.startsWith("f_data.DataObject")
        }
        func putTuple(x: DataTuple) {
            let (key, value) = (x.key, x.value)
            match (key) {
                case x: DataString where Regex.IDENTIFIER.matched(x.data) =>
                    targetData.set(x.data, value, flag: flag)
                    target
                case _ where (flag & IGNORE_FIELD_NOT_CONVERTABLE) > 0 => None<T>
                case _ => throw DataException("${key} cannot be field name of an object")
            }
        }
        match (src) {
            case x: Iterable<DataTuple> =>
                for (e in x) {
                    putTuple(e)
                }
                target
            case x: DataTuple => putTuple(x)
            case _ where isDataObject() =>
                let srcDataItr = ((TypeMemberInfos.instanceFunction(srcDataType, 'iterator')?.apply(src)).getOrThrow() as Iterator<(String, Data)>).getOrThrow()
                for((n, d) in srcDataItr){
                    targetData.set(n, d, flag: flag)
                }
                target
            case _ where (flag & IGNORE_FIELD_NOT_CONVERTABLE) > 0 => None<T>
            case _ => throw DataException("src cannot be converted to ${TypeInfos.get<T>()}")
        }
    }
    public static func populate(src: Data, flag!: DataConversionFlag = SILENCE): ?T {
        populate(src, T.dataFields().create(), flag: flag)
    }
    public static func populate<S>(src: S, flag!: DataConversionFlag = SILENCE): ?T where S <: Object & ObjectData<S> {
        populate(DataObject<S>(src), flag: flag)
    }
    public static func populate<S>(src: S, target: T, flag!: DataConversionFlag = SILENCE): ?T where S <: Object & ObjectData<S> {
        populate(DataObject<S>(src), target, flag: flag)
    }
    public static func populate<M, V>(src: M, flag!: DataConversionFlag = SILENCE): ?T where M <: Map<String, V> & DataFields<M>,
        V <: DataFields<V> {
        populate(src.toData(), flag: flag)
    }
    public static func populate<M, V>(src: M, target: T, flag!: DataConversionFlag = SILENCE): ?T where M <: Map<String, V> & DataFields<M>,
        V <: DataFields<V> {
        populate(src.toData(), target, flag: flag)
    }
    public static func populate<M, V>(src: T, map: M, flag!: DataConversionFlag = SILENCE): M where M <: Map<String, V>,
        V <: DataFields<V> {
        for ((k, v) in DataObject<T>(src)) {
            match(V.tryFromData(v, flag: flag)){
                case x: ?V => match(x){
                    case Some(x) => map[k] = x
                    case _ where (flag & IGNORE_FIELD_NOT_CONVERTABLE) == 0 => 
                        throw DataException('field ${k} of ${TypeInfos.get<T>()} cannot be converted to ${TypeInfos.get<V>()}')
                    case _ => continue
                }
                case x: V => map[k] = x
                case _ where (flag & IGNORE_FIELD_NOT_CONVERTABLE) == 0 => 
                    throw DataException('field ${k} of ${TypeInfos.get<T>()} cannot be converted to ${TypeInfos.get<V>()}')
                case _ => continue
            }
        }
        map
    }
}
