import SwiftUI
import WebKit
import Network
import Foundation

@main
struct PapayaFarmClassicApp: App {
    var body: some Scene {
        WindowGroup {
            PapayaWebContainer()
                .ignoresSafeArea()
                .statusBarHidden()
        }
    }
}

struct PapayaWebContainer: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> GameViewController { GameViewController() }
    func updateUIViewController(_ controller: GameViewController, context: Context) {}
}

final class GameViewController: UIViewController, WKScriptMessageHandler {
    private var browser: WKWebView!
    private let farm = FarmConnection()
    private var heartbeat: Timer?

    override var prefersStatusBarHidden: Bool { true }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .landscape }
    override var shouldAutorotate: Bool { true }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(red: 0.19, green: 0.39, blue: 0.18, alpha: 1)
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.userContentController.add(self, name: "papaya")
        browser = WKWebView(frame: view.bounds, configuration: config)
        browser.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        browser.isOpaque = false
        browser.backgroundColor = view.backgroundColor
        browser.scrollView.isScrollEnabled = false
        browser.scrollView.bounces = false
        view.addSubview(browser)

        if let url = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "www") {
            browser.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
        farm.onEvent = { [weak self] info in self?.publish(info) }
        heartbeat = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            self?.farm.tick()
        }
    }

    deinit { heartbeat?.invalidate(); farm.stop() }

    private func publish(_ dictionary: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(dictionary),
              let data = try? JSONSerialization.data(withJSONObject: dictionary),
              let json = String(data: data, encoding: .utf8) else { return }
        DispatchQueue.main.async { [weak self] in
            self?.browser.evaluateJavaScript("window.onPapayaNative(\(json));", completionHandler: nil)
        }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let data = message.body as? [String: Any],
              let cmd = data["cmd"] as? String else { return }
        func integer(_ key: String) -> Int { (data[key] as? NSNumber)?.intValue ?? 0 }
        switch cmd {
        case "connect":
            let ip = (data["ip"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let name = data["name"] as? String ?? ""
            let pin = data["pin"] as? String ?? ""
            guard name.range(of: "^[A-Za-z0-9_]{2,16}$", options: .regularExpression) != nil,
                  pin.range(of: "^[A-Za-z0-9_!#@$%^&*-]{4,20}$", options: .regularExpression) != nil,
                  !ip.isEmpty else {
                publish(["type":"message", "message":"Enter a valid server address, farm name (2-16 letters/numbers), and PIN (4-20 characters)."])
                return
            }
            farm.connect(ip: ip, name: name, pin: pin)
        case "disconnect": farm.stop()
        case "action": farm.action(integer("kind"), integer("a"), integer("b"))
        case "list": farm.requestList(integer("offset"))
        case "visit": farm.visit(data["name"] as? String ?? "")
        case "home": farm.home()
        case "refresh": farm.ping()
        default: break
        }
    }
}

private enum PacketType: UInt32 {
    case hello = 1, welcome, snapshot, action, visit, home, list, directory, ping, error, goodbye, health
}

// Matches the Python NAS server's ctypes wire layout (version 3).
// All integers are little-endian. Packet size: 1080; farm-state size: 736.
final class FarmConnection {
    var onEvent: (([String: Any]) -> Void)?
    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "org.papaya.classic.network")
    private var farmName = ""
    private var pin = ""
    private var token: UInt64 = 0
    private var request: UInt32 = 1
    private var lastHello: TimeInterval = 0
    private var lastPing: TimeInterval = 0
    private var lastResponse: TimeInterval = 0
    private var ready = false

    private func tell(_ type: String, _ message: String) {
        DispatchQueue.main.async { [weak self] in
            self?.onEvent?(["type":type,"message":message])
        }
    }

    func stop() {
        if token != 0 { send(.goodbye) }
        connection?.cancel(); connection = nil
        token = 0; ready = false; pin = ""
        tell("disconnected", "Disconnected. Farms remain saved on the NAS.")
    }

    func connect(ip: String, name: String, pin: String) {
        stop()
        farmName = name; self.pin = pin; request = 1
        let host = NWEndpoint.Host(ip)
        let port = NWEndpoint.Port(rawValue: 37942)!
        let conn = NWConnection(host: host, port: port, using: .udp)
        connection = conn
        conn.stateUpdateHandler = { [weak self, weak conn] state in
            guard let self = self, let conn = conn, conn === self.connection else { return }
            switch state {
            case .ready:
                self.ready = true
                self.tell("message", "Connected to network; signing in to your NAS farm...")
                self.sendHello()
                self.receive(on: conn)
            case .failed(let error):
                self.ready = false
                self.tell("message", "Connection failed: \(error.localizedDescription)")
            default: break
            }
        }
        conn.start(queue: queue)
        tell("message", "Connecting to \(ip):37942...")
    }

    private func receive(on conn: NWConnection) {
        conn.receiveMessage { [weak self, weak conn] content, _, _, error in
            guard let self = self, let conn = conn, conn === self.connection else { return }
            if let bytes = content, bytes.count == 1080 { self.decode(bytes) }
            if error == nil { self.receive(on: conn) }
            else { self.tell("message", "Network interrupted. Reconnect from the login screen.") }
        }
    }

    private func writeU32(_ data: inout Data, _ offset: Int, _ value: UInt32) {
        for i in 0..<4 { data[offset+i] = UInt8(truncatingIfNeeded: value >> (i*8)) }
    }
    private func writeU64(_ data: inout Data, _ offset: Int, _ value: UInt64) {
        for i in 0..<8 { data[offset+i] = UInt8(truncatingIfNeeded: value >> (i*8)) }
    }
    private func writeString(_ data: inout Data, _ offset: Int, _ width: Int, _ text: String) {
        for (i,b) in text.utf8.prefix(width-1).enumerated() { data[offset+i] = b }
    }
    private func readU32(_ data: Data, _ offset: Int) -> UInt32 {
        (0..<4).reduce(0) { $0 | UInt32(data[offset+$1]) << ($1*8) }
    }
    private func readU64(_ data: Data, _ offset: Int) -> UInt64 {
        (0..<8).reduce(0) { $0 | UInt64(data[offset+$1]) << ($1*8) }
    }
    private func readInt(_ data: Data, _ offset: Int) -> Int { Int(Int32(bitPattern: readU32(data,offset))) }
    private func readString(_ data: Data, _ offset: Int, _ count: Int) -> String {
        let slice = data[offset..<(offset+count)].prefix { $0 != 0 }
        return String(bytes:slice, encoding:.utf8) ?? ""
    }

    private func send(_ kind: PacketType, a: Int = 0, b: Int = 0, c: Int = 0, target: String = "") {
        guard let connection = connection, ready else { return }
        var packet = Data(repeating: 0, count: 1080)
        writeU32(&packet,0,0x33464e50)
        writeU32(&packet,4,3)
        writeU32(&packet,8,kind.rawValue)
        writeU32(&packet,12,request)
        writeU64(&packet,16,token)
        writeU32(&packet,24,UInt32(bitPattern:Int32(clamping:a)))
        writeU32(&packet,28,UInt32(bitPattern:Int32(clamping:b)))
        writeU32(&packet,32,UInt32(bitPattern:Int32(clamping:c)))
        writeString(&packet,40,24,farmName)
        if kind == .hello { writeString(&packet,64,24,pin) }
        if !target.isEmpty { writeString(&packet,88,24,target) }
        request &+= 1
        connection.send(content:packet, completion: .contentProcessed({ [weak self] error in
            if let error = error { self?.tell("message", "Send error: \(error.localizedDescription)") }
        }))
    }

    private func sendHello() {
        lastHello = Date().timeIntervalSince1970
        send(.hello)
    }
    func action(_ kind: Int,_ a: Int,_ b: Int) { if token != 0 { send(.action,a:kind,b:a,c:b) } }
    func requestList(_ offset: Int = 0) { if token != 0 { send(.list,a:offset) } }
    func visit(_ name: String) { if token != 0 { send(.visit,target:name) } }
    func home() { if token != 0 { send(.home) } }
    func ping() { if token != 0 { send(.ping) } }

    func tick() {
        guard ready else { return }
        let now = Date().timeIntervalSince1970
        if token == 0 {
            if now-lastHello > 4 { sendHello() }
        }else if now-lastPing > 5 {
            lastPing=now;ping()
            if lastResponse > 0 && now-lastResponse > 18 { tell("message", "NAS not responding. Check its address or network/VPN.") }
        }
    }

    private func decode(_ data: Data) {
        guard readU32(data,0) == 0x33464e50, readU32(data,4) == 3 else { return }
        let type = readU32(data,8)
        let message = readString(data,112,112)
        lastResponse=Date().timeIntervalSince1970
        if type == PacketType.error.rawValue {
            tell("message",message)
            if message.contains("Session ended") {
                token=0
                sendHello()
            } else if message.contains("Incorrect PIN") || message.contains("Name:") {
                // Do not repeatedly attempt an invalid login.
                lastHello=Date().timeIntervalSince1970 + 86_400
                tell("disconnected",message)
            }
            return
        }
        if type == PacketType.welcome.rawValue {
            token=readU64(data,16)
            tell("connected", "Welcome to your NAS farm!")
        }
        if type == PacketType.directory.rawValue {
            let total=readInt(data,24),offset=readInt(data,28)
            let names=(0..<5).map { readString(data,224+$0*24,24) }.filter{!$0.isEmpty}
            DispatchQueue.main.async { [weak self] in
                self?.onEvent?(["type":"directory","names":names,"total":total,"offset":offset])
            }
            return
        }
        guard type == PacketType.welcome.rawValue || type == PacketType.snapshot.rawValue else { return }
        let base=344
        func field(_ off:Int)->Int {readInt(data,base+off)}
        func array(_ off:Int,_ count:Int)->[Int] {(0..<count).map{field(off+$0*4)}}
        func times(_ off:Int,_ count:Int)->[Double] {(0..<count).map{Double(readU64(data,base+off+$0*8))}}
        let state:[String:Any] = [
            "cash":field(8),"papayas":field(12),"xp":field(16),"rp":field(20),
            "harvestTotal":field(24),"fertCount":field(28),"quick":field(32),
            "selected":field(36),"screen":field(40),"tool":field(44),
            "inv":array(48,7),"harvested":array(76,7),"unlocked":array(104,20),
            "crop":array(184,20),"weeds":array(264,20),"bugs":array(344,20),
            "planted":times(504,20),"animalOwned":array(664,3),
            "animalFed":array(676,3),"animalWater":array(688,3),
            "animalReady":times(712,3)
        ]
        let username=readString(data,40,24)
        let target=readString(data,88,24)
        DispatchQueue.main.async { [weak self] in
            self?.onEvent?(["type":"snapshot","state":state,"name":username,"target":target,"message":message])
        }
    }
}
