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
package fountain::f_mcp

import std.collection.ArrayList
import std.fs.File
import std.time.DateTime
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_data.*

@Test
class McpTransport_test {
    @TestCase
    public func testSseStreamFormatsEvents(): Unit {
        let hub = SubscriptionHub()
        let topics = ArrayList<String>()
        topics.add('tools/list_changed')
        let stream = McpSseStream(hub, topics)
        let params = JsonObject()
        params.add('reason', 'test')
        hub.publish('tools/list_changed', params)
        let chunk = stream.poll().getOrThrow()
        let text = String.fromUtf8(chunk)
        @Assert(true, text.contains('event: message'))
        @Assert(true, text.contains('data: '))
        @Assert(true, text.contains('notifications/tools/list_changed'))
        stream.close()
    }

    @TestCase
    public func testStdioFraming(): Unit {
        let stamp = DateTime.now().toUnixTimeStamp().toNanoseconds().toString()
        let script = '/tmp/mcp_stdio_test_${stamp}.sh'
        let body = "#!/bin/bash\n" +
            "while IFS= read -r line; do\n" +
            "  echo '{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"resultType\":\"complete\",\"content\":[{\"type\":\"text\",\"text\":\"ok\"}],\"isError\":false}}'\n" +
            "done\n"
        File.writeTo(script, body.unsafeBytes())
        let client = McpClient.stdio('/bin/bash', args: [script])
        let result = client.callTool('anything')
        @Assert('complete', result.resultType)
        @Assert('ok', result.content[0].asObject()['text'].asString().value)
        client.close()
    }
}
