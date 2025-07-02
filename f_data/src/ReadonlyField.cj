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

public class ReadonlyField <: ReadableField {
    public init(name: String, typeInfo: TypeInfo, getter: (Any) -> Data) {
        super(name, typeInfo, getter)
    }
    public static func new<O, F>(name: String, getter: (O) -> F): ReadonlyField where O <: ObjectData<O>,
        F <: DataFields<F> {
        ReadonlyField(name, TypeInfos.get<F>(), newGetter<O, F>(getter))
    }
}
