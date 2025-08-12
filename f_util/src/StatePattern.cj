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
package f_util

/**
 * 状态模式
 */
public interface State<D> {
    /**
     * 是否有后续状态
     */
    prop continues: Bool{
        get(){
            true
        }
    }
    /**
     * 执行当前状态
     */
    func exec(): State<D>
    /**
     * 当前状态的数据
     */
    prop data: D
    /**
     * 执行状态
     */
    static func execute<S, D>(state: S): D where S <: State<D> {
        var s = state
        while(s.continues) {
            s = s.exec()
        }
        s.data
    }
}

