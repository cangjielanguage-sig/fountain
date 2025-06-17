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
 * bean初始化条件，满足条件的bean才初始化，否则将被从BeanFactory删除
 */
public interface BeanCondition {
    func on(factory: BeanFactory): Bool
    public const operator func &(right: BeanCondition): BeanCondition{
        AndCond(this, right)
    }
    public const operator func |(right: BeanCondition): BeanCondition{
        OrCond(this, right)
    }
    public const operator func !() : BeanCondition{
        NotCond(this)
    }
}
/**
 * 默认的bean初始化条件，初始化BeanMeta时的占位。永远返回true。
 */
public class NoneBeanCondition <: BeanCondition {
    public static const instance = NoneBeanCondition()
    private const init() {}
    public func on(factory: BeanFactory): Bool {
        true
    }
}
