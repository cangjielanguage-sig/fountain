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
import std.collection.concurrent.ConcurrentHashMap
import std.sync.{Timer, CatchupStyle, Mutex}

import fountain::f_collection.*
import fountain::f_util.PathPattern

internal struct FleetStore {
    private static let mutex = Mutex()
    private static let store = Store(FleetServerConfig.storePath)
    private static let hosts = FleetServerConfig.hosts
    private static let timer: Timer
    static init(){
        let prefix = 'T#'.unsafeBytes()
        timer = Timer.repeat(Duration.second, Duration.second, {=>
            try(itr = store.prefix(prefix)){
                let removed = ArrayList<Array<Byte>>()
                for((k, v) in itr where DateTime.parse(unsafeUtf8(v)) <= DateTime.now()){
                    removed.add(k)
                }
                for(k in removed){
                    synchronized(mutex){
                        if(let Some(v) <- store.get(k) && DateTime.parse(unsafeUtf8(v)) <= DateTime.now()){
                            store.remove(k)
                            let path = unsafeUtf8(k[2 .. ])
                            store.remove('D#${path}'.unsafeBytes())
                            notify(path, None)
                        }
                    }
                }
            }
        }, style: Delay)
    }
    private static func unsafeUtf8(utf8: Array<Byte>){
        unsafe{
            String.withRawData(utf8)
        }
    }
    private init(){}

    static func add(path: String, data: ?Array<Byte>, expireAt: ?DateTime): Unit {
        if(let Some(d) <- data){
            if(let Some(ex) <- expireAt){
                synchronized(mutex){
                    store.add('D#${path}'.unsafeBytes(), d, ex)
                    store.add('T#${path}'.unsafeBytes(), ex.toString().unsafeBytes())
                }
            }else{
                synchronized(mutex){
                    store.add('D#${path}'.unsafeBytes(), d)
                }
            }
        }else{
            remove(path)
        }
        notify(path, data)
    }
    static func remove(path: String): Unit {
        synchronized(mutex){
            store.remove('D#${path}'.unsafeBytes())
            store.remove('T#${path}'.unsafeBytes())
        }
        notify(path, None)
    }
    static func checkHost(buffer: SocketBuffer, path: String){
        hosts[path.hashCode() % hosts.size] == buffer.localAddress.toString()
    }
    private static func notify(path: String, data: ?Array<Byte>): Unit {
        for((id, pattern) in patterns){
            if(let Some(buffer) <- pattern.data<SocketBuffer>(path) && checkHost(buffer, path)){
                Message.resp(id, qos: QoS.AtMostOnce, ack: false, data: FleetDataMessage(path, data)) |>
                buffer.transfer
            }
        }
    }
    private static let patterns = ConcurrentHashMap<MessageID, PathPattern>()
    static func subscribe(pattern: String, id: MessageID, buffer: SocketBuffer): Unit {
        patterns.computeIfAbsent(id){
            PathPattern()
        }.compile(pattern, buffer)
    }
    static func unsubscribe(id: MessageID): Unit {
        patterns.remove(id)
    }
    static func get(path: String): ?Array<Byte> {
        store.get('D#${path}'.unsafeBytes())
    }
    static func filter(pattern: String): Iterator<FleetDataMessage> {
        let pp = PathPattern()
        pp.compile(pattern, ())
        let prefix = 'D#'.unsafeBytes()
        store.prefix(prefix).filter{tpl =>
            unsafeUtf8(tpl[0][2 .. ]) |>
            pp.matches
        }.map{tpl => FleetDataMessage(unsafeUtf8(tpl[0][2..]), tpl[1])}
    }
}