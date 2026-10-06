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

/**
 * §3.1 / BEAN-L7：把「类节点 / 注解节点」的包装提成**无捕获**的静态函数。
 * 原先是 `doRegister` 循环体内现定义、捕获循环局部量 `isClass` 的局部函数 ⇒
 * 每个被展开的类型节点都要新建一个闭包对象（探针实测 ~52 → ~37 ns/节点，每节点省 ~15 ns）。
 */
private func wrapType(isClass: Bool, typeInfo: TypeInfo): BeanType {
    if (isClass) {
        ClassType(typeInfo)
    } else {
        AnnotationType(typeInfo)
    }
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
            // §3.1 / BEAN-L6：同一类型节点只展开一次。插入本身幂等 ⇒ 去重不改变两张表的最终内容，
            // 但能避免共享节点被反复展开，并防止「注解元链成环」（A 注解 B、B 注解 A）时死循环。
            let visited = HashSet<TypeInfo>()
            while (let Some(bt) <- typeQueue.removeFirst()) {
                let (klass, map, isClass) = match(bt){
                    case ClassType(klass) => (klass, beanTypeMap, true)
                    case AnnotationType(klass) => (klass, annotationMap, false)
                }
                if (visited.contains(klass)) {
                    continue
                }
                visited.add(klass)
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
                // §3.1 / BEAN-L6：注解节点也展开自身的注解（**元注解链**）—— 原先只有类节点展开
                // `annotations`，于是「`@Meta` 修饰注解 `@A`、bean 被 `@A` 修饰」时按 `@Meta` 查不到该 bean。
                // 类节点仍沿用 std/基础接口白名单（避免给每个 bean 都挂上 std 侧注解）。
                if (!isClass ||
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
                for (superInterface in klass.superInterfaces where superInterface != any && superInterface != klass) {
                    typeQueue.addLast(wrapType(isClass, superInterface))
                }
                if (let s: ClassTypeInfo <- klass && let Some(sc) <- s.superClass && sc != object) {
                    typeQueue.addLast(wrapType(isClass, sc))
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
                // §3.1 / BEAN-L1(b)：只在确实移除成功时记账 —— 键变空 ⇔ 其最后一个元素被本次移除 ⇒ 收尾不会漏删
                for ((t, set) in beanTypeMap) {
                    if (set.remove(d)) {
                        typeRemoved.add(t)
                    }
                }
                for ((t, set) in annotationMap) {
                    if (set.remove(d)) {
                        annotationRemoved.add(t)
                    }
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
    public func getList<T>(cond!: StringCond = IgnoreCond): ArrayList<T> {
        // §3.1 / BEAN-L10：单参重载的 beanType 就是 T 自己的 TypeInfo ⇒ 直走无校验内部路径
        getListByType<T>(TypeInfo.of<T>(), cond)
    }
    public func getList<T>(beanType: TypeInfo, cond!: StringCond = IgnoreCond): ArrayList<T> {
        beanTypeIs<T>(beanType)
        getListByType<T>(beanType, cond)
    }
    /**
     * `getList` 的内部实现：调用方已完成 `beanTypeIs` 校验（或 `beanType` 就是 `T` 自己的 `TypeInfo`）。
     *
     * §3.1 / `BEAN-L10`：不再经私有 `getAll(cond, put)` —— 那条路每个元素都要付一次间接闭包调用
     * （外加 `beanLog` 的捕获闭包，以及中间 `ArrayList` 从 0 容量扩容）。改为在循环内直接收集；
     * 遍历源、类型判定与 `beanLog` 均与原先一致 ⇒ 元素集合、顺序、实例化次数、日志一字不变。
     */
    private func getListByType<T>(beanType: TypeInfo, cond: StringCond): ArrayList<T> {
        let list = ArrayList<T>()
        for (m in iteratorByType<T>(beanType, cond)) {
            beanLog('getAll', beanType, cond, m)
            if (let b: T <- m.bean) {
                list.add(b)
            }
        }
        list
    }
    public func getMap<T>(cond!: StringCond = IgnoreCond): HashMap<String, T> {
        // §3.1 / BEAN-L10：同 `getList` 的单参重载
        getMapByType<T>(TypeInfo.of<T>(), cond)
    }
    public func getMap<T>(beanType: TypeInfo, cond!: StringCond = IgnoreCond): HashMap<String, T> {
        beanTypeIs<T>(beanType)
        getMapByType<T>(beanType, cond)
    }
    /**
     * `getMap` 的内部实现（说明同 `getListByType`）。
     */
    private func getMapByType<T>(beanType: TypeInfo, cond: StringCond): HashMap<String, T> {
        let map = HashMap<String, T>()
        for (m in iteratorByType<T>(beanType, cond)) {
            beanLog('getAll', beanType, cond, m)
            if (let b: T <- m.bean) {
                map[m.name] = b
            }
        }
        map
    }
    /**
     * §3.1 / `BEAN-L6`：`annotationMap` 的取桶入口 —— 补齐 README 声明过的「按注解取 bean」能力
     * （此前该表只写不读）。注解桶与类型桶同为 `TreeSet<BeanManager>`、同一比较器（`primary` 优先、
     * 再 `order`、再名字）⇒ 结果顺序与既有查询一致。
     */
    private func annotationManagers(annotation: TypeInfo): Collection<BeanManager> {
        annotationMap.get(annotation) ?? []
    }
    /**
     * 取「类型被注解 `A` 修饰（含父类/接口/元注解链，见 `doRegister` 的类型队列）且类型是 `T` 的子类型、
     * 名字满足 `cond`」的第一个 bean；没有则 `None`。
     */
    public func getFirstByAnnotation<T, A>(cond!: StringCond = IgnoreCond): ?T where T <: Object, A <: Annotation {
        getFirstByAnnotation<T>(TypeInfo.of<A>(), cond)
    }
    /**
     * `getFirstByAnnotation` 的内部实现。注意：桶是按**注解**建立的 ⇒ 桶内子类型判定**不**恒真，
     * 故逐元素做真实类型判定（也因此只对命中的 bean 取 `.bean`，不会实例化未命中的 prototype）。
     */
    private func getFirstByAnnotation<T>(annotation: TypeInfo, cond: StringCond): ?T where T <: Object {
        let requiredType = TypeInfo.of<T>()
        for (m in annotationManagers(annotation) where m.beanType.isSubtypeOf(requiredType) && cond.on(m.name)) {
            beanLog('getFirstByAnnotation', requiredType, cond, m)
            return m.bean as T
        }
        None
    }
    /**
     * 取全部「类型被注解 `A` 修饰且类型是 `T` 的子类型、名字满足 `cond`」的 bean（顺序同注解桶）。
     */
    public func getListByAnnotation<T, A>(cond!: StringCond = IgnoreCond): ArrayList<T> where T <: Object,
        A <: Annotation {
        getListByAnnotation<T>(TypeInfo.of<A>(), cond)
    }
    /**
     * `getListByAnnotation` 的内部实现（说明同 `getFirstByAnnotation`）。
     */
    private func getListByAnnotation<T>(annotation: TypeInfo, cond: StringCond): ArrayList<T> where T <: Object {
        let requiredType = TypeInfo.of<T>()
        let list = ArrayList<T>()
        for (m in annotationManagers(annotation) where m.beanType.isSubtypeOf(requiredType) && cond.on(m.name)) {
            beanLog('getListByAnnotation', requiredType, cond, m)
            if (let b: T <- m.bean) {
                list.add(b)
            }
        }
        list
    }
    /**
     * 同 `getListByAnnotation`，返回的 `HashMap` 以 `BeanManager.name`（bean 名）为 KEY。
     */
    public func getMapByAnnotation<T, A>(cond!: StringCond = IgnoreCond): HashMap<String, T> where T <: Object,
        A <: Annotation {
        getMapByAnnotation<T>(TypeInfo.of<A>(), cond)
    }
    /**
     * `getMapByAnnotation` 的内部实现（说明同 `getFirstByAnnotation`）。
     */
    private func getMapByAnnotation<T>(annotation: TypeInfo, cond: StringCond): HashMap<String, T> where T <: Object {
        let requiredType = TypeInfo.of<T>()
        let map = HashMap<String, T>()
        for (m in annotationManagers(annotation) where m.beanType.isSubtypeOf(requiredType) && cond.on(m.name)) {
            beanLog('getMapByAnnotation', requiredType, cond, m)
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
        // §3.1 / BEAN-L10：`getAll(cond, put)` 删除后，这里也改为循环内直接收集（行为与原先一致）
        let beanType = TypeInfo.of<T>()
        for (m in iteratorByType<T>(beanType, cond)) {
            beanLog('getAll', beanType, cond, m)
            if (let bean <- m.bean && let b: T <- bean) {
                list.add((m.name, b, m.generateDestroy(bean)))
            }
        }
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
