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

import fountain::f_app.{SubCommand, SubCommandMediator}
import fountain::f_net.server.Server

private struct FleetServerCommand <: SubCommand {
    static init(){
        SubCommandMediator.register(FleetServerCommand())
    }
    private init(){}
    
    public prop command: String{
        get(){
            'fleet'
        }
    }
    public func exec(args: Array<String>): Int64 {
        DataSyncer.start()
        FleetServer.start()
        0
    }
}
/*
| **  Control Packet   ** | **Bit 3** | **Bit 2** | **Bit 1** | **Bit 0** |
| ----------------------- | --------- | --------- | --------- | --------- |
| AUTH                    | HASDATA   | 0         | 0         | ACK       |
| SLAVEOF                 | REG       | 0         | 0         | ACK       |
| REGISTER                | 0         | 0         | 0         | ACK       |
| PUBLISH                 | DUP       | QoS1      | Qos0      | RETAIN    |
| SUBSCRIBE               | 0         | 0         | 0         | ACK       |
| UNSUBSCRIBE             | 0         | 0         | 0         | ACK       |
| CONSUME                 | ONCE      | QoS1      | QoS0      | 0         |
| RESP                    | 0         | QoS1      | QoS0      | ACK       |
| PING                    | 0         | 0         | 0         | ACK       |
| ELECT                   | VOTE      | APPROVE   | ASSUME    | ACK       |
| ACK                     | 0         | 0         | 0         | 0         |
| DEREGISTER              | 0         | 0         | 0         | ACK       |

| AUTH(Byte)    //0
| SLAVEOF(Byte) //1
| REGISTER      //2
| PUBLISH(Byte) //3
| DLQ_LIST      //4
| DLQ_REDELIVER //5
| ERROR         //6
| RESERVED      //7
| SUBSCRIBE     //8
| UNSUBSCRIBE   //9
| CONSUME(Byte) //10
| RESP(Byte)    //11
| PING(Byte)    //12
| ELECT(Byte)   //13
| ACK           //14
| DEREGISTER    //15
*/