import UIKit
import Network
import CoreGraphics

class ViewController: UIViewController {
    
    var touchConnection: NWConnection?
    var videoConnection: NWConnection?
    
    let queue = DispatchQueue(label: "TouchNetworkQueue")
    let videoQueue = DispatchQueue(label: "VideoNetworkQueue")
    
    var touchMap = [UITouch: Int]()
    var availableIds = Array(0...9)
    
    // Dùng CALayer thay vì UIImageView để hiển thị pixel thô trực tiếp
    let videoLayer = CALayer()
    
    // ==========================================
    // 1. CẤU HÌNH HIỂN THỊ TRÀN MÀN HÌNH TỐI ĐA
    // ==========================================
    override var prefersStatusBarHidden: Bool {
        return true
    }
    
    override var prefersHomeIndicatorAutoHidden: Bool {
        return true
    }
    
    override var shouldAutorotate: Bool {
        return true
    }
    
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        return .landscape
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        view.isMultipleTouchEnabled = true
        
        // Ép iOS cập nhật lại giao diện, ép mất thanh trạng thái
        setNeedsStatusBarAppearanceUpdate()
        setNeedsUpdateOfHomeIndicatorAutoHidden()
        
        // Cấu hình Layer hứng ảnh thô
        videoLayer.frame = view.bounds
        videoLayer.contentsGravity = .resizeAspectFill
        view.layer.addSublayer(videoLayer)
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.promptForIP()
        }
    }
    
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        videoLayer.frame = view.bounds
    }
    
    // ==========================================
    // 2. GIAO DIỆN KẾT NỐI
    // ==========================================
    func promptForIP() {
        let alert = UIAlertController(title: "Nhập IP Máy Tính", message: "Kết nối qua Cáp USB (vd: 172.20.10.x)", preferredStyle: .alert)
        alert.addTextField { textField in
            textField.keyboardType = .decimalPad
            textField.text = UserDefaults.standard.string(forKey: "LastPCIP") ?? "172.20.10."
        }
        
        alert.addAction(UIAlertAction(title: "Bắt đầu", style: .default, handler: { [weak self] _ in
            let ip = alert.textFields?.first?.text ?? ""
            UserDefaults.standard.set(ip, forKey: "LastPCIP")
            self?.startConnection(to: ip)
        }))
        present(alert, animated: true)
    }
    
    func startConnection(to ip: String) {
        setupNetwork(pcIP: ip)
        setupRawImageStream(pcIP: ip)
    }
    
    func setupNetwork(pcIP: String) {
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(pcIP), port: 8765)
        touchConnection = NWConnection(to: endpoint, using: .tcp)
        touchConnection?.stateUpdateHandler = { [weak self] state in
            if case .failed(_) = state { DispatchQueue.main.async { self?.promptForIP() } }
        }
        touchConnection?.start(queue: queue)
    }
    
    // ==========================================
    // 3. NHẬN PIXEL THÔ VÀ ĐỔ RA MÀN HÌNH (0% CPU DECODE)
    // ==========================================
    func setupRawImageStream(pcIP: String) {
        videoConnection?.cancel()
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(pcIP), port: 12345)
        
        let params = NWParameters.tcp
        if let tcpOptions = params.defaultProtocolStack.internetProtocol as? NWProtocolTCP.Options {
            tcpOptions.noDelay = true
        }
        
        videoConnection = NWConnection(to: endpoint, using: params)
        videoConnection?.stateUpdateHandler = { [weak self] state in
            if case .ready = state {
                self?.receiveNextRawFrame()
            }
        }
        videoConnection?.start(queue: videoQueue)
    }
    
    func receiveNextRawFrame() {
        guard let connection = videoConnection else { return }
        
        // Đọc 4 byte để lấy dung lượng của mảng pixel
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] data, _, _, error in
            guard let self = self, let data = data, data.count == 4, error == nil else { return }
            
            let length = UInt32(bigEndian: data.withUnsafeBytes { $0.load(as: UInt32.self) })
            
            // Đọc mảng pixel BGRA thô
            connection.receive(minimumIncompleteLength: Int(length), maximumLength: Int(length)) { rawData, _, _, _ in
                if let rawData = rawData {
                    self.renderRawPixels(data: rawData)
                }
                self.receiveNextRawFrame()
            }
        }
    }
    
    // Hàm này biến mảng Byte thô thành hình ảnh mà KHÔNG CẦN DECODE JPEG
    func renderRawPixels(data: Data) {
        // Kích thước chuẩn được hạ xuống để vừa với băng thông cáp Lightning (USB 2.0)
        let width = 640
        let height = 360
        let bytesPerRow = width * 4 // Mỗi pixel 4 byte (B, G, R, A)
        
        // Hệ màu tương thích trực tiếp với dữ liệu mss xuất ra từ Windows
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue
        
        guard let provider = CGDataProvider(data: data as CFData) else { return }
        
        if let cgImage = CGImage(width: width, height: height,
                                 bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
                                 space: colorSpace, bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo),
                                 provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) {
            
            DispatchQueue.main.async {
                // Đổ thẳng vào Layer màn hình (Giống hệt cách màn hình máy tính hoạt động)
                self.videoLayer.contents = cgImage
            }
        }
    }
    
    // ==========================================
    // 4. XỬ LÝ CHẠM ĐA ĐIỂM
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
