/*
    Copyright (c) [2022] [WuJingrun（吴京润）]
    fountain is licensed under Mulan PSL v2.
    You can use this software according to the terms and conditions of the Mulan PSL v2.
    You may obtain a copy of Mulan PSL v2 at:
            http://license.coscl.org.cn/MulanPSL2
    THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
    See the Mulan PSL v2 for more details.
 */
package f_aspect

public import std.collection.ArrayList
import std.ast.*
import std.collection.concurrent.ConcurrentHashMap
import std.fs.{Directory, Path, File, OpenMode, exists, FileInfo}
import std.io.StringReader
import std.posix.getcwd
import std.sync.ReentrantMutex
import f_base.*
import f_bean.{BeanFactory, BeanManager}
import f_collection.*
import f_macros.*
import f_regex.*

public class Aspects {
    private static let mutex = ReentrantMutex()
    private static let allAspects = TreeMap<BeanManager, BeanManager>()
    private static let routeAspectsMap = ConcurrentHashMap<String, (Array<Any>, () -> Any) -> Any>()
    private static let routeAnnotationsMap = ConcurrentHashMap<String, Collection<Object>>()

    public static func register(factory: BeanFactory) {
        synchronized(mutex) {
            for (bm in factory.getBeanManagers<Aspect>()) {
                allAspects[bm] = bm
            }
        }
    }
    public static func insertPointcut() {
        let path = getcwd()
        insertPointcut(path)
    }
    private static func insertPointcut(path: String): Unit {
        if (exists(path) && FileInfo(path).isDirectory()) {
            let tomlPath = "${path}/cjpm.toml"
            if (exists(tomlPath)) {
                let module = {=>
                    try (reader = StringReader(File(tomlPath, ReadWrite))) {
                        while(let Some(line) <- reader.readln()) {
                            let current = line.trimAscii()
                            let matcher = "^name\\s*=\\s*\"([a-zA-Z]\\w*)\\s*\"$".regex().matcher(current)
                            if (matcher.matches()) {
                                return matcher.find().getOrThrow().matchStr(1).trimAscii()
                            }
                        }
                    }
                    ''
                }()
                Directory.walk(path){fi => 
                    if(fi.isDirectory()){
                        if (fi.path.toString().endsWith("/src")) {
                            func doInsert(path: Path): Unit {
                                Directory.walk(path){src => 
                                    if (!src.isDirectory() && src.path.toString().endsWith(".cj")) {
                                        insertPointcutIntoCode(path.toString(), module)
                                    } else if (src.isDirectory()) {
                                        doInsert(src.path)
                                    }
                                    true
                                }
                            }
                            doInsert(fi.path)
                        } else {
                            insertPointcut(fi.path.toString())
                        }
                    }
                    true
                }
            }
        }
    }
    private static func insertPointcutIntoCode(filePath: String, module: String) {
        let fileInfo = FileInfo(filePath)
        let dir = (fileInfo.parentDirectory?.path).getOrThrow()
        let aspectImports = "${dir}/fountain__aspect__imports.cj"
        if(!exists(aspectImports)) {
            try (imports = File(aspectImports, Append)) {
                imports.write(unsafe{
                    """
import f_aspect.*
import f_aspect.macros.*
""".rawData()
                })
            }
        }
        var code = String.fromUtf8(File.readFrom(filePath))
        let tokens = cangjieLex(code)
        let program = parseProgram(tokens)
        var changed = false
        let packageHeader = program.packageHeader.packageIdentifier.value
        let pdecls = program.decls
        for (c in 0 .. pdecls.size) {
            match(pdecls[c]) {
                case cd: ClassDecl =>
                    var pointcut = false
                    let body = cd.body.decls
                    for (i in 0 .. body.size) {
                        match(body[i]) {
                            case fn: FuncDecl where isPublic(fn) && !isStatic(fn) =>
                                let route = "${module}.${packageHeader}.${cd.identifier.value}${cd.genericParam.toTokens()}.${fn.identifier.value}"
                                let param = parseParameterTypes(fn.funcParams.toTokens().toString().replace(" ", ""))
                                let typeInfo = TypeInfos.get(route)
                                let fnInfo = TypeMemberInfos.instanceFunction(typeInfo, fn.identifier.value, param).getOrThrow()
                                let returnType = fnInfo.returnType
                                let checked = checkRoute(route, param, returnType)
                                let fnTokens = fn.toTokens()
                                let pointcutting = fnTokens[0 .. 3] == quote(@PointCut[) || fnTokens[0 .. 7] == quote(@aspect.macros.PointCut[)
                                if (checked) {
                                    if (!pointcutting) {
                                        body[i] = parseDecl(quote(
                                            @aspect.macros.PointCut[]
                                            $(fn)))
                                        changed = true
                                    }
                                    pointcut = true
                                } else if (pointcutting) {
                                    var fi = 0
                                    while(fi < fnTokens.size && fnTokens[fi] != `rsquare`[0] && fnTokens[fi] != `public`[0] && fnTokens[fi] != `open`[0]) {
                                        fi++
                                    }
                                    if (fi > 0) {
                                        body[i] = parseDecl(fnTokens[fi + 1 .. ])
                                        changed = true
                                    }
                                }
                            case _ => ()
                        }
                    }
                    let klassTokens = cd.toTokens()
                    let pointcutting = klassTokens[0 .. 3] == quote(@PointCut[) || klassTokens[0 .. 7] == quote(@aspect.macros.PointCut[)
                    if (pointcut) {
                        if (!pointcutting) {
                            pdecls[c] = parseDecl(quote(
                                @PointCut[]
                                $(cd)
                            ))
                            changed = true
                        }
                    } else if (pointcutting) {
                        var i = 0
                        while(i < klassTokens.size && klassTokens[i] != `public`[0] && klassTokens[i] != `class`[0] && klassTokens[i] != `open`[0] && klassTokens[i] != `sealed`[0] && klassTokens[i] != `abstract`[0]) {
                            i++
                        }
                        if (i > 0) {
                            pdecls[c] = parseDecl(klassTokens[i + 1 .. ])
                            changed = true
                        }
                    }
                case _ => ()
            }
        }
        if (changed) {
            code = program.toTokens().toString()
            File.writeTo(filePath, unsafe{code.rawData()})
        }
    }
    private static func qualifiedRoute(route: String, argTypes: Array<TypeInfo>){
        let argTypeStr = StringBuilder()
        var i = 0
        while(i < argTypes.size) {
            if (i > 0) {
                argTypeStr.append(",")
            }
            var typeStr = argTypes[i].qualifiedName
            argTypeStr.append(typeStr)
            i++
        }
        "${route}(${argTypeStr})"
    }
    /**
     * route 是module_name.package_name.TypeName.funcName，TypeName包含泛型参数
     */
    public static func getAnnotations(route: String, argTypes: Array<TypeInfo>): Collection<Object>{
        let qualified = qualifiedRoute(route, argTypes)
        if(let Some(collection) <- routeAnnotationsMap.get(qualified)){
            collection
        }else{
            let qualifiedFunc = route.replace(" ", "")
            let dotIdx = qualifiedFunc.lastIndexOf(".") ?? -1
            let qualifiedName = qualifiedFunc[0 .. dotIdx]
            let funcName = qualifiedFunc[dotIdx + 1 .. ]
            let collection = TypeInfos.get(qualifiedName).getInstanceFunction(funcName, argTypes).annotations
            routeAnnotationsMap[qualified] = collection
            collection
        }
    }
    private static func checkRoute(route: String, argTypes: Array<TypeInfo>, returnType: TypeInfo): Bool {
        let qualifiedRoute = Aspects.qualifiedRoute(route, argTypes)
        for (bm in allAspects.keys()) {
            match (bm.get()) {
                case x: Aspect =>
                    let aspectType = TypeInfo.of(x)
                    for (annotation in aspectType.annotations where annotation is AspectRoute) {
                        let qualifiedFunc = "${qualifiedRoute}:${returnType}"
                        let matched = (annotation as AspectRoute).getOrThrow().matched(qualifiedFunc)
                        if (matched) {
                            return true
                        }
                    }
                case _ => throw UnreachableException()
            }
        }
        false
    }
    /**
     * route 是module_name.package_name.TypeName.funcName，TypeName包含泛型参数
     */
    public static func proceed(route: String, args: Array<Any>, argTypes: Array<TypeInfo>, returnType: TypeInfo, fn: () -> Any): Any {
        let qualifiedRoute = Aspects.qualifiedRoute(route, argTypes)
        let aspectFunc = if (let Some(aspectFn) <- routeAspectsMap.get(qualifiedRoute)) {
            aspectFn
        } else {
            synchronized(mutex) {
                if (let Some(aspectFn) <- routeAspectsMap.get(qualifiedRoute)) {
                    aspectFn
                } else {
                    var aspectFn = None<(Array<Any>, () -> Any) -> Any>
                    let aspectList = ArrayList<BeanManager>()
                    for (bm in allAspects.keys()) {
                        match (bm.get()) {
                            case x: Aspect =>
                                let aspectType = TypeInfo.of(x)
                                for (annotation in aspectType.annotations where annotation is AspectRoute) {
                                    let qualifiedFunc = "${qualifiedRoute}:${returnType}"
                                    let matched = (annotation as AspectRoute).getOrThrow().matched(qualifiedFunc)
                                    if (matched) {
                                        aspectList.add(bm)
                                    }
                                }
                            case _ => throw UnreachableException()
                        }
                    }
                    var i = aspectList.size
                    while (i >= 0) {
                        let bm = aspectList[i]
                        aspectFn = match (aspectFn) {
                            case Some(fn) => {
                                args, actualFn => match (bm.get()) {
                                    case x: Aspect => fn(args) {
                                        x.proceed(route, args, actualFn)
                                    }
                                    case _ => throw UnreachableException()
                                }
                            }
                            case _ => {
                                args, actualFn => match (bm.get()) {
                                    case x: Aspect => x.proceed(route, args, actualFn)
                                    case _ => throw UnreachableException()
                                }
                            }
                        }
                        i--
                    }
                    let f = match (aspectFn) {
                        case Some(f) => f
                        case _ => {a: Array<Any>, f: () -> Any => f()}
                    }
                    routeAspectsMap[route] = f
                    f
                }
            }
        }
        aspectFunc(args, fn)
    }
}
