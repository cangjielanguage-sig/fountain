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

import fountain::f_log.impl.{LoggerFactory, LogFilter, LoggerConfig}

private enum BeanType{
    | AnnotationType(TypeInfo)
    | ClassType(TypeInfo)
}
public class BeanFactory {
    private static let log = LoggerFactory.getLogger<BeanFactory>()
    public static let instance = BeanFactory()
    private let mutex = Mutex()
    private let beans = HashMap<String, BeanManager>()
    private let beanTypeMap = HashMap<TypeInfo, TreeSet<BeanManager>>()
    private let annotationMap = HashMap<TypeInfo, TreeSet<BeanManager>>()
    private let registered = AtomicBool(false)

    private init() {
        ExitCallbacks.atExit(253, this.shutdown)
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
        var beanType = TypeInfo.of<T>()
        if(beanType.isSubtypeOf(TypeInfo.of<FactoryBean>()) && 
           let Some(p) <- TypeMemberInfos.staticProperty(beanType, 'typeInfo') && 
           let t: TypeInfo <- p.getValue()){
            beanType = t
        }//这里曾有个反射BUG，调用isSubtypeOf会导致得不到类实现的直接接口，
         //由于FactoryBean这个特性所用不多，又不希望失去这个功能，把isSubtypeOf放到if条件最后面，
         //可以在不使用FactoryBean的时候可以正常运行，同时确保代码逻辑上正确。
         //如今这个BUG没有了，为了效率可以把这个isSubtypeOf放到最前面。
        let manager = BeanManager(meta, beanType, creator)
        synchronized(mutex) {
            if (let Some(existed) <- beans.addIfAbsent(manager.name, manager)) {
                throw BeanException(
                    'duplicate bean name ${manager.name}, existed bean type is ${existed.beanType}, current bean type is ${manager.beanType}')
            }
            let typeQueue = LinkedList<BeanType>()
            typeQueue.addLast(ClassType(beanType))
            let any = TypeInfo.of<Any>()
            let object = TypeInfo.of<Object>()
            typeQueue.addLast(ClassType(any))
            typeQueue.addLast(ClassType(object))
            while (let Some(bt) <- typeQueue.removeFirst()) {
                let (klass, map, isClass) = match(bt){
                    case ClassType(klass) => (klass, beanTypeMap, true)
                    case AnnotationType(klass) => (klass, annotationMap, false)
                }
                if (let Some(set) <- map.get(klass)) {
                    set
                } else {
                    let set = TreeSet<BeanManager>()
                    map.add(klass, set)
                    set
                }.add(manager)
                if(klass == any || klass == object){
                    continue
                }
                if (isClass && 
                    !(klass.qualifiedName.startsWith('std.') || 
                      klass.qualifiedName.startsWith('stdx.') || 
                      klass.qualifiedName.startsWith('Equatable<') ||
                      klass.qualifiedName == 'Hashable' ||
                      klass.qualifiedName == 'ToString' ||
                      klass.qualifiedName == 'Any' || 
                      klass.qualifiedName == 'Object' || 
                      klass.qualifiedName.startsWith('Comparable<') ||
                      klass.qualifiedName.startsWith('Equal<') ||
                      klass.qualifiedName.startsWith('NotEqual<') ||
                      klass.qualifiedName.startsWith('Greater<') || 
                      klass.qualifiedName.startsWith('Less<') || 
                      klass.qualifiedName.startsWith('LessOrEqual<') || 
                      klass.qualifiedName.startsWith('GreaterOrEqual<') || 
                      klass.qualifiedName.startsWith('Countable<') || 
                      klass.qualifiedName.startsWith('Collection<') ||
                      klass.qualifiedName.startsWith('Iterable<') || 
                      klass.qualifiedName.startsWith('Iterator<') ||
                      klass.qualifiedName.startsWith('Resource<')
                      )) {
                    for (annotation in klass.annotations) {
                        typeQueue.addLast(AnnotationType(ClassTypeInfo.of(annotation)))
                    }
                }
                func beanType(typeInfo: TypeInfo) {
                    if (isClass) {
                        ClassType(typeInfo)
                    } else {
                        AnnotationType(typeInfo)
                    }
                }
                for (superInterface in klass.superInterfaces where superInterface != any && superInterface != klass) {
                    typeQueue.addLast(beanType(superInterface))
                }
                if (let s: ClassTypeInfo <- klass && let Some(sc) <- s.superClass && sc != object) {
                    typeQueue.addLast(beanType(sc))
                }
            }
        }
        log.debug{'bean registered ${manager}'}
    }
    public func register<T>(creator: () -> T): Unit where T <: Object {
        let meta = TypeInfo.of<T>().findAnnotation<BeanMeta>() ?? BeanMeta()
        doRegister<T>(meta, creator)
    }
    public func registerByStaticFunction<T>(fnName: String, creator: () -> T): Unit where T <: Object {
        let meta = TypeInfo.of<T>().getStaticFunction(fnName, []).findAnnotation<BeanMeta>() ?? BeanMeta()
        doRegister<T>(meta, creator)
    }
    public func registerByInstanceFunction<T>(fnName: String, creator: () -> T): Unit where T <: Object {
        let meta = TypeInfo.of<T>().getInstanceFunction(fnName, []).findAnnotation<BeanMeta>() ?? BeanMeta()
        doRegister<T>(meta, creator)
    }
    public func afterRegistered() {
        this.registered.store(true)
        if (!beans.isEmpty()) {
            check()
            initBeansIfNeed()
            if(let Some(lf) <- getFirst<LogFilter>()){
                LoggerConfig.filter = lf
            }
        }
    }
    private func check() {
        synchronized(mutex) {
            let discarded = TreeSet<BeanManager>()
            for ((_, m) in beans where !(discarded.contains(m) || m.on(this))) {
                discarded.add(m)
                log.debug{"bean discarded: ${m}"}
            }
            let typeRemoved = HashSet<TypeInfo>()
            let annotationRemoved = HashSet<TypeInfo>()
            for (d in discarded) {
                beans.remove(d.name)
                for ((t, set) in beanTypeMap) {
                    set.remove(d)
                    typeRemoved.add(t)
                }
                for((t, set) in annotationMap){
                    set.remove(d)
                    annotationRemoved.add(t)
                }
            }
            for (t in typeRemoved where beanTypeMap[t].isEmpty()) {
                beanTypeMap.remove(t)
            }
            for(t in annotationRemoved where annotationMap[t].isEmpty()){
                annotationMap.remove(t)
            }
        }
    }
    private func initBeansIfNeed() {
        if (shouldInitBean) {
            for ((_, m) in beans) {
                if(m.initIfNeed()){
                    log.debug{'bean init on starting: ${m}'}
                }
            }
        }
    }
    internal func beanManagers(typeInfo: TypeInfo): Collection<BeanManager> {
        beanTypeMap.get(typeInfo) ?? []
    }
    private func matches<T>(m: BeanManager) {
        matches(TypeInfo.of<T>(), m)
    }
    private func matches(beanType: TypeInfo, m: BeanManager) {
        m.beanType.isSubtypeOf(beanType)
    }
    public func getFirst<T>(cond!: StringCond = IgnoreCond): ?T {
        // §2.15 / BEAN-2：这里的 beanType 就是 T 自己的 TypeInfo，beanTypeIs 恒真 ⇒ 走内部路径，
        // 省掉一次 TypeInfo.of<T>() 与一次 isSubtypeOf（f_mvc/src/RequestMeta.cj 每请求调一次）。
        getFirstByType<T>(TypeInfo.of<T>(), cond)
    }
    private func beanTypeIs<T>(beanType: TypeInfo) {
        let requiredType = TypeInfo.of<T>()
        if (!beanType.isSubtypeOf(requiredType)) {
            throw BeanException('${beanType} is not sub type of ${requiredType}')
        }
    }
    private func beanLog(logPrefix: String, requiredType: TypeInfo, cond: StringCond, manager: BeanManager){
        log.debug {
            'BeanFactory.${logPrefix}:requiredType-${requiredType}; beanNameCondition-${cond}; beanType-${manager.beanType}'
        }
    }
    public func getFirst<T>(beanType: TypeInfo, cond!: StringCond = IgnoreCond): ?T {
        beanTypeIs<T>(beanType)
        getFirstByType<T>(beanType, cond)
    }
    /**
     * `getFirst` 的内部实现：调用方已完成 `beanTypeIs` 校验（或 `beanType` 就是 `T` 自己的 `TypeInfo`）。
     */
    private func getFirstByType<T>(beanType: TypeInfo, cond: StringCond): ?T {
        match (cond) {
            case Exactly(n) => 
            match (beans.get(n)) {
                case Some(m) where matches(beanType, m) => 
                    beanLog('getFirst', beanType, cond, m)
                    return m.bean as T
                case _ => ()
            }
            case _ => 
                match (beanTypeMap.get(beanType)) {
                case Some(tree) => 
                    // §2.15 / BEAN-2：桶由注册期按「beanType 的超类型闭包」填充（见 doRegister），
                    // 桶内每个 manager 的 beanType 必是该 key 的子类型 ⇒ 子类型复检恒真，只留名字条件。
                    for (m in tree where cond.on(m.name)) {
                        beanLog('getFirst', beanType, cond, m)
                        return m.bean as T
                    }
                case _ => ()
            }
        }
        None
    }
    private func getAll<T>(cond: StringCond, put: (BeanManager) -> Unit) {
        getAll<T>(TypeInfo.of<T>(), cond, put)
    }
    private func getAll<T>(beanType: TypeInfo, cond: StringCond, put: (BeanManager) -> Unit) {
        for (m in iterator<T>(beanType, cond: cond)) {
            beanLog('getAll', beanType, cond, m)
            put(m)
        }
    }
    public func getList<T>(cond!: StringCond = IgnoreCond): ArrayList<T> {
        getList<T>(TypeInfo.of<T>(), cond: cond)
    }
    public func getList<T>(beanType: TypeInfo, cond!: StringCond = IgnoreCond): ArrayList<T> {
        let list = ArrayList<T>()
        getAll<T>(beanType, cond){bm: BeanManager =>
            if (let b: T <- bm.bean) {
                list.add(b)
            }
        }
        list
    }
    public func getMap<T>(cond!: StringCond = IgnoreCond): HashMap<String, T> {
        getMap<T>(TypeInfo.of<T>(), cond: cond)
    }
    public func getMap<T>(beanType: TypeInfo, cond!: StringCond = IgnoreCond): HashMap<String, T> {
        let map = HashMap<String, T>()
        getAll<T>(beanType, cond){m: BeanManager => 
            if (let b: T <- m.bean) {
                map[m.name] = b
            }
        }
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
    public func getFirstTuple<T>(cond!: StringCond = IgnoreCond): ?(String, T, () -> Unit) where T <: Object {
        match (cond) {
            case Exactly(n) => return generateTuple<T>(beans.get(n))
            case _ => match (beanTypeMap.get(TypeInfo.of<T>())) {
                // §2.16 / BEAN-3（同族）：桶 key 就是 TypeInfo.of<T>()，子类型复检恒真；
                // 原先 matches<T>(cond, m) 还会逐元素重算 TypeInfo.of<T>() + isSubtypeOf。
                case Some(tree) => for (m in tree where cond.on(m.name)) {
                    if (let bean: T <- m.bean) {
                        return (m.name, bean, m.generateDestroy(bean))
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
        // §2.16 / BEAN-3（同族，与 §2.15 同一处理）：beanType 就是 T 自己的 TypeInfo，beanTypeIs 恒真
        // ⇒ 直接走内部路径，省掉一次 TypeInfo.of<T>() 与一次 isSubtypeOf；getList/getMap/lookup* 都经此。
        iteratorByType<T>(TypeInfo.of<T>(), cond)
    }
    public func iterator<T>(beanType: TypeInfo, cond!: StringCond = IgnoreCond): Iterator<BeanManager> {
        beanTypeIs<T>(beanType)
        iteratorByType<T>(beanType, cond)
    }
    /**
     * `iterator` 的内部实现：调用方已完成 `beanTypeIs` 校验（或 `beanType` 就是 `T` 自己的 `TypeInfo`）。
     */
    private func iteratorByType<T>(beanType: TypeInfo, cond: StringCond): Iterator<BeanManager> {
        match (cond) {
            case Exactly(n) => match (beans.get(n)) {
                case Some(m) where matches(beanType, m) => [m].iterator()
                case _ => EmptyIterator<BeanManager>.instance()
            }
            case _ => match (beanTypeMap.get(beanType)) {
                case Some(tree) =>
                    // §2.16 / BEAN-3：IgnoreCond 无需过滤（子类型由注册期入桶保证，见 §2.15）⇒ 不建闭包、
                    // 不做逐元素判定；有名字条件时也只留 cond.on（原先 matches 里的子类型复检恒真）。
                    if (cond.ignored) {
                        tree.iterator()
                    } else {
                        tree.iterator().filter {m => cond.on(m.name)}
                    }
                case _ => EmptyIterator<BeanManager>.instance()
            }
        }
    }
}
