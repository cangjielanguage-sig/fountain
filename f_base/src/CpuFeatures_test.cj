package fountain::f_base

import std.unittest.*
import std.unittest.testmacro.*

/** CpuFeatures：本机 aarch64 恒 false；x86_64 由 /proc/cpuinfo 判定。 */
@Test
public class CpuFeatures_test {
    @TestCase
    public func sse41IsDeterministic(): Unit {
        let v = CpuFeatures.hasSse41
        @Assert(v == CpuFeatures.hasSse41, true)
        if (!Arch.current.isX86_64) {
            @Assert(v, false)
        }
    }
}
