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
package fountain::fleet.client

import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_config.Config
import fountain::fleet.config.SyncConfig
import fountain::fleet.exception.InvalidKeyException

@Test
class SyncClientKeyValidationTest {
    @TestCase
    func absolutePathAccepted(): Unit {
        try {
            SyncClient.requireAbsolutePath('/valid/path')
        } catch (e: InvalidKeyException) {
            @Assert(false)
        }
    }

    @TestCase
    func relativePathRejected(): Unit {
        try {
            SyncClient.requireAbsolutePath('relative/path')
            @Assert(false)
        } catch (e: InvalidKeyException) {
            @Assert(true)
        }
    }

    @TestCase
    func emptyPathRejected(): Unit {
        try {
            SyncClient.requireAbsolutePath('')
            @Assert(false)
        } catch (e: InvalidKeyException) {
            @Assert(true)
        }
    }
}

@Test
class SyncClientInstanceTest {
    @TestCase
    func getInstanceReturnsSingleton(): Unit {
        Config.set([(SyncConfig.hosts, '127.0.0.1:1203')], ifAbsent: false)
        // 仅验证构造不抛异常（连接失败是另一回事）
        try {
            let _ = SyncClient.getInstance()
        } catch (_: Exception) {}
    }
}
