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
    
    // Lớp hiển thị Video bằng Phần cứng của Apple (0 Delay)
    var videoLayer = AVSampleBufferDisplayLayer()
    
    // Buffer và biến dùng cho VideoToolbox
    var videoBuffer = Data()
    var formatDesc: CMVideoFormatDescription?
    var spsData: [UInt8]?
    var ppsData: [UInt8]?
    
    // Biến quản lý chế độ Toàn màn hình
    var isFullscreen = false
    var swipe3StartY: CGFloat = 0
    var isSwiping3Down = false
    
    override var prefersStatusBarHidden: Bool { return isFullscreen }
    override var prefersHomeIndicatorAutoHidden: Bool { return isFullscreen }
    override var shouldAutorotate: Bool { return true }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { return .landscape }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        view.isMultipleTouchEnabled = true
        
        // Cài đặt lớp hiển thị Video phần cứng
        videoLayer.frame = view.bounds
        videoLayer.videoGravity = .resizeAspectFill
        
        var controlTimebase: CMTimebase?
        CMTimebaseCreateWithMasterClock(allocator: kCFAllocatorDefault, masterClock: CMClockGetHostTimeClock(), timebaseOut: &controlTimebase)
        videoLayer.controlTimebase = controlTimebase
        CMTimebaseSetTime(videoLayer.controlTimebase!, time: CMTimeMake(value: 0, timescale: 1))
        CMTimebaseSetRate(videoLayer.controlTimebase!, rate: 1.0)
        
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
    // 1. BẢNG NHẬP IP NHƯ CŨ
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
    
    // ==========================================
    // 2. KẾT NỐI VÀ XỬ LÝ VIDEOTOOLBOX H264
    // ==========================================
    func startConnection(to ip: String) {
        setupNetwork(pcIP: ip)
        setupH264Stream(pcIP: ip)
    }
    
    func setupNetwork(pcIP: String) {
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(pcIP), port: 8765)
        touchConnection = NWConnection(to: endpoint, using: .tcp)
        touchConnection?.stateUpdateHandler = { [weak self] state in
            if case .failed(_) = state { DispatchQueue.main.async { self?.promptForIP() } }
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
    // 3. XỬ LÝ CHẠM ĐA ĐIỂM & GESTURE 3 NGÓN
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
    
    func sendTouches(touches: Set<UITouch>, event: UIEvent?, action: String) {
        // --- XỬ LÝ THAO TÁC VUỐT 3 NGÓN XUỐNG ĐỂ FULLSCREEN ---
        if let allTouches = event?.allTouches, allTouches.count == 3 {
            let avgY = allTouches.reduce(0) { $0 + $1.location(in: view).y } / 3.0
            if action == "start" {
                swipe3StartY = avgY
                isSwiping3Down = false
            } else if action == "move" {
                if avgY - swipe3StartY > 80 { isSwiping3Down = true } // Vuốt xuống 80px
            } else if action == "end" {
                if isSwiping3Down {
                    isFullscreen.toggle()
                    UIView.animate(withDuration: 0.3) {
                        self.setNeedsStatusBarAppearanceUpdate()
                        self.setNeedsUpdateOfHomeIndicatorAutoHidden()
                    }
                    isSwiping3Down = false
                }
            }
        }
        // --------------------------------------------------------

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
    
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) { sendTouches(touches: touches, event: event, action: "start") }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) { sendTouches(touches: touches, event: event, action: "move") }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { sendTouches(touches: touches, event: event, action: "end") }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { sendTouches(touches: touches, event: event, action: "end") }
}
