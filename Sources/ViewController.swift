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
        
        setupVideoPlayer()
        setupNetwork()
    }
    
    func setupNetwork() {
        // Kết nối tới IP localhost qua cổng 8765 do pymobiledevice3 mở
        let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: 8765)
        connection = NWConnection(to: endpoint, using: .tcp)
        
        connection?.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                print("Đã nối mạng TCP tới PC")
            case .failed(_):
                // Thử lại nếu mất mạng
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    self?.setupNetwork()
                }
            default: break
            }
        }
        connection?.start(queue: queue)
    }
    
    func setupVideoPlayer() {
        mediaPlayer = VLCMediaPlayer()
        mediaPlayer.delegate = self
        mediaPlayer.drawable = self.view
        
        // Nhận luồng Video H264 siêu mượt qua cổng 12345
        let url = URL(string: "udp://@127.0.0.1:12345")!
        let media = VLCMedia(url: url)
        
        // Ép VLC giảm độ trễ (delay) xuống thấp nhất có thể
        media.addOptions([
            "--network-caching=50",
            "--clock-jitter=0",
            "--drop-late-frames"
        ])
        
        mediaPlayer.media = media
        mediaPlayer.play()
    }
    
    // XỬ LÝ CHẠM
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
                "id": id,
                "action": action,
                "x": location.x / screenWidth,
                "y": location.y / screenHeight
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
