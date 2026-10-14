import Foundation
import XCTest
@testable import EnvanterCore

/// Sahte websocket: bağlantıları ve gönderilenleri kaydeder; testler sunucu mesajı / açılış / kopma üretir
final class FakeRealtimeTransport: RealtimeTransport, @unchecked Sendable {
    private struct Connection {
        var onOpen: () -> Void
        var onText: (String) -> Void
        var onClose: (String?) -> Void
    }

    private let lock = NSLock()
    private var current: Connection?
    private var stale: [Connection] = []
    private var _connects: [URL] = []
    private var _sent: [String] = []
    private var _closeCount = 0

    var connects: [URL] { locked { _connects } }
    var sent: [String] { locked { _sent } }
    var closeCount: Int { locked { _closeCount } }
    var messages: [RealtimeMessage] { sent.compactMap { RealtimeMessage(text: $0) } }
    var last: RealtimeMessage? { messages.last }

    func connect(url: URL, onOpen: @escaping () -> Void, onText: @escaping (String) -> Void, onClose: @escaping (String?) -> Void) {
        locked {
            _connects.append(url)
            current = Connection(onOpen: onOpen, onText: onText, onClose: onClose)
        }
    }

    func send(_ text: String) { locked { _sent.append(text) } }

    func close() {
        locked {
            _closeCount += 1
            if let c = current { stale.append(c) }
            current = nil
        }
    }

    func open() { locked { current }?.onOpen() }
    func server(_ text: String) { locked { current }?.onText(text) }
    func drop(_ reason: String? = "bağlantı koptu") { locked { current }?.onClose(reason) }
    /// Kapatılmış bir bağlantının geç gelen mesajı
    func staleServer(_ text: String) { locked { stale.last }?.onText(text) }

    private func locked<T>(_ f: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return f()
    }
}

/// Anında ilerleyen sahte zamanlayıcı
final class FakeRealtimeScheduler: RealtimeScheduler, @unchecked Sendable {
    final class Item: RealtimeCancellable {
        let due: TimeInterval
        let work: () -> Void
        var cancelled = false
        var done = false
        init(due: TimeInterval, work: @escaping () -> Void) { self.due = due; self.work = work }
        func cancel() { cancelled = true }
    }

    private let lock = NSLock()
    private var items: [Item] = []
    private(set) var now: TimeInterval = 0
    /// Her işten sonra çağrılır (istemcinin kuyruğunu boşaltmak için)
    var drain: () -> Void = {}

    func schedule(after seconds: TimeInterval, _ work: @escaping () -> Void) -> RealtimeCancellable {
        lock.lock(); defer { lock.unlock() }
        let item = Item(due: now + seconds, work: work)
        items.append(item)
        return item
    }

    /// Bekleyen işlerin kalan süreleri (sıralı)
    var pending: [TimeInterval] {
        lock.lock(); defer { lock.unlock() }
        return items.filter { !$0.cancelled && !$0.done }.map { $0.due - now }.sorted()
    }

    func advance(by seconds: TimeInterval) {
        let target = now + seconds
        while true {
            lock.lock()
            let next = items.filter { !$0.cancelled && !$0.done && $0.due <= target + 1e-9 }.min { $0.due < $1.due }
            if let next { next.done = true; now = max(now, next.due) }
            lock.unlock()
            guard let next else { break }
            next.work()
            drain()
        }
        lock.lock(); now = target; lock.unlock()
    }
}

final class RealtimeTests: XCTestCase {
    let ws = "11111111-1111-1111-1111-111111111111"
    let config = CloudConfig(url: "https://proje.supabase.co/", publishableKey: "sb_publishable_x")
    let meta: [String: JSONValue] = ["client": .string("mac"), "branch": .string("Tuzla"), "app": .string("2.0"),
                                     "since": .string("2026-10-11T06:00:00Z")]

    final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _statuses: [RealtimeStatus] = []
        private var _changes = 0
        private var _presence: [[String: [JSONValue]]] = []
        var token: String? = "jwt-1"
        var tokenCalls = 0
        var statuses: [RealtimeStatus] { lock.lock(); defer { lock.unlock() }; return _statuses }
        var changes: Int { lock.lock(); defer { lock.unlock() }; return _changes }
        var presence: [[String: [JSONValue]]] { lock.lock(); defer { lock.unlock() }; return _presence }
        func status(_ s: RealtimeStatus) { lock.lock(); _statuses.append(s); lock.unlock() }
        func change() { lock.lock(); _changes += 1; lock.unlock() }
        func presence(_ p: [String: [JSONValue]]) { lock.lock(); _presence.append(p); lock.unlock() }
    }

    private var transport: FakeRealtimeTransport!
    private var scheduler: FakeRealtimeScheduler!
    private var client: RealtimeClient!
    private var rec: Recorder!

    override func setUp() {
        transport = FakeRealtimeTransport()
        scheduler = FakeRealtimeScheduler()
        client = RealtimeClient(transport: transport, scheduler: scheduler, callbackQueue: nil)
        rec = Recorder()
        let c = client!, r = rec!
        scheduler.drain = { c.waitIdle() }
        client.onStatus = { r.status($0) }
        client.onChange = { r.change() }
        client.onPresence = { r.presence($0) }
    }

    override func tearDown() {
        client.stop()
        client.waitIdle()
    }

    private var topic: String { "realtime:envanter-canli:\(ws)" }

    private func start() {
        let r = rec!
        client.start(config: config, workspaceID: ws, deviceKey: "cihaz-1", presence: meta, tokenSource: { done in
            r.tokenCalls += 1
            done(r.token)
        })
        client.waitIdle()
    }

    private func step(_ f: () -> Void) {
        f()
        client.waitIdle()
    }

    private func reply(_ ref: String?, status: String = "ok", topic: String? = nil, response: String = "{}") -> String {
        #"{"event":"phx_reply","payload":{"response":\#(response),"status":"\#(status)"},"ref":\#(ref.map { "\"\($0)\"" } ?? "null"),"topic":"\#(topic ?? self.topic)"}"#
    }

    private func changeFrame() -> String {
        #"{"event":"postgres_changes","payload":{"data":{"commit_timestamp":"2026-10-11T06:00:00Z","errors":null,"record":{"key":"items","rev":42},"schema":"public","table":"envanter_docs","type":"UPDATE"},"ids":[7]},"ref":null,"topic":"\#(topic)"}"#
    }

    /// Bağlan, aç, katıl
    private func connectAndJoin() {
        start()
        step { transport.open() }
        let join = transport.messages.last { $0.event == "phx_join" }
        step { transport.server(reply(join?.ref)) }
    }

    // MARK: - Mesaj ve adres

    func testMessageCoding() throws {
        let m = try XCTUnwrap(RealtimeMessage(text: #"{"event":"system","payload":{"status":"ok"},"ref":null,"topic":"t"}"#))
        XCTAssertEqual(m, RealtimeMessage(topic: "t", event: "system", payload: j(#"{"status":"ok"}"#)))
        XCTAssertNil(m.ref)
        XCTAssertEqual(RealtimeMessage(text: #"{"event":"phx_reply","payload":{},"ref":12,"join_ref":"3","topic":"t"}"#)?.ref, "12")
        XCTAssertEqual(RealtimeMessage(text: #"{"event":"phx_reply","payload":{},"ref":12,"join_ref":"3","topic":"t"}"#)?.joinRef, "3")
        XCTAssertNil(RealtimeMessage(text: "değil json"))
        XCTAssertNil(RealtimeMessage(text: #"{"event":"x"}"#))
        let out = RealtimeMessage(topic: "phoenix", event: "heartbeat", payload: .object([:]), ref: "5")
        XCTAssertEqual(out.text, #"{"event":"heartbeat","payload":{},"ref":"5","topic":"phoenix"}"#)
        XCTAssertEqual(RealtimeMessage(text: out.text), out)
    }

    func testSocketURL() {
        XCTAssertEqual(RealtimeSession.url(config: config)?.absoluteString,
                       "wss://proje.supabase.co/realtime/v1/websocket?apikey=sb_publishable_x&vsn=1.0.0")
        XCTAssertEqual(RealtimeSession.url(base: " http://127.0.0.1:54321// ", publishableKey: "sb_publishable_local")?.absoluteString,
                       "ws://127.0.0.1:54321/realtime/v1/websocket?apikey=sb_publishable_local&vsn=1.0.0")
        XCTAssertEqual(RealtimeSession.url(base: "https://p.supabase.co", publishableKey: "a+b/c=d&e ş")?.absoluteString,
                       "wss://p.supabase.co/realtime/v1/websocket?apikey=a%2Bb%2Fc%3Dd%26e%20%C5%9F&vsn=1.0.0")
        XCTAssertEqual(RealtimeSession.url(base: "HTTPS://p.supabase.co", publishableKey: "eyJ.a-b_c.d")?.absoluteString,
                       "wss://p.supabase.co/realtime/v1/websocket?apikey=eyJ.a-b_c.d&vsn=1.0.0")
        XCTAssertNil(RealtimeSession.url(base: "ftp://p.supabase.co", publishableKey: "k"))
        XCTAssertNil(RealtimeSession.url(base: "p.supabase.co", publishableKey: "k"))
        XCTAssertNil(RealtimeSession.url(base: "https://p.supabase.co", publishableKey: " "))
    }

    func testPresenceMetaHasNoPersonalData() {
        let m = RealtimePresence.mac(branch: "Tuzla Marina", app: "2.1", since: Date(timeIntervalSince1970: 1_791_547_200))
        XCTAssertEqual(m, ["client": .string("mac"), "branch": .string("Tuzla Marina"), "app": .string("2.1"),
                           "fmt": .number(Double(DataFormat.level)), "since": .string("2026-10-09T12:00:00Z")])
    }

    // MARK: - Oturum (saf durum makinesi)

    func testJoinMessageExactJSON() {
        var s = RealtimeSession(workspaceID: "W", accessToken: "jwt-1", deviceKey: "cihaz-1")
        XCTAssertEqual(s.topic, "realtime:envanter-canli:W")
        let join = s.start()
        XCTAssertEqual(join.text, #"{"event":"phx_join","join_ref":"1","payload":{"access_token":"jwt-1","config":{"broadcast":{"ack":false,"self":false},"postgres_changes":[{"event":"*","filter":"workspace_id=eq.W","schema":"public","table":"envanter_docs"}],"presence":{"enabled":true,"key":"cihaz-1"},"private":false}},"ref":"1","topic":"realtime:envanter-canli:W"}"#)
        XCTAssertEqual(s.joinRef, "1")
        XCTAssertFalse(s.isJoined)
    }

    func testSessionRoutesEvents() {
        var s = RealtimeSession(workspaceID: ws, accessToken: "jwt-1", deviceKey: "cihaz-1")
        let join = s.start()
        // Katılmadan önce takip / anahtar mesajı yok
        XCTAssertNil(s.track(presence: meta))
        XCTAssertNil(s.updateToken("jwt-1"))
        XCTAssertEqual(s.receive(reply("99")), [])                                  // bilinmeyen ref
        XCTAssertEqual(s.receive(reply(join.ref, topic: "realtime:baska")), [])    // başka konu
        XCTAssertEqual(s.receive(reply(join.ref, response: #"{"postgres_changes":[{"id":7,"event":"*","schema":"public","table":"envanter_docs"}]}"#)), [.joined])
        XCTAssertTrue(s.isJoined)
        XCTAssertEqual(s.receive(reply(join.ref)), [])                              // yinelenen yanıt
        XCTAssertEqual(s.receive(#"{"event":"system","payload":{"channel":"envanter-canli:\#(ws)","extension":"postgres_changes","message":"Subscribed to PostgreSQL","status":"ok"},"ref":null,"topic":"\#(topic)"}"#), [])
        XCTAssertEqual(s.receive(changeFrame()), [.changed])
        XCTAssertEqual(s.receive(#"{"event":"broadcast","payload":{"event":"x","payload":{}},"ref":null,"topic":"\#(topic)"}"#), [])
        XCTAssertEqual(s.receive("bozuk"), [])
        XCTAssertEqual(s.receive(#"{"event":"system","payload":{"extension":"system","message":"Token has expired 0 seconds ago","status":"error"},"ref":null,"topic":"\#(topic)"}"#),
                       [.errored("Token has expired 0 seconds ago")])
        // Çevrimiçi durumu
        XCTAssertEqual(s.receive(#"{"event":"presence_state","payload":{"web-1":{"metas":[{"phx_ref":"a","client":"web"}]},"cihaz-1":{"metas":[{"phx_ref":"b","client":"mac"}]}},"ref":null,"topic":"\#(topic)"}"#),
                       [.presence(["web-1": [j(#"{"phx_ref":"a","client":"web"}"#)], "cihaz-1": [j(#"{"phx_ref":"b","client":"mac"}"#)]])])
        XCTAssertEqual(s.receive(#"{"event":"presence_diff","payload":{"joins":{"web-2":{"metas":[{"phx_ref":"c","client":"web"}]}},"leaves":{"web-1":{"metas":[{"phx_ref":"a","client":"web"}]}}},"ref":null,"topic":"\#(topic)"}"#),
                       [.presence(["web-2": [j(#"{"phx_ref":"c","client":"web"}"#)], "cihaz-1": [j(#"{"phx_ref":"b","client":"mac"}"#)]])])
        // Takip ve anahtar: katılma ref'iyle
        let track = s.track(presence: meta)
        XCTAssertEqual(track?.event, "presence")
        XCTAssertEqual(track?.joinRef, join.ref)
        XCTAssertEqual(track?.payload, .object(["type": .string("presence"), "event": .string("track"), "payload": .object(meta)]))
        XCTAssertEqual(s.receive(reply(track?.ref)), [])
        XCTAssertNil(s.updateToken("jwt-1"))                                        // değişmedi
        let token = s.updateToken("jwt-2")
        XCTAssertEqual(token?.event, "access_token")
        XCTAssertEqual(token?.topic, topic)
        XCTAssertEqual(token?.payload, j(#"{"access_token":"jwt-2"}"#))
        XCTAssertEqual(s.joinPayload["access_token"], .string("jwt-2"))
        XCTAssertEqual(s.receive(#"{"event":"phx_close","payload":{},"ref":"1","topic":"\#(topic)"}"#), [.closed])
        XCTAssertFalse(s.isJoined)
        XCTAssertEqual(s.receive(#"{"event":"phx_error","payload":{},"ref":"1","topic":"\#(topic)"}"#), [.errored("Kanal hatası")])
    }

    func testJoinErrorAndHeartbeatBookkeeping() {
        var s = RealtimeSession(workspaceID: ws, accessToken: "jwt-1", deviceKey: "k")
        let join = s.start()
        XCTAssertEqual(s.receive(reply(join.ref, status: "error", response: #"{"reason":"Invalid JWT"}"#)), [.joinFailed("Invalid JWT")])
        XCTAssertFalse(s.isJoined)
        let hb = s.heartbeat()
        XCTAssertEqual(hb?.topic, "phoenix")
        XCTAssertEqual(hb?.payload, .object([:]))
        XCTAssertNil(hb?.joinRef)
        XCTAssertNil(s.heartbeat())                                                 // yanıt gelmedi → yeniden bağlan
        XCTAssertEqual(s.receive(reply(hb?.ref, topic: "phoenix")), [])
        let hb2 = s.heartbeat()
        XCTAssertNotNil(hb2)
        XCTAssertNotEqual(hb2?.ref, hb?.ref)
        XCTAssertEqual(s.receive(reply(hb2?.ref, status: "error", topic: "phoenix")), [.errored("Kalp atışı reddedildi: bilinmeyen neden")])
        XCTAssertEqual(s.receive(reply("1234", topic: "phoenix")), [])               // bilinmeyen kalp atışı
        // Yeni bağlantıda ref'ler baştan
        XCTAssertEqual(s.start().ref, "1")
    }

    // MARK: - İstemci

    func testClientJoinsTracksAndBeats() throws {
        start()
        XCTAssertEqual(transport.connects.map(\.absoluteString), ["wss://proje.supabase.co/realtime/v1/websocket?apikey=sb_publishable_x&vsn=1.0.0"])
        XCTAssertEqual(rec.statuses, [.connecting])
        XCTAssertEqual(transport.sent, [])                                          // açılmadan gönderilmez
        step { transport.open() }
        let join = try XCTUnwrap(transport.last)
        XCTAssertEqual(join.event, "phx_join")
        XCTAssertEqual(join.topic, topic)
        XCTAssertEqual(join.payload["access_token"], .string("jwt-1"))
        XCTAssertEqual(join.payload["config"]?["presence"]?["key"], .string("cihaz-1"))
        step { transport.server(reply(join.ref)) }
        XCTAssertEqual(rec.statuses, [.connecting, .connected])
        let track = try XCTUnwrap(transport.last)
        XCTAssertEqual(track.event, "presence")
        XCTAssertEqual(track.payload["payload"], .object(meta))

        // Kalp atışı 25 sn'de bir; her atışta anahtar sorulur
        XCTAssertEqual(rec.tokenCalls, 1)
        scheduler.advance(by: 24.9)
        XCTAssertEqual(transport.messages.filter { $0.event == "heartbeat" }.count, 0)
        scheduler.advance(by: 0.1)
        var beats = transport.messages.filter { $0.event == "heartbeat" }
        XCTAssertEqual(beats.count, 1)
        XCTAssertEqual(rec.tokenCalls, 2)
        step { transport.server(reply(beats[0].ref, topic: "phoenix")) }
        // Anahtar yenilendi: sonraki atışta access_token gönderilir
        rec.token = "jwt-2"
        scheduler.advance(by: 25)
        beats = transport.messages.filter { $0.event == "heartbeat" }
        XCTAssertEqual(beats.count, 2)
        XCTAssertEqual(transport.last?.event, "access_token")
        XCTAssertEqual(transport.last?.payload, j(#"{"access_token":"jwt-2"}"#))
        XCTAssertEqual(transport.last?.joinRef, join.ref)
        step { transport.server(reply(beats[1].ref, topic: "phoenix")) }
        scheduler.advance(by: 25)
        XCTAssertEqual(transport.messages.filter { $0.event == "access_token" }.count, 1)   // değişmeyen anahtar yeniden gönderilmez
        XCTAssertEqual(transport.closeCount, 0)
        XCTAssertEqual(rec.statuses, [.connecting, .connected])
    }

    func testChangesAreCoalescedAndSystemMessagesIgnored() {
        connectAndJoin()
        step { transport.server(#"{"event":"system","payload":{"channel":"envanter-canli:\#(ws)","extension":"postgres_changes","message":"Subscribed to PostgreSQL","status":"ok"},"ref":null,"topic":"\#(topic)"}"#) }
        scheduler.advance(by: 1)
        XCTAssertEqual(rec.changes, 0)
        step { transport.server(changeFrame()) }
        XCTAssertEqual(rec.changes, 0)                                              // 0,3 sn birleştirme
        step { transport.server(changeFrame()) }
        scheduler.advance(by: 0.2)
        step { transport.server(changeFrame()) }
        scheduler.advance(by: 0.1)
        XCTAssertEqual(rec.changes, 1)
        scheduler.advance(by: 5)
        XCTAssertEqual(rec.changes, 1)
        step { transport.server(changeFrame()) }
        scheduler.advance(by: 0.3)
        XCTAssertEqual(rec.changes, 2)
    }

    func testImmediateChangeWithoutCoalescing() {
        client = RealtimeClient(transport: transport, scheduler: scheduler, callbackQueue: nil, coalesce: 0)
        let c = client!, r = rec!
        scheduler.drain = { c.waitIdle() }
        client.onChange = { r.change() }
        connectAndJoin()
        step { transport.server(changeFrame()) }
        XCTAssertEqual(rec.changes, 1)
    }

    func testJoinErrorBacksOffAndResetsAfterJoin() {
        start()
        var delays: [TimeInterval] = []
        for attempt in 1...6 {
            XCTAssertEqual(transport.connects.count, attempt)
            step { transport.open() }
            let join = transport.messages.last { $0.event == "phx_join" }
            step { transport.server(reply(join?.ref, status: "error", response: #"{"reason":"Invalid JWT"}"#)) }
            XCTAssertEqual(transport.closeCount, attempt)
            XCTAssertEqual(rec.statuses.last, .disconnected)
            let pending = scheduler.pending
            XCTAssertEqual(pending.count, 1, "yalnızca yeniden bağlanma bekler")
            delays.append(pending[0])
            scheduler.advance(by: pending[0])
        }
        XCTAssertEqual(delays, [1, 2, 5, 10, 30, 30])
        XCTAssertEqual(client.lastProblemForTests, "Kanala katılınamadı: Invalid JWT")
        // Başarılı katılma sayacı sıfırlar
        step { transport.open() }
        let join = transport.messages.last { $0.event == "phx_join" }
        step { transport.server(reply(join?.ref)) }
        XCTAssertEqual(rec.statuses.last, .connected)
        step { transport.drop() }
        XCTAssertEqual(scheduler.pending.first, 1)
    }

    func testPhxCloseReconnectsWithNewToken() throws {
        connectAndJoin()
        let firstJoin = try XCTUnwrap(transport.messages.first { $0.event == "phx_join" })
        // Anahtar yenilendi: hemen bildirilir
        rec.token = "jwt-2"
        step { client.updateToken("jwt-2") }
        XCTAssertEqual(transport.last?.event, "access_token")
        XCTAssertEqual(transport.last?.payload["access_token"], .string("jwt-2"))
        // Sunucu kanalı kapattı → 1 sn sonra yeniden bağlanır; yeni katılma yeni anahtarla
        step { transport.server(#"{"event":"phx_close","payload":{},"ref":"\#(firstJoin.ref!)","topic":"\#(topic)"}"#) }
        XCTAssertEqual(transport.closeCount, 1)
        XCTAssertEqual(rec.statuses, [.connecting, .connected, .disconnected])
        XCTAssertEqual(scheduler.pending, [1])
        scheduler.advance(by: 1)
        XCTAssertEqual(transport.connects.count, 2)
        XCTAssertEqual(rec.statuses.last, .connecting)
        step { transport.open() }
        let secondJoin = try XCTUnwrap(transport.last)
        XCTAssertEqual(secondJoin.event, "phx_join")
        XCTAssertEqual(secondJoin.ref, "1")
        XCTAssertEqual(secondJoin.payload["access_token"], .string("jwt-2"))
        // Kapatılmış bağlantının geç gelen mesajı yok sayılır
        step { transport.staleServer(changeFrame()) }
        scheduler.advance(by: 1)
        XCTAssertEqual(rec.changes, 0)
    }

    func testMissingHeartbeatReplyReconnects() {
        connectAndJoin()
        scheduler.advance(by: 25)
        XCTAssertEqual(transport.messages.filter { $0.event == "heartbeat" }.count, 1)
        XCTAssertEqual(transport.closeCount, 0)
        scheduler.advance(by: 25)                                                   // yanıt gelmedi
        XCTAssertEqual(transport.messages.filter { $0.event == "heartbeat" }.count, 1)
        XCTAssertEqual(transport.closeCount, 1)
        XCTAssertEqual(rec.statuses.last, .disconnected)
        XCTAssertEqual(client.lastProblemForTests, "Kalp atışına yanıt gelmedi")
        scheduler.advance(by: 1)
        XCTAssertEqual(transport.connects.count, 2)
    }

    func testHeartbeatErrorAndTransportDropReconnect() {
        connectAndJoin()
        scheduler.advance(by: 25)
        let beat = transport.messages.last { $0.event == "heartbeat" }
        step { transport.server(reply(beat?.ref, status: "error", topic: "phoenix")) }
        XCTAssertEqual(transport.closeCount, 1)
        scheduler.advance(by: 1)
        XCTAssertEqual(transport.connects.count, 2)
        step { transport.drop("ağ gitti") }
        XCTAssertEqual(client.lastProblemForTests, "ağ gitti")
        XCTAssertEqual(scheduler.pending, [2])                                      // katılmadan koptu: sayaç sürer
    }

    func testOpenOrJoinTimeoutReconnects() {
        start()
        scheduler.advance(by: 9.9)
        XCTAssertEqual(transport.closeCount, 0)
        scheduler.advance(by: 0.1)                                                  // açılmadı
        XCTAssertEqual(transport.closeCount, 1)
        scheduler.advance(by: 1)
        step { transport.open() }
        scheduler.advance(by: 10)                                                   // katılma yanıtı yok
        XCTAssertEqual(transport.closeCount, 2)
        XCTAssertEqual(client.lastProblemForTests, "Bağlantı ya da kanala katılma zaman aşımına uğradı")
    }

    func testMissingTokenBacksOff() {
        rec.token = nil
        start()
        XCTAssertEqual(transport.connects.count, 0)
        XCTAssertEqual(rec.statuses, [.connecting, .disconnected])
        XCTAssertEqual(scheduler.pending, [1])
        rec.token = "jwt-9"
        scheduler.advance(by: 1)
        XCTAssertEqual(transport.connects.count, 1)
        step { transport.open() }
        XCTAssertEqual(transport.last?.payload["access_token"], .string("jwt-9"))
    }

    func testStopClosesTransportAndCancelsTimers() {
        connectAndJoin()
        step { transport.server(changeFrame()) }                                   // birleştirme zamanlayıcısı bekliyor
        XCTAssertFalse(scheduler.pending.isEmpty)
        step { client.stop() }
        XCTAssertEqual(transport.closeCount, 1)
        XCTAssertEqual(rec.statuses.last, .disconnected)
        XCTAssertEqual(scheduler.pending, [])
        let sentCount = transport.sent.count
        scheduler.advance(by: 120)
        step { transport.staleServer(changeFrame()) }
        XCTAssertEqual(transport.connects.count, 1)
        XCTAssertEqual(transport.sent.count, sentCount)
        XCTAssertEqual(rec.changes, 0)
        step { client.updateToken("jwt-3") }
        XCTAssertEqual(transport.sent.count, sentCount)
        // Yeniden başlatılabilir
        start()
        XCTAssertEqual(transport.connects.count, 2)
    }

    func testPresenceIsReportedAndUpdated() {
        connectAndJoin()
        step { transport.server(#"{"event":"presence_state","payload":{"web-1":{"metas":[{"phx_ref":"a","client":"web"}]}},"ref":null,"topic":"\#(topic)"}"#) }
        XCTAssertEqual(rec.presence.last?["web-1"]?.first?["client"], .string("web"))
        step { client.updatePresence(["client": .string("mac"), "branch": .string("Kadıköy")]) }
        XCTAssertEqual(transport.last?.event, "presence")
        XCTAssertEqual(transport.last?.payload["payload"]?["branch"], .string("Kadıköy"))
    }

    func testAsyncTokenProvider() async throws {
        let t = FakeRealtimeTransport()
        let c = RealtimeClient(transport: t, scheduler: FakeRealtimeScheduler(), callbackQueue: nil)
        c.start(config: config, workspaceID: ws, deviceKey: "k", presence: [:], accessToken: { "jwt-async" })
        for _ in 0..<400 where t.connects.isEmpty {
            try await Task.sleep(nanoseconds: 5_000_000)
            c.waitIdle()
        }
        XCTAssertEqual(t.connects.count, 1)
        t.open()
        c.waitIdle()
        XCTAssertEqual(t.last?.payload["access_token"], .string("jwt-async"))
        c.stop()
        c.waitIdle()
        XCTAssertEqual(t.closeCount, 1)
    }
}

extension RealtimeClient {
    /// Son bağlantı sorunu (testler)
    var lastProblemForTests: String? {
        waitIdle()
        return lastProblem
    }
}
