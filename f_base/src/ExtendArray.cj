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
package f_base

public interface ExtendArray<T>{
    /**
     * 扩容数组，如果新的size小于当前数组大小会抛出IllegalArgumentException
     * 如果新的size等于当前数组大小仅仅是复制当前数组
     * 如果新的size大于当前数组大小，扩容的新值是new，默认是zeroValue<T>()
     */
    func grow(size: Int64, new!: T): Array<T>
    operator func *(repeat: Int64): Array<T>
}
extend<T> Array<T> <: ExtendArray<T> {
    public func grow(size: Int64, new!: T = unsafe{zeroValue<T>()}): Array<T> {
        if(size < this.size){
            throw IllegalArgumentException('new size must be greater than old, but new size is ${size} and current size is ${this.size}')
        }
        Array<T>(size){i =>
            if(i < this.size){
                this[i]
            }else{
                new
            }
        }
    }
    public operator func *(repeat: Int64): Array<T>{
        Array<T>(this.size * repeat){i => 
           this[i % this.size]
        }
    }
}