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

public interface DataFields<T> where T <: DataFields<T> {
    static prop isSimple: Bool {
        get(){
            true
        }
    }
    func toData(): Data
    static func fromData(data: Data, flag: DataConversionFlag): T {
        match(T.tryFromData(data, flag)){
            case x: ?T => match(x){
                case Some(x) => x
                case _ => throw DataException('data ${data} cannot be converted to ${TypeInfos.get<T>()}')
            }
            case x: T => x
            case _ => throw DataException('data ${data} cannot be converted to ${TypeInfos.get<T>()}')
        }
    }
    static func fromData(data: Data){
        fromData(data, DEFAULT_DATA_FLAG)
    }
    static func tryFromData(data: Data, flag: DataConversionFlag): Any
    static func tryFromData(data: Data){
        tryFromData(data, DEFAULT_DATA_FLAG)
    }
}
public func convert<T>(data: Data, flag!: DataConversionFlag = DEFAULT_DATA_FLAG): ?T where T <: DataFields<T> {
    match(T.tryFromData(data, flag)){
        case x: ?T => x
        case x: T => x
        case _ where (flag & IGNORE_FIELD_NOT_CONVERTABLE) == 0 => 
            throw DataException('data ${data} cannot be converted to ${TypeInfos.get<T>()}')
        case _ => None<T>
    }
}
public func f_data_tryFromData<O>(data: Data, flag: DataConversionFlag): Any where O <: ObjectData<O> {
    match(DataObject<O>.populate(data, flag: flag)){
        case Some(o: O) => o
        case _ where (flag & IGNORE_FIELD_NOT_CONVERTABLE) == 0 => throw DataException('${data} cannot be converted to ${TypeInfos.get<O>()}')
        case _ => None<O>
    }
}
internal func internal_f_data_tryFromData<T>(data: Data, flag: DataConversionFlag): ?T where T <: DataFields<T> {
    match(T.tryFromData(data, flag)){
        case x: T => x
        case x: ?T => match(x){
            case Some(x) => x
            case _ where (flag & IGNORE_FIELD_NOT_CONVERTABLE) != 0 => None<T>
            case _ => throw DataException("cannot convert data to ${TypeInfos.get<T>()}")
        }
        case _ where (flag & IGNORE_FIELD_NOT_CONVERTABLE) != 0 => None<T>
        case _ => throw DataException("cannot convert data to ${TypeInfos.get<T>()}")
    }
}