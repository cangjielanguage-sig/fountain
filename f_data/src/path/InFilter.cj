/*
    Copyright (c) 2022 WuJingrun（吴京润）
    fountain is licensed under Mulan PSL v2.
    You can use this software according to the terms and conditions of the Mulan PSL v2.
    You may obtain a copy of Mulan PSL v2 at:
            http://license.coscl.org.cn/MulanPSL2
    THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
    See the Mulan PSL v2 for more details.
 */
package f_data.path

internal class InFilter<T> <: DataFilter where T <: Hashable & Equatable<T> {
    InFilter(private let left: DataPath, private let right: HashSet<T>) {}
    init(left: String, right: String, solid: String) {
        this(compilePath(left, solid), parseHashSet<T>(right))
    }
    public func check(data: Data): Bool {
        let d = match (left.get(data).next()) {
            case Some(x) => x
            case _ => return false
        }
        match (d) {
            case x: DataDateTime => match (x.data) {
                case x: T => right.contains(x)
                case _ => false
            }
            case x: DataDuration => match (x.data) {
                case x: T => right.contains(x)
                case _ => false
            }
            case x: DataReal => match (x.data) {
                case x: T => right.contains(x)
                case _ => false
            }
            case x: DataString => match (x.data) {
                case x: T => right.contains(x)
                case _ => false
            }
            case x: DataBool => match (x.data) {
                case x: T => right.contains(x)
                case _ => false
            }
            case _ => false
        }
    }
}
