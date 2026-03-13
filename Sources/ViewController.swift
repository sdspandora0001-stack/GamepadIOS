import UIKit
import Network
import MobileVLCKit

class ViewController: UIViewController, VLCMediaPlayerDelegate {
    
    var connection: NWConnection?
    let queue = DispatchQueue(label: "TouchNetworkQueue")
    
    var touchMap = [UITouch: Int]()
    var availableIds = Array(0...9)
    
    var mediaPlayer: VLCMediaPlayer!
    
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        view.isMultipleTouchEnabled = true
        
        // Hiện bảng chọn chế độ ngay khi mở App
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.promptConnectionMode()
        }
    }
    
    // Giao diện chọn chế độ USB hoặc Wi-Fi
    func promptConnectionMode() {
        let alert = UIAlertController(title: "Chế Độ Kết Nối", message: "Bạn muốn kết nối qua phương thức nào?", preferredStyle: .alert)
        
        alert.addAction(UIAlertAction(title: "📱 Cáp USB (Hotspot)", style: .default, handler: { _ in
            self.promptForIP(defaultPrefix: "172.20.10.")
        }))
        
        alert.addAction(UIAlertAction(title: "📶 Wi-Fi (LAN)", style: .default, handler: { _ in
            self.promptForIP(defaultPrefix: "192.168.")
        }))
        
        present(alert, animated: true)
    }
    
    func promptForIP(defaultPrefix: String) {
        let alert = UIAlertController(title: "Nhập IP Máy Tính", message: "Xem IP hiển thị trên cửa sổ Tool PC", preferredStyle: .alert)
        alert.addTextField { textField in
            textField.keyboardType = .decimalPad
            let saved = UserDefaults.standard.string(forKey: "LastPCIP")
            // Nếu có IP lưu cũ thì hiện lại, nếu không thì hiện gợi ý theo chế độ
            textField.text = (saved != nil && saved!.starts(with: defaultPrefix.prefix(5))) ? saved : defaultPrefix
        }
        
        alert.addAction(UIAlertAction(title: "Quay lại", style: .cancel, handler: { [weak self] _ in
            self?.promptConnectionMode()
        }))
        
        alert.addAction(UIAlertAction(title: "Bắt đầu", style: .default, handler: { [weak self] _ in
            let ip = alert.textFields?.first?.text ?? ""
            UserDefaults.standard.set(ip, forKey: "LastPCIP")
            self?.startConnection(to: ip)
        }))
        
        present(alert, animated: true)
    }
    
    func startConnection(to ip: String) {
        setupNetwork(pcIP: ip)
        setupVideoPlayer()
    }
    
    func setupNetwork(pcIP: String) {
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(pcIP), port: 8765)
        connection = NWConnection(to: endpoint, using: .tcp)
        
        connection?.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                print("Đã nối TCP tới PC")
            case .failed(_):
                DispatchQueue.main.async {
                    self?.promptConnectionMode() // Lỗi mạng thì cho chọn lại
                }
            default: break
            }
        }
        connection?.start(queue: queue)
    }
    
    func setupVideoPlayer() {
        if mediaPlayer == nil {
            mediaPlayer = VLCMediaPlayer()
            mediaPlayer.delegate = self
            mediaPlayer.drawable = self.view
        }
        
        // Nhận video gửi tới
        let url = URL(string: "udp://@0.0.0.0:12345")!
        let media = VLCMedia(url: url)
        
        let options: [AnyHashable: Any] = [
            "network-caching": 50,
            "clock-jitter": 0,
            "drop-late-frames": ""
        ]
        media.addOptions(options)
        
        mediaPlayer.media = media
        mediaPlayer.play()
    }
    
    // ================= XỬ LÝ CHẠM =================
    func getTouchId(for touch: UITouch) -> Int {
        if let id = touchMap[touch] { return id }
        let newId = availableIds.removeFirst()
        touchMap[touch] = newId
        return newId
    }
    
    func releaseTouchId(for touch: UITouch) {
        if let id = touchMap.removeValue(forKey: touch) {
            availableIds.append(id)
            availableIds.sort()
        }
    }
    
    func sendTouches(touches: Set<UITouch>, action: String) {
        guard connection?.state == .ready else { return }
        
        let screenWidth = view.bounds.width
        let screenHeight = view.bounds.height
        var touchesPayload: [[String: Any]] = []
        
        for touch in touches {
            let id = getTouchId(for: touch)
            let location = touch.location(in: view)
            
            touchesPayload.append([
                "id": id, "action": action,
                "x": location.x / screenWidth, "y": location.y / screenHeight
            ])
            if action == "end" { releaseTouchId(for: touch) }
        }
        
        if touchesPayload.isEmpty { return }
        let payload: [String: Any] = ["type": "multitouch", "touches": touchesPayload]
        
        if let jsonData = try? JSONSerialization.data(withJSONObject: payload),
           var jsonString = String(data: jsonData, encoding: .utf8) {
            jsonString += "\n"
            let data = jsonString.data(using: .utf8)!
            connection?.send(content: data, completion: .contentProcessed({ _ in }))
        }
    }
    
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) { sendTouches(touches: touches, action: "start") }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) { sendTouches(touches: touches, action: "move") }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { sendTouches(touches: touches, action: "end") }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { sendTouches(touches: touches, action: "end") }
    
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { return .landscape }
}
