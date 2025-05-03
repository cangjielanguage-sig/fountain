/*
    Copyright (c) [2022] [WuJingrun（吴京润）]
    fountain is licensed under Mulan PSL v2.
    You can use this software according to the terms and conditions of the Mulan PSL v2.
    You may obtain a copy of Mulan PSL v2 at:
            http://license.coscl.org.cn/MulanPSL2
    THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
    See the Mulan PSL v2 for more details.
 */
package f_orm

public class ConversionQueryMaper<D, T, O> <: QueryMapper<O> {
    public init(
        dataType!: DataType,
        converter!: (D) -> T,
        putter!: (O, T) -> Unit
    ) {
        super(dataType: dataType, putter: {o, v => putter(o, converter(convert<D>(v)))})
    }
    public init(
        name!: String,
        converter!: (D) -> T,
        putter!: (O, T) -> Unit
    ){
        this(dataType: UnknownDataType(true, name), converter: converter, putter: putter)
    }
}
