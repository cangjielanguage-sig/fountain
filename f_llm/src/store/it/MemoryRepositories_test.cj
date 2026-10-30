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
package fountain::f_llm.store.it

import std.unittest.*
import std.unittest.testmacro.*

import fountain::f_llm.store.*
import fountain::f_llm.store.postgres.*
import fountain::f_llm.store.mysql.*

@Test
public class MemoryRepositoriesTest {

    @TestCase
    func testRegistryContainsBothBackends(): Unit {
        let names = MemoryRepositories.names()
        @Expect(names.size >= 2, true)
    }

    @TestCase
    func testUnknownNameThrowsWithAvailableList(): Unit {
        var message = ''
        try{
            MemoryRepositories.create('nope')
        }catch(e: Exception){
            message = e.message
        }
        @Expect(message.contains('nope'), true)
        @Expect(message.contains('postgres'), true)
    }
}
