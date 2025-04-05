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

/**
 * 两个bean初始化条件都是true时本条件才是true。
 */
public class AndCond <: BeanCondition {
    public const AndCond(public let left: BeanCondition, public let right: BeanCondition) {}
    public func on(factory: BeanFactory): Bool {
        left.on(factory) && right.on(factory)
    }
}
/**
 * 两个bean初始化条件有一个是true本条件就是true，首先执行left。
 */
public class OrCond <: BeanCondition {
    public const OrCond(public let left: BeanCondition, public let right: BeanCondition) {}
    public func on(factory: BeanFactory): Bool {
        left.on(factory) || right.on(factory)
    }
}
/**
 * 将指定初始化条件取反
 */
public class NotCond <: BeanCondition {
    public const NotCond(public let op: BeanCondition) {}
    public func on(factory: BeanFactory): Bool {
        !op.on(factory)
    }
}
