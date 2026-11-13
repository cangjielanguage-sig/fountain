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
package fountain::fprobe.custom

import std.collection.ArrayList
import std.fs.*
import std.sync.AtomicInt64
import std.time.DateTime
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_data.JsonObject
import fountain::f_probe.{ProbeAgent, ProbeErrorCode, ProbeException, ProbeRegistry}

private let tempCounter = AtomicInt64(0)

private func tempDir(label: String): String {
    let id = tempCounter.fetchAdd(1)
    let stamp = DateTime.now().toUnixTimeStamp().toMilliseconds()
    let dir = '/tmp/fprobe-custom-${label}-${stamp}-${id}'
    Directory.create(Path(dir), recursive: true)
    dir
}

private func touch(path: String): Unit {
    let file = File.create(Path(path))
    file.close()
}

/** 仅用于区分「内置工厂」与「扩展工厂」。 */
private class MarkerAgent <: ProbeAgent {
    private let kindName: String
    private let hostName: String

    init(kind: String, host: String) {
        this.kindName = kind
        this.hostName = host
    }

    public prop kind: String {
        get() {
            kindName
        }
    }

    public prop host: String {
        get() {
            hostName
        }
    }

    public prop data: JsonObject {
        get() {
            JsonObject()
        }
    }
}

/** 8.1：目录扫描只收动态库，并按完整路径排序。 */
@Test
public class CustomLoaderLibraries_test {
    @TestCase
    public func missingDirectoryMeansNoExtension(): Unit {
        let missing = '/tmp/fprobe-custom-missing-${tempCounter.fetchAdd(1)}'
        @Assert(CustomLoader.librariesOf(missing).isEmpty())
    }

    @TestCase
    public func onlyLibrariesAreCollectedAndSorted(): Unit {
        let dir = tempDir('libraries')
        touch('${dir}/z.dylib')
        touch('${dir}/README.md')
        touch('${dir}/a.so')
        touch('${dir}/b.dll')

        let libraries = CustomLoader.librariesOf(dir)
        @Assert(libraries.size, 3)
        @Assert(libraries[0], '${dir}/a.so')
        @Assert(libraries[1], '${dir}/b.dll')
        @Assert(libraries[2], '${dir}/z.dylib')
    }
}

/** 8.2：可注入 loader 的调用顺序、failFast 抛 LOAD、非 failFast 继续。 */
@Test
public class CustomLoaderLoad_test {
    @TestCase
    public func loaderReceivesSortedPathsWithoutExtension(): Unit {
        let dir = tempDir('order')
        touch('${dir}/b.so')
        touch('${dir}/a.so')
        touch('${dir}/README.md')

        let seen = ArrayList<String>()
        let report = CustomLoader.loadWith(dir, true, {path => seen.add(path)}, {_ => ()})

        @Assert(seen.size, 2)
        @Assert(seen[0], '${dir}/a')
        @Assert(seen[1], '${dir}/b')
        @Assert(report.loaded.size, 2)
        @Assert(report.loaded[0], '${dir}/a.so')
        @Assert(report.loaded[1], '${dir}/b.so')
        @Assert(report.failures.isEmpty())
    }

    @TestCase
    public func failFastWrapsFailureAsLoadError(): Unit {
        let dir = tempDir('failfast')
        touch('${dir}/a.so')

        var caught = false
        try {
            CustomLoader.loadWith(dir, true, {path => throw Exception('boom at ${path}')}, {_ => ()})
        } catch (e: ProbeException) {
            caught = true
            @Assert(e.code, ProbeErrorCode.LOAD)
            @Assert(e.message.contains("a.so"))
            @Assert(e.message.contains("boom"))
        }
        @Assert(caught)
    }

    @TestCase
    public func nonFailFastLogsAndContinues(): Unit {
        let dir = tempDir('continue')
        touch('${dir}/a.so')
        touch('${dir}/b.so')
        touch('${dir}/c.so')

        let seen = ArrayList<String>()
        let errors = ArrayList<String>()
        let report = CustomLoader.loadWith(dir, false, {path =>
                seen.add(path)
                if (path == '${dir}/b') {
                    throw Exception("b exploded")
                }
            }, {message => errors.add(message)})

        @Assert(seen.size, 3)
        @Assert(report.loaded.size, 2)
        @Assert(report.loaded[0], '${dir}/a.so')
        @Assert(report.loaded[1], '${dir}/c.so')
        @Assert(report.failures.size, 1)
        @Assert(report.failures[0].library, '${dir}/b.so')
        @Assert(report.failures[0].message.contains("b exploded"))
        @Assert(errors.size, 1)
        @Assert(errors[0].contains("b.so"))
    }
}

/** 8.3：内置先注册，扩展同名注册被拒绝，注册表仍指向内置工厂。 */
@Test
public class CustomLoaderDuplicate_test {
    @TestCase
    public func duplicateKindIsRejectedAndBuiltinWins(): Unit {
        ProbeRegistry.clear()
        ProbeRegistry.registerAgent("cpu", {=> MarkerAgent("cpu", "builtin")})

        var duplicate: ?ProbeException = None
        try {
            ProbeRegistry.registerAgent("cpu", {=> MarkerAgent("cpu", "custom")})
        } catch (e: ProbeException) {
            duplicate = Some(e)
        }

        let error = duplicate.getOrThrow()
        @Assert(error.code, ProbeErrorCode.DUPLICATE)
        @Assert(error.message.contains("cpu"))
        let factory = ProbeRegistry.agent("cpu").getOrThrow()
        @Assert(factory().host, "builtin")
        ProbeRegistry.clear()
    }

    /** 扩展在包初始化期注册重名时，failFast 应把 DUPLICATE 收敛为 LOAD。 */
    @TestCase
    public func extensionRegistrationFailureHonorsFailFast(): Unit {
        let dir = tempDir('duplicate')
        touch('${dir}/a.so')
        ProbeRegistry.clear()
        ProbeRegistry.registerAgent("cpu", {=> MarkerAgent("cpu", "builtin")})

        var caught = false
        try {
            CustomLoader.loadWith(dir, true, {_ =>
                    ProbeRegistry.registerAgent("cpu", {=> MarkerAgent("cpu", "custom")})
                }, {_ => ()})
        } catch (e: ProbeException) {
            caught = true
            @Assert(e.code, ProbeErrorCode.LOAD)
            @Assert(e.message.contains("a.so"))
        }
        @Assert(caught)
        let factory = ProbeRegistry.agent("cpu").getOrThrow()
        @Assert(factory().host, "builtin")
        ProbeRegistry.clear()
    }
}
