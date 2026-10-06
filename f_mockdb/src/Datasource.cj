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
package fountain::f_mockdb

public class MockDatasource <: Datasource {
    private var closed_ = false
    private var connectionString_ = ''
    private let options_ = HashMap<String, String>()
    /**open 时收到的连接串（供用例断言驱动确实收到了参数）*/
    public prop connectionString: String {
        get(){
            connectionString_
        }
    }
    /**setOption 累积的连接选项，返回副本*/
    public prop options: Map<String, String> {
        get(){
            copyMap(options_)
        }
    }
    func setConnectionString(value: String): Unit {
        connectionString_ = value
    }
    public func isClosed(): Bool {
        closed_
    }
    public func close(): Unit {
        closed_ = true
    }
    public func connect(): Connection {
        MockConnection()
    }
    public func setOption(key: String, value: String): Unit {
        MOCKDB.log('Datasource option: key: ${key}; value: ${value}; threadID: ${MOCKDB.currentThreadId}')
        options_[key] = value
    }
}