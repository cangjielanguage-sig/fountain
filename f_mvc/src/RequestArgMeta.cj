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
package f_mvc

class RequestArgMeta {
    private let args = HashMap<String, ControllerFuncParam>()
    private func doExtract<T>(ctx: HttpContext, name: String, pattern: ?HttpRequestPathPatterns): ?T where T <: DataFields<T> {
        args[name].extract<T>(name, ctx, pattern.getOrThrow())
    }
    func extract<T>(ctx: HttpContext, name: String, pattern: ?HttpRequestPathPatterns): T where T <: DataFields<T> {
        doExtract<T>(ctx, name, pattern).getOrThrow()
    }
    func extract<T>(ctx: HttpContext, name: String, default: T, pattern: ?HttpRequestPathPatterns): T where T <: DataFields<T> {
        doExtract<T>(ctx, name, pattern) ?? default
    }
    func contains(name: String): Bool {
        args.contains(name)
    }

    operator func [](name: String): ControllerFuncParam {
        args[name]
    }
    operator func [](name: String, value!: ControllerFuncParam): Unit {
        args[name] = value
    }
    func add(all!: HashMap<String, ControllerFuncParam>): Unit {
        args.add(all: all)
    }
}