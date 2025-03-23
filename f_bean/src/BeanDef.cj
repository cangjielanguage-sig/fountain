/*
    Copyright (c) [2022] [WuJingrun（吴京润）]
    fountain is licensed under Mulan PSL v2.
    You can use this software according to the terms and conditions of the Mulan PSL v2.
    You may obtain a copy of Mulan PSL v2 at:
            http://license.coscl.org.cn/MulanPSL2
    THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
    See the Mulan PSL v2 for more details.
 */
package f_bean

@Annotation[target: [Type, MemberFunction]]
public class Order {
    public const Order(public let value: Int64) {}
}

@Annotation[target: [Type, MemberFunction]]
public class Primary {
    public const init() {}
}

@Annotation[target: [Type, MemberFunction]]
public class Scope {
    public const Scope(public let value: BeanScope) {}
}

@Annotation[target: [Type, MemberFunction]]
public class Lazy {
    public const Lazy(public let value: Bool) {}
    public const init() {
        this(true)
    }
}
