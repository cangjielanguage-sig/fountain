/*
    Copyright (c) [2022] [WuJingrun（吴京润）]
    fountain is licensed under Mulan PSL v2.
    You can use this software according to the terms and conditions of the Mulan PSL v2.
    You may obtain a copy of Mulan PSL v2 at:
            http://license.coscl.org.cn/MulanPSL2
    THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
    See the Mulan PSL v2 for more details.  
*/
package f_base

import std.reflect.TypeInfo

public class AsyncIterator<T> <: Iterator<Future<?T>> {
    public AsyncIterator(private let itr: Iterator<T>){}
    public func next(): ?Future<?T> {
        spawn{
            itr.next()
        }
    }
}
public interface ExtendIterator<T>{}
extend<T> Iterator<T> <: ExtendIterator<T> {
    public func async(): Iterator<Future<?T>> {
        AsyncIterator<T>(this)
    }
    public func flatten<R>(toThrow!: Bool = true): Iterator<R> {
        if(toThrow){
            flatMap<R>{v => 
                match(v){
                    case x: Iterator<R> => x
                    case _ => throw IllegalArgumentException('${TypeInfo.of<T>()} does not match ${TypeInfo.of<Iterator<R>>()}')
                }
            }
        }else{
            flatMap<R>{v => 
                match(v){
                    case x: Iterator<R> => x
                    case _ => EmptyIterator<R>.instance
                }
            }
        }
    }
}