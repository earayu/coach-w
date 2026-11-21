import Foundation
import Testing

@testable import CoachKit

@Test func acceptsHttpAndHttpsWithHost() {
    #expect(ServerAddress.parse("https://coach.example.com")?.host == "coach.example.com")
    #expect(ServerAddress.parse("http://192.168.1.10:8000")?.port == 8000)
    #expect(ServerAddress.parse("HTTPS://coach.example.com") != nil)
}

@Test func trimsPastedWhitespace() {
    #expect(ServerAddress.parse("  https://coach.example.com \n")?.absoluteString == "https://coach.example.com")
    #expect(" code-123 \n".trimmedForSettings == "code-123")
}

@Test func rejectsOtherSchemesAndHostlessValues() {
    #expect(ServerAddress.parse("") == nil)
    #expect(ServerAddress.parse("coach.example.com") == nil)
    #expect(ServerAddress.parse("ws://coach.example.com") == nil)
    #expect(ServerAddress.parse("ftp://coach.example.com") == nil)
    #expect(ServerAddress.parse("https://") == nil)
    #expect(ServerAddress.parse("file:///etc/hosts") == nil)
}
