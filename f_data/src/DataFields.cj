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
    func toData(): Data
    static func fromData(data: Data, flag!: DataConversionFlag): T {
        match(T.tryFromData(data, flag: flag)){
            case x: ?T => match(x){
                case Some(x) => x
                case _ => throw DataException('data ${data} cannot be converted to ${TypeInfos.get<T>()}')
            }
            case x: T => x
            case _ => throw DataException('data ${data} cannot be converted to ${TypeInfos.get<T>()}')
        }
    }
    static func tryFromData(data: Data, flag!: DataConversionFlag): Any
}
public func convert<T>(data: Data, flag!: DataConversionFlag = SILENCE): ?T where T <: DataFields<T> {
    match(T.tryFromData(data, flag: flag)){
        case x: ?T => x
        case x: T => x
        case _ where (flag & IGNORE_FIELD_NOT_CONVERTABLE) == 0 => 
            throw DataException('data ${data} cannot be converted to ${TypeInfos.get<T>()}')
        case _ => None<T>
    }
}