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
package fountain::fprobe.collect.proc

import std.math.*
import std.unittest.*
import std.unittest.testmacro.*
import fountain::fprobe.collect.hw.{CommandResult, FixtureCommandRunner}
import fountain::f_probe.{ProbeErrorCode, ProbeException}

private let DF_SPACE = '''
Filesystem     1024-blocks     Used Available Capacity Mounted on
/dev/sda1         102400000 51200000  51200000      50% /
tmpfs              16384000        0  16384000       0% /dev/shm
/dev/sdb1         204800000 10240000 194560000       5% /data
/dev/sdc1          10240000  1024000   9216000      10% /mnt/my data
'''

private let DF_INODE = '''
Filesystem      Inodes  IUsed   IFree IUse% Mounted on
/dev/sda1      6400000 640000 5760000   10% /
tmpfs           4096000      1 4095999    1% /dev/shm
/dev/sdb1      1280000   1280 1278720    1% /data
/dev/sdc1       100000   1000   99000    1% /mnt/my data
'''

private let MOUNTS = '''
/dev/sda1 / ext4 rw 0 0
tmpfs /dev/shm tmpfs rw 0 0
/dev/sdb1 /data xfs rw 0 0
/dev/sdc1 /mnt/my\\040data ext4 rw 0 0
'''

private let DF_HEADER_ONLY = '''
Filesystem     1024-blocks     Used Available Capacity Mounted on
'''

private let DF_INODE_HEADER_ONLY = '''
Filesystem      Inodes  IUsed   IFree IUse% Mounted on
'''

private let DISKSTATS_FRAME_1 = '''
   8       0 sda 1000 0 20000 500 500 0 10000 300 0 800 1300
'''

private let DISKSTATS_FRAME_2 = '''
   8       0 sda 1200 0 24000 700 600 0 10800 500 0 1100 1700
'''

private func ok(stdout: String): CommandResult {
    CommandResult(0, stdout, "", false, "")
}

private func diskRunner(space: CommandResult, inode: CommandResult): FixtureCommandRunner {
    let runner = FixtureCommandRunner()
    runner.respond(["df", "-Pk"], space)
    runner.respond(["df", "-Pi"], inode)
    return runner
}

private func excludeDefault(): Array<String> {
    ["tmpfs", "devtmpfs", "overlay", "squashfs"]
}

@Test
public class DiskProbe_test {
    @TestCase
    public func mergesSpaceAndInodeByMountPoint(): Unit {
        let reader = FixtureProcReader([("/proc/mounts", MOUNTS)])
        let probe = DiskProbe(reader, diskRunner(ok(DF_SPACE), ok(DF_INODE)), excludeDefault())
        let data = probe.data
        @Assert(probe.kind, "disk")
        let mounts = data.get("mounts").getOrThrow().asArray()
        // tmpfs 被 probe_diskExcludeFs 排除
        @Assert(mounts.size, 3)

        let root = mounts[0].asObject()
        @Assert(root.get("path").getOrThrow().asString().value, "/")
        @Assert(root.get("fs").getOrThrow().asString().value, "ext4")
        @Assert(root.get("totalBytes").getOrThrow().asInt().toInt64(), 102400000 * 1024)
        @Assert(root.get("usedBytes").getOrThrow().asInt().toInt64(), 51200000 * 1024)
        @Assert(root.get("availableBytes").getOrThrow().asInt().toInt64(), 51200000 * 1024)
        @Assert(abs(root.get("usedPercent").getOrThrow().asDecimal().toFloat64() - 50.0) < 1e-9)
        @Assert(root.get("inodesTotal").getOrThrow().asInt().toInt64(), 6400000)
        @Assert(root.get("inodesUsed").getOrThrow().asInt().toInt64(), 640000)
        @Assert(abs(root.get("inodesUsedPercent").getOrThrow().asDecimal().toFloat64() - 10.0) < 1e-9)

        let dataMount = mounts[1].asObject()
        @Assert(dataMount.get("path").getOrThrow().asString().value, "/data")
        @Assert(dataMount.get("fs").getOrThrow().asString().value, "xfs")
        @Assert(dataMount.get("totalBytes").getOrThrow().asInt().toInt64(), 204800000 * 1024)
    }

    @TestCase
    public func keepsMountPointContainingSpaces(): Unit {
        let reader = FixtureProcReader([("/proc/mounts", MOUNTS)])
        let probe = DiskProbe(reader, diskRunner(ok(DF_SPACE), ok(DF_INODE)), excludeDefault())
        let mounts = probe.data.get("mounts").getOrThrow().asArray()
        @Assert(mounts.size, 3)
        @Assert(mounts[2].asObject().get("path").getOrThrow().asString().value, "/mnt/my data")
    }

    @TestCase
    public func malformedDfOutputFailsWithoutPartialData(): Unit {
        let reader = FixtureProcReader([("/proc/mounts", MOUNTS)])
        let probe = DiskProbe(reader, diskRunner(ok("garbage without columns\n"), ok(DF_INODE)), excludeDefault())
        var caught = false
        try {
            probe.data
        } catch (e: ProbeException) {
            caught = true
            @Assert(e.code, ProbeErrorCode.COLLECT)
            @Assert(e.message.contains("df -Pk"))
        }
        @Assert(caught)
    }

    @TestCase
    public func nonZeroDfExitFailsProbe(): Unit {
        let reader = FixtureProcReader([("/proc/mounts", MOUNTS)])
        let failed = CommandResult(1, "", "df: permission denied", false, "")
        let probe = DiskProbe(reader, diskRunner(failed, ok(DF_INODE)), excludeDefault())
        var caught = false
        try {
            probe.data
        } catch (e: ProbeException) {
            caught = true
            @Assert(e.code, ProbeErrorCode.COLLECT)
        }
        @Assert(caught)
    }

    /** 两次采样相隔 1000ms：读 200 次、写 100 次、I/O 时间 +300ms。 */
    @TestCase
    public func computesIoRatesFromTwoFrames(): Unit {
        let reader = FixtureProcReader([
            ("/proc/diskstats", DISKSTATS_FRAME_1),
            ("/proc/mounts", "")
        ])
        let now = [1000]
        let probe = DiskProbe(reader, diskRunner(ok(DF_HEADER_ONLY), ok(DF_INODE_HEADER_ONLY)),
            excludeDefault(), {=> now[0]})
        let first = probe.data.get("devices").getOrThrow().asArray()
        @Assert(first.size, 1)
        @Assert(first[0].asObject().get("readIops").getOrThrow().asDecimal().toFloat64() == 0.0)
        @Assert(first[0].asObject().get("utilPercent").getOrThrow().asDecimal().toFloat64() == 0.0)

        reader.set("/proc/diskstats", DISKSTATS_FRAME_2)
        now[0] = 2000
        let devices = probe.data.get("devices").getOrThrow().asArray()
        @Assert(devices.size, 1)
        let device = devices[0].asObject()
        @Assert(device.get("device").getOrThrow().asString().value, "sda")
        @Assert(device.get("readBytes").getOrThrow().asInt().toInt64(), 24000 * 512)
        @Assert(device.get("writeBytes").getOrThrow().asInt().toInt64(), 10800 * 512)
        @Assert(abs(device.get("readIops").getOrThrow().asDecimal().toFloat64() - 200.0) < 1e-9)
        @Assert(abs(device.get("writeIops").getOrThrow().asDecimal().toFloat64() - 100.0) < 1e-9)
        @Assert(abs(device.get("awaitMs").getOrThrow().asDecimal().toFloat64() - 400.0 / 300.0) < 1e-9)
        @Assert(abs(device.get("utilPercent").getOrThrow().asDecimal().toFloat64() - 30.0) < 1e-9)
    }

    @TestCase
    public func malformedDiskstatsFailsProbe(): Unit {
        let reader = FixtureProcReader([
            ("/proc/diskstats", "8 0 sda not-a-number 0 0 0 0 0 0 0 0 0 0\n"),
            ("/proc/mounts", "")
        ])
        let probe = DiskProbe(reader, diskRunner(ok(DF_HEADER_ONLY), ok(DF_INODE_HEADER_ONLY)), excludeDefault())
        var caught = false
        try {
            probe.data
        } catch (e: ProbeException) {
            caught = true
            @Assert(e.code, ProbeErrorCode.COLLECT)
        }
        @Assert(caught)
    }
}
