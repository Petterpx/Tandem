import Testing
import Foundation
@testable import ControlProtocol

@Test func pairDeliversLines() async throws {
    let (a, b) = MemoryChannel.pair()
    try a.send(Data("ping".utf8))
    try b.send(Data("pong".utf8))
    var ia = a.incoming.makeAsyncIterator()
    var ib = b.incoming.makeAsyncIterator()
    #expect(await ib.next() == Data("ping".utf8))
    #expect(await ia.next() == Data("pong".utf8))
}

@Test func closeEndsBothSides() async throws {
    let (a, b) = MemoryChannel.pair()
    a.close()
    var ia = a.incoming.makeAsyncIterator()
    var ib = b.incoming.makeAsyncIterator()
    #expect(await ia.next() == nil)
    #expect(await ib.next() == nil)
    #expect(throws: SocketError.closed) { try a.send(Data("x".utf8)) }
    #expect(throws: SocketError.closed) { try b.send(Data("x".utf8)) }
}
