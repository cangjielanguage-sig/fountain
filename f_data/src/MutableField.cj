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

public class MutableField <: ReadableField {
    public MutableField(
        name: String, typeInfo: TypeInfo,
        getter: (Object)->Data,
        private let setter: (Object, Data, UInt64) -> Bool
    ){
        super(name, typeInfo, getter)
    }

    public func set(instance: Object, data: Data, flag!: DataConversionFlag = SILENCE): Bool {
        let t = TypeInfo.of(instance)
        if(t == typeInfo || t.isSubtypeOf(typeInfo)){
            setter(instance, data, flag)
        }else{
            throw DataException('${t} is not subtype of ${typeInfo}')
        }
    }
}
