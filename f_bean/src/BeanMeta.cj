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

public class BeanMeta <: IBeanCondition {
    static func defaultPostConstruct(o: Any): Unit {
    }
    static func defaultDestroy(o: Any): Unit {
    }
    private var _name: String = ""
    private var _typeInfo = None<TypeInfo>
    private var _creator: () -> Any = {=> throw BeanException("creator func must be specified for BeanMeta of IOC.")}
    private var _postConstruct: (Any) -> Unit = defaultPostConstruct
    private var _destroy: (Any) -> Unit = defaultDestroy
    private var _order = 0
    private var _primary = false
    private var _scope = BeanScope.Singleton
    private var _lazy = true
    private var _condition: ?IBeanCondition = None
    private var _dependencies: Array<BeanDependency> = []

    public prop name: String {
        get() {
            _name
        }
    }
    public prop typeInfo: TypeInfo {
        get() {
            _typeInfo.getOrThrow {BeanException("TypeInfo of bean named as ${name} is not specified")}
        }
    }
    public prop creator: () -> Any {
        get() {
            _creator
        }
    }
    public prop postConstruct: (Any) -> Unit {
        get() {
            _postConstruct
        }
    }
    public prop destroy: (Any) -> Unit {
        get() {
            _destroy
        }
    }
    public prop order: Int64 {
        get() {
            _order
        }
    }
    public prop primary: Bool {
        get() {
            _primary
        }
    }
    public prop scope: BeanScope {
        get() {
            _scope
        }
    }
    public prop lazy: Bool {
        get() {
            _lazy
        }
    }
    public prop condition: ?IBeanCondition {
        get() {
            _condition
        }
    }
    public prop dependencies: Array<BeanDependency> {
        get() {
            _dependencies
        }
    }
    public static func create<T>(
        beanName!: String = "",
        creator!: () -> T,
        postConstruct!: (Any) -> Unit = BeanMeta.defaultPostConstruct,
        destroy!: (Any) -> Unit = BeanMeta.defaultDestroy,
        dependencies!: Array<BeanDependency> = []
    ): BeanMeta {
        let typeInfo = TypeInfos.get<T>()
        var order = 0
        var primary = false
        var scope = BeanScope.Singleton
        var lazy = true
        for (annotation in typeInfo.annotations) {
            match(annotation) {
                case x: Order => order = x.value
                case x: Primary => primary = true
                case x: Scope => scope = x.value
                case x: Lazy => lazy = x.value
                case _ => ()
            }
        }
        let meta = BeanMeta()
        meta._name = beanName
        meta._order = order
        meta._primary = primary
        meta._scope = scope
        meta._lazy = lazy
        meta._creator = {=> creator()}
        meta._postConstruct = postConstruct
        meta._destroy = destroy
        meta._dependencies = dependencies
        meta._typeInfo = typeInfo
        for (annotation in typeInfo.annotations where annotation is IBeanCondition) {
            meta._condition = (annotation as IBeanCondition).getOrThrow()
            break
        }
        meta
    }
    private static let optionQualified = "Option"
    private static let arrayQualified = "Array"
    private static let arrayListQualified = "std/collection.ArrayList"
    private static let mapQualified = "std/collection.Map"
    private static let hashMapQualified = "std/collection.HashMap"
    private static let array = "Array"
    private static let arrayList = "ArrayList"
    private static let map = "Map"
    private static let hashMap = "HashMap"
    public static func create<C>(configuration: C, beanName: String, isStatic: Bool, fnName: String, args: Array<TypeInfo>): BeanMeta {
        let meta = BeanMeta()
        meta._name = beanName
        func extractBeanMetas(annotations: Collection<Object>) {
            for (annotation in annotations) {
                match (annotation) {
                    case x: Order => meta._order = x.value
                    case x: Primary => meta._primary = true
                    case x: Scope => meta._scope = x.value
                    case x: Lazy => meta._lazy = x.value
                    case _ => ()
                }
            }
        }
        func extractBeanType(typeInfo: TypeInfo) {
            meta._typeInfo = typeInfo
            var i = 0
            for (fn in typeInfo.instanceFunctions) {
                for (annotation in fn.annotations) {
                    match (annotation) {
                        case x: PostConstruct =>
                            meta._postConstruct = {o => fn.apply(o)}
                            i++
                        case x: Destroy =>
                            meta._destroy = {o => fn.apply(o)}
                            i++
                        case _ => ()
                    }
                }
                if (i == 2) {
                    break
                }
            }
        }
        func extractParams(parameters: InfoList<ParameterInfo>): Array<Any> {
            let argVals = ArrayList<Any>()
            let dependencies = ArrayList<BeanDependency>()
            for (param in parameters) {
                var argType = param.typeInfo
                let qualifiedName = argType.qualifiedName.replace(" ", "")
                var single = true
                var collection = ""
                var collectionType = argType
                if (qualifiedName.startsWith("${optionQualified}<")) {
                    argType = TypeInfos.get(qualifiedName[optionQualified.size + 1..qualifiedName.size - 1])
                } else if (qualifiedName.startsWith(arrayQualified)) {
                    collection = array
                    argType = TypeInfos.get(qualifiedName[arrayQualified.size + 1..qualifiedName.size - 1])
                    single = false
                } else if (qualifiedName.startsWith(arrayListQualified)) {
                    collection = arrayList
                    argType = TypeInfos.get(qualifiedName[arrayListQualified.size + 1..qualifiedName.size - 1])
                    single = false
                } else if (qualifiedName.startsWith(mapQualified)) {
                    collection = map
                    argType = TypeInfos.get(
                        qualifiedName[mapQualified.size + 1..qualifiedName.size - 1]["String,".size..])
                    single = false
                } else if (qualifiedName.startsWith(hashMapQualified)) {
                    collection = hashMap
                    argType = TypeInfos.get(
                        qualifiedName[hashMapQualified.size + 1..qualifiedName.size - 1]["String,".size..])
                    single = false
                }
                for (annotation in param.annotations where annotation is Inject) {
                    match (annotation) {
                        case x: Inject => match (x.pattern) {
                            case Name(n) =>
                                dependencies.add(
                                    BeanDependency(nameDef: WithName(n), typeDef: WithType(argType.qualifiedName)))
                                argVals.add(BeanFactory.instance.get(n, argType))
                            case Prefix(n) =>
                                dependencies.add(
                                    BeanDependency(nameDef: WithPrefix(n), typeDef: WithType(argType.qualifiedName)))
                                if (single) {
                                    argVals.add(BeanFactory.instance.getFirstByPrefix(n, argType))
                                } else {
                                    if (collection == array) {
                                        match (collectionType) {
                                            case x: StructTypeInfo => argVals.add(
                                                x.construct([BeanFactory.instance.getByPrefix(n, argType).values()]))
                                            case _ => ()
                                        }
                                    } else if (collection == arrayList) {
                                        match (collectionType) {
                                            case x: ClassTypeInfo => argVals.add(
                                                x.construct([BeanFactory.instance.getByPrefix(n, argType).values()]))
                                            case _ => ()
                                        }
                                    } else if (collection == map || collection == hashMap) {
                                        argVals.add(BeanFactory.instance.getByPrefix(n, argType))
                                    }
                                }
                            case Suffix(n) =>
                                dependencies.add(
                                    BeanDependency(nameDef: WithSuffix(n), typeDef: WithType(argType.qualifiedName)))
                                if (single) {
                                    argVals.add(BeanFactory.instance.getFirstBySuffix(n, argType))
                                } else {
                                    if (collection == array) {
                                        match (collectionType) {
                                            case x: StructTypeInfo => argVals.add(
                                                x.construct([BeanFactory.instance.getBySuffix(n, argType).values()]))
                                            case _ => ()
                                        }
                                    } else if (collection == arrayList) {
                                        match (collectionType) {
                                            case x: ClassTypeInfo => argVals.add(
                                                x.construct([BeanFactory.instance.getBySuffix(n, argType).values()]))
                                            case _ => ()
                                        }
                                    } else if (collection == map || collection == hashMap) {
                                        argVals.add(BeanFactory.instance.getBySuffix(n, argType))
                                    }
                                }
                            case Wildcard(n) =>
                                dependencies.add(
                                    BeanDependency(nameDef: WithWildcard(n), typeDef: WithType(argType.qualifiedName)))
                                if (single) {
                                    argVals.add(BeanFactory.instance.getFirstByWildcard(n, argType))
                                } else {
                                    if (collection == array) {
                                        match (collectionType) {
                                            case x: StructTypeInfo => argVals.add(
                                                x.construct([BeanFactory.instance.getByWildcard(n, argType).values()]))
                                            case _ => ()
                                        }
                                    } else if (collection == arrayList) {
                                        match (collectionType) {
                                            case x: ClassTypeInfo => argVals.add(
                                                x.construct([BeanFactory.instance.getByWildcard(n, argType).values()]))
                                            case _ => ()
                                        }
                                    } else if (collection == map || collection == hashMap) {
                                        argVals.add(BeanFactory.instance.getByWildcard(n, argType))
                                    }
                                }
                            case Regex(n) =>
                                dependencies.add(
                                    BeanDependency(nameDef: WithRegex(n), typeDef: WithType(argType.qualifiedName)))
                                if (single) {
                                    argVals.add(BeanFactory.instance.getFirstByRegex(n, argType))
                                } else {
                                    if (collection == array) {
                                        match (collectionType) {
                                            case x: StructTypeInfo => argVals.add(
                                                x.construct([BeanFactory.instance.getByRegex(n, argType).values()]))
                                            case _ => ()
                                        }
                                    } else if (collection == arrayList) {
                                        match (collectionType) {
                                            case x: ClassTypeInfo => argVals.add(
                                                x.construct([BeanFactory.instance.getByRegex(n, argType).values()]))
                                            case _ => ()
                                        }
                                    } else if (collection == map || collection == hashMap) {
                                        argVals.add(BeanFactory.instance.getByRegex(n, argType))
                                    }
                                }
                        }
                        case x: ParamValue =>
                            let key = x.key
                            if (single) {
                                argVals.add(
                                    if (argType == TypeInfos.get<String>()) {
                                    Config.getString(key).getOrThrow {BeanException("${key} does not exist")}
                                } else if (argType == TypeInfos.get<Int64>()) {
                                    Config.getData<Int64>(key)
                                } else if (argType == TypeInfos.get<Float64>()) {
                                    Config.getData<Float64>(key)
                                } else if (argType == TypeInfos.get<Bool>()) {
                                    Config.getData<Bool>(key)
                                } else if (argType == TypeInfos.get<Decimal>()) {
                                    Config.getData<Decimal>(key)
                                } else if (argType == TypeInfos.get<Duration>()) {
                                    Config.getData<Duration>(key)
                                } else if (argType == TypeInfos.get<DateTime>()) {
                                    Config.getValue<DateTime>(key)
                                } else {
                                    throw BeanException("type of parameter ${param.name} does not exist")
                                })
                            } else {
                                if (collection == array) {
                                    argVals.add(
                                        if (argType == TypeInfos.get<String>()) {
                                        Config.getStringArray(key)
                                    } else if (argType == TypeInfos.get<Int64>()) {
                                        Config.getDatas<Int64>(key)
                                    } else if (argType == TypeInfos.get<Float64>()) {
                                        Config.getDatas<Float64>(key)
                                    } else if (argType == TypeInfos.get<Bool>()) {
                                        Config.getDatas<Bool>(key)
                                    } else if (argType == TypeInfos.get<Decimal>()) {
                                        Config.getDatas<Decimal>(key)
                                    } else if (argType == TypeInfos.get<Duration>()) {
                                        Config.getDatas<Duration>(key)
                                    } else if (argType == TypeInfos.get<DateTime>()) {
                                        Config.getValues<DateTime>(key)
                                    } else {
                                        throw BeanException("type of parameter ${param.name} does not exist")
                                    })
                                } else {
                                    throw BeanException("ParamValue does support Array only.")
                                }
                            }
                        case _ => break
                    }
                }
            }
            meta._dependencies = dependencies.toArray()
            argVals.toArray()
        }
        let cfgType = TypeInfos.get<C>()
        if(fnName.isEmpty()){
            let fn = match(cfgType){
                case c: ClassTypeInfo => c.getConstructor(args)
                case s: StructTypeInfo => s.getConstructor(args)
                case _ => throw BeanException("type of configuration supports class or struct, but current is ${cfgType}")
            }
            extractBeanMetas(fn.annotations)
            extractBeanType(cfgType)
            let argVals = extractParams(fn.parameters)
            meta._creator = {=> fn.apply(argVals)}
        } else if (isStatic) {
            let fn = cfgType.getStaticFunction(fnName, args)
            extractBeanMetas(fn.annotations)
            extractBeanType(fn.returnType)
            let argVals = extractParams(fn.parameters)
            meta._creator = {=> fn.apply(argVals)}
        } else {
            let fn = cfgType.getInstanceFunction(fnName, args)
            extractBeanMetas(fn.annotations)
            extractBeanType(fn.returnType)
            let argVals = extractParams(fn.parameters)
            meta._creator = {=> fn.apply(configuration, argVals)}
        }
        meta
    }
    public func on(): Bool {
        if (let Some(c) <- _condition) {
            c.on()
        } else {
            true
        }
    }
}
public enum BeanScope <: ToTokens {
    | Singleton
    | Prototype

    public func toTokens(): Tokens {
        match (this) {
            case Singleton => quote(Singleton)
            case Prototype => quote(Prototype)
        }
    }
}
public enum BeanDef {
    | Single
    | Multi
    | Missing
}
public enum BeanNameDef {
    | WithName(String)
    | WithoutName(String)
    | WithPrefix(String)
    | OnlyOnePrefix(String)
    | MultiPrefix(String)
    | WithoutPrefix(String)
    | WithSuffix(String)
    | OnlyOneSuffix(String)
    | MultiSuffix(String)
    | WithoutSuffix(String)
    | WithRegex(String)
    | OnlyOneRegex(String)
    | MultiRegex(String)
    | WithoutRegex(String)
    | WithWildcard(String)
    | OnlyOneWildcard(String)
    | MultiWildcard(String)
    | WithoutWildcard(String)
}
/**
 * 用于定义bean初始化条件OnType
 */
public enum TypeDef {
    /**
     * 有子类型就满足条件
     */
    | WithSubType(String)
    /**
     * 没有子类型就满足条件
     */
    | WithoutSubType(String)
    /**
     * 只有一个子类型就满足条件
     */
    | OnlyOneSubType(String)
    /**
     * 有多个子类型就满足条件
     */
    | MultiSubType(String)
    /**
     * 有指定类型就满足条件，构造器参数是类型的全路径名
     */
    | WithType(String)
    /**
     * 未定义指定类型就满足条件，构造器参数是类型的全路径名
     */
    | Missing(String)
}
public enum ConfDef<T> where T <: Equatable<T> {
    | WithKey(String)
    | WithoutKey(String)
    | MatchValue(String, T)
    | NotMatchValue(String, T)
}
