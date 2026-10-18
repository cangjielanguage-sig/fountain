package fountain::mq_e2e_client

import std.convert.*
import std.env.*
import fountain::f_data.*
import fountain::f_mq.*

/**
 * 端到端脚本用的最小客户端。
 *
 * 用法：
 *   mq_e2e_client publish   <hosts> <topic> <count>
 *   mq_e2e_client consume   <hosts> <topic> <group> <count> [auto]
 *   mq_e2e_client noack     <hosts> <topic> <group> <count>
 *   mq_e2e_client consume-one <hosts> <topic> <group>
 */
main(args: Array<String>): Int64 {
    if (args.size < 4) {
        eprintln("usage: mq_e2e_client <publish|consume|noack|consume-one> <hosts> <topic> <group|-> [count]")
        return 2
    }
    let mode = args[0]
    let hosts = args[1].split(',')
    let topic = args[2]
    let group = args[3]
    let client = MQClient(hosts)
    try {
        match (mode) {
            case "publish" =>
                let count = Int64.parse(args[3])
                for (i in 0..count) {
                    client.publish(topic, "msg-${i}", tags: ["e2e"])
                    println("PUBLISHED ${i}")
                }
                0
            case "consume" =>
                let count = Int64.parse(args[4])
                let auto = args.size > 5 && args[5] == "auto"
                let sid = client.subscribe(topic, subscribeGroup: group, autoAck: auto)
                for (_ in 0..count) {
                    let message = client.consume(sid)
                    println("CONSUMED ${message.get<String>().getOrThrow()} ${message.segmentedIndex}:${message.segmentedOffset}")
                    if (!auto) {
                        client.ack(sid, message.segmentedIndex, message.segmentedOffset)
                    }
                }
                client.unsubscribe(sid)
                0
            case "noack" =>
                let count = Int64.parse(args[4])
                let sid = client.subscribe(topic, subscribeGroup: group)
                for (_ in 0..count) {
                    let message = client.consume(sid)
                    println("CONSUMED ${message.get<String>().getOrThrow()} ${message.segmentedIndex}:${message.segmentedOffset}")
                }
                0
            case "redeliver" =>
                // 不确认地反复消费，用来观察超时重投与死信
                let attempts = Int64.parse(args[4])
                let sid = client.subscribe(topic, subscribeGroup: group)
                for (_ in 0..attempts) {
                    let message = client.consume(sid)
                    println("CONSUMED ${message.get<String>().getOrThrow()} ${message.segmentedIndex}:${message.segmentedOffset}")
                    sleep(Duration.millisecond * 2500)
                }
                0
            case "consume-one" =>
                let sid = client.subscribe(topic, subscribeGroup: group)
                let message = client.consume(sid)
                println("CONSUMED ${message.get<String>().getOrThrow()} ${message.segmentedIndex}:${message.segmentedOffset}")
                0
            case _ =>
                eprintln("unknown mode ${mode}")
                2
        }
    } finally {
        client.close()
    }
}
