package fountain::f_net.client

import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_protocol.default.*

@Test
public class PendingRequestsTest {
    @TestCase
    public func disconnectCompletesOnlyItsOwnWaiters(): Unit {
        let failed = PendingRequests()
        let healthy = PendingRequests()
        let id = MessageID(hostId: 1)
        let response = Message.ack(id)
        let a = failed.add(id)
        let b = failed.add(MessageID(hostId: 2))
        let c = healthy.add(id)
        let wait = spawn {
            try { a.get(); false } catch (e: ClientException) { e.message == "disconnected" }
        }
        failed.close(ClientException("disconnected"))
        @Assert(wait.get(Duration.second))
        @AssertThrows[ClientException](b.tryGet(Duration.second))
        @AssertThrows[ClientException](failed.add(id))
        @Assert(failed.take(id).isNone())
        healthy.take(id).getOrThrow().set(response)
        healthy.close(ClientException("closed"))
        @Assert(c.get().id == id)
    }
}
