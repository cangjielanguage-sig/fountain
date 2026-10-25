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
package fountain::f_jsonrpc.server

import std.reflect.TypeInfo
import fountain::f_mvc.*

class JsonRpcTestController {
    @JsonRpcMapping[path: '/test/rpc']
    public func handleRoot(@RequestBody raw: Array<Byte>): Any {
        ()
    }

    @JsonRpcMapping[path: '/test/rpc/{topic}']
    public func handleTopic(@PathVariable topic: String, @RequestBody raw: Array<Byte>): Any {
        ()
    }
}

@Test
class JsonRpcMapping_test {
    @TestCase
    public func testAnnotationFixesProtocolFields(): Unit {
        let m = JsonRpcMapping(path: '/rpc')
        @Assert('/rpc', m.path)
        @Assert(RequestMethod.POST, m.method)
        @Assert('application/json', m.consumes)
        @Assert('application/json', m.produces)
    }

    @TestCase
    public func testAnnotationKeepsRoutingOptions(): Unit {
        let m = JsonRpcMapping(path: '/rpc', params: 'v=1', headers: 'X-A=1', ignoreAuth: true, ignorePrivilege: true)
        @Assert('v=1', m.params)
        @Assert('X-A=1', m.headers)
        @Assert(true, m.ignoreAuth)
        @Assert(true, m.ignorePrivilege)
    }

    @TestCase
    public func testControllerMethodIsRegisteredAsPostRoute(): Unit {
        let metas = MVCStarter.generateAndRegister<JsonRpcTestController>('handleRoot',
            [TypeInfo.of<Array<Byte>>()])
        @Assert(1, metas.size)
        @Assert('/test/rpc', metas[0].path)
        @Assert(RequestMethod.POST, metas[0].method)
        @Assert(true, metas[0].toString().contains('application/json'))
    }

    @TestCase
    public func testTopicMethodIsRegistered(): Unit {
        let metas = MVCStarter.generateAndRegister<JsonRpcTestController>('handleTopic',
            [TypeInfo.of<String>(), TypeInfo.of<Array<Byte>>()])
        @Assert(1, metas.size)
        @Assert('/test/rpc/{topic}', metas[0].path)
    }
}
