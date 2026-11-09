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
package fountain::fprobe

/**
 * fprobe 可执行文件入口。
 *
 * 当前只承载模块骨架要求的最小行为：`--help` / `-h` 返回 0；其余调用打印顶层用法并
 * 返回 2。子命令分发在后续任务中实现。
 */
main(args: Array<String>): Int64 {
    if (args.size > 0 && (args[0] == "--help" || args[0] == "-h")) {
        println(Usage.root())
        return 0
    }
    println(Usage.root())
    2
}
