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
package fountain::f_dbd

import std.database.sql.DriverManager
import std.unittest.*
import std.unittest.testmacro.*

/**
 * 根包公开入口（G02）：只 `import fountain::f_dbd.*` 即可取到常用类型与版本入口。
 */
@Test
public class DbdTest {

    @TestCase
    public func versionEntryIsNotEmpty(): Unit {
        @Assert(fdBDVersion().size > 0)
        @Assert(fdBDVersion().contains('fountain'))
    }

    @TestCase
    public func rootPackageReexportsCommonTypes(): Unit {
        // 编译期即验证重导出：不写深层包路径也能构造这些类型
        let url = DbdUrl.parse('fdbm://u:p@h:1/db0')
        @Assert(url.database, 'db0')
        @Assert(DbdErrorCode.CONFIG.value > 0, true)
        @Assert(DbdException(DbdErrorCode.CONFIG, 'x').code, DbdErrorCode.CONFIG)
        let multi = MultiDUrl.parse('multidbm://h1:1,h2:2/db0')
        @Assert(multi.database, 'db0')
        @Assert(DriverManager.getDriver('multidbd').isSome(), true)
    }
}
