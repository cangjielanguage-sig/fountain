/*
    Copyright (c) 2022 WuJingrun（吴京润）
    fountain is licensed under Mulan PSL v2.
    You can use this software according to the terms and conditions of the Mulan PSL v2.
    You may obtain a copy of Mulan PSL v2 at:
            http://license.coscl.org.cn/MulanPSL2
    THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
    See the Mulan PSL v2 for more details.
 */
package f_bean

/**
 * 定义bean的作用范围。prototype和singleton，可以在其它模块定义新的作用范围。
 * 受自定义作用范围影响的bean生命周期由范围定义模块维持
 */
public abstract class BeanScope <: Equatable<BeanScope> {
    public static const prototype = PrototypeBeanScope()
    public static const singleton = SingletonBeanScope()
    public const init() {}
    /**
     * 返回当前类型的TypeInfo
     */
    public prop typeInfo: TypeInfo
    public operator func ==(other: BeanScope) {
        refEq(this, other) || this.typeInfo == other.typeInfo
    }
    public prop isPrototype: Bool {
        get() {
            this == prototype
        }
    }
    public prop isSingleton: Bool {
        get() {
            this == singleton
        }
    }
}

public class PrototypeBeanScope <: BeanScope {
    internal const init() {}
    public prop typeInfo: TypeInfo {
        get() {
            TypeInfos.get<PrototypeBeanScope>()
        }
    }
}

public class SingletonBeanScope <: BeanScope {
    internal const init() {}
    public prop typeInfo: TypeInfo {
        get() {
            TypeInfos.get<PrototypeBeanScope>()
        }
    }
}
