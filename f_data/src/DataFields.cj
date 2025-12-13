/*
Copyright (c) 2025 WuJingrun（吴京润）

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
 */
package f_data

public interface ToData {
    func toData(): Data
}
public interface FromData {
    static func fromData(data: Data, flag: DataConversionFlag): Any 
    static func fromData(data: Data){
        fromData(data, DEFAULT_DATA_FLAG)
    }
    static func tryFromData(data: Data, flag: DataConversionFlag): Any
    static func tryFromData(data: Data){
        tryFromData(data, DEFAULT_DATA_FLAG)
    }
}
public interface FromToData <: FromData & ToData {}
public interface DataFields<T> <: FromToData where T <: DataFields<T> {
    static prop isSimple: Bool {
        get() {
            true
        }
    }
    static func fromData(data: Data, flag: DataConversionFlag): Any {
        match (T.tryFromData(data, flag)) {
            case x: ?T => match (x) {
                case Some(x) => x
                case _ => throw DataException('data ${data} cannot be converted to ${TypeInfos.get<T>()}')
            }
            case x: T => x
            case _ => throw DataException('data ${data} cannot be converted to ${TypeInfos.get<T>()}')
        }
    }
}

public func convert<T>(data: Data, flag!: DataConversionFlag = DEFAULT_DATA_FLAG): ?T where T <: DataFields<T> {
    match (T.tryFromData(data, flag)) {
        case x: ?T => x
        case x: T => x
        case _ where (flag & IGNORE_FIELD_NOT_CONVERTABLE) == 0 => throw DataException(
            'data ${data} cannot be converted to ${TypeInfos.get<T>()}')
        case _ => None<T>
    }
}
public func convertToMap<M>(data: Data, flag!: DataConversionFlag = DEFAULT_DATA_FLAG): ?M where M <: Map<String, Any> {
    match(data){
        case x: DataTuples => 
            let mapType = TypeInfo.of<M>()
            let map = if (mapType == ClassTypeInfo.of<HashMap<String, Any>>() || mapType == TypeInfo.of<Map<String, Any>>()) {
                HashMap<String, Any>() as M
            } else if (mapType == ClassTypeInfo.of<TreeMap<String, Any>>()){
                TreeMap<String, Any>() as M
            } else if (mapType == ClassTypeInfo.of<LinkedHashMap<String, Any>>()) {
                LinkedHashMap<String, Any>() as M
            } else if ((flag & IGNORE_FIELD_NOT_CONVERTABLE) == 0)  {
                None<M>
            } else {
                throw DataException('data ${data} cannot be converted to ${TypeInfo.of<M>()}')
            }
            if(let Some(m) <- map){
                for((k, v) in x) {
                    m[k.toString()] = match(v) {
                        case x: DataReal => x.data
                        case x: DataString => x.data
                        case x: DataBool => x.data
                        case x: DataDuration => x.data
                        case x: DataDateTime => x.data
                        case x: DataTuples => convertToMap<HashMap<String, Any>>(x, flag: flag)
                        case x: Iterable<(Data, Data)> => convertToMap<HashMap<String, Any>>(DataTuples(x.iterator()), flag: flag)
                        case x: Collection<(String, Data)> => 
                            convertToMap<HashMap<String, Any>>(DataTuples(x.iterator().map{tpl => (tpl[0].toData(), tpl[1])}), flag: flag)
                        case _ where (flag & IGNORE_FIELD_NOT_CONVERTABLE) == 0 => 
                            throw DataException('data ${v} with key ${k} cannot be converted to (String, Any)')
                        case _ => continue
                    }
                }
            }
            map
        case _ where (flag & IGNORE_FIELD_NOT_CONVERTABLE) == 0 => throw DataException('data ${data} cannot be converted to ${TypeInfos.get<M>()}')
        case _ => None<M>
    }
}

public func f_data_tryFromData<O>(data: Data, flag: DataConversionFlag): Any where O <: ObjectData<O> {
    match (DataObject<O>.populate(data, flag: flag)) {
        case Some(o: O) => o
        case _ where (flag & IGNORE_FIELD_NOT_CONVERTABLE) == 0 => throw DataException(
            '${data} cannot be converted to ${TypeInfos.get<O>()}')
        case _ => None<O>
    }
}

internal func internal_f_data_tryFromData<T>(data: Data, flag: DataConversionFlag): ?T where T <: DataFields<T> {
    match (T.tryFromData(data, flag)) {
        case x: T => x
        case x: ?T => match (x) {
            case Some(x) => x
            case _ where (flag & IGNORE_FIELD_NOT_CONVERTABLE) != 0 => None<T>
            case _ => throw DataException("cannot convert data to ${TypeInfos.get<T>()}")
        }
        case _ where (flag & IGNORE_FIELD_NOT_CONVERTABLE) != 0 => None<T>
        case _ => throw DataException("cannot convert data to ${TypeInfos.get<T>()}")
    }
}
