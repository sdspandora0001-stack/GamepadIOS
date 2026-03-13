import UIKit
import Network

class ViewController: UIViewController {
    
    var touchConnection: NWConnection?
    var videoConnection: NWConnection?
    
    let queue = DispatchQueue(label: "TouchNetworkQueue")
    let videoQueue = DispatchQueue(label: "VideoNetworkQueue")
    
    var touchMap = [UITouch: Int]()
    var availableIds = Array(0...9)
    
    let imageView = UIImageView()
    
    // ==========================================
    // 1. CẤU HÌNH HIỂN THỊ (SỬA LỖI MÀN HÌNH VÀ XOAY)
    // ==========================================
    
    // Ẩn hoàn toàn thanh trạng thái (Pin, Giờ, Sóng...)
    override var prefersStatusBarHidden: Bool {
        return true
    }
    
    // Ẩn thanh Home ảo ở cạnh dưới (nếu có)
    override var prefersHomeIndicatorAutoHidden: Bool {
        return true
    }
    
    // Cho phép máy tự động xoay
    override var shouldAutorotate: Bool {
        return true
    }
    
    // Ép chế độ xoay: Chỉ cho phép xoay ngang (trái hoặc phải) giống Game
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        return .landscape
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        view.isMultipleTouchEnabled = true
        
        imageView.frame = view.bounds
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        imageView.contentMode = .scaleToFill
        view.addSubview(imageView)
        view.sendSubviewToBack(imageView)
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.promptConnectionMode()
        }
    }
    
    // ==========================================
    // 2. GIAO DIỆN KẾT NỐI
    // ==========================================
    func promptConnectionMode() {
        let alert = UIAlertController(title: "Chế Độ Kết Nối", message: "Bạn muốn kết nối qua phương thức nào?", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "📱 Cáp USB (Hotspot)", style: .default, handler: { _ in self.promptForIP(defaultPrefix: "172.20.10.") }))
        alert.addAction(UIAlertAction(title: "📶 Wi-Fi (LAN)", style: .default, handler: { _ in self.promptForIP(defaultPrefix: "192.168.") }))
        present(alert, animated: true)
    }
    
    func promptForIP(defaultPrefix: String) {
        let alert = UIAlertController(title: "Nhập IP Máy Tính", message: "Xem IP hiển thị trên cửa sổ Tool PC", preferredStyle: .alert)
        alert.addTextField { textField in
            textField.keyboardType = .decimalPad
            let saved = UserDefaults.standard.string(forKey: "LastPCIP")
            textField.text = (saved != nil && saved!.starts(with: defaultPrefix.prefix(5))) ? saved : defaultPrefix
        }
        
        alert.addAction(UIAlertAction(title: "Quay lại", style: .cancel, handler: { [weak self] _ in self?.promptConnectionMode() }))
        alert.addAction(UIAlertAction(title: "Bắt đầu", style: .default, handler: { [weak self] _ in
            let ip = alert.textFields?.first?.text ?? ""
            UserDefaults.standard.set(ip, forKey: "LastPCIP")
            self?.startConnection(to: ip)
        }))
        present(alert, animated: true)
    }
    
    func startConnection(to ip: String) {
        setupNetwork(pcIP: ip)
        setupImageStream(pcIP: ip)
    }
    
    func setupNetwork(pcIP: String) {
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(pcIP), port: 8765)
        touchConnection = NWConnection(to: endpoint, using: .tcp)
        touchConnection?.stateUpdateHandler = { [weak self] state in
            if case .failed(_) = state { DispatchQueue.main.async { self?.promptConnectionMode() } }
        }
        touchConnection?.start(queue: queue)
    }
    
    // ==========================================
    // 3. NHẬN ẢNH SIÊU TỐC TỪ PC
    // ==========================================
    func setupImageStream(pcIP: String) {
        videoConnection?.cancel()
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(pcIP), port: 12345)
        
        let params = NWParameters.tcp
        if let tcpOptions = params.defaultProtocolStack.internetProtocol as? NWProtocolTCP.Options {
            tcpOptions.noDelay = true
        }
        
        videoConnection = NWConnection(to: endpoint, using: params)
        videoConnection?.stateUpdateHandler = { [weak self] state in
            if case .ready = state {
                self?.receiveNextFrame()
            }
        }
        videoConnection?.start(queue: videoQueue)
    }
    
    func receiveNextFrame() {
        guard let connection = videoConnection else { return }
        
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] data, _, _, error in
            guard let self = self, let data = data, data.count == 4, error == nil else { return }
            
            let length = UInt32(bigEndian: data.withUnsafeBytes { $0.load(as: UInt32.self) })
            
            connection.receive(minimumIncompleteLength: Int(length), maximumLength: Int(length)) { imgData, _, _, _ in
                // BẢO BỐI AUTORELEASEPOOL: Xóa sạch bộ nhớ ngay sau khi dán ảnh lên, chống tràn RAM gây giật lag trên iPhone 7
                autoreleasepool {
                    if let imgData = imgData, let image = UIImage(data: imgData) {
                        DispatchQueue.main.async {
                            self.imageView.image = image
                        }
                    }
                }
                self.receiveNextFrame()
            }
        }
    }
    
    // ==========================================
    // 4. XỬ LÝ CHẠM
    // ==========================================
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
        guard touchConnection?.state == .ready else { return }
        
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
            touchConnection?.send(content: data, completion: .contentProcessed({ _ in }))
        }
    }
    
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) { sendTouches(touches: touches, action: "start") }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) { sendTouches(touches: touches, action: "move") }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { sendTouches(touches: touches, action: "end") }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { sendTouches(touches: touches, action: "end") }
}
