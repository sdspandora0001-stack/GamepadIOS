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
    
    // Lớp hiển thị Video bằng Phần cứng của Apple
    var videoLayer = AVSampleBufferDisplayLayer()
    
    // Giao diện tự chế để không làm mất Fullscreen
    let uiContainer = UIView()
    let ipTextField = UITextField()
    
    // Buffer và biến dùng cho VideoToolbox
    var videoBuffer = Data()
    var formatDesc: CMVideoFormatDescription?
    var spsData: [UInt8]?
    var ppsData: [UInt8]?
    
    override var prefersStatusBarHidden: Bool { return true }
    override var prefersHomeIndicatorAutoHidden: Bool { return true }
    override var shouldAutorotate: Bool { return true }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { return .landscape }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        view.isMultipleTouchEnabled = true
        
        // Cài đặt lớp hiển thị Video phần cứng
        videoLayer.frame = view.bounds
        videoLayer.videoGravity = .resizeAspectFill
        
        // Tối ưu để báo cho iOS biết ta cần hiển thị ngay lập tức (0 delay)
        var controlTimebase: CMTimebase?
        CMTimebaseCreateWithMasterClock(allocator: kCFAllocatorDefault, masterClock: CMClockGetHostTimeClock(), timebaseOut: &controlTimebase)
        videoLayer.controlTimebase = controlTimebase
        CMTimebaseSetTime(videoLayer.controlTimebase!, time: CMTimeMake(value: 0, timescale: 1))
        CMTimebaseSetRate(videoLayer.controlTimebase!, rate: 1.0)
        
        view.layer.addSublayer(videoLayer)
        
        setupCustomUI()
    }
    
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        videoLayer.frame = view.bounds
        uiContainer.center = view.center
    }
    
    // ==========================================
    // 1. TẠO GIAO DIỆN NHẬP IP TRỰC TIẾP TRÊN MÀN HÌNH
    // ==========================================
    func setupCustomUI() {
        uiContainer.frame = CGRect(x: 0, y: 0, width: 300, height: 150)
        uiContainer.backgroundColor = UIColor(white: 0.2, alpha: 0.8)
        uiContainer.layer.cornerRadius = 10
        view.addSubview(uiContainer)
        
        let label = UILabel(frame: CGRect(x: 10, y: 10, width: 280, height: 30))
        label.text = "Nhập IP PC (Cáp USB)"
        label.textColor = .white
        label.textAlignment = .center
        uiContainer.addSubview(label)
        
        ipTextField.frame = CGRect(x: 20, y: 50, width: 260, height: 40)
        ipTextField.backgroundColor = .white
        ipTextField.textColor = .black
        ipTextField.keyboardType = .decimalPad
        ipTextField.textAlignment = .center
        ipTextField.text = UserDefaults.standard.string(forKey: "LastPCIP") ?? "172.20.10."
        ipTextField.layer.cornerRadius = 5
        uiContainer.addSubview(ipTextField)
        
        let btn = UIButton(frame: CGRect(x: 80, y: 100, width: 140, height: 40))
        btn.setTitle("Bắt đầu", for: .normal)
        btn.backgroundColor = .systemBlue
        btn.layer.cornerRadius = 5
        btn.addTarget(self, action: #selector(btnClicked), for: .touchUpInside)
        uiContainer.addSubview(btn)
    }
    
    @objc func btnClicked() {
        let ip = ipTextField.text ?? ""
        UserDefaults.standard.set(ip, forKey: "LastPCIP")
        ipTextField.resignFirstResponder()
        uiContainer.isHidden = true // Giấu bảng đi, giữ nguyên Fullscreen
        startConnection(to: ip)
    }
    
    // ==========================================
    // 2. KẾT NỐI VÀ XỬ LÝ VIDEOTOOLBOX
    // ==========================================
    func startConnection(to ip: String) {
        setupNetwork(pcIP: ip)
        setupH264Stream(pcIP: ip)
    }
    
    func setupNetwork(pcIP: String) {
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(pcIP), port: 8765)
        touchConnection = NWConnection(to: endpoint, using: .tcp)
        touchConnection?.stateUpdateHandler = { [weak self] state in
            if case .failed(_) = state { DispatchQueue.main.async { self?.uiContainer.isHidden = false } }
        }
        touchConnection?.start(queue: queue)
    }
    
    func setupH264Stream(pcIP: String) {
        videoConnection?.cancel()
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(pcIP), port: 12345)
        
        let params = NWParameters.tcp
        if let tcpOptions = params.defaultProtocolStack.internetProtocol as? NWProtocolTCP.Options {
            tcpOptions.noDelay = true // 0 Delay TCP
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
    
    // Thuật toán bóc tách dữ liệu H.264 thô (Tìm các byte 00 00 00 01)
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
                
                // Phân loại khung hình (SPS, PPS, I-Frame, P-Frame)
                if naluType == 7 {
                    spsData = bytes
                } else if naluType == 8 {
                    ppsData = bytes
                    createVideoFormatDescription()
                } else if naluType == 5 || naluType == 1 { // Khung hình có chứa ảnh
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
            if data[searchIndex] == sequence[0] &&
               data[searchIndex+1] == sequence[1] &&
               data[searchIndex+2] == sequence[2] &&
               data[searchIndex+3] == sequence[3] {
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
            allocator: kCFAllocatorDefault,
            parameterSetCount: 2,
            parameterSetPointers: parameterSetPointers,
            parameterSetSizes: parameterSetSizes,
            nalUnitHeaderLength: 4,
            formatDescriptionOut: &formatDesc
        )
    }
    
    func decodeAndRender(naluData: [UInt8]) {
        guard let formatDesc = formatDesc else { return }
        
        // VideoToolbox yêu cầu thay 4 byte start code (00 00 00 01) thành 4 byte kích thước
        var length = CFSwapInt32HostToBig(UInt32(naluData.count))
        var blockBuffer: CMBlockBuffer?
        
        let dataPointer = UnsafeMutablePointer<UInt8>.allocate(capacity: naluData.count + 4)
        memcpy(dataPointer, &length, 4)
        memcpy(dataPointer + 4, naluData, naluData.count)
        
        CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: dataPointer,
            blockLength: naluData.count + 4,
            blockAllocator: kCFAllocatorNull,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: naluData.count + 4,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        
        var sampleBuffer: CMSampleBuffer?
        var sampleSizeArray = [naluData.count + 4]
        
        CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDesc,
            sampleCount: 1,
            sampleTimingEntryCount: 0,
            sampleTimingArray: nil,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSizeArray,
            sampleBufferOut: &sampleBuffer
        )
        
        if let sb = sampleBuffer {
            // Nhét trực tiếp vào Chip đồ họa để bung ra màn hình!
            DispatchQueue.main.async {
                if self.videoLayer.status == .failed {
                    self.videoLayer.flush()
                }
                self.videoLayer.enqueue(sb)
            }
        }
        dataPointer.deallocate()
    }
    
    // ==========================================
    // 3. XỬ LÝ CHẠM ĐA ĐIỂM
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
