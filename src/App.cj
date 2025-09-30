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
package fountain

import std.collection.{HashMap, HashSet, Map}
import std.convert.*
import std.env.{getWorkingDirectory, getVariables, getCommand}
import std.fs.*
import std.io.{StringReader, SeekPosition}
import std.process.*
import std.reflect.PackageInfo
import std.regex.Regex
import std.time.DateTime
import fountain.base.{OS, StringGenerator, ExtendString}
import fountain.bean.BeanFactory
import fountain.mvc.MVCStarter
import fountain.ticktock.Ticktock
import f_base.UnsafeBytes

internal const BANNER = #'
  _____                    __         .__
_/ ____\____  __ __  _____/  |______  |__| ____
\   __\/  _ \|  |  \/    \   __\__  \ |  |/    \
 |  | (  <_> )  |  /   |  \  |  / __ \|  |   |  \
 |__|  \____/|____/|___|  /__| (____  /__|___|  /
                        \/          \/        \/'#
/**
 * App不会发生传参赋值，用命令行参数实例化后只调用boot函数。所以用struct比较合适，不会占用堆空间。
 */
public struct App {
    private static const APP_VERSION_MODULE_SUFFIX = '_App__vErsIOn___Impl____'
    private let starts: DateTime = DateTime.now()
    private let args: Array<String>
    private let idx: Int64
    private let path: Path
    private let ext: String
    private let libPathName: String
    private let delim: String

    public App(args: Array<String>, 
               appHomeIsWorkingPath!: Bool = true, 
               private let dynamic!: Bool = true, 
               private let name!: String = '') {
        this.args = args
        var idx = 0
        for (i in 1..args.size where !args[i].startsWith("--dylibPattern=")) {
            idx = i
            break
        }
        this.idx = idx + 1
        let path = if ((idx >= 1 && !(args[0] == 'restart' || args[0] == 'shutdown' || args[0] == 'rerun')) || args[0] == 'install') {
            Path(args[1])
        } else if (idx >= 2 && !(args[0] == 'restart' || args[0] == 'shutdown' || args[0] == 'rerun')) {
            Path(args[2])
        } else if (appHomeIsWorkingPath || args[0] == 'cleanUpdate' || args[0] == 'build' || args[0] == 'count') {
            getWorkingDirectory()
        } else {
            let p = canonicalize(Path(getCommand()))
            if (p.parent.fileName == 'bin') {
                p.parent.parent
            } else {
                p.parent
            }
        }
        if(!exists(path)){
            Directory.create(path)
        }
        this.path = canonicalize(path)
        (ext, libPathName, delim) = match (OS.current) {
            case Windows => (".dll", 'Path', ';')
            case macOS => (".dylib", 'DYLD_FALLBACK_LIBRARY_PATH', ':')
            case _ => (".so", 'LD_LIBRARY_PATH', ':')
        }
    }
    private func convertArgs(first: String){
        match (this.args[0]) {
            case x where x == first => Array<String>(args.size - 1) {
                i => if (i == 0) {
                    x.replace('re', '')
                } else {
                    args[i + 1]
                }
            }
            case _ => args
        }
    }
    private func start(): Int64 {
        let libSet = HashSet<String>()
        let env = HashMap<String, String>(getVariables())
        let ldlibPath = StringGenerator(env.get(libPathName) ?? '')
        func genLibPath(path: Path): Unit {
            Directory.walk(path) {
                fi =>
                if (fi.isDirectory()) {
                    genLibPath(fi.path)
                } else if (fi.path.fileName.endsWith(ext) && let libpath <- fi.path.parent.toString() &&
                    !libSet.contains(libpath)) {
                    libSet.add(libpath)
                    if (ldlibPath.size > 0) {
                        ldlibPath.append(delim)
                    }
                    ldlibPath.append(libpath)
                }
                true
            }
        }
        genLibPath(path)
        env[libPathName] = ldlibPath.toString()
        start(convertArgs('restart'), env)
    }
    private func start(args: Array<String>, env: Map<String, String>) {
        args[0] = 'run'
        execute(getCommand(), args, workingDirectory: path, environment: env)
    }
    private func run(): Int64 {
        run(args)
    }
    private func run(args: Array<String>): Int64{
        func extractPattern() {
            if (idx > 0) {
                let p = args[idx]['--dylibPattern='.size..]
                if ((p.startsWith("'") && p.endsWith("'")) || (p.startsWith('"') && p.endsWith('"'))) {
                    return p[1..p.size - 1]
                }
                p
            } else {
                ''
            }
        }
        func load(path: Path, pattern: Regex): Unit {
            Directory.walk(path) {
                fi =>
                if (fi.isDirectory()) {
                    load(fi.path, pattern)
                } else if (fi.path.fileName.endsWith(ext) && pattern.matches(fi.path.fileNameWithoutExtension)) {
                    PackageInfo.load(fi.path.toString().replace(ext, ''))
                }
                true
            }
        }
        if(dynamic){
            load(path, Regex('^lib.*(${extractPattern()}|.+${APP_VERSION_MODULE_SUFFIX}).*$'))
        }
        BeanFactory.instance.afterRegistered()
        Ticktock.getInstance(anyway: false)
        let mvc = MVCStarter.initialize()
        //orm 需要应用开发者显式注册数据库驱动及初始化事务切面，
        //执行load函数时一定会加载初始化orm的动态链接库从而完成初始化
        //其它模块是工具API没有专门的初始化API
        let app = this.app
        let end = DateTime.now()
        let appVersion = if (let Some(v) <- BeanFactory.instance.getFirst<AppVersion>()) {
            v
        } else {
            DummyAppVersion.instance
        }
        let appver = if(appVersion.version.isEmpty()){
            ''
        }else{
            '(${appVersion.version})'
        }
        println(appVersion.banner)//banner不能是多行插值串，因为有\_，编译器认为是错误的转义符。使用\\_就不好看了
        println('${app}${appver} is started by fountain(1.0.0) in ${end - starts} on ${end}')
        mvc?.start()
        0
    }
    private func version(){
        println('fountain(1.0.0)')
        0
    }
    private prop app: String {
        get() {
            if (name.size > 0) {
                name
            } else if (path.toString().endsWith('/target/release')) {
                path.parent.parent.fileName
            } else if (path.toString().endsWith('/release')) {
                path.parent.fileName
            } else {
                path.fileName
            }
        }
    }
    private func pid() {
        Int64.parse(args[1])
    }
    private func shutdown(): Int64 {
        //每个模块都注册了atExit，所以发送退出命令的时候都会执行atExit
        let pid = this.pid()
        shutdown(pid)
    }
    private func shutdown(pid: Int64): Int64 {
        shutdown(pid, findProcess(pid))
    }
    private func shutdown(pid: Int64, process: Process): Int64 {
        process.terminate()
        while (true) {
            try {
                findProcess(pid)
            } catch (_: ProcessException) {
                break
            }
        }
        0
    }
    private func restart(): Int64 {
        let pid = this.pid()
        let process = findProcess(pid)
        shutdown(pid, process)
        start()
    }
    private func rerun(): Int64 {
        shutdown()
        run(convertArgs('rerun'))
    }
    private func directories(){
        if(path == getWorkingDirectory()){
            let p = Path('${path}/${path.fileName}')
            if(!exists(p)){
                Directory.create(p, recursive: true)
            }
            (path, p)
        }else{
            (getWorkingDirectory(), path)
        }
    }
    private func entireFileText(path: Path){
        String.fromUtf8(File.readFrom(path))
    }
    private func appendToml(dir: Path): Unit {
        let toml = '''

[profile.build]
  incremental = true
[profile.build.combined]
  ${dir.fileName} = "dynamic"

[target]
[target.x86_64-unknown-linux-gnu]
  compile-option = "-O2 --lto=full --dy-std"
  override-compile-option = "-O2 --lto=full --dy-std"
[target.x86_64-unknown-linux-gnu.bin-dependencies]
  path-option = ["\${CANGJIE_STDX_DYNAMIC_PATH}", "\${CANGJIE_FOUNTAIN_LIBS}"]
[target.aarch64-unknown-linux-gnu]
  compile-option = "-O2 --lto=full --dy-std"
  override-compile-option = "-O2 --lto=full --dy-std"
[target.aarch64-unknown-linux-gnu.bin-dependencies]
  path-option = ["\${CANGJIE_STDX_DYNAMIC_PATH}", "\${CANGJIE_FOUNTAIN_LIBS}"]
[target.x86_64-w64-mingw32]
  compile-option = "-O2 --dy-std"
  override-compile-option = "-O2 --dy-std"
[target.x86_64-w64-mingw32.bin-dependencies]
  path-option = ["\${CANGJIE_STDX_DYNAMIC_PATH}", "\${CANGJIE_FOUNTAIN_LIBS}"]
[target.x86_64-apple-darwin]
  compile-option = "-O2 --dy-std"
  override-compile-option = "-O2 --dy-std"
[target.x86_64-apple-darwin.bin-dependencies]
  path-option = ["\${CANGJIE_STDX_DYNAMIC_PATH}", "\${CANGJIE_FOUNTAIN_LIBS}"]
[target.aarch64-apple-darwin]
  compile-option = "-O2 --dy-std"
  override-compile-option = "-O2 --dy-std"
[target.aarch64-apple-darwin.bin-dependencies]
  path-option = ["\${CANGJIE_STDX_DYNAMIC_PATH}", "\${CANGJIE_FOUNTAIN_LIBS}"]
'''
        let tomlPath = dir.join('cjpm.toml')
        var content = entireFileText(tomlPath).replace('[workspace]', '''
[workspace]
  version = "1.0.0"
'''
).replace('[dependencies]', '''
[dependencies]
  fountain = {git = "https://gitcode.com/Cangjie-SIG/fountain.git"}
'''
)
        content = '''
${content}

${toml}
'''
        File.writeTo(tomlPath, content.unsafeBytes())
    }
    private func doInit(arg: String): Int64 {
        let code = execute('cjpm', ['init', arg], workingDirectory: getWorkingDirectory())
        code
    }
    private func initWorkspace(): Int64 {
        let code = doInit('--workspace')
        if(code != 0){
            return code
        }
        appendToml(getWorkingDirectory())
        code
    }
    private func initDynamic(): Int64 {
        doInit('--type=dynamic')
    }
    private func cleanUpdate(): Int64 {
        let (workingDir, targetDir) = directories()
        println('fboot cleanUpdate ${workingDir} --target-dir=${targetDir}')
        let code = execute('cjpm', ['clean', '--target-dir=${targetDir}'], workingDirectory: workingDir)
        if(code != 0){
            return code
        }
        removeIfExists('${workingDir}/cjpm.lock')
        execute('cjpm', ['update'], workingDirectory: workingDir)
    }
    private func extract(dir: Path, extractName!: Bool = false){
        var version = ''
        var name = ''
        try(file = File(dir.join('cjpm.toml'), Read)){
            let reader = StringReader(file)
            for (line in reader.lines()) {
                let l = line.trimAscii()
                if (l.startsWith('version') && let Some(idx) <- l.indexOf('"')) {
                    version = l[idx + 1 .. l.size - 1]
                } else if (l.startsWith('name') && let Some(idx) <- l.indexOf('"')) {
                    name = l[idx + 1 .. l.size - 1]
                }
            }
        }
        (version, if (name.isEmpty()) {
            dir.fileName
        } else {
            name
        })
    }
    private func banner(): String {
        let path = '${getWorkingDirectory()}/banner.txt'
        var banner_ = ''
        if(exists(path)) {
            try(file = File(path, Read)){
                banner_ = StringReader(file).readToEnd()
            }
        }
        if(!banner_.isEmpty()){
            return banner_
        }
        BANNER
    }
    private func replaceVersion(): Int64 {
        println('fboot replaceVersion ${path}')
        let workingDir = getWorkingDirectory()
        let (fountainPath, fbootPath) = 
        match(workingDir.fileName) {
            case 'fountain' => 
                (workingDir, workingDir.join('fboot'))
            case 'fboot' =>
                (workingDir.parent, workingDir)
            case _ => throw BootException('working directory ${workingDir} is not path of project fountain')
        }
        var version = extract(fountainPath)[0]
        if(!version.isEmpty()) {
            let appPath = fountainPath.join('src/App.cj')
            let code = entireFileText(appPath)
            File.writeTo(appPath, Regex(#'fountain\((\d+\.)+\d+\)'#).replaceAll(code, 'fountain(${version})').unsafeBytes())
        }
        0
    }
    private func appVersionModuleName(name: String): String {
        '${name}${APP_VERSION_MODULE_SUFFIX}'
    }
    private func genCode(name: String, version: String) {
'''
package ${appVersionModuleName(name)}
import fountain.AppVersion
import fountain.bean.macros.Bean
import fountain.bean.*
@Bean
public class ${name}_AppVersionImpl <: AppVersion {
    public prop version: String {
        get() {
            '${version}'
        }
    }
    public prop banner: String {
        get() {
            #'${banner()}'#
        }
    }
}
'''
    }
    private func build(): Int64 {
        println('fboot build 此命令专门用来编译使用fountain开发的应用项目')
        let (workingDir, targetDir) = directories()
        println('fboot build ${workingDir} --target-dir=${targetDir}')
        let versionModuleName = appVersionModuleName(workingDir.fileName)
        let versionModuleDir = workingDir.join(versionModuleName)
        Directory.create(versionModuleDir, recursive: true)
        let execode = execute('cjpm', ['init', '--type=dynamic'], workingDirectory: versionModuleDir)
        let tomlPath = workingDir.join('cjpm.toml')
        var toml = ''
        try {
            if(execode != 0) {
                return execode
            }
            var (version, name) = extract(workingDir, extractName: true)
            let appVersionPath = versionModuleDir.join('src/${name}_AppVersionImpl.cj')
            File.writeTo(appVersionPath, genCode(workingDir.fileName, version).unsafeBytes())
            toml = entireFileText(tomlPath)
            if(let Some(membersIdx) <- toml.indexOf('members') && let Some(idx) <- toml.indexOf(']', membersIdx)) {
                let members = toml[membersIdx ..= idx]
                let newMembers = members.replaceLast(']', ', "./${versionModuleName}"]')
                let newtoml = toml.replaceFirst(members, newMembers)
                File.writeTo(tomlPath, newtoml.unsafeBytes())
            }
            execute('cjpm', ['build', '--target-dir=${targetDir}'], workingDirectory: workingDir)
        } finally {
            File.writeTo(tomlPath, toml.unsafeBytes())
            removeIfExists(versionModuleDir, recursive: true)
        }
    }
    private func count(dir: Path, counter: CodeCounter, ext: String, ignore: Bool): Unit {
        Directory.walk(dir){fi =>
            if(fi.isDirectory()){
                count(fi.path, counter, ext, ignore)
            } else if(fi.path.fileName.endsWith(ext)){
                counter.files++
                try(f = File(fi.path, Read)){
                    let r = StringReader(f)
                    for(line in r.lines()){
                        let l = line.trimAscii()
                        if(l.isEmpty() || (ignore && '{[(.)]}'.contains(l))){
                            continue
                        }
                        counter.lines++
                    }
                }
            }
            true
        }
    }
    private func count(): Int64 {
        var ext = 'cj'
        var ignore = false
        for(arg in args[1 ..]){
            if(arg.startsWith('--ext=')){
                ext = arg['--ext='.size ..]
            }else if(arg == '--ignore'){
                ignore = true
            }
        }
        println('path=${path};ext=${ext};ignore=${ignore}')
        let counter = CodeCounter()
        let start = DateTime.now()
        count(path, counter, ext, ignore)
        println('files: ${counter.files}, lines: ${counter.lines}, consumes: ${DateTime.now() - start}')
        0
    }
    public func boot(): Int64 {
        match (args[0]) {
            case 'start' => start()
            case 'restart' => restart()
            case 'run' => run()
            case 'shutdown' => shutdown()
            case 'rerun' => rerun()
            case 'dynamic' => initDynamic()
            case 'workspace' => initWorkspace()
            case 'cleanUpdate' => cleanUpdate()
            case 'build' => build()
            case 'count' => count()
            case 'replaceVersion' => replaceVersion()
            case 'version' => version()
            case _ => throw BootException(
                'first command arg must be run|start|shutdown|restart|dynamic|workspace|cleanUpdate|build|count|replaceVersion|version, but current args are ${args}')
        }
    }
}
private class CodeCounter{
    var files = 0
    var lines = 0
}