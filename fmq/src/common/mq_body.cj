/*
 * MQ 通用消息体类型，用于 f_net::Server/Client 的 T 参数。
 * DefaultCodec 通过 @DataAssist 为此类型生成编解码。
 */
package fountain::fmq.common

import fountain::f_data.macros.*

/**
 * MQ 消息体包装类型。
 * 替代 DataAny 作为 f_net::Server/Client 的 T 参数，
 * 确保 DefaultCodec 能正确编解码。
 */
@DataAssist[props fields]
public class MqBody {
    private var bodyType: String = ""
    private var payload: Array<Byte> = []
    public init() {}
    public init(bodyType: String, payload: Array<Byte>) {
        this.bodyType = bodyType
        this.payload = payload
    }
}
