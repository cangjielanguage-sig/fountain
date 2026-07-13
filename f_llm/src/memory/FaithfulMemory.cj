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
package fountain::f_llm.memory

public interface FaithfulMemory {
    func add(session: String, role: Role, content: String): Unit
    func summarise(fn: (String, ArrayList<ChatMessage>) -> Bool): Unit
    func summarise(earlierThan: DateTime, fn: (String, ArrayList<ChatMessage>) -> Bool): Unit
}
struct DummyMemory <: FaithfulMemory {
    init(){}
    public func add(_: String, _: Role, _: String): Unit{}
    public func summarise(_: (String, ArrayList<ChatMessage>) -> Bool): Unit{}
    public func summarise(_: DateTime, _: (String, ArrayList<ChatMessage>) -> Bool): Unit{}
}
struct FaithfulMemoryImpl <: FaithfulMemory {
    private static let log = LoggerFactory.getLogger<FaithfulMemory>()
    private static const CONTENT_KEY_PREFIX = 'FaithfulMemory'
    private static const FULL_DATE_FORMAT = 'yyyyMMddHHmmssSSS'
    private static const DUPLICATE_MEMORY = 'DuplicateMemory'
    private let store = Store(LLMConfig.getFaithfulMemoryPath().toString())

    private func current(now: DateTime): String {
        now.format(FULL_DATE_FORMAT)
    }
    private func contentKey(now: DateTime, session: String, role: Role) {
        contentKey(current(now), session, role)
    }
    private func contentKey(time: String, session: String, role: Role) {
        '${CONTENT_KEY_PREFIX}:${session}:${time}:${role}'.unsafeBytes()
    }
    private func duplicateKey(md5: MD5, session: String, role: Role, content: String){
        md5.write('${session}:${role}:${content}'.unsafeBytes())
        let hex = md5.finish() |> toHexString
        '${DUPLICATE_MEMORY}:${hex}'.unsafeBytes()
    }
    public func add(session: String, role: Role, content: String): Unit {
        let md5 = MD5()
        let duplicateKey = this.duplicateKey(md5, session, role, content)
        let contentKey = this.contentKey(DateTime.now(), session, role)
        let bytes = content.unsafeBytes()
        if(!store.contains(duplicateKey)){
            store.add(contentKey, bytes)
            store.add(duplicateKey, [])
        }
    }
    public func summarise(fn: (String, ArrayList<ChatMessage>) -> Bool): Unit {
        summarise(DateTime.now() - Duration.hour * 8, fn)
    }
    public func summarise(earlierThan: DateTime, fn: (String, ArrayList<ChatMessage>) -> Bool): Unit {
        let md5 = MD5()
        var lastSession = ''
        var currentSession = ''
        let messages = ArrayList<ChatMessage>()
        try(itr = store.prefix(CONTENT_KEY_PREFIX.unsafeBytes())){
            for((key, val) in itr){
                let k = unsafe{String.withRawData(key)}
                let v = unsafe{String.withRawData(val)}
                let keyParts = k.split(':')
                currentSession = keyParts[1]
                let timeStr = keyParts[2]
                let time = DateTime.parse(timeStr, FULL_DATE_FORMAT)
                let role = keyParts[3]
                if(time >= earlierThan){
                    break
                }
                let message = ChatMessage(role, v)
                if(lastSession.isEmpty()){
                    lastSession = currentSession
                }
                if(lastSession == currentSession){
                    messages.add(message)
                }else if(fn(lastSession, messages)){
                    for(m in messages){
                        let session = lastSession
                        store.remove(duplicateKey(md5, session, m.role, m.content))
                        store.remove(contentKey(timeStr, session, m.role))
                        md5.reset()
                    }
                    messages.clear()
                    lastSession = currentSession
                    messages.add(message)
                }else{
                    log.warn('summarise failed, or ExperienceFinder instance not found, current session: ${currentSession}')
                    break
                }
            }
        }
    }
}