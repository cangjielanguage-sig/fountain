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
package fountain::f_mcp.client

import std.fs.File
import std.time.{DateTime, MonoTime}
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_data.*
import fountain::f_mcp.base.*

/**
 * 写一个 bash 假服务端脚本。
 *
 * 脚本里用 `@` 代替 `$`（仓颉字符串里 `$` 会触发插值），写入前统一替换回来。
 */
private func writeStdioScript(name: String, body: String): String {
    let stamp = DateTime.now().toUnixTimeStamp().toNanoseconds().toString()
    let path = '/tmp/mcp_stdio_${name}_${stamp}.sh'
    File.writeTo(path, body.replace('@', '$').unsafeBytes())
    path
}

private func textOf(result: CallToolResult): String {
    if (result.content.size == 0) {
        return ''
    }
    match (result.content[0].toJson().get('text')) {
        case Some(value) => value.asString().value
        case _ => ''
    }
}

/** 逐行读取请求，按请求 id 回一条 `text` 结果。 */
private const ECHO_ID = "  id=$(printf '%s' \"@line\" | sed -n 's/.*\"id\":\\([0-9][0-9]*\\).*/\\1/p')\n"

private func responseLine(text: String): String {
    "  echo \"{\\\"jsonrpc\\\":\\\"2.0\\\",\\\"id\\\":@id,\\\"result\\\":{\\\"resultType\\\":\\\"complete\\\",\\\"content\\\":[{\\\"type\\\":\\\"text\\\",\\\"text\\\":\\\"${text}\\\"}]}}\"\n"
}

@Test
class McpStdio_test {
    @TestCase
    public func testStdioFraming(): Unit {
        let script = writeStdioScript('framing',
            "#!/bin/bash\nwhile IFS= read -r line; do\n" + ECHO_ID + responseLine('ok') + "done\n")
        let client = McpClient.stdio('/bin/bash', args: [script])
        try {
            let result = client.callTool('anything')
            @Assert('complete', result.resultType)
            @Assert('ok', textOf(result))
        } finally {
            client.close()
        }
    }

    /** 服务端先发通知、再发一行噪声，客户端都要跳过。 */
    @TestCase
    public func testStdioSkipsNotificationsAndNoise(): Unit {
        let script = writeStdioScript('noise',
            "#!/bin/bash\nwhile IFS= read -r line; do\n" + "  echo 'starting server...'\n" +
                "  echo '{\"jsonrpc\":\"2.0\",\"method\":\"notifications/tools/list_changed\"}'\n" + ECHO_ID +
                responseLine('after-noise') + "done\n")
        let client = McpClient.stdio('/bin/bash', args: [script])
        try {
            let result = client.callTool('anything')
            @Assert('after-noise', textOf(result))
        } finally {
            client.close()
        }
    }

    /** 请求 id 由 JsonRpcClient 分配且单调递增；迟到 / 不匹配的响应被忽略。 */
    @TestCase
    public func testStdioIdsAreMonotonicAndStaleIgnored(): Unit {
        let stamp = DateTime.now().toUnixTimeStamp().toNanoseconds().toString()
        let requests = '/tmp/mcp_stdio_requests_${stamp}.txt'
        let script = writeStdioScript('ids',
            "#!/bin/bash\nwhile IFS= read -r line; do\n" + "  echo \"@line\" >> '${requests}'\n" + ECHO_ID +
                "  echo '{\"jsonrpc\":\"2.0\",\"id\":999,\"result\":{\"content\":[]}}'\n" +
                "  echo \"{\\\"jsonrpc\\\":\\\"2.0\\\",\\\"id\\\":@id,\\\"result\\\":{\\\"resultType\\\":\\\"complete\\\",\\\"content\\\":[{\\\"type\\\":\\\"text\\\",\\\"text\\\":\\\"v@id\\\"}]}}\"\n" +
                "done\n")
        let client = McpClient.stdio('/bin/bash', args: [script])
        try {
            let first = client.callTool('anything')
            @Assert('v1', textOf(first))
            let second = client.callTool('anything')
            @Assert('v2', textOf(second))
        } finally {
            client.close()
        }
        let recorded = String.fromUtf8(File.readFrom(requests))
        @Assert(true, recorded.contains('"id":1'))
        @Assert(true, recorded.contains('"id":2'))
    }

    /** 子进程不输出任何内容时，读超时抛错而不是永久阻塞。 */
    @TestCase
    public func testStdioReadTimeout(): Unit {
        let script = writeStdioScript('silent', "#!/bin/bash\nsleep 10\n")
        let options = McpClientOptions()
        options.timeout = Duration.millisecond * 500
        let client = McpClient.stdio('/bin/bash', args: [script], options: options)
        let start = MonoTime.now()
        try {
            try {
                client.callTool('anything')
                @Fail('expected timeout')
            } catch (e: McpException) {
                @Assert(true, e.message.contains('timeout'))
            }
            @Assert(true, MonoTime.now() - start < Duration.second * 5)
        } finally {
            client.close()
        }
    }
}
