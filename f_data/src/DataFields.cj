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
        T.tryFromData(data, flag: flag).value.getOrThrow{DataException('data ${data} cannot be converted to ${TypeInfos.get<T>()}')}
    }
    static func tryFromData(data: Data, flag!: DataConversionFlag): DataOption<T>
}
