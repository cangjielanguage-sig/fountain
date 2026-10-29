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
package fountain::f_zip

import std.unittest.*
import std.unittest.testmacro.*

@Test
public class EntryNameTable_test {
    /** 全表覆盖：`a.txt → a_2.txt → a_3.txt` 等七类边界。 */
    @TestCase
    public func suffixTable(): Unit {
        let table = EntryNameTable()
        @Assert(table.allocate("a.txt"), "a.txt")
        @Assert(table.allocate("a.txt"), "a_2.txt")
        @Assert(table.allocate("a.txt"), "a_3.txt")
    }

    @TestCase
    public func suffixOnAlreadySuffixedName(): Unit {
        let table = EntryNameTable()
        @Assert(table.allocate("a_2.txt"), "a_2.txt")
        @Assert(table.allocate("a_2.txt"), "a_2_2.txt")
        @Assert(table.allocate("a_2_2.txt"), "a_2_2_2.txt")
    }

    @TestCase
    public func noExtension(): Unit {
        let table = EntryNameTable()
        @Assert(table.allocate("a"), "a")
        @Assert(table.allocate("a"), "a_2")
    }

    /** 点在目录段里不算扩展名。 */
    @TestCase
    public func dotInDirectorySegment(): Unit {
        let table = EntryNameTable()
        @Assert(table.allocate("dir.d/file"), "dir.d/file")
        @Assert(table.allocate("dir.d/file"), "dir.d/file_2")
    }

    /** 点开头的隐藏文件视为无扩展名。 */
    @TestCase
    public func hiddenFile(): Unit {
        let table = EntryNameTable()
        @Assert(table.allocate(".gitignore"), ".gitignore")
        @Assert(table.allocate(".gitignore"), ".gitignore_2")
    }

    /** 末尾点仍算扩展名分隔。 */
    @TestCase
    public func trailingDot(): Unit {
        let table = EntryNameTable()
        @Assert(table.allocate("a."), "a.")
        @Assert(table.allocate("a."), "a_2.")
    }

    /** 场景「同名目录合并」+「目录与文件不同名不算冲突」。 */
    @TestCase
    public func directoryMergeAndFileCoexistence(): Unit {
        let table = EntryNameTable()
        let (firstName, writeFirst) = table.allocateDirectory("d/")
        let (secondName, writeSecond) = table.allocateDirectory("d/")
        @Assert(firstName, "d/")
        @Assert(writeFirst, true)
        @Assert(secondName, "d/")
        @Assert(writeSecond, false)
        // 目录与同名文件不同名（一个带斜杠）
        @Assert(table.allocate("d"), "d")
        @Assert(table.contains("d/"), true)
        @Assert(table.contains("d"), true)
    }
}
