/*
Copyright (c) 2026 WuJingrun（吴京润）

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
package fountain::f_app

import std.random.Random
public class PublishCommand <: SubCommand {
    static init(){
        SubCommandMediator.register(PublishCommand())
    }
    private init(){}
    /**
     * 子命令名，即fboot <subcommand> 
     */
    public prop command: String {
        get(){
            'pub'
        }
    }
    private var version = ''
    private var bundleArgs = Array<String>()

    private func entireFile(path: String): String {
        entireFile(Path(path))
    }
    private func entireFile(path: Path): String {
        if(exists(path)){
            path |> File.readFrom |> String.fromUtf8
        }else{
            ''
        }
    }
    private func lines(path: Path): Iterator<String> {
        println('reading file ${path}...')
        entireFile(path).lines().filter{line => if(let l <- line.trimAscii()){
            l.size > 0 && !l.startsWith('#')
        }else{
            false
        }}
    }
    private func lines(path: String): Iterator<String> {
        path |> canonicalize |> lines
    }
    /**
     * 执行
     */
    public func exec(args: Array<String>): Int64 {
        let start = MonoTime.now()
        if(args.size >= 1){
            let reg = Regex(#'^\d+.\d+.\d+$'#)
            if(reg.matches(args[0])){
                this.version = args[0]
            }else{
                throw Exception('version must be specified and version must be like x.y.z, command line must be like fboot pub <x.y.z> [--skip-lint] [--skip-test]')
            }
            bundleArgs = if(args.size > 1 && args[1].startsWith('--')){
                Array<String>(args.size){i => 
                    if(i == 0){
                        'bundle'
                    }else{
                        args[i]
                    }
                }
            }else{
                ['bundle']
            }
        }else{
            throw Exception('version must be specified and command line must be like fboot pub <x.y.z> [--skip-lint] [--skip-test]')
        }
        let lines = this.lines('./.modules')
        let includes = HashSet<String>()
        let excludes = HashSet<String>()
        const INCLUDING = 1
        const EXCLUDING = 2
        const DETENTION = 3
        var section = 0
        for (line in lines where line != '') {
            if (line == '[include]') {
                section = INCLUDING
                continue
            } else if (line == '[exclude]') {
                section = EXCLUDING
                continue
            } else if (line == '[detention]') {
                section = DETENTION
                continue
            }
            let module = if(line == '.'){
                canonicalize('./').fileName
            }else{
                line
            }
            if(section == INCLUDING){
                includes.add(module)
            }else if (section == EXCLUDING) {
                excludes.add(module)
            }
        }
        println('including modules: ${includes}')
        println('excluding modules: ${excludes}')
        if(includes.size > 0 && excludes.size > 0){
            throw Exception('[include] and [exclude] cannot be used at the same time')
        }else if(includes.size > 0){
            publishIncludes(includes)
        }else if(excludes.size > 0){
            publishExcludes(excludes)
        }else{
            publishAll()
        }
        println('publish completed in ${MonoTime.now() - start}')
        0
    }
    private func allModules(path: Path, modules: HashMap<String, Path>): Unit{
        Directory.walk(path){fi => 
            if(fi.isDirectory()){
                if(exists(fi.path.join('cjpm.toml'))){
                    modules[fi.path.fileName] = fi.path |> canonicalize
                }
                allModules(fi.path, modules)
            }
            true
        }
    }
    private func allModules(): HashMap<String, Path> {
        let modules = HashMap<String, Path>()
        let path = canonicalize('./')
        if(exists(path.join('cjpm.toml'))){
            modules[path.fileName] = path
        }
        allModules(path, modules)
        modules
    }
    private func check(modules: HashSet<String>, all: HashMap<String, Path>): Unit {
        for(m in modules where !all.contains(m)){
            throw Exception('module ${m} which is in [include] does not exists')
        }
    }
    private func extractCjpm(includes: HashSet<String>, modules: HashMap<String, Path>): HashMap<String, ModuleInfo> {
        let moduleInfos = HashMap<String, ModuleInfo>()
        for(m in includes){
            let cjpmLines = modules[m].join('cjpm.toml') |> this.lines
            var afterPublishing = false
            for(line in cjpmLines){
                println('extracting ${line} ...')
                if(line == '[workspace]'){
                    break
                }else if(Regex(#'^\s*"?organization"?\s*=\s*".+"\s*$'#).matches(line)){
                    let info = if(let Some(info) <- moduleInfos.get(m)){
                        info
                    }else{
                        let info = ModuleInfo()
                        moduleInfos[m] = info
                        info
                    }
                    info.organization = line.split('=')[1].trimAscii().replace('"', '').trimAscii()
                    if(info.organization.isEmpty()){
                        info.organization = 'default'
                    }
                    println('organization: ${info.organization}')
                }else if(line == '[dependencies]'){
                    afterPublishing = true
                }else if (afterPublishing && line.startsWith('[')){
                    afterPublishing = false
                }else if(afterPublishing){
                    let kv = line.split('=')
                    var dep = kv[0].trimAscii()
                    if(dep.startsWith('"') && dep.endsWith('"')){
                        dep = dep[1 .. dep.size - 1]
                    }
                    if(let Some(index) <- dep.indexOf('::')){
                        dep = dep[index + 2 ..]
                    }
                    if(!modules.contains(dep)){
                        continue
                    }
                    if(!includes.contains(dep)){
                        throw Exception('module ${m} is to publish, but it dependences a module ${dep} which is not contained in [include]')
                    }
                    if(let Some(info) <- moduleInfos.get(dep)){
                        info.dependenced++
                    }else{
                        let info = ModuleInfo()
                        info.dependenced = 1
                        moduleInfos[dep] = info
                    }//被依赖模块的依赖数+1
                    if(m == dep){
                        throw Exception('module ${m} is to be published, but it depends on itself')
                    }
                    if(let Some(info) <- moduleInfos.get(m)){//添加当前模块依赖的模块列表
                        info
                    }else{
                        let info = ModuleInfo()
                        moduleInfos[m] = info
                        info
                    }.dependencing.add(dep)
                    println('dependency: ${m} depends on ${dep}')
                }
            }
        }
        moduleInfos
    }
    private func populateQueue(includes: HashSet<String>): ArrayQueue<String> {
        let q = ArrayQueue<String>(includes.size)
        for(m in includes){
            q.add(m)
        }
        q
    }
    
    private func replaceDependencies(path: Path, organization: String, all: HashMap<String, Path>, dry: Bool){
        let cjpmPath = path.join('cjpm.toml')
        var cjpmContent = String.fromUtf8(File.readFrom(cjpmPath))
        cjpmContent = Regex(#'\s+version\s*=\s*"(.+)"'#).replace(cjpmContent, '\n  version = "${version}"')
        println('cjpm.toml: ${cjpmPath}')
        println(cjpmContent)
        println('========================================')
        if(!dry){
            File.writeTo(cjpmPath, cjpmContent.unsafeBytes())
            copy(cjpmPath, to: path.join('cjpm.toml.bak'), overwrite: false)
        }
        let regexGen = StringGenerator()
        for(m in all.keys()){
            if(regexGen.size > 0){
                regexGen.append('|')
            }
            regexGen.append(m)
        }
        let moduleRegex = Regex('^\\s*"?(${organization}::)?(${regexGen})"?\\s*=\\s*\\{.*(path|git)\\s*=\\s*".+".*\\}\\s*$')
        let replaced = StringGenerator()
        for(line in this.lines(cjpmPath)){
            let replacedLine = if(moduleRegex.matches(line)){
                let depreg = Regex('\\{.*(path|git)\\s*=\\s*".+".*\\}')
                depreg.replaceAll(line, '"${version}"')
            }else{
                line
            }
            println('dependencing_replaced: ${line} -> ${replacedLine}')
            replaced.appendUnixNewLine(replacedLine)
        }
        println('dependencing_replaced: ${cjpmPath}')
        println(replaced)
        println('=============================================')
        if(!dry){
            File.writeTo(cjpmPath, replaced.toString().unsafeBytes())
        }
    }
    private func checkLoop<T>(action: String, fn: () -> ?T): T {
        var a = 0
        var b = 1
        var waited = 0
        var result = None<T>
        while(result.isNone()){
            let next = Random().nextInt64(b) + 1
            println('waiting for ${action} waited ${Duration.second * waited}, to check again after ${Duration.second * next} from ${DateTime.now()}')
            sleep(Duration.second * next)
            waited += next
            let tmp = a + b
            a = b
            b = tmp
            result = fn()
        }
        result.getOrThrow()
    }
    private func checkPublished(organization: String, module: String, once: Bool): Bool {
        let url = 'https://pkg.cangjie-lang.cn/v1/artifact/getPackageMetadata?group=${organization}&moduleName=${module}&version=${version}'
        println('checking published ${organization}::${module} ...; url: ${url}; once: ${once}')
        checkLoop<Bool>('${module} to be published...'){
            var tls = TlsClientConfig()
            tls.verifyMode = TrustAll
            let client = ClientBuilder().tlsConfig(tls).build()
            try{
                let resp = client.get(url)
                let body = StringReader(resp.body).readToEnd()
                let json = JsonValue.fromStr(body).asObject()
                let code = (json.get('code')?.asInt().toInt64()) ?? 0
                let msg = (json.get('msg')?.asString().value) ?? ''
                println('check url response - code: ${code}, msg: ${msg}')
                if(code == 200 && msg == 'success'){
                    return true
                }else if(once){
                    return false
                }
            }catch(e: Exception){
                e.printStackTrace()
            }finally{
                client.close()
            }
            None<Bool>
        }
    }
    private func publish(includes: HashSet<String>, all: HashMap<String, Path>): Unit {
        let pout = getStdOut()
        let moduleInfos = extractCjpm(includes, all)
        let q = populateQueue(includes)
        while(let Some(m) <- q.remove()){
            if(let Some(info) <- moduleInfos.get(m)) {
                let path = all[m]
                func pub(dry: Bool){
                    for(d in info.dependencing where moduleInfos.contains(d)){
                        println('to publish ${info.organization}::${m} after ${d}')
                        q.add(m)
                        return
                    }
                    println('publishing ${info.organization}::${m} ...')
                    replaceDependencies(path, info.organization, all, dry)
                    try{
                        cjpm(path, 'cjpm clean success', ['clean'], dry)
                        removeIfExists(path.join('cjpm.lock'))
                        var success = cjpm(path, 'cjpm bundle success', bundleArgs, dry)
                        if(success){
                            success = cjpm(path, 'cjpm publish success', ['publish'], dry)
                        }
                        if(!success){
                            throw Exception('to publish ${m} failed')
                        }
                    }finally{
                        if(!dry){
                            let cjpmBakPath = path.join('cjpm.toml.bak')
                            if(exists(cjpmBakPath)){
                                rename(cjpmBakPath, to: path.join('cjpm.toml'), overwrite: true)
                            }
                        }
                    }
                    if(info.dependenced > 0){
                        checkPublished(info.organization, m, dry)
                    }
                    moduleInfos.remove(m)
                }
                let published = checkPublished(info.organization, m, true)
                checkLoop<Unit>('doing pub...'){
                    try{
                        pub(published)
                        return ()
                    }catch(e: Exception){
                        e.printStackTrace()
                        return None<Unit>
                    }
                }
            }else{
                throw Exception('unreachable if no bug on module ${m}')
            }
        }
    }
    private func cjpm(path: Path, successLine: String, args: Array<String>, dry: Bool): Bool {
        println('running "cjpm ${String.join(args, delimiter: ' ')}" in ${path} ...')
        println('')
        if(dry){
            return true
        }
        let p = launch('cjpm', args, workingDirectory: path, stdOut: Pipe)
        let cmdout = StringReader(p.stdOut)
        var success = false
        for(line in cmdout.lines()){
            println(line)
            if(line == successLine){
                success = true
            }
        }
        success
    }
    private func publishIncludes(includes: HashSet<String>): Unit {
        let all = allModules()
        check(includes, all)
        publish(includes, all)
    }
    private func publishExcludes(excludes: HashSet<String>): Unit {
        let all = allModules()
        let includes = all.keys().iterator().filter{m => !excludes.contains(m)}.fold(HashSet<String>()){set, m => 
            set.add(m)
            set
        }
        check(includes, all)
        publish(includes, all)
    }
    private func publishAll(): Unit {
        let all = allModules()
        publish(HashSet<String>(all.keys()), all)
    }
}

public class ModuleInfo{
    public var dependenced: Int64 = 0//当前模块被依赖的次数
    public var organization: String = 'default'//当前模块的所属组织
    public let dependencing = ArrayList<String>()
}