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
package f_orm.sql

/**
 * 分页对象
 *
 * @param <T> 泛型，数据映射类型
 * @param page 当前页码
 * @param size 每页大小
 * @param pages 总页数
 * @param rows 总记录数
 * @param list 数据列表
 */
public class Pagination<T> <: ObjectData<Pagination<T>> where T <: DataFields<T> {
    public let pages: Int64
    public Pagination(
        public let page!: Int64,
        public let size!: Int64,
        public let rows!: Int64,
        public let list!: ArrayList<T>
    ) {
        this.pages = rows / size + if (rows % size == 0) {
            0
        } else {
            1
        }
    }
    public func toData(): Data {
        DataObject<Pagination<T>>(this)
    }
    public static func tryFromData(data: Data, flag: DataConversionFlag): Any {
        f_data_tryFromData<Pagination<T>>(data, flag)
    }
    public static func dataFields(): ObjectFields<Pagination<T>> {
        ObjectFields<Pagination<T>>([
            ReadonlyField.new<Pagination<T>, Int64>('page'){o => o.page},
            ReadonlyField.new<Pagination<T>, Int64>('size'){o => o.size},
            ReadonlyField.new<Pagination<T>, Int64>('rows'){o => o.rows},
            ReadonlyField.new<Pagination<T>, Int64>('pages'){o => o.pages},
            ReadonlyField.new<Pagination<T>, ArrayList<T>>('list'){o => o.list}
        ]){
            throw IllegalAccessException()
        }
    }
}
