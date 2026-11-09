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
package fountain::fprobe.collect.hw

import fountain::f_data.*
import fountain::f_data.macros.*
import fountain::f_probe.ProbeAgent

/** `hardware` 监控项的数据形状：三组硬件读数并列。 */
@DataAssist[props fields]
public class HardwareSample {
    private var ipmi: Array<IpmiReading> = []
    private var snmp: Array<SnmpReading> = []
    private var smart: Array<SmartReading> = []

    public init() {}

    public init(ipmi: Array<IpmiReading>, snmp: Array<SnmpReading>, smart: Array<SmartReading>) {
        this.ipmi = ipmi
        this.snmp = snmp
        this.smart = smart
    }
}

/**
 * 硬件健康探针：把 IPMI 传感器、SNMP 传感器与磁盘 SMART 合并为一个监控项。
 *
 * 三个子采集器各自处理工具缺失与超时，本探针只做聚合，因此任一工具不可用
 * 都不会影响其它两类数据的上报。
 */
public class HardwareProbe <: ProbeAgent {
    private let ipmi: IpmiProbe
    private let snmp: SnmpProbe
    private let smart: SmartProbe

    public init(ipmi: IpmiProbe, snmp: SnmpProbe, smart: SmartProbe) {
        this.ipmi = ipmi
        this.snmp = snmp
        this.smart = smart
    }

    public prop kind: String {
        get() {
            "hardware"
        }
    }

    public prop data: JsonObject {
        get() {
            let sample = HardwareSample(ipmi.collect(), snmp.collect(), smart.collect())
            JsonValue.from(sample.toData()).asObject()
        }
    }
}
