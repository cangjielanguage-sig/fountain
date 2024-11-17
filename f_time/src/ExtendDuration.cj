/*
    Copyright (c) [2022] [WuJingrun（吴京润）]
    fountain is licensed under Mulan PSL v2.
    You can use this software according to the terms and conditions of the Mulan PSL v2.
    You may obtain a copy of Mulan PSL v2 at:
            http://license.coscl.org.cn/MulanPSL2
    THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
    See the Mulan PSL v2 for more details.
 */
package f_time

public interface ExtendDuration {
    prop ago: DateTime
    prop later: DateTime
    func before(current: DateTime): DateTime
    func after(current: DateTime): DateTime
}
extend Duration <: ExtendDuration {
    public prop ago: DateTime {
        get() {
            return DateTime.now() - this
        }
    }
    public prop later: DateTime {
        get() {
            return DateTime.now() + this
        }
    }
    public func before(current: DateTime): DateTime {
        return current - this
    }
    public func after(current: DateTime): DateTime {
        return current + this
    }
}
