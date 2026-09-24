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
package fountain::f_io

import fountain::f_base.OS
import fountain::f_regex.*
public import std.fs.*

public interface ExtendPath{
    func copy(to!: String): Unit {
        copy(to: Path(to))
    }
    func copy(to!: Path): Unit{
        copy(to: to, matched: {_ => true})
    }
    func copy(srcPattern: String, to!: String): Unit {
        copy(srcPattern, to: Path(to))
    }
    func copy(srcPattern: String, to!: Path): Unit{
        var pattern = if(OS.current.isWindows){
            var pattern = srcPattern.replace('/', '\\\\')
            pattern = pattern.replace('.', '\\.')
            pattern.replace('*', '.*').replace('.*.*\\\\', '(.+\\\\)*')
            if (pattern.endsWith('\\\\')) {
                pattern = pattern[0 .. pattern.size - 2]
            }
            if(pattern.contains(':')){
                '^${pattern}'
            }else{
                '^.*\\\\${pattern}'
            }
        }else{
            var pattern = srcPattern.replace('.', '\\.')
            pattern = pattern.replace('*', '.*').replace('.*.*/', '(.+/)*')
            if (!pattern.startsWith('/')) {
                pattern = '^/.*/${pattern}'
            }
            if (pattern.endsWith('/')) {
                pattern = pattern[0 .. pattern.size - 1]
            }
            pattern
        }
        pattern = '${pattern}$'
        let regexp = pattern.regex(solid: false)
        copy(to: to, matched: {path => regexp.matches(path.toString())})
    }
    func copy(to!: String, matched!: (Path) -> Bool): Unit {
        copy(to: Path(to), matched: matched)
    }
    func copy(to!: Path, matched!: (Path) -> Bool): Unit
}

extend Path <: ExtendPath {
    private func copyFile(base: Path, origin: Path, src: FileInfo, to: Path): Unit {
        let sub = origin.parent.toString()[base.toString().size..]
        let targetDir = to.join(sub)
        if(!exists(targetDir)){
            Directory.create(targetDir, recursive: true)
        }
        let bytes = File.readFrom(src.path)
        File.writeTo(targetDir.join(origin.fileName), bytes)
    }
    private func copy(base: Path, to!: Path, matched!: (Path) -> Bool): Unit {
        if (!FileInfo(to).isDirectory()) {
            throw FSException("target path ${to} must be a directory")
        }
        let fi = FileInfo(this)
        if(fi.isDirectory()){
            Directory.walk(this){fi =>
                fi.path.copy(base, to: to, matched: matched)
                true
            }
        }else if(fi.isRegular() && matched(fi.path)){
            copyFile(base, fi.path, fi, to)
        }else if(fi.isSymbolicLink()){
            let symbolicTarget = SymbolicLink.readFrom(this, recursive: true)
            let symbolicFI = FileInfo(symbolicTarget)
            if(symbolicFI.isRegular() && matched(fi.path)){
                copyFile(base, fi.path, symbolicFI, to)
            }else{
                symbolicTarget.copy(symbolicTarget, to: to, matched: matched)
            }
        }
    }
    public func copy(to!: Path, matched!: (Path) -> Bool): Unit {
        copy(canonicalize(this), to: canonicalize(to), matched: matched)
    }
}