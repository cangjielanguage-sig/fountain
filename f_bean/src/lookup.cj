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
package fountain::f_bean

public func lookup<T>(): T {
    lookup<T>(StringCond.IgnoreCond)
}

public func lookup<T>(name: String): T {
    lookup<T>(Exactly(name))
}

public func lookup<T>(cond: StringCond): T {
    lookupOption<T>(cond).getOrThrow {
        BeanException('bean type ${TypeInfo.of<T>()} with bean name condition ${cond} does not exist.')
    }
}

public func lookupOption<T>(): ?T {
    lookupOption<T>(StringCond.IgnoreCond)
}

public func lookupOption<T>(name: String): ?T {
    lookupOption<T>(Exactly(name))
}

public func lookupOption<T>(cond: StringCond): ?T {
    BeanFactory.instance.getFirst<T>(cond: cond)
}

public func lookupList<T>(): ArrayList<T> {
    lookupList<T>(IgnoreCond)
}

public func lookupList<T>(cond: StringCond): ArrayList<T> {
    BeanFactory.instance.getList<T>(cond: cond)
}

public func lookupHashSet<T>(): HashSet<T> where T <: Hashable & Equatable<T> {
    lookupHashSet<T>(IgnoreCond)
}

public func lookupHashSet<T>(cond: StringCond): HashSet<T> where T <: Hashable & Equatable<T> {
    // §3.1 / BEAN-L5：直接向目标集合填充（遍历与过滤同 `getList`：同一个 `iterator<T>(cond:)` + 同一个类型判定），
    // 不再先把该类型的全部 bean 物化成中间 `ArrayList` 再重建一次。
    let set = HashSet<T>()
    for (m in BeanFactory.instance.iterator<T>(cond: cond)) {
        if (let bean: T <- m.bean) {
            set.add(bean)
        }
    }
    set
}

public func lookupTreeSet<T>(): TreeSet<T> where T <: Comparable<T> {
    lookupTreeSet<T>(IgnoreCond)
}

public func lookupTreeSet<T>(cond: StringCond): TreeSet<T> where T <: Comparable<T> {
    // §3.1 / BEAN-L5：同 `lookupHashSet`，直接建树、不再经过中间 `ArrayList`
    let tree = TreeSet<T>()
    for (m in BeanFactory.instance.iterator<T>(cond: cond)) {
        if (let bean: T <- m.bean) {
            tree.add(bean)
        }
    }
    tree
}

public func lookupHashMap<T>(): HashMap<String, T> {
    lookupHashMap<T>(IgnoreCond)
}

public func lookupHashMap<T>(cond: StringCond): HashMap<String, T> {
    BeanFactory.instance.getMap<T>(cond: cond)
}

public func lookupLabels<L, T>(): HashMap<L, T> where L <: Hashable & Equatable<L>, T <: BeanLabel<L> {
    lookupLabels<L, T>(IgnoreCond)
}

public func lookupLabels<L, T>(cond: StringCond): HashMap<L, T> where L <: Hashable & Equatable<L>, T <: BeanLabel<L> {
    let map = HashMap<L, T>()
    for (bean in lookupList<T>(cond)) {
        map[bean.label] = bean
    }
    map
}
public func lookupLabel<L, T>(label: L): T where L <: Hashable & Equatable<L>, T <: BeanLabel<L> {
    lookupLabel<L, T>(StringCond.IgnoreCond, label)
}
public func lookupLabel<L, T>(name: String, label: L): T where L <: Hashable & Equatable<L>, T <: BeanLabel<L> {
    lookupLabel<L, T>(Exactly(name), label)
}
public func lookupLabel<L, T>(cond: StringCond, label: L): T where L <: Hashable & Equatable<L>, T <: BeanLabel<L> {
    lookupLabelOption<L, T>(cond, label).getOrThrow {
        BeanException('bean type ${TypeInfo.of<T>()} with bean name condition ${cond} does not exist.')
    }
}
public func lookupLabelOption<L, T>(label: L): ?T where L <: Hashable & Equatable<L>, T <: BeanLabel<L> {
    lookupLabelOption<L, T>(StringCond.IgnoreCond, label)
}
public func lookupOptionLable<L, T>(name: String, label: L): ?T where L <: Hashable & Equatable<L>, T <: BeanLabel<L> {
    lookupLabelOption<L, T>(Exactly(name), label)
}
public func lookupLabelOption<L, T>(cond: StringCond, label: L): ?T where L <: Hashable & Equatable<L>, T <: BeanLabel<L> {
    for(bean in lookupList<T>(cond) where bean.label == label){
        return bean
    }
    None<T>
}

public func lookupWeights<W, T>(): TreeMap<W, T> where W <: Comparable<W> & Addable<W>, T <: BeanWeight<W> {
    lookupWeights<W, T>(IgnoreCond)
}

public func lookupWeights<W, T>(cond: StringCond): TreeMap<W, T> where W <: Comparable<W> & Addable<W>,
    T <: BeanWeight<W> {
    let map = TreeMap<W, T>()
    var weight = None<W>
    for (bean in lookupList<T>(cond)) {
        let w = if (let Some(w) <- weight) {
            w + bean.weight
        } else {
            bean.weight
        }
        weight = w
        map[w] = bean
    }
    map
}

/**
 * §3.1 / `BEAN-L6`：按注解取 bean（补上 README 声明过、此前缺失的查询入口）。
 * `A` 是注解类型（`@Annotation` 标记的类）；匹配范围含**父类/接口/元注解**链上的注解（见 `doRegister`）。
 */
public func lookupByAnnotation<T, A>(): T where T <: Object, A <: Annotation {
    lookupByAnnotation<T, A>(StringCond.IgnoreCond)
}

/**
 * 取「类型被注解 `A` 修饰且类型是 `T` 的子类型、名字满足 `cond`」的第一个 bean，没有则抛 `BeanException`。
 */
public func lookupByAnnotation<T, A>(cond: StringCond): T where T <: Object, A <: Annotation {
    BeanFactory.instance.getFirstByAnnotation<T, A>(cond: cond).getOrThrow {
        BeanException(
            'bean type ${TypeInfo.of<T>()} annotated with ${TypeInfo.of<A>()} with bean name condition ${cond} does not exist.')
    }
}

/**
 * 取全部「类型被注解 `A` 修饰且类型是 `T` 的子类型、名字满足 `cond`」的 bean（顺序同注解桶）。
 */
public func lookupListByAnnotation<T, A>(): ArrayList<T> where T <: Object, A <: Annotation {
    lookupListByAnnotation<T, A>(IgnoreCond)
}

/**
 * 同 `lookupListByAnnotation`，带名字条件。
 */
public func lookupListByAnnotation<T, A>(cond: StringCond): ArrayList<T> where T <: Object, A <: Annotation {
    BeanFactory.instance.getListByAnnotation<T, A>(cond: cond)
}

/**
 * 取全部「类型被注解 `A` 修饰且类型是 `T` 的子类型、名字满足 `cond`」的 bean，返回的 `HashMap`
 * 以 bean 名（`BeanManager.name`）为 KEY。
 */
public func lookupMapByAnnotation<T, A>(): HashMap<String, T> where T <: Object, A <: Annotation {
    lookupMapByAnnotation<T, A>(IgnoreCond)
}

/**
 * 同 `lookupMapByAnnotation`，带名字条件。
 */
public func lookupMapByAnnotation<T, A>(cond: StringCond): HashMap<String, T> where T <: Object, A <: Annotation {
    BeanFactory.instance.getMapByAnnotation<T, A>(cond: cond)
}
