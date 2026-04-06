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
        entireFile(path).lines().map{l => l.trimAscii()}
    }
    private func lines(path: String): Iterator<String> {
        path |> canonicalize |> lines
    }
    /**
     * 执行
     */
    public func exec(args: Array<String>): Int64 {
        if(args.size >= 1){
            let reg = Regex(#'^\d+.\d+.\d+$'#)
            if(reg.matches(args[0])){
                this.version = args[0]
            }else{
                throw Exception('version must be specified and version must be like x.y.z, command line must be like fboot pub <x.y.z> [--skip-lint] [--skip-test]')
            }
            if(args.size > 1 && args[1].startsWith('--')){
                bundleArgs = args[1 ..]
            }
        }else{
            throw Exception('version must be specified and command line must be like fboot pub <x.y.z> [--skip-lint] [--skip-test]')
        }
        let lines = this.lines('./modules')
        let includes = HashSet<String>()
        let excludes = HashSet<String>()
        var including = false
        for(line in lines where line != ''){
            if(line == '[include]'){
                including = true
                continue
            }
            if(including){
                includes.add(line)
            }else{
                excludes.add(line)
            }
        }
        if(includes.size > 0 && excludes.size > 0){
            throw Exception('[include] and [exclude] cannot be used at the same time')
        }else if(includes.size > 0){
            publishIncludes(includes)
        }else if(excludes.size > 0){
            publishExcludes(excludes)
        }else{
            publishAll()
        }
        0
    }
    private func allModules(path: Path, modules: HashMap<String, Path>): Unit{
        Directory.walk(path){fi => 
            if(fi.isDirectory()){
                if(exists(fi.path.join('./cjpm.toml'))){
                    modules[fi.path.fileName] = fi.path |> canonicalize
                }
                allModules(fi.path, modules)
            }
            true
        }
    }
    private func allModules(): HashMap<String, Path> {
        let modules = HashMap<String, Path>()
        allModules(canonicalize('./'), modules)
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
            let currentModuleInfos = HashMap<String, ModuleInfo>()
            let cjpmLines = modules[m].join('cjpm.toml') |> this.lines
            var afterDependency = false
            for(line in cjpmLines){
                if(line == '[workspace]'){
                    break
                }else if(Regex(#'^\s*"?organization"?\s*=\s*".+"\s*$'#).matches(line)){
                    let info = if(let Some(info) <- currentModuleInfos.get(m)){
                        info
                    }else{
                        let info = ModuleInfo()
                        currentModuleInfos[m] = info
                        info
                    }
                    info.organization = line.split('=')[1].trimAscii().replace('"', '')
                    getStdOut().writeln('organization: ${info.organization}')
                }else if(line == '[dependencies]'){
                    afterDependency = true
                    continue
                }else if (line.startsWith('[')){
                    break
                }else if(afterDependency){
                    let kv = line.split('=')
                    var dep = kv[0].trimAscii()
                    if(dep.startsWith('"') && dep.endsWith('"')){
                        dep = dep[1 .. dep.size - 1]
                    }
                    if(let Some(index) <- dep.indexOf('::')){
                        dep = dep[index ..]
                    }
                    if(!modules.contains(dep)){
                        continue
                    }
                    if(!includes.contains(dep)){
                        throw Exception('module ${m} is to publish, but it dependences a module ${dep} which is not contained in [include]')
                    }
                    if(let Some(info) <- currentModuleInfos.get(dep)){
                        info.dependenced++
                    }else{
                        let info = ModuleInfo()
                        info.dependenced = 1
                        currentModuleInfos[dep] = info
                    }//被依赖模块的依赖数+1
                    if(let Some(info) <- currentModuleInfos.get(m)){//添加当前模块依赖的模块列表
                        info
                    }else{
                        let info = ModuleInfo()
                        currentModuleInfos[m] = info
                        info
                    }.dependencing.add(dep)
                    getStdOut().writeln('dependency: ${m} is dependencing ${dep}')
                }
            }
            moduleInfos.add(all: currentModuleInfos)
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
    
    private func replaceDependencies(path: Path, organization: String, all: HashMap<String, Path>){
        let cjpmPath = path.join('cjpm.toml')
        copy(cjpmPath, to: path.join('cjpm.toml.bak'), overwrite: false)
        let regexGen = StringGenerator()
        for(m in all.keys()){
            if(regexGen.size > 0){
                regexGen.append('|')
            }
            regexGen.append(m)
        }
        let moduleRegex = Regex('(${organization}::)?(${regexGen})\\s*=\\s*\\{.*(path|git)\\s*=\\s*".+"\\.*\\}')
        let replaced = StringGenerator()
        for(line in cjpmPath |> this.lines){
            let replacedLine = if(moduleRegex.matches(line)){
                Regex('\\{.*(path|git)\\s*=\\s*".+"\\.*\\}').replaceAll(line, '"${version}"')
            }else{
                line
            }
            getStdOut().writeln('dependencing_replaced: ${line} -> ${replacedLine}')
            replaced.appendUnixNewLine(replacedLine)
        }
        File.writeTo(cjpmPath, replaced.toString().unsafeBytes())
    }
    private func checkPublished(organization: String, module: String): Unit {
        let url = 'https://pkg.cangjie-lang.cn/v1/artifact/getPackageMetadata?group=${organization}&moduleName=${module}&version=${version}'
        getStdOut().writeln('checking published ${organization}::${module} ...; url: ${url}')
        var a = 0
        var b = 1
        var waited = 0
        while(true){
            sleep(Duration.second * b)
            waited += b
            let tmp = a + b
            a = b
            b = tmp
            let client = ClientBuilder().build()
            try{
                let resp = client.get(url)
                let body = resp.body
                let bodySize = resp.bodySize ?? 0
                if(bodySize == 0){
                    continue
                }
                let buf = Array<Byte>(bodySize, repeat: 0)
                body.read(buf)
                let json = (String.fromUtf8(buf) |> JsonValue.fromStr).asObject()
                let code = (json.get('code')?.asInt().getValue()) ?? 0
                let msg = (json.get('msg')?.asString().getValue()) ?? ''
                getStdOut().writeln('check url respse - code:${code}, msg:${msg}')
                if(code == 200 && msg == 'success'){
                    break
                }
            }catch(_){
            }finally{
                client.close()
            }
            getStdOut().writeln('waiting for ${module} to be published... waited ${waited}s, to check again after ${b}s')
        }
    }
    private func publish(includes: HashSet<String>, all: HashMap<String, Path>): Unit {
        let pout = getStdOut()
        let moduleInfos = extractCjpm(includes, all)
        let q = populateQueue(includes)
        while(let Some(m) <- q.remove()){
            if(let Some(info) <- moduleInfos.get(m)){
                func pub(){
                    for(d in info.dependencing where moduleInfos.contains(d)){
                        q.add(m)
                        return
                    }
                    getStdOut().writeln('publishing ${m} ...')
                    let path = all[m]
                    replaceDependencies(path, info.organization, all)
                    try{
                        var success = cjpm(path, 'cjpm bundle success', bundleArgs)
                        if(success){
                            success = cjpm(path, 'cjpm publish success', [])
                        }
                        if(!success){
                            throw Exception('to publish ${m} failed')
                        }
                    }finally{
                        let cjpmBakPath = path.join('cjpm.toml.bak')
                        if(exists(cjpmBakPath)){
                            rename(cjpmBakPath, to: path.join('cjpm.toml'), overwrite: true)
                        }
                    }
                    if(info.dependenced > 0){
                        checkPublished(info.organization, m)
                    }
                    moduleInfos.remove(m)
                }
                pub()
            }else{
                throw Exception('unreachable if no bug')
            }
        }
    }
    private func cjpm(path: Path, successLine: String, args: Array<String>): Bool {
        getStdOut().writeln('running cjpm ${args.iterator().intersperse(' ').fold(StringGenerator()){g, s => g.append(s)}} in ${path} ...')
        let p = launch('cjpm', args, workingDirectory: path, stdOut: Pipe)
        let cmdout = StringReader(p.stdOut)
        var success = false
        for(line in cmdout.lines()){
            getStdOut().writeln(line)
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