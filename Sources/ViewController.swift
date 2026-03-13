import UIKit
import Network
import VideoToolbox
import AVFoundation

class ViewController: UIViewController {
    
    var touchConnection: NWConnection?
    var videoConnection: NWConnection?
    
    let queue = DispatchQueue(label: "TouchNetworkQueue")
    let videoQueue = DispatchQueue(label: "VideoNetworkQueue")
    
    var touchMap = [UITouch: Int]()
    var availableIds = Array(0...9)
    
    var videoLayer = AVSampleBufferDisplayLayer()
    var videoBuffer = Data()
    var formatDesc: CMVideoFormatDescription?
    var spsData: [UInt8]?
    var ppsData: [UInt8]?
    
    // Giao diện nhập IP Tự chế (Chống phá vỡ Fullscreen)
    let customAlertView = UIView()
    let ipTextField = UITextField()
    
    // ==========================================
    // CẤU HÌNH FULLSCREEN TUYỆT ĐỐI VÀ CHỐNG ĐƠ MÉP
    // ==========================================
    override var prefersStatusBarHidden: Bool { return true }
    override var prefersHomeIndicatorAutoHidden: Bool { return true }
    override var shouldAutorotate: Bool { return true }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { return .landscape }
    
    // Lệnh này giúp mép màn hình nhận cảm ứng ngay lập tức thay vì bắt vuốt 2 lần
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { return .all }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        view.isMultipleTouchEnabled = true
        
        // Ép iOS dọn sạch các thanh công cụ
        setNeedsStatusBarAppearanceUpdate()
        setNeedsUpdateOfHomeIndicatorAutoHidden()
        
        // Setup Video Layer
        videoLayer.frame = view.bounds
        videoLayer.videoGravity = .resizeAspectFill
        
        var controlTimebase: CMTimebase?
        CMTimebaseCreateWithMasterClock(allocator: kCFAllocatorDefault, masterClock: CMClockGetHostTimeClock(), timebaseOut: &controlTimebase)
        videoLayer.controlTimebase = controlTimebase
        CMTimebaseSetTime(videoLayer.controlTimebase!, time: CMTimeMake(value: 0, timescale: 1))
        CMTimebaseSetRate(videoLayer.controlTimebase!, rate: 1.0)
        view.layer.addSublayer(videoLayer)
        
        // THÊM: GESTURE VUỐT 3 NGÓN CHÍNH CHỦ CỦA APPLE
        let swipeDown = UISwipeGestureRecognizer(target: self, action: #selector(handle3FingerSwipe))
        swipeDown.numberOfTouchesRequired = 3
        swipeDown.direction = .down
        view.addGestureRecognizer(swipeDown)
        
        // Vẽ bảng nhập IP
        setupCustomAlertUI()
    }
    
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        videoLayer.frame = view.bounds
        customAlertView.center = view.center
    }
    
    // ==========================================
    // GIAO DIỆN NHẬP IP TỰ CHẾ (Không dùng UIAlertController)
    // ==========================================
    func setupCustomAlertUI() {
        customAlertView.frame = CGRect(x: 0, y: 0, width: 320, height: 180)
        customAlertView.backgroundColor = UIColor(white: 0.15, alpha: 0.95)
        customAlertView.layer.cornerRadius = 15
        customAlertView.layer.shadowColor = UIColor.black.cgColor
        customAlertView.layer.shadowOpacity = 0.5
        customAlertView.layer.shadowOffset = CGSize(width: 0, height: 5)
        view.addSubview(customAlertView)
        
        let titleLbl = UILabel(frame: CGRect(x: 20, y: 15, width: 280, height: 30))
        titleLbl.text = "Nhập IP Máy Tính"
        titleLbl.textColor = .white
        titleLbl.font = UIFont.boldSystemFont(ofSize: 18)
        titleLbl.textAlignment = .center
        customAlertView.addSubview(titleLbl)
        
        let subLbl = UILabel(frame: CGRect(x: 20, y: 45, width: 280, height: 20))
        subLbl.text = "(Cắm cáp USB & Bật Hotspot)"
        subLbl.textColor = .lightGray
        subLbl.font = UIFont.systemFont(ofSize: 13)
        subLbl.textAlignment = .center
        customAlertView.addSubview(subLbl)
        
        ipTextField.frame = CGRect(x: 30, y: 75, width: 260, height: 40)
        ipTextField.backgroundColor = .white
        ipTextField.textColor = .black
        ipTextField.keyboardType = .decimalPad
        ipTextField.textAlignment = .center
        ipTextField.layer.cornerRadius = 8
        ipTextField.text = UserDefaults.standard.string(forKey: "LastPCIP") ?? "172.20.10."
        customAlertView.addSubview(ipTextField)
        
        let btn = UIButton(frame: CGRect(x: 85, y: 125, width: 150, height: 40))
        btn.setTitle("Bắt đầu kết nối", for: .normal)
        btn.backgroundColor = UIColor.systemBlue
        btn.layer.cornerRadius = 8
        btn.titleLabel?.font = UIFont.boldSystemFont(ofSize: 16)
        btn.addTarget(self, action: #selector(btnStartClicked), for: .touchUpInside)
        customAlertView.addSubview(btn)
    }
    
    @objc func btnStartClicked() {
        let ip = ipTextField.text ?? ""
        UserDefaults.standard.set(ip, forKey: "LastPCIP")
        ipTextField.resignFirstResponder()
        
        // Tàng hình bảng nhập IP
        UIView.animate(withDuration: 0.3) {
            self.customAlertView.alpha = 0
        } completion: { _ in
            self.customAlertView.isHidden = true
            self.startConnection(to: ip)
        }
    }
    
    // Xử lý sự kiện vuốt 3 ngón (Hiện lại bảng IP)
    @objc func handle3FingerSwipe() {
        self.customAlertView.isHidden = false
        UIView.animate(withDuration: 0.3) {
            self.customAlertView.alpha = 1
        }
    }
    
    // ==========================================
    // KẾT NỐI MẠNG & GIẢI MÃ VIDEO
    // ==========================================
    func startConnection(to ip: String) {
        setupNetwork(pcIP: ip)
        setupH264Stream(pcIP: ip)
    }
    
    func setupNetwork(pcIP: String) {
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(pcIP), port: 8765)
        touchConnection = NWConnection(to: endpoint, using: .tcp)
        touchConnection?.stateUpdateHandler = { [weak self] state in
            if case .failed(_) = state { 
                DispatchQueue.main.async { self?.handle3FingerSwipe() } // Lỗi mạng thì hiện lại bảng
            }
        }
        touchConnection?.start(queue: queue)
    }
    
    func setupH264Stream(pcIP: String) {
        videoConnection?.cancel()
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(pcIP), port: 12345)
        
        let params = NWParameters.tcp
        if let tcpOptions = params.defaultProtocolStack.internetProtocol as? NWProtocolTCP.Options {
            tcpOptions.noDelay = true
        }
        
        videoConnection = NWConnection(to: endpoint, using: params)
        videoConnection?.stateUpdateHandler = { [weak self] state in
            if case .ready = state { self?.receiveRawH264Data() }
        }
        videoConnection?.start(queue: videoQueue)
    }
    
    func receiveRawH264Data() {
        videoConnection?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self, let data = data, error == nil else { return }
            
            self.videoBuffer.append(data)
            self.extractNALUnits()
            
            if !isComplete { self.receiveRawH264Data() }
        }
    }
    
    func extractNALUnits() {
        let startCode: [UInt8] = [0, 0, 0, 1]
        
        while true {
            guard let startIndex = findSequence(startCode, in: videoBuffer) else { break }
            let nextStartIndex = findSequence(startCode, in: videoBuffer, searchRange: (startIndex + 4)..<videoBuffer.count)
            let endIndex = nextStartIndex ?? videoBuffer.count
            let naluData = videoBuffer.subdata(in: (startIndex + 4)..<endIndex)
            
            if naluData.count > 0 {
                let bytes = [UInt8](naluData)
                let naluType = bytes[0] & 0x1F
                
                if naluType == 7 {
                    spsData = bytes
                } else if naluType == 8 {
                    ppsData = bytes
                    createVideoFormatDescription()
                } else if naluType == 5 || naluType == 1 {
                    decodeAndRender(naluData: bytes)
                }
            }
            
            if let next = nextStartIndex {
                videoBuffer.removeSubrange(0..<next)
            } else {
                videoBuffer.removeAll()
                break
            }
        }
    }
    
    func findSequence(_ sequence: [UInt8], in data: Data, searchRange: Range<Int>? = nil) -> Int? {
        let range = searchRange ?? 0..<data.count
        var searchIndex = range.lowerBound
        while searchIndex <= range.upperBound - sequence.count {
            if data[searchIndex] == sequence[0] && data[searchIndex+1] == sequence[1] &&
               data[searchIndex+2] == sequence[2] && data[searchIndex+3] == sequence[3] {
                return searchIndex
            }
            searchIndex += 1
        }
        return nil
    }
    
    func createVideoFormatDescription() {
        guard let sps = spsData, let pps = ppsData else { return }
        let spsPointer = UnsafePointer<UInt8>(sps)
        let ppsPointer = UnsafePointer<UInt8>(pps)
        let parameterSetPointers = [spsPointer, ppsPointer]
        let parameterSetSizes = [sps.count, pps.count]
        
        CMVideoFormatDescriptionCreateFromH264ParameterSets(
            allocator: kCFAllocatorDefault, parameterSetCount: 2,
            parameterSetPointers: parameterSetPointers, parameterSetSizes: parameterSetSizes,
            nalUnitHeaderLength: 4, formatDescriptionOut: &formatDesc
        )
    }
    
    func decodeAndRender(naluData: [UInt8]) {
        guard let formatDesc = formatDesc else { return }
        
        var length = CFSwapInt32HostToBig(UInt32(naluData.count))
        var blockBuffer: CMBlockBuffer?
        let dataPointer = UnsafeMutablePointer<UInt8>.allocate(capacity: naluData.count + 4)
        memcpy(dataPointer, &length, 4)
        memcpy(dataPointer + 4, naluData, naluData.count)
        
        CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: dataPointer, blockLength: naluData.count + 4,
            blockAllocator: kCFAllocatorNull, customBlockSource: nil, offsetToData: 0,
            dataLength: naluData.count + 4, flags: 0, blockBufferOut: &blockBuffer
        )
        
        var sampleBuffer: CMSampleBuffer?
        var sampleSizeArray = [naluData.count + 4]
        
        CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: blockBuffer, formatDescription: formatDesc,
            sampleCount: 1, sampleTimingEntryCount: 0, sampleTimingArray: nil,
            sampleSizeEntryCount: 1, sampleSizeArray: &sampleSizeArray, sampleBufferOut: &sampleBuffer
        )
        
        if let sb = sampleBuffer {
            DispatchQueue.main.async {
                if self.videoLayer.status == .failed { self.videoLayer.flush() }
                self.videoLayer.enqueue(sb)
            }
        }
        dataPointer.deallocate()
    }
    
    // ==========================================
    // CẢM ỨNG ĐA ĐIỂM
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
            touchesPayload.append(["id": id, "action": action, "x": location.x / screenWidth, "y": location.y / screenHeight])
            if action == "end" { releaseTouchId(for: touch) }
        }
        
        if touchesPayload.isEmpty { return }
        let payload: [String: Any] = ["type": "multitouch", "touches": touchesPayload]
        if let jsonData = try? JSONSerialization.data(withJSONObject: payload),
           var jsonString = String(data: jsonData, encoding: .utf8) {
            jsonString += "\n"
            touchConnection?.send(content: jsonString.data(using: .utf8)!, completion: .contentProcessed({ _ in }))
        }
    }
    
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) { sendTouches(touches: touches, action: "start") }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) { sendTouches(touches: touches, action: "move") }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { sendTouches(touches: touches, action: "end") }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { sendTouches(touches: touches, action: "end") }
}
