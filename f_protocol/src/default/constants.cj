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
package fountain::f_protocol.default

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
| PING                    | WITHNODE  | 0         | 0         | ACK       |
| ELECT                   | VOTE      | APPROVE   | ASSUME    | ACK       |
| ACK                     | 0         | 0         | 0         | 0         |
| DEREGISTER              | 0         | 0         | 0         | ACK       |
*/
public const HASDATA = 8u8
public const REG = 8u8
public const DUP = 8u8
public const ONCE = 8u8
public const VOTE = 8u8
public const WITHNODE = 8u8
public const AT_MOST_ONCE = 0u8
public const AT_LEAST_ONCE = 2u8
public const EXACTLY_ONCE = 4u8
public const APPROVE = 4u8
public const ASSUME = 2u8
public const RETAIN = 1u8
public const ACK = 1u8

public enum QoS <: Equatable<QoS> & ToString {
    | AtMostOnce
    | AtLeastOnce 
    | ExactlyOnce
    public prop value: Byte {
        get(){
            match(this){
                case AtMostOnce => AT_MOST_ONCE
                case AtLeastOnce => AT_LEAST_ONCE
                case ExactlyOnce => EXACTLY_ONCE
            }
        }
    }
    public static func parse(value: Byte): QoS {
        let bit = value & (AT_MOST_ONCE | AT_LEAST_ONCE | EXACTLY_ONCE)
        if(bit == AT_MOST_ONCE){
            AtMostOnce
        }else if (bit == AT_LEAST_ONCE){
            AtLeastOnce
        }else if (bit == EXACTLY_ONCE){
            ExactlyOnce
        }else{
            throw CommandException("invalid QoS bits: ${value}")
        }
        // match(value & (AT_MOST_ONCE | AT_LEAST_ONCE | EXACTLY_ONCE)){
        //     case AT_MOST_ONCE => AtMostOnce
        //     case AT_LEAST_ONCE => AtLeastOnce
        //     case EXACTLY_ONCE => ExactlyOnce
        //     case _ => throw CommandException("invalid QoS bits: ${value}")
        // }
    }
    public operator func ==(other: QoS): Bool {
        match((this, other)){
            case (AtMostOnce, AtMostOnce) | (AtLeastOnce, AtLeastOnce) | (ExactlyOnce, ExactlyOnce) => true
            case _ => false
        }
    }
    public func toString(): String {
        match(this){
            case AtMostOnce => "AtMostOnce"
            case AtLeastOnce => "AtLeastOnce"
            case ExactlyOnce => "ExactlyOnce"
        }
    }
}
/*
| **Name**    | **Value** | **Direction of flow**                | **Description**                          |
| ----------- | --------- | ------------------------------------ | ---------------------------------------- |
| AUTH        | 0         | Client to Server                     | Connection request                       |
| SLAVEOF     | 1         | Slave to Master                      |                                          |
| REGISTER    | 2         | Client to Server                     | Register new topic                       |
| PUBLISH     | 3         | Client to Server or Server to Client | Publish message                          |
| RESERVED    | 4         |                                      |                                          |
| RESERVED    | 5         |                                      |                                          |
| RESERVED    | 6         |                                      |                                          |
| RESERVED    | 7         |                                      |                                          |
| SUBSCRIBE   | 8         | Client to Server                     | Subscribe request                        |
| UNSUBSCRIBE | 9         | Client to Server                     | Unsubscribe request                      |
| CONSUME     | 10        | Client to Server                     | consume messages                         |
| RESP        | 11        | Server to Client                     |                                          |
| PING        | 12        | Client to Server                     | PING request                             |
| ELECT       | 13        | EACH OTHER among Masters             |                                          |
| ACK         | 14        | Client to Server or Server to Client |                                          |
| DEREGISTER  | 15        | Deregister a topic                   | Deregister a topic                       |
*/
public enum Command {
    | AUTH(Byte)    //0
    | SLAVEOF(Byte) //1
    | REGISTER      //2
    | PUBLISH(Byte) //3
    | SUBSCRIBE     //8
    | UNSUBSCRIBE   //9
    | CONSUME(Byte) //10
    | RESP(Byte)    //11
    | PING(Byte)    //12
    | ELECT(Byte)   //13
    | ACK           //14
    | DEREGISTER    //15

    private static func tag(x: Byte): Byte {
        x & 0xf
    }
    public prop value: Byte {
        get(){
            match(this){
                case AUTH(x)     => ( 0 << 4) | tag(x)
                case SLAVEOF(x)  => ( 1 << 4) | tag(x)
                case REGISTER    => ( 2 << 4) | 1
                case PUBLISH(x)  => ( 3 << 4) | tag(x)
                case SUBSCRIBE   => ( 8 << 4) | 1
                case UNSUBSCRIBE => ( 9 << 4) | 1
                case CONSUME(x)  => (10 << 4) | tag(x)
                case RESP(x)     => (11 << 4) | tag(x)
                case PING(x)     => (12 << 4) | tag(x) | 1
                case ELECT(x)    => (13 << 4) | tag(x)
                case ACK         => (14 << 4) | 0
                case DEREGISTER  => (15 << 4) | 1
            }
        }
    }
    public static func parse(value: Byte): Command {
        func tag(){
            tag(value)
        }
        match(value >> 4){
            case  0 => AUTH(tag())
            case  1 => SLAVEOF(tag())
            case  2 => REGISTER
            case  3 => PUBLISH(tag())
            case  8 => SUBSCRIBE
            case  9 => UNSUBSCRIBE
            case 10 => CONSUME(tag())
            case 11 => RESP(tag())
            case 12 => PING(tag())
            case 13 => ELECT(tag())
            case 14 => ACK
            case 15 => DEREGISTER
            case _ => throw CommandException(toHex(value))
        }
    }
}
