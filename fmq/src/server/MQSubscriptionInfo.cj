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
package fountain::fmq.server

import fountain::f_mq.base.MQFilter
import fountain::f_net.SocketBuffer
import fountain::fmq.queue.MQSubscriptionView

/**
 * 服务端订阅：绑定 `subscribedId`、订阅参数与发起订阅的连接。
 *
 * `buffer` 允许为空（单测），生产路径总是由 `SUBSCRIBE` 请求的 socket 绑定。
 */
protected class MQSubscriptionInfo {
    let subscribedId: String
    let topic: String
    let subscribeGroup: String
    let tags: Array<String>
    let filter: MQFilter
    let autoAck: Bool
    /** 连接键：服务端接受的连接远端地址唯一标识一条 TCP 连接（单测为空串）。 */
    let connectionKey: String
    var buffer: SocketBuffer

    init(subscribedId: String, topic: String, subscribeGroup: String, tags: Array<String>, filter: MQFilter,
        autoAck: Bool, buffer: SocketBuffer) {
        this.subscribedId = subscribedId
        this.topic = topic
        this.subscribeGroup = subscribeGroup
        this.tags = tags
        this.filter = filter
        this.autoAck = autoAck
        this.buffer = buffer
        this.connectionKey = if(isEmptySocketBuffer(buffer)){
            ''
        }else{
            buffer.remoteAddress.toString()
        }
    }
    private static func isEmptySocketBuffer(buffer: SocketBuffer): Bool {
        refEq(buffer, EMPTY_SOCKET_BUFFER)
    }
    func view(): MQSubscriptionView {
        MQSubscriptionView(subscribedId, topic, tags, filter, autoAck)
    }

    func isConnected(): Bool {
        if(isEmptySocketBuffer(buffer)){
            return false
        }
        !buffer.isClosed()
    }

    /** 连接已断开（无连接的单测订阅不算断开）。 */
    func isDisconnected(): Bool {
        if(isEmptySocketBuffer(buffer)){
            return false
        }
        buffer.isClosed()
    }

    func hasBuffer(buffer: SocketBuffer): Bool {
        !connectionKey.isEmpty() && connectionKey == buffer.remoteAddress.toString()
    }
}
