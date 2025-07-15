/*
    Copyright (c) [2022] [WuJingrun（吴京润）]
    fountain is licensed under Mulan PSL v2.
    You can use this software according to the terms and conditions of the Mulan PSL v2.
    You may obtain a copy of Mulan PSL v2 at:
            http://license.coscl.org.cn/MulanPSL2
    THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
    See the Mulan PSL v2 for more details.  
*/
package f_rx

enum EmitterState<T>{
    | Data(?T)
    | Ex(Exception)
}
/**
 * 务必确保调用on*(*)函数的线程跟调用next()函数的线程不是同一个
 */
public class Emitter<T> {
    private let q: LinkedBlockingQueue<EmitterState<T>>

    public init(qsize!: Int64 = 1) {
        q = LinkedBlockingQueue<EmitterState<T>>(qsize)
    }

    func next(): ?T {
        match(q.remove()){
            case Data(d) => d
            case Ex(e) => throw e
        }
    }
    public func onNext(data: T) {
        q.add(Data(data))
    }
    public func onError(e: Exception) {
        q.add(Ex(e))
    }
    public func onComplete() {
        q.add(Data(None))
    }
}
class EmitterIterator<T> <: Iterator<T> {
    EmitterIterator(private let emitter: Emitter<T>) {}
    public func next(): ?T {
        emitter.next()
    }
}