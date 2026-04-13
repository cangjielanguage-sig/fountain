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

internal func confirmTargetPath(args: Array<String>){
    let path = if(args.size > 1){
        Path(args[1])
    }else{
        getWorkingDirectory()
    }
    if(!exists(path)){
        Directory.create(path)
    }
    canonicalize(path)
}
internal func load(args: Array<String>, dynamic: Bool): (Path, ArrayList<() -> Unit>) {
    let path = confirmTargetPath(args)
    let (ext, libPathName, delim) = match (OS.current) {
        case Windows => (".dll", 'Path', ';')
        case macOS => (".dylib", 'DYLD_FALLBACK_LIBRARY_PATH', ':')
        case _ => (".so", 'LD_LIBRARY_PATH', ':')
    }
    func extractPattern() {
        var idx = 0
        for (i in 1..args.size where !args[i].startsWith("--dylibPattern=")) {
            idx = i
            break
        }
        idx++
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
            log.debug{'scanning: ${fi.path}'}
            if (fi.isDirectory()) {
                load(fi.path, pattern)
            } else if (fi.path.fileName.endsWith(ext) && pattern.matches(fi.path.fileNameWithoutExtension)) {
                log.debug{"loading: ${fi.path}"}
                PackageInfo.load(fi.path.toString().replace(ext, ''))
            }
            true
        }
    }
    if(dynamic){
        load(path, Regex('^lib.*(${extractPattern()}|.+${APP_STATIC_RESOURCE_SUFFIX}).*$'))
    }
    let starters = InitializerCollection.initialize()
    (path, starters)
}