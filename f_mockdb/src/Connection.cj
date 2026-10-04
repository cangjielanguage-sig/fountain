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

public class MockConnection <: Connection {
    private var closed_ = false
    public prop state: ConnectionState {
        get(){
            if(closed_){
                Closed
            }else{
                Connected
            }
        }
    }
    public func createTransaction(): Transaction{
        MockTransaction()
    }
    public func getMetaData(): Map<String, String> {
        MOCKDB.metadata
    }
    public func prepareStatement(sql: String): Statement {
        MockStatement(sql)
    }
    public func isClosed(): Bool {
        closed_
    }
    public func close(): Unit {
        //只关闭连接自身：夹具的生命周期由用例用 MOCKDB.clear() 显式管理，关连接不再清夹具
        closed_ = true
    }
}