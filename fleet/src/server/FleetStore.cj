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
package fountain::fleet.server

import std.collection.ArrayList
import std.sync.{Timer, CatchupStyle, Mutex}

internal struct FleetStore {
    private static let mutex = Mutex()
    private static let store = Store(FleetServerConfig.storePath)
    private static let timer: Timer
    static init(){
        let prefix = 'T#'.unsafeBytes()
        timer = Timer.repeat(Duration.second, Duration.second, {=>
            try(itr = store.prefix(prefix)){
                let removed = ArrayList<Array<Byte>>()
                for((k, v) in itr where DateTime.parse(String.fromUtf8(v)) <= DateTime.now()){
                    removed.add(k)
                }
                for(k in removed){
                    synchronized(mutex){
                        if(let Some(v) <- store.get(k) && DateTime.parse(String.fromUtf8(v)) <= DateTime.now()){
                            store.remove(k)
                            //todo 向订阅当前path变化的客户端发送通知
                        }
                    }
                }
            }
        }, style: Delay)
    }
    private init(){}

    static func add(path: String, data: Array<Byte>, expireAt: DateTime){
        synchronized(mutex){
            store.add('D#${path}'.unsafeBytes(), data, expireAt)
            store.add('T#${path}'.unsafeBytes(), expireAt.toString().unsafeBytes())
        }
    }
    static func remove(path: String) {
        store.remove(path.unsafeBytes())
    }
}