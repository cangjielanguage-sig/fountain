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
package f_bean

public class BeanFactory {
    public static let instance = BeanFactory()
    private let mutex = Mutex()
    private let beans = HashMap<String, BeanManager>()
    private let beanTypeMap = HashMap<TypeInfo, TreeSet<BeanManager>>()
    private let registered = AtomicBool(false)

    private init() {
        atExit(this.shutdown)
    }
    private func shutdown() {
        for ((_, m) in beans) {
            m.doDestroy()
        }
    }
    private func doRegister<T>(
        meta: BeanMeta,
        creator: () -> Object
    ) where T <: Object {
        if (registered.load()) {
            throw BeanException('To register bean to a registered BeanFactory is forbidden')
        }
        var beanType = TypeInfos.get<T>()
        let manager = BeanManager(meta, beanType, creator)
        synchronized(mutex) {
            if (let Some(existed) <- beans.addIfAbsent(manager.name, manager)) {
                throw BeanException(
                    'duplicate bean name ${manager.name}, existed bean type is ${existed.beanType}, current bean type is ${manager.beanType}')
            }
            let typeQueue = LinkedList<TypeInfo>()
            typeQueue.addLast(beanType)
            typeQueue.addLast(TypeInfos.get<Any>())
            typeQueue.addLast(TypeInfos.get<Object>())
            while (let Some(klass) <- typeQueue.removeFirst()) {
                if (let Some(set) <- beanTypeMap
                    .get(klass)) {
                        set
                    } else {
                        let set = TreeSet<BeanManager>()
                        beanTypeMap
                        .add(klass, set)
                        set
                    }
                    .add(manager)
                if (!klass.isSubtypeOf(TypeInfos.get<Annotation>())) {
                    for (annotation in klass.annotations) {
                        typeQueue.addLast(ClassTypeInfo.of(annotation))
                    }
                }
                for (superInterface in klass.superInterfaces) {
                    typeQueue.addLast(superInterface)
                }
                if (let s: ClassTypeInfo <- klass && let Some(sc) <- s.superClass) {
                    typeQueue.addLast(sc)
                }
            }
        }
    }
    public func register<T>(creator: () -> T) where T <: Object {
        let typeInfo = TypeInfos.get<T>()
        let meta = if (let Some(meta) <- typeInfo.findAnnotation<BeanMeta>()) {
            meta
        } else {
            BeanMeta()
        }
        doRegister<T>(meta, creator)
    }
    public func afterRegistered() {
        this.registered.store(true)
        if (!beans.isEmpty()) {
            check()
            initBeansIfNeed()
        }
    }
    private func check() {
        synchronized(mutex) {
            let discarded = TreeSet<BeanManager>()
            for ((_, m) in beans where !(discarded.contains(m) || m.on(this))) {
                discarded.add(m)
            }
            let removed = HashSet<TypeInfo>()
            for (d in discarded) {
                beans.remove(d.name)
                for ((t, set) in beanTypeMap) {
                    set.remove(d)
                    removed.add(t)
                }
            }
            for (t in removed where beanTypeMap[t].isEmpty()) {
                beanTypeMap.remove(t)
            }
        }
    }
    private func initBeansIfNeed() {
        if (shouldInitBean) {
            for ((_, m) in beans) {
                m.initIfNeed()
            }
        }
    }
    internal func beanManagers(typeInfo: TypeInfo): Collection<BeanManager> {
        beanTypeMap.get(typeInfo) ?? []
    }
    private func matches<T>(m: BeanManager) {
        matches(TypeInfos.get<T>(), m)
    }
    private func matches(beanType: TypeInfo, m: BeanManager) {
        m.beanType.isSubtypeOf(beanType)
    }
    private func matches<T>(cond: StringCond, m: BeanManager) {
        matches(TypeInfos.get<T>(), cond, m)
    }
    private func matches(beanType: TypeInfo, cond: StringCond, m: BeanManager) {
        matches(beanType, m) && cond.on(m.name)
    }
    public func getFirst<T>(cond!: StringCond = IgnoreCond): ?T {
        getFirst<T>(TypeInfos.get<T>(), cond: cond)
    }
    private func beanTypeIs<T>(beanType: TypeInfo) {
        if (!beanType.isSubtypeOf(TypeInfos.get<T>())) {
            throw BeanException('${beanType} is sub type of ${TypeInfos.get<T>()}')
        }
    }
    public func getFirst<T>(beanType: TypeInfo, cond!: StringCond = IgnoreCond): ?T {
        beanTypeIs<T>(beanType)
        match (cond) {
            case Exactly(n) => match (beans.get(n)) {
                case Some(m) where matches(beanType, m) => return m.bean as T
                case _ => ()
            }
            case _ => match (beanTypeMap.get(beanType)) {
                case Some(tree) => for (m in tree where matches(beanType, cond, m)) {
                    return m.bean as T
                }
                case _ => ()
            }
        }
        None
    }
    private func getAll<T>(cond: StringCond, put: (BeanManager) -> Unit) {
        getAll<T>(TypeInfos.get<T>(), cond, put)
    }
    private func getAll<T>(beanType: TypeInfo, cond: StringCond, put: (BeanManager) -> Unit) {
        for (m in iterator<T>(beanType, cond: cond)) {
            put(m)
        }
    }
    public func getList<T>(cond!: StringCond = IgnoreCond): ArrayList<T> {
        getList<T>(TypeInfos.get<T>(), cond: cond)
    }
    public func getList<T>(beanType: TypeInfo, cond!: StringCond = IgnoreCond): ArrayList<T> {
        let list = ArrayList<T>()
        func put(m: BeanManager) {
            if (let b: T <- m.bean) {
                list.add(b)
            }
        }
        getAll<T>(beanType, cond, put)
        list
    }
    public func getMap<T>(cond!: StringCond = IgnoreCond): HashMap<String, T> {
        getMap<T>(TypeInfos.get<T>(), cond: cond)
    }
    public func getMap<T>(beanType: TypeInfo, cond!: StringCond = IgnoreCond): HashMap<String, T> {
        let map = HashMap<String, T>()
        func put(m: BeanManager) {
            if (let b: T <- m.bean) {
                map[m.name] = b
            }
        }
        getAll<T>(beanType, cond, put)
        map
    }

    private func generateTuple<T>(manager: BeanManager): ?(String, T, () -> Unit) {
        if (matches<T>(manager)) {
            let bean = manager.bean
            let b = (bean as T).getOrThrow()
            return (manager.name, b, manager.generateDestroy(bean))
        }
        None
    }
    private func generateTuple<T>(manager: ?BeanManager): ?(String, T, () -> Unit) {
        match (manager) {
            case Some(m) => generateTuple<T>(m)
            case _ => None
        }
    }

    /**
     * 返回的元组分别是(beanName, bean, bean的销毁函数)
     */
    public func getFirstTuple<T>(cond!: StringCond = IgnoreCond): ?(String, T, () -> Unit) {
        match (cond) {
            case Exactly(n) => return generateTuple<T>(beans.get(n))
            case _ => match (beanTypeMap.get(TypeInfos.get<T>())) {
                case Some(tree) => for (m in tree where matches<T>(cond, m)) {
                    if (let bean <- m.bean && let b: T <- bean) {
                        return (m.name, b, m.generateDestroy(bean))
                    }
                }
                case _ => ()
            }
        }
        None
    }
    /**
     * 返回的元组分别是(beanName, bean, bean的销毁函数)
     */
    public func getAllTuples<T>(cond!: StringCond = IgnoreCond): Collection<(String, T, () -> Unit)> {
        let list = ArrayList<(String, T, () -> Unit)>()
        func put(m: BeanManager) {
            if (let bean <- m.bean && let b: T <- bean) {
                list.add((m.name, b, m.generateDestroy(bean)))
            }
        }
        getAll<T>(cond, put)
        list
    }
    public func get<T>(name: String): ?T {
        getFirst<T>(cond: Exactly(name))
    }
    public func iterator<T>(cond!: StringCond = IgnoreCond): Iterator<BeanManager> {
        iterator<T>(TypeInfos.get<T>(), cond: cond)
    }
    public func iterator<T>(beanType: TypeInfo, cond!: StringCond = IgnoreCond): Iterator<BeanManager> {
        beanTypeIs<T>(beanType)
        match (cond) {
            case Exactly(n) => match (beans.get(n)) {
                case Some(m) where matches(beanType, m) => [m].iterator()
                case _ => EmptyIterator<BeanManager>.INSTANCE()
            }
            case _ => match (beanTypeMap.get(beanType)) {
                case Some(tree) => tree.iterator().filter {m => matches(beanType, cond, m)}
                case _ => EmptyIterator<BeanManager>.INSTANCE()
            }
        }
    }
}
