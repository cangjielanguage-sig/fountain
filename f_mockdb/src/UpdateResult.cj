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

public class MockUpdateResult <: UpdateResult {
    /**构造时快照本次执行的结果：之后的执行（或 clear）不再改变本对象*/
    public MockUpdateResult(
        private let lastInsertId_: Int64,
        private let rowCount_: Int64
    ){}
    public prop lastInsertId: Int64 {
        get(){
            lastInsertId_
        }
    }
    public prop rowCount: Int64 {
        get(){
            rowCount_
        }
    }
}