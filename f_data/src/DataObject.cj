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

public interface DataObject<T> <: DataFields<T> where T <: Object & DataObject<T> {
    static func dataFields(): ObjectFields

    func toData(): Data

    static func tryFromData(data: Data, flag!: DataConversionFlag): DataOption<T>
}

class FieldIterator<T> <: Iterator<(String, Data)> where T <: Object & DataObject<T> {
    public FieldIterator(private let data: T, private let itr: Iterator<ReadableField>) {}

    public func next(): ?(String, Data) {
        for (f in itr) {
            return (f.name, f.get(data))
        }
        None
    }
}

public class ObjectData<T> <: Data & Iterable<(String, Data)> where T <: Object & DataObject<T> {
    public ObjectData(public let data: T) {
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
    public func set<V>(name: String, value: V, flag!: UInt64 = SILENCE): Unit where V <: DataFields<V>{
        set(name, value.toData(), flag: flag)
    }
    public func set(name: String, value: Data, flag!: UInt64 = SILENCE): Unit {
        T.dataFields().mutableField(name)?.set(data, value, flag: flag)
    }
    public func get<V>(name: String, flag!: UInt64 = SILENCE): ?V where V <: DataFields<V> {
        match(T.dataFields().readableField(name)?.get(data)){
            case Some(x) => V.tryFromData(x, flag: flag).value
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
            ObjectData<T>((data as T).getOrThrow())
        } else {
            None<Data>
        }
    }
    public static func parse(string: String): Data {
        tryParse(string).getOrThrow {DataException("current type ${TypeInfos.get<T>()} is not Parsable")}
    }
    public static func populate(src: Data, target: T, flag!: UInt64 = SILENCE): ?T {
        let srcDataType = TypeInfo.of(src)
        func isObjectData() {
            srcDataType.qualifiedName.startsWith("f_data.ObjectData")
        }
        func putValue(dstFields: ObjectFields, name: String, dst: T, data: Data, srcType: TypeInfo): Bool {
            match (dstFields.mutableField(name)) {
                case Some(mf) where mf.set(dst, data, flag: flag) => true
                case Some(_) where (flag & IGNORE_FIELD_NOT_CONVERTABLE) != 0 => true
                case Some(_) => throw DataException(
                    "source field ${name} which type is ${srcType} connoted be converted")
                case None where (flag & IGNORE_FIELD_NOT_FOUND) != 0 => true
                case None => throw DataException("field name ${name} is not found from ${TypeInfos.get<T>()}")
            }
            true
        }
        func putTuple(x: DataTuple, dstTuple!: ?(ObjectFields, T) = None) {
            let (key, value) = (x.key, x.value)
            match (key) {
                case x: DataString where #"^_*[a-zA-Z]+\w*$"#.regex(solid: true).matched(x.data) =>
                    let (dstFields, dst) = match (dstTuple) {
                        case Some(x) => x
                        case _ =>
                            let dstFields = T.dataFields()
                            (dstFields, target)
                    }
                    putValue(dstFields, x.data, dst, value, srcDataType)
                    dst
                case _ where (flag & IGNORE_FIELD_NOT_CONVERTABLE) > 0 => None<T>
                case _ => throw DataException("${key} cannot be field name of an object")
            }
        }
        match (src) {
            case x: Iterable<DataTuple> =>
                let dstFields = T.dataFields()
                for (e in x) {
                    match (e) {
                        case x: DataTuple => putTuple(x, dstTuple: (dstFields, target))
                        case _ where (flag & IGNORE_FIELD_NOT_CONVERTABLE) > 0 => continue
                        case _ => throw DataException(
                            "at least on element in current DataSequence cannot be converted to a DataTuple for populating current object which type is ${TypeInfos.get<T>()}"
                        )
                    }
                }
                target
            case x: DataTuple => putTuple(x)
            case _ where isObjectData() =>
                let dstFields = T.dataFields()
                let srcDataObjectType = (srcDataType as ClassTypeInfo).getOrThrow()
                let srcData = srcDataObjectType.getInstanceVariable("data").getValue(src)
                let srcType = TypeInfo.of(srcData)
                let srcFields = srcType.getStaticFunction("dataFields").apply([])
                let srcFieldsType = (TypeInfo
                    .of(srcFields)
                    .getInstanceFunction("iterator")
                    .apply(srcFields) as Iterator<ReadableField>)
                    .getOrThrow()
                for (sf in srcFieldsType) {
                    let srcData = sf.get((srcData as Object).getOrThrow())
                    putValue(dstFields, sf.name, target, srcData, srcType)
                }
                target
            case _ where (flag & IGNORE_FIELD_NOT_CONVERTABLE) > 0 => None<T>
            case _ => throw DataException("src cannot be converted to ${TypeInfos.get<T>()}")
        }
    }
    public static func populate(src: Data, flag!: UInt64 = SILENCE): ?T {
        populate(src, (T.dataFields().create() as T).getOrThrow(), flag: flag)
    }
    public static func populate<S>(src: S, flag!: UInt64 = SILENCE): ?T where S <: DataObject<S> {
        populate(ObjectData<S>(src), flag: flag)
    }
    public static func populate<S>(src: S, target: T, flag!: UInt64 = SILENCE): ?T where S <: DataObject<S> {
        populate(ObjectData<S>(src), target, flag: flag)
    }
    public static func populate<M, V>(src: M, flag!: UInt64 = SILENCE): ?T where M <: Map<String, V> & DataFields<M>,
        V <: DataFields<V> {
        populate(src.toData(), flag: flag)
    }
    public static func populate<M, V>(src: M, target: T, flag!: UInt64 = SILENCE): ?T where M <: Map<String, V> & DataFields<M>,
        V <: DataFields<V> {
        populate(src.toData(), target, flag: flag)
    }
    public static func populate<M, V>(src: T, map: M, flag!: UInt64 = SILENCE): M where M <: Map<String, V>,
        V <: DataFields<V> {
        for ((k, v) in ObjectData<T>(src)) {
            if (let Some(x) <- V.tryFromData(v, flag: flag).value) {
                map[k] = x
            } else if ((flag & IGNORE_FIELD_NOT_CONVERTABLE) == 0) {
                throw DataException('field ${k} of ${TypeInfos.get<T>()} cannot be converted to ${TypeInfos.get<V>()}')
            }
        }
        map
    }
}
