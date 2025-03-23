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
 * 不支持bean的循环引用，如果发生循环引用会导致栈溢出
 */
public class BeanFactory {
    private static let log = LoggerFactory.getLogger<BeanFactory>()
    public static const BEAN_LIBRARIES_LOAD_PATH = "bean.libraries.load.path"
    private static let mutex = ReentrantMutex()
    private static var instance_ = BeanFactory()
    public static func addBeanFactory() {
        let factory = BeanFactory()
        factory.setInherited(instance)
        synchronized(mutex) {
            instance_ = factory
        }
    }
    public static prop instance: BeanFactory {
        get() {
            instance_
        }
    }
    private let beans = ConcurrentHashMap<String, BeanManager>()
    private let typeMap = ConcurrentHashMap<TypeInfo, TreeMap<BeanManager, BeanManager>>()
    private let annotationMap = ConcurrentHashMap<TypeInfo, TreeMap<BeanManager, BeanManager>>()
    private var inherited = None<BeanFactory>
    private init() {
        Process.current.atExit {
            destroy()
            if (let Some(f) <- inherited) {
                f.destroy()
            }
        }
    }
    /**
     * 从指定路径加载动态链接库，如果参数是空数组就从当前的工作路径加载动态链接库
     */
    private func load(paths: Array<String>): Unit {
        if (paths.isEmpty()) {
            return load(CmdArgs.instance.currentWorkingDirectory.toString())
        }
        for (path in paths) {
            if (exists(path)) {
                if(FileInfo(path).isDirectory()){
                    Directory.walk(path){fi => 
                        load(fi.path.toString())
                        true
                    }
                }else if (path.endsWith('.so') || path.endsWith('.dll')) {
                    ModuleInfo.load(path[0..path.size - if (OS.current.isWindows) {
                            ".dll"
                        } else {
                            ".so"
                        }.size])
                }
            }
        }
    }
    private func destroy(): Unit {
        for ((_, b) in beans.iterator()) {
            try {
                b.destroy()
            } catch (e: Exception) {
                log.warn(e)
            }
        }
    }
    public func setInherited(inherited: BeanFactory): BeanFactory {
        this.inherited = inherited
        this
    }
    private static func offerQueue(queue: LinkedList<TypeInfo>, typeInfo: TypeInfo) {
        match (typeInfo) {
            case ti: ClassTypeInfo => if (let Some(s) <- ti.superClass) {
                queue.addLast(s)
            }
            case _ => ()
        }
        for (si in typeInfo.superInterfaces where si != TypeInfos.get<Any>()) {
            queue.addLast(si)
        }
    }
    public func deregister(names: Array<String>) {
        for (name in names) {
            if (let Some(bean) <- beans.remove(name)) {
                try {
                    bean.destroy()
                } catch (e: Exception) {
                    log.warn(e)
                }
            }
        }
    }
    private func register(bean: BeanManager): BeanFactory {
        if (beans.putIfAbsent(bean.name, bean).isSome()) {
            throw BeanException("duplicate bean name: ${bean.name}")
        } else {
            func populateMap(typeInfo: TypeInfo, map: ConcurrentHashMap<TypeInfo, TreeMap<BeanManager, BeanManager>>) {
                match (map.get(typeInfo)) {
                    case Some(tree) => tree
                    case _ =>
                        let tree = TreeMap<BeanManager, BeanManager>()
                        map[typeInfo] = tree
                        tree
                }.add(bean, bean)
            }
            synchronized(mutex) {
                let queue = LinkedList<TypeInfo>()
                if (bean.typeInfo is ClassTypeInfo) {
                    queue.addLast(TypeInfos.get<Object>())
                }
                queue.addLast(TypeInfos.get<Object>())
                queue.addLast(TypeInfos.get<Any>())
                queue.addLast(bean.typeInfo)
                while (let Some(typeInfo) <- queue.removeFirst()) {
                    populateMap(typeInfo, typeMap)
                    offerQueue(queue, typeInfo)
                }
                for (annotation in bean.typeInfo.annotations) {
                    populateMap(TypeInfo.of(annotation), annotationMap)
                }
            }
        }
        this
    }
    public func register(meta: BeanMeta): BeanFactory {
        register(BeanManager(meta))
    }
    public func register(fn: () -> BeanMeta): BeanFactory {
        register(fn())
        this
    }
    public func register(beans: Iterable<BeanMeta>): BeanFactory {
        for (bean in beans) {
            register(bean)
        }
        this
    }
    public func register(fn: () -> Iterable<BeanMeta>): BeanFactory {
        register(fn())
    }
    public func register(fns: Iterable<() -> BeanMeta>): BeanFactory {
        for (fn in fns) {
            register(fn)
        }
        this
    }
    public func register(fns: Iterable<() -> Iterable<BeanMeta>>): BeanFactory {
        for (fn in fns) {
            register(fn)
        }
        this
    }
    private var finished = false
    /**
     * 待所有bean元数据都初始化完成，就执行这个函数，检查每个bean是否满足初始化条件，如果不满足就从BeanFactory删除，检查时如果条件有循环依赖就抛出异常。
     * 如果参数checkDependencyRing是true就检查每个bean的依赖关系，确认有没有循环依赖，如果发现循环依赖就抛出异常。
     */
    public func initialize(paths!: Array<String>, checkDependencyRing!: Bool = true) {
        if (finished) {
            return
        }
        finished = true
        if (let Some(i) <- inherited) {
            i.doInitialize(checkDependencyRing)
        }
        load(paths)
        doInitialize(checkDependencyRing)
    }
    private func doInitialize(checkDependencyRing: Bool) {
        let list = ArrayList<BeanManager>()
        func removeNotMatches() {
            for (b in list) {
                beans.remove(b.name)
                typeMap[TypeInfos.get<Any>()].remove(b)
                typeMap[TypeInfos.get<Object>()].remove(b)
                let queue = LinkedList<TypeInfo>()
                queue.addLast(b.typeInfo)
                while (let Some(typeInfo) <- queue.removeFirst()) {
                    typeMap[typeInfo].remove(b)
                    offerQueue(queue, typeInfo)
                }
            }
            list.clear()
        }
        let ringChecker = RingChecker()
        for ((_, b) in beans) {
            if (!b.on(ringChecker)) {
                list.add(b)
            }
            ringChecker.clear()
        }
        removeNotMatches()
        for ((_, b) in beans) {
            b.resetOn()
        }
        for ((_, b) in beans) {
            if (b.on(ringChecker)) {
                ringChecker.clear()
                if (checkDependencyRing) {
                    ringChecker.forOn = false
                    ringChecker.put(b)
                    b.dependencyCheck(ringChecker)
                    ringChecker.forOn = true
                }
                if (!b.lazy) {
                    b.get()
                }
            } else {
                list.add(b)
            }
            ringChecker.clear()
        }
        removeNotMatches()
    }
    public func getBeanManagers<T>(): Collection<BeanManager> {
        this.typeMap[TypeInfos.get<T>()].keys()
    }
    public func get(name: String, typeInfo: TypeInfo): ?Any {
        if (let Some(v) <- get<Any>(name)) {
            if (TypeInfo.of(v).isSubtypeOf(typeInfo)) {
                return v
            }
        }
        None
    }

    public func get<T>(checker: (String, Any) -> Bool) {
        get(TypeInfos.get<T>(), checker)
    }
    public func get(typeInfo: TypeInfo, checker: (String, Any) -> Bool): Map<String, Any> {
        let beans = HashMap<String, Any>()
        if (let Some(i) <- inherited) {
            beans.add(all: i.get(typeInfo, checker))
        }
        if (let Some(ts) <- typeMap.get(typeInfo)) {
            for ((t, _) in ts) {
                let o = t.get()
                if (checker(t.name, o)) {
                    match (o) {
                        case x: FactoryBean =>
                            let bean = x.get()
                            x.beanPostConstruct(bean)
                            beans[t.name] = bean
                        case _ => beans[t.name] = o
                    }
                }
            }
        }
        beans
    }
    public func getByPrefix(prefix: String, typeInfo: TypeInfo) {
        get(typeInfo, prefixChecker<Any>(prefix))
    }
    public func getBySuffix(suffix: String, typeInfo: TypeInfo) {
        get(typeInfo, suffixChecker<Any>(suffix))
    }
    public func getByWildcard<T>(pattern: String) {
        getByWildcard(pattern, TypeInfos.get<T>())
    }
    public func getByWildcard(pattern: String, typeInfo: TypeInfo) {
        get(typeInfo, wildcardChecker<Any>(pattern))
    }
    public func getByRegex<T>(regex: String) {
        getByRegex(regex, TypeInfos.get<T>())
    }
    public func getByRegex(regex: String, typeInfo: TypeInfo) {
        get(typeInfo, regexChecker<Any>(regex))
    }
    public func getFirstByPrefix(prefix: String, typeInfo: TypeInfo): ?Any {
        for ((_, bean) in getByPrefix(prefix, typeInfo)) {
            return bean
        }
        None
    }
    public func getFirstBySuffix(suffix: String, typeInfo: TypeInfo): ?Any {
        for ((_, bean) in getBySuffix(suffix, typeInfo)) {
            return bean
        }
        None
    }
    public func getFirstByWildcard<T>(pattern: String) {
        getFirstByWildcard(pattern, TypeInfos.get<T>())
    }
    public func getFirstByWildcard(pattern: String, typeInfo: TypeInfo): ?Any {
        for ((_, bean) in getByWildcard(pattern, typeInfo)) {
            return bean
        }
        None
    }
    public func getFirstByRegex<T>(regex: String) {
        getFirstByRegex(regex, TypeInfos.get<T>())
    }
    public func getFirstByRegex(regex: String, typeInfo: TypeInfo): ?Any {
        for ((_, bean) in getByRegex(regex, typeInfo)) {
            return bean
        }
        None
    }
    private static let annotationType = TypeInfos.get<Annotation>()
    private static func checkAnnotation(typeInfo: TypeInfo) {
        if (!typeInfo.isSubtypeOf(annotationType)) {
            throw BeanException("${typeInfo} is not an annotation")
        }
    }
    public func getByAnnotation<T>(name: String): ?Any {
        getByAnnotation(name, TypeInfos.get<T>())
    }
    public func getByAnnotation(name: String, typeInfo: TypeInfo): ?Any {
        checkAnnotation(typeInfo)
        if (let Some(v) <- get<Any>(name)) {
            for (annotation in TypeInfo.of(v).annotations where TypeInfo.of(annotation).isSubtypeOf(typeInfo)) {
                return v
            }
        }
        None
    }
    public func getByAnnotation<T>(checker: (String, Any) -> Bool): Map<String, Any> {
        getByAnnotation(TypeInfos.get<T>(), checker)
    }
    public func getByAnnotation(typeInfo: TypeInfo, checker: (String, Any) -> Bool): Map<String, Any> {
        checkAnnotation(typeInfo)
        let beans = HashMap<String, Any>()
        if (let Some(i) <- inherited) {
            beans.add(all: i.getByAnnotation(typeInfo, checker))
        }
        if (let Some(ts) <- annotationMap.get(typeInfo)) {
            for ((t, _) in ts) {
                let o = t.get()
                if (checker(t.name, o)) {
                    match (o) {
                        case x: FactoryBean =>
                            let bean = x.get()
                            x.beanPostConstruct(bean)
                            beans[t.name] = bean
                        case _ => beans[t.name] = o
                    }
                }
            }
        }
        beans
    }
    public func getByPrefixAndAnnotation<T>(prefix: String) {
        getByPrefixAndAnnotation(prefix, TypeInfos.get<T>())
    }
    public func getByPrefixAndAnnotation(prefix: String, typeInfo: TypeInfo) {
        get(typeInfo, prefixChecker<Any>(prefix))
    }
    public func getBySuffixAndAnnotation<T>(prefix: String) {
        getBySuffixAndAnnotation(prefix, TypeInfos.get<T>())
    }
    public func getBySuffixAndAnnotation(suffix: String, typeInfo: TypeInfo) {
        get(typeInfo, suffixChecker<Any>(suffix))
    }
    public func getByWildcardAndAnnotation<T>(prefix: String) {
        getByWildcardAndAnnotation(prefix, TypeInfos.get<T>())
    }
    public func getByWildcardAndAnnotation(pattern: String, typeInfo: TypeInfo) {
        get(typeInfo, wildcardChecker<Any>(pattern))
    }
    public func getByRegexAndAnnotation<T>(prefix: String) {
        getByRegexAndAnnotation(prefix, TypeInfos.get<T>())
    }
    public func getByRegexAndAnnotation(regex: String, typeInfo: TypeInfo) {
        get(typeInfo, regexChecker<Any>(regex))
    }
    public func getFirstByPrefixByAnnotation<T>(prefix: String) {
        getFirstByPrefixByAnnotation(prefix, TypeInfos.get<T>())
    }
    public func getFirstByPrefixByAnnotation(prefix: String, typeInfo: TypeInfo): ?Any {
        for ((_, bean) in getByPrefixAndAnnotation(prefix, typeInfo)) {
            return bean
        }
        None
    }
    public func getFirstBySuffixAndAnnotation<T>(prefix: String) {
        getFirstBySuffixAndAnnotation(prefix, TypeInfos.get<T>())
    }
    public func getFirstBySuffixAndAnnotation(suffix: String, typeInfo: TypeInfo): ?Any {
        for ((_, bean) in getBySuffixAndAnnotation(suffix, typeInfo)) {
            return bean
        }
        None
    }
    public func getFirstByWildcardAndAnnotation<T>(prefix: String) {
        getFirstByWildcardAndAnnotation(prefix, TypeInfos.get<T>())
    }
    public func getFirstByWildcardAndAnnotation(pattern: String, typeInfo: TypeInfo): ?Any {
        for ((_, bean) in getByWildcardAndAnnotation(pattern, typeInfo)) {
            return bean
        }
        None
    }
    public func getFirstByRegexAndAnnotation<T>(prefix: String) {
        getFirstByRegexAndAnnotation(prefix, TypeInfos.get<T>())
    }
    public func getFirstByRegexAndAnnotation(regex: String, typeInfo: TypeInfo): ?Any {
        for ((_, bean) in getByRegexAndAnnotation(regex, typeInfo)) {
            return bean
        }
        None
    }

    public func get<T>(name: String): ?T {
        var result: ?T = if (let Some(b) <- beans.get(name)) {
            match (b.get()) {
                case x: T => x
                case _ => None<T>
            }
        } else if (let Some(f) <- inherited) {
            f.get<T>(name)
        } else {
            None<T>
        }
        result
    }

    private func prefixChecker<T>(prefix: String): (String, T) -> Bool {
        {name, bean => name.startsWith(prefix)}
    }
    public func getByPrefix<T>(prefix: String): Map<String, T> {
        get<T>(this.prefixChecker<T>(prefix))
    }
    public func useByPrefix<T>(prefix: String, exec: (T) -> Unit): Unit {
        use<T>(this.prefixChecker<T>(prefix), exec)
    }
    public func getFirstByPrefix<T>(prefix: String): ?T {
        getFirst<T>(this.prefixChecker<T>(prefix))
    }
    private func suffixChecker<T>(suffix: String): (String, T) -> Bool {
        {name, bean => name.endsWith(suffix)}
    }
    public func getBySuffix<T>(suffix: String): Map<String, T> {
        get<T>(this.suffixChecker<T>(suffix))
    }
    public func useBySuffix<T>(suffix: String, exec: (T) -> Unit): Unit {
        use<T>(this.suffixChecker<T>(suffix), exec)
    }
    public func getFirstBySuffix<T>(suffix: String): ?T {
        getFirst<T>(this.suffixChecker<T>(suffix))
    }
    private func wildcardChecker<T>(pattern: String): (String, T) -> Bool {
        {name, bean => "^${pattern.replace("*", ".*")}$".regex().matched(name)}
    }

    //支持通配符*
    public func getWithWildcard<T>(pattern: String): Map<String, T> {
        get<T>(wildcardChecker<T>(pattern))
    }
    public func useWithWildcard<T>(pattern: String, exec: (T) -> Unit): Unit {
        use<T>(wildcardChecker<T>(pattern), exec)
    }
    public func getFirstWithWildcard<T>(pattern: String): ?T {
        getFirst<T>(wildcardChecker<T>(pattern))
    }
    private func regexChecker<T>(pattern: String): (String, T) -> Bool {
        {name, bean => pattern.regex().matched(name)}
    }
    public func getWithRegex<T>(pattern: String): Map<String, T> {
        get<T>(regexChecker<T>(pattern))
    }
    public func useWithRegex<T>(pattern: String, exec: (T) -> Unit): Unit {
        use<T>(regexChecker<T>(pattern), exec)
    }
    public func getFirstWithRegex<T>(pattern: String): ?T {
        getFirst<T>(regexChecker<T>(pattern))
    }
    private func alwaysTrue<T>(): (String, T) -> Bool {
        {k, b => b is T}
    }
    public func get<T>(): Map<String, T> {
        get<T>(alwaysTrue<T>())
    }
    public func use<T>(exec: (T) -> Unit): Unit {
        use<T>(alwaysTrue<T>(), exec)
    }
    public func use<T, R>(name: String, exec: (T) -> ?R): ?R {
        if (let Some(b) <- get<T>(name)) {
            exec(b)
        } else {
            None
        }
    }

    public func getFirst<T>(): ?T {
        getFirst<T> {k, T => true}
    }
    public func get<T>(checker: (String, T) -> Bool): Map<String, T> {
        let beans = HashMap<String, T>()
        if (let Some(i) <- inherited) {
            beans.add(all: i.get<T>(checker))
        }
        if (let Some(tree) <- this.typeMap.get(TypeInfos.get<T>())) {
            for (bean in tree.keys()) {
                let name = bean.name
                match (bean.get()) {
                    case x: T where checker(name, x) => beans[name] = x
                    case fb: FactoryBean =>
                        let bean = fb.get()
                        match (bean) {
                            case x: T =>
                                fb.beanPostConstruct(x)
                                if (checker(name, x)) {
                                    beans[name] = x
                                } else {
                                    continue
                                }
                            case _ => continue
                        }
                    case _ => continue
                }
            }
        }
        beans
    }
    public func use<T>(checker: (String, T) -> Bool, exec: (T) -> Unit): Unit {
        for (bean in get<T>(checker).values()) {
            exec(bean)
        }
    }
    public func use<T>(checker: (String, T) -> Bool): BeanFactoryWrapper<T> {
        BeanFactoryWrapper<T>(this, checker)
    }
    public func useFirst<T>(checker: (String, T) -> Bool): FirstBeanFactoryWrapper<T> {
        FirstBeanFactoryWrapper<T>(this, checker)
    }
    public func getFirst<T>(checker: (String, T) -> Bool): ?T {
        if (let Some(tree) <- this.typeMap.get(TypeInfos.get<T>())) {
            for (bean in tree.keys()) {
                let name = bean.name
                match (bean.get()) {
                    case x: T where checker(name, x) => return x
                    case x: FactoryBean =>
                        let bean = x.get()
                        x.beanPostConstruct(bean)
                        match (bean) {
                            case x: T where checker(name, x) => return x
                            case _ => continue
                        }
                    case _ => continue
                }
            }
        }
        var result = None<T>
        if (let Some(i) <- inherited) {
            result = i.getFirst<T>(checker)
        }
        result
    }
    public func useFirst<T, R>(checker: (String, T) -> Bool, exec: (T) -> ?R): ?R {
        if (let Some(f) <- getFirst<T>(checker)) {
            exec(f)
        } else {
            None
        }
    }
    public func useFirstByPrefix<T, R>(prefix: String, exec: (T) -> ?R): ?R {
        useFirst<T, R>(this.prefixChecker<T>(prefix), exec)
    }
    public func useFirst<T, R>(exec: (T) -> ?R): ?R {
        useFirst<T, R>(alwaysTrue(), exec)
    }
    public func useFirstBySuffix<T, R>(suffix: String, exec: (T) -> ?R): ?R {
        useFirst<T, R>(this.suffixChecker<T>(suffix), exec)
    }
    public func useFirstWithWildcard<T, R>(pattern: String, exec: (T) -> ?R): ?R {
        useFirst<T, R>(this.wildcardChecker<T>(pattern), exec)
    }
}

public class BeanFactoryWrapper<T> {
    BeanFactoryWrapper(private let factory: BeanFactory, private let checker: (String, T) -> Bool) {}

    public func exec(exec: (T) -> Unit): Unit {
        factory.use<T>(checker, exec)
    }
}

public class FirstBeanFactoryWrapper<T> {
    FirstBeanFactoryWrapper(private let factory: BeanFactory, private let checker: (String, T) -> Bool) {}

    public func exec<R>(exec: (T) -> ?R): ?R {
        factory.useFirst<T, R>(checker, exec)
    }
}
