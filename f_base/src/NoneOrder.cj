/*
    Copyright (c) 2022 WuJingrun（吴京润）
    fountain is licensed under Mulan PSL v2.
    You can use this software according to the terms and conditions of the Mulan PSL v2.
    You may obtain a copy of Mulan PSL v2 at:
            http://license.coscl.org.cn/MulanPSL2
    THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
    See the Mulan PSL v2 for more details.
 */
package f_base

public enum NoneOrder <: Comparable<NoneOrder> {
    Greatest | Least

    public func compare(other: NoneOrder) {
        match ((this, other)) {
            case (Greatest, Greatest) | (Least, Least) => EQ
            case (Greatest, Least) => GT
            case (Least, Greatest) => LT
        }
    }
    public prop isGreatest: Bool {
        get() {
            this == Greatest
        }
    }
    public prop isLeast: Bool {
        get() {
            this == Least
        }
    }
}
