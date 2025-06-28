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
        creator: () -> Object,
        postConstruct!: (Object) -> Unit = {o =>},
        destroy!: (Object) -> Unit = {o =>}
    ) where T <: Object {
        if (registered.load()) {
            throw BeanException('To register bean to a registered BeanFactory is forbidden')
        }
        var beanType = TypeInfos.get<T>()
        let manager = BeanManager(meta, beanType, creator, postConstruct: postConstruct, destroy: destroy)
        synchronized(mutex) {
            if (let Some(existed) <- beans.addIfAbsent(manager.name, manager)) {
                throw BeanException(
                    'duplicate bean name ${manager.name}, existed bean type is ${existed.beanType}, current bean type is ${manager.beanType}'
                )
            }
            let typeQueue = LinkedList<TypeInfo>()
            typeQueue.addLast(beanType)
            typeQueue.addLast(TypeInfos.get<Any>())
            typeQueue.addLast(TypeInfos.get<Object>())
            while (let Some(klass) <- typeQueue.removeFirst()) {
                if (let Some(set) <- beanTypeMap.get(klass)) {
                        set
                    } else {
                        let set = TreeSet<BeanManager>()
                        beanTypeMap.add(klass, set)
                        set
                    }.add(manager)
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
        func fn(f: InstanceFunctionInfo): (Object) -> Unit {
            {o: Object => f.apply(o)}
        }
        var postConstruct = BeanManager.dummyFunc
        var destroy = BeanManager.dummyFunc
        var i = 0
        for(f in TypeInfos.get<T>().instanceFunctions where f.parameters.isEmpty() && f.genericParams.isEmpty()){
            if(TypeInfos.withAnnotation<T, PostConstruct>(f.name, [])){
                postConstruct = fn(f)
                i++
            }else if(TypeInfos.withAnnotation<T, Destroy>(f.name, [])){
                destroy = fn(f)
                i++
            }
            if(i == 2){
                break
            }
        }
        register<T>(creator, postConstruct, destroy)
    }
    public func register<T>(creator: () -> T, postConstruct: (Object) -> Unit, destroy: (Object) -> Unit) where T <: Object {
        let typeInfo = TypeInfos.get<T>()
        let meta = if (let Some(meta) <- typeInfo.findAnnotation<BeanMeta>()) {
            meta
        } else {
            BeanMeta()
        }
        doRegister<T>(meta, creator, postConstruct: postConstruct, destroy: destroy)
    }
    public func afterRegistered() {
        this.registered.store(true)
        if(!beans.isEmpty()){
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
        if(shouldInitBean){
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
    private func matches(beanType: TypeInfo, m: BeanManager){
        m.beanType.isSubtypeOf(beanType)
    }
    private func matches<T>(cond: StringCond, m: BeanManager) {
        matches(TypeInfos.get<T>(), cond, m)
    }
    private func matches(beanType: TypeInfo, cond: StringCond, m: BeanManager){
        matches(beanType, m) && cond.on(m.name)
    }
    public func getFirst<T>(cond!: StringCond = IgnoreCond): ?T {
        getFirst<T>(TypeInfos.get<T>(), cond: cond)
    }
    private func beanTypeIs<T>(beanType: TypeInfo){
        if(!beanType.isSubtypeOf(TypeInfos.get<T>())){
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
        for(m in iterator<T>(beanType, cond: cond)){
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
    public func iterator<T>(cond!: StringCond = IgnoreCond): Iterator<BeanManager>{
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
                case Some(tree) => tree.iterator().filter{m => matches(beanType, cond, m)}
                case _ => EmptyIterator<BeanManager>.INSTANCE()
            }
        }
    }
}
