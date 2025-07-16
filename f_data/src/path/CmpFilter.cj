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

internal class CmpFilter<T> <: DataFilter where T <: Comparable<T> {
    CmpFilter(private let left: DataPath, private let right: T, private let ordering: Ordering, private let eq: Bool) {}
    init(left: String, right: String, orderingStr: String, eqStr: String, solid: String) {
        this(compilePath(left, solid), parse<T>(right),
            match (orderingStr) {
                case 'LT' => LT
                case 'GT' => GT
                case 'EQ' => EQ
                case _ => throw DataException('illegal Ordering string')
            }, Bool.parse(eqStr))
    }

    public func check(data: Data): Bool {
        let d = match (left.get(data).next()) {
            case Some(x) => x
            case _ => return false
        }
        match (d) {
            case x: DataDateTime => match (x.data) {
                case x: T =>
                    let cmp = x.compare(right)
                    cmp == ordering || (eq && cmp == EQ)
                case _ => false
            }
            case x: DataDuration => match (x.data) {
                case x: T =>
                    let cmp = x.compare(right)
                    cmp == ordering || (eq && cmp == EQ)
                case _ => false
            }
            case x: DataReal => match (x.data) {
                case x: T =>
                    let cmp = x.compare(right)
                    cmp == ordering || (eq && cmp == EQ)
                case _ => false
            }
            case x: DataString => match (x.data) {
                case x: T =>
                    let cmp = x.compare(right)
                    cmp == ordering || (eq && cmp == EQ)
                case _ => false
            }
            case _ => false
        }
    }
}
