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

public func lookup<T>(): T where T <: Object {
    lookup<T>(IgnoreCond)
}

public func lookup<T>(name: String): T where T <: Object {
    lookup<T>(Exactly(name))
}

public func lookup<T>(cond: StringCond): T where T <: Object {
    BeanFactory
        .instance
        .getFirst<T>(cond: cond)
        .getOrThrow {BeanException('bean type ${TypeInfos.get<T>()} with bean name condition ${cond} does not exist.')}
}

public func lookupList<T>(): ArrayList<T> where T <: Object {
    lookupList<T>(IgnoreCond)
}

public func lookupList<T>(cond: StringCond): ArrayList<T> where T <: Object {
    BeanFactory.instance.getList<T>(cond: cond)
}

public func lookupHashSet<T>(): HashSet<T> where T <: Object & Hashable & Equatable<T> {
    lookupHashSet<T>(IgnoreCond)
}

public func lookupHashSet<T>(cond: StringCond): HashSet<T> where T <: Object & Hashable & Equatable<T> {
    HashSet<T>(lookupList<T>(cond))
}

public func lookupTreeSet<T>(): TreeSet<T> where T <: Object & Comparable<T> {
    lookupTreeSet<T>(IgnoreCond)
}

public func lookupTreeSet<T>(cond: StringCond): TreeSet<T> where T <: Object & Comparable<T> {
    TreeSet<T>(lookupList<T>(cond))
}

public func lookupHashMap<T>(): HashMap<String, T> where T <: Object {
    lookupHashMap<T>(IgnoreCond)
}

public func lookupHashMap<T>(cond: StringCond): HashMap<String, T> where T <: Object {
    BeanFactory.instance.getMap<T>(cond: cond)
}

public func lookupLabels<L, T>(): HashMap<L, T> where L <: Hashable & Equatable<L>, T <: Object & BeanLabel<L> {
    lookupLabels<L, T>(IgnoreCond)
}

public func lookupLabels<L, T>(cond: StringCond): HashMap<L, T> where L <: Hashable & Equatable<L>,
    T <: Object & BeanLabel<L> {
    let map = HashMap<L, T>()
    for (bean in lookupList<T>(cond)) {
        map[bean.label] = bean
    }
    map
}

public func lookupWeights<W, T>(): TreeMap<W, T> where W <: Comparable<W> & Addable<W>, T <: Object & BeanWeight<W> {
    lookupWeights<W, T>(IgnoreCond)
}

public func lookupWeights<W, T>(cond: StringCond): TreeMap<W, T> where W <: Comparable<W> & Addable<W>,
    T <: Object & BeanWeight<W> {
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
