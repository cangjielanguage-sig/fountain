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
package fountain::f_pool

internal import std.time.MonoTime

class Ref<T> {
    private var pooledTime_ = MonoTime.now()
    //value是?T，目的是为了判定是否执行过终结器
    Ref(private var value: ?T, private let idleTimeout: Duration, private let destroy: (T) -> Unit){}
    ~init(){
        if(let Some(v) <- value){
            try{
                destroy(v)
            }catch(e: Exception){
                logger.warn('Error on destroying', e)
            }finally{
                value = None
            }
        }
    }
    func get(): ?T {
        value
    }
    prop pooledTime: MonoTime {
        get(){
            pooledTime_
        }
    }
    func reset(): Unit {
        pooledTime_ = MonoTime.now()
    }
    func isIdleTimeout(): Bool {
        MonoTime.now() - pooledTime >= idleTimeout
    }
}