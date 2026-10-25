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
package fountain::jsonrpcclient

import std.env.{exit, getVariable}
import fountain::f_app.{Initializer, InitializerCollection}
import fountain::f_data.*
import fountain::f_jsonrpc.client.*

private func runDemo(): Unit {
    let port = getVariable('rpc_demo_port') ?? '18080'
    let client = JsonRpcClient('http://127.0.0.1:${port}/rpc')
    try {
        let searchParams = JsonArray()
        searchParams.add('hello')
        let search = client.call('knowledge.search', params: searchParams).asString().value
        if (search != 'found:hello') {
            throw Exception('unexpected search result: ${search}')
        }

        let addParams = JsonObject()
        addParams.add('a', 2)
        addParams.add('b', 3)
        let sum = client.call('knowledge.add', params: addParams).asInt().toInt64()
        if (sum != 5) {
            throw Exception('unexpected add result: ${sum}')
        }

        let echoParams = JsonObject()
        echoParams.add('text', 'hi')
        let echoed = client.call('knowledge.echo', params: echoParams).asObject()['text'].asString().value
        if (echoed != 'hi!') {
            throw Exception('unexpected echo result: ${echoed}')
        }

        let touch = client.call('knowledge.touch', params: JsonObject())
        if (touch.kind != JsonKind.JsonNull) {
            throw Exception('unexpected touch result: ${touch.toString()}')
        }

        println('JSONRPC_DEMO_OK search=${search} add=${sum} echo=${echoed}')
    } finally {
        client.close()
    }
}

public struct JsonRpcDemoClient <: Initializer {
    static init() {
        InitializerCollection.register(JsonRpcDemoClient())
    }

    private init() {}

    public prop name: String {
        get() {
            'fjsonrpcdemo::client'
        }
    }

    public func initialize(): Unit {}

    public func start(): Unit {
        try {
            runDemo()
            exit(0)
        } catch (e: Exception) {
            println('JSONRPC_DEMO_FAILED ${e.message}')
            exit(1)
        }
    }
}
