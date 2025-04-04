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
    private let mutex = ReentrantMutex()
    private let beans = HashMap<String, BeanManager>()
    private let beanTypeMap = HashMap<TypeInfo, TreeSet<BeanManager>>()
    private let registered = AtomicBool(false)

    public init(){
        Process.current.atExit(this.shutdown)
    }
    private func shutdown(){
        for((_, m) in beans){
            m.doDestroy()
        }
    }
    public func register<T>(meta: BeanMeta, 
                            creator: () -> Object, 
                            postConstruct!: (Object) -> Unit = {o =>},
                            destroy!: (Object) -> Unit = {o =>}){
        if(registered.load()){
            throw BeanException('To register bean to a registered BeanFactory is forbidden')
        }
        var beanType = TypeInfos.get<T>()
        let manager = BeanManager(meta, beanType, creator, postConstruct: postConstruct, destroy: destroy)
        synchronized(mutex){
            if(!beans.addIfAbsent(manager.name, manager)){
                let prevType = beans[manager.name].beanType
                throw BeanException('duplicate bean name ${manager.name}, existed bean type is ${prevType}, current bean type is ${manager.beanType}')
            }
            let typeQueue = LinkedList<TypeInfo>()
            typeQueue.addLast(beanType)
            typeQueue.addLast(TypeInfos.get<Any>())
            typeQueue.addLast(TypeInfos.get<Object>())
            while(let Some(klass) <- typeQueue.removeFirst()){
                if(let Some(set) <- beanTypeMap.get(klass)){
                    set
                }else{
                    let set = TreeSet<BeanManager>()
                    beanTypeMap.add(klass, set)
                    set
                }.add(manager)
                if(!klass.isSubtypeOf(TypeInfos.get<Annotation>())){
                    for(annotation in klass.annotations){
                        typeQueue.addLast(TypeInfo.of(annotation))
                    }
                }
                for(superInterface in klass.superInterfaces){
                    typeQueue.addLast(superInterface)
                }
                if(let s: ClassTypeInfo <- klass && let Some(sc) <- s.superClass){
                    typeQueue.addLast(sc)
                }
            }

        }
    }
    public func afterRegistered(){
        this.registered.store(true)
        check()
        initBeansIfNeed()
    }
    private func check(){
        synchronized(mutex){
            let discarded = TreeSet<BeanManager>()
            for((_, m) in beans where !(discarded.contains(m) || m.on(this))){
                discarded.add(m)
            }
            let removed = HashSet<TypeInfo>()
            for(d in discarded){
                beans.remove(d.name)
                for((t, set) in beanTypeMap){
                    set.remove(d)
                    removed.add(t)
                }
            }
            for(t in removed where beanTypeMap[t].isEmpty()){
                beanTypeMap.remove(t)
            }
        }
    }
    private func initBeansIfNeed(){
        for((_, m) in beans){
            m.initIfNeed()
        }
    }
    internal func beanManagers(typeInfo: TypeInfo): Collection<BeanManager> {
        beanTypeMap.get(typeInfo) ?? []
    }
    private func matches<T>(m: BeanManager){
        m.beanType.isSubtypeOf(TypeInfos.get<T>())
    }
    private func matches<T>(cond: StringCond, m: BeanManager){
        matches<T>(m) && cond.on(m.name)
    }
    public func getFirst<T>(cond!: StringCond = IgnoreCond): ?T {
        match(cond){
            case Exactly(n) => match(beans.get(n)){
                case Some(m) where matches<T>(m) => 
                    return m.bean as T
                case _ => ()
            }
            case _ => match(beanTypeMap.get(TypeInfos.get<T>())){
                case Some(tree) => for(m in tree where matches<T>(cond, m)){
                        return m.bean as T
                    }
                case _ => ()
            }
        }
        None
    }
    private fucn getAll<T>(cond: StringCond, put: (ArrayList<T>, BeanManger) -> Unit){
        let list = ArrayList<T>()
        match(cond){
            case Exactly(n) => match(beans.get(n)){
                case Some(m) where matches<T>(m) => 
                    put(list, m)
                case _ => ()
            }
            case _ => match(beanTypeMap.get(TypeInfos.get<T>())){
                case Some(tree) => for(m in tree where matches<T>(cond, m)) {
                    put(list, m)
                }
                case _ => ()
            }
        }
        list
    }
    public func getAll<T>(cond!: StringCond = IgnoreCond): Collection<T> {
        func put(list: ArrayList<T>, m: BeanManager){
            if(let b: T <- m.bean){
                list.add(b)
            }
        }
        getAll<T>(cond, put)
    }
    
    private func generateTuple<T>(manager: BeanManager): ?(T, () -> Unit){
        if(matches<T>(manager)){
            let bean = manager.bean
            let b = (bean as T).getOrThrow()
            return (b, manager.generateDestroy(bean))
        }
        None
    }
    private func generateTuple<T>(manager: ?BeanManager): ?(T, () -> Unit) {
        match(manager){
            case Some(m) => generateTuple<T>(m)
            case _ => None
        }
    }

    public func getFirstTuple<T>(cond!: StringCond = IgnoreCond): ?(T, () -> Unit){
        match(cond){
            case Exactly(n) => return generateTuple<T>(beans.get(n))
            case _ => match(beanTypeMap.get(TypeInfos.get<T>())){
                case Some(tree) => for(m in tree where matches<T>(cond, m)){
                    if(let bean <- m.bean && let b: T <- bean){
                        return (b, m.generateDestroy(bean))
                    }
                }
                case _ => ()
            }
        }
        None
    }
    public func getAllTuples<T>(cond!: StringCond = IgnoreCond): Collection<(T, () -> Unit)>{
        func put(list: ArrayList<(T, () -> Unit)>, m: BeanManager){
            if(let bean <- m.bean && let b: T <- bean){
                list.add((b, m.generateDestroy(bean)))
            }
        }
        getAll<T>(cond, put)
    }
    public func get<T>(name: String): ?T {
        getFirst<T>(cond: Exactly(name))
    }
}