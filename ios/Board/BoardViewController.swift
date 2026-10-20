import UIKit
import WebKit
import Photos
import CoreLocation
import AVFoundation
import MediaPlayer
import AVKit
import CoreMotion

/// GitHub Pages의 보드판 웹페이지를 띄우는 화면.
/// 실행할 때마다 최신 페이지를 받아 저장해 두고, 인터넷이 없으면 마지막으로 받은 페이지를 연다.
/// 사진 저장·GPS·실시간 카메라는 웹페이지가 아니라 아이폰 기능으로 처리한다.
/// 카메라 화면은 웹뷰 뒤에 깔고, 촬영 화면에서는 웹페이지 배경이 투명해져 카메라가 비쳐 보인다.
final class BoardViewController: UIViewController, WKScriptMessageHandler, WKUIDelegate,
                                 CLLocationManagerDelegate, AVCapturePhotoCaptureDelegate {
    static let remoteURL = URL(string: "https://josang0909-svg.github.io/sahsid-cydwi1-defTom/index.html")!

    private var webView: WKWebView!
    private let location = CLLocationManager()

    private let session = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()
    private let camQueue = DispatchQueue(label: "board.camera")
    /// 화면 회전 잠금이 켜져 있어도 폰을 실제로 어느 쪽으로 들었는지 알기 위한 기울기 센서
    private let motion = CMMotionManager()
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var camConfigured = false
    private var camDevice: AVCaptureDevice?
    /// 화면에 보이는 1× 에 해당하는 실제 zoomFactor. 초광각이 있는 카메라는 zoomFactor 1이 0.5× 라서 2 정도가 된다.
    private var zoomBase: CGFloat = 1
    /// 웹페이지 배율 버튼에 보일 배율 (.5, 1, 2, 3 …)
    private var zoomPresets: [Double] = [1, 2]
    private let zoomMaxDisplay: CGFloat = 10

    /// 볼륨 버튼·블루투스 리모컨 셔터 (iOS 17.2+ 는 카메라 앱과 같은 공식 방식, 그 아래는 볼륨 변화 감지)
    private var shutterInteraction: UIInteraction?
    private var volumeObservation: NSKeyValueObservation?
    private let volumeView = MPVolumeView(frame: CGRect(x: -2000, y: -2000, width: 10, height: 10))
    private var resettingVolume = false

    /// 플래시 켬/끔 (웹페이지 버튼)
    private var flashOn = false
    /// 웹페이지가 원하는 사진 폭. 웹페이지에는 이 크기로 줄여 보내고(빠르게), 원본은 여기 들고 있다가 저장할 때 붙인다.
    private var captures: [Int64: (maxW: CGFloat, id: Int)] = [:]   // camQueue: 찍는 중인 사진별 크기·번호 (번호는 웹페이지가 붙임)
    private var lastPhoto: Data?
    private var lastPhotoId = 0                // 메인: lastPhoto가 몇 번 사진의 원본인지
    /// 웹페이지가 알려 준 뷰파인더(4:3) 위치. 카메라 미리보기를 이 자리에만 띄운다.
    private var camRect: CGRect?

    /// 키보드 위 막대(원래 ^ ∨ 완료 자리)에 띄우는 입력 바로가기 버튼. 목록은 웹페이지 설정에서 받는다.
    private let snipBar = SnipBar()

    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    /// 촬영 화면(가로)에서는 홈 바를 한 번 쓸어서는 앱이 넘어가지 않게 (한 번 더 쓸어야 넘어감)
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { orientMask == .portrait ? [] : .all }
    /// 홈·설정은 세로, 촬영 화면은 가로 (웹페이지가 orient 메시지로 바꾼다)
    private var orientMask: UIInterfaceOrientationMask = .portrait
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { orientMask }
    override var preferredInterfaceOrientationForPresentation: UIInterfaceOrientation { orientMask == .portrait ? .portrait : .landscapeRight }

    private var pageURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("www/index.html")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        let content = WKUserContentController()
        content.add(WeakScriptHandler(self), name: "board")
        content.addUserScript(WKUserScript(source: Self.geoShim, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        // 웹페이지가 이 앱의 버전과 기능을 알 수 있게 알려 준다 (오래된 앱이면 페이지가 업데이트 안내를 띄움)
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        content.addUserScript(WKUserScript(source: "window.__boardApp = { version: '\(version)', camera: true, photos: true, focus: true, http: true, orient: true, snipBar: true };",
                                           injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let config = WKWebViewConfiguration()
        config.userContentController = content
        config.allowsInlineMediaPlayback = true

        webView = WKWebView(frame: view.bounds, configuration: config)
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        // 페이지 자체는 스크롤하지 않는다 (키보드가 뜰 때 화면이 밀려 카메라 위치가 어긋나던 원인)
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        webView.scrollView.minimumZoomScale = 1
        webView.scrollView.maximumZoomScale = 1
        webView.scrollView.pinchGestureRecognizer?.isEnabled = false
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardDidHide),
                                               name: UIResponder.keyboardDidHideNotification, object: nil)
        webView.uiDelegate = self
        view.addSubview(webView)
        snipBar.onPick = { [weak self] i in
            self?.webView.evaluateJavaScript("window.__snip && window.__snip(\(i))")
        }
        snipBar.onDone = { [weak self] in self?.webView.endEditing(true) }
        installSnipBar()

        setupShutterButtons()

        location.delegate = self
        location.desiredAccuracy = kCLLocationAccuracyBest
        loadPage()
    }

    /// 웹뷰 입력칸의 키보드 위 막대를 바로가기 막대로 바꾼다.
    /// 웹뷰 안쪽 입력 담당 뷰(WKContentView)를 이 막대를 돌려주는 하위 클래스로 바꿔 끼우는 방식 (iOS 공개 API로는 바꿀 수 없음)
    private static var snipBarRef: UIView?
    private func installSnipBar() {
        Self.snipBarRef = snipBar
        guard let content = webView.scrollView.subviews.first(where: { String(describing: type(of: $0)).hasPrefix("WKContent") }) else { return }
        let base: AnyClass = type(of: content)
        let name = "\(NSStringFromClass(base))_BoardSnips"
        if NSStringFromClass(base) == name { return }
        var cls: AnyClass? = NSClassFromString(name)
        if cls == nil, let made = objc_allocateClassPair(base, name, 0) {
            let block: @convention(block) (AnyObject) -> UIView? = { _ in BoardViewController.snipBarRef }
            class_addMethod(made, #selector(getter: UIResponder.inputAccessoryView),
                            imp_implementationWithBlock(block), "@@:")
            objc_registerClassPair(made)
            cls = made
        }
        if let cls = cls { object_setClass(content, cls) }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        applyPreviewFrame()
    }

    @objc private func keyboardDidHide() {
        webView.scrollView.setZoomScale(1, animated: false)
        webView.scrollView.setContentOffset(.zero, animated: false)
        webView.evaluateJavaScript("window.scrollTo(0,0)")
    }

    private func applyPreviewFrame() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        previewLayer?.frame = camRect ?? view.bounds
        CATransaction.commit()
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        coordinator.animate(alongsideTransition: nil) { _ in self.updateCameraOrientation() }
    }

    private func js(_ code: String) {
        DispatchQueue.main.async { self.webView.evaluateJavaScript(code) }
    }

    // MARK: - 클라우드 백업 요청 (웹뷰 fetch는 file:// 페이지라 CORS에 막힐 수 있어 앱이 대신 보낸다)

    private func httpRequest(id: Int, url: String, method: String, body: String?, headers: [String: String]?) {
        guard let u = URL(string: url), u.scheme == "https" else {
            js("window.__httpDone && __httpDone(\(id), 0, '')"); return
        }
        var req = URLRequest(url: u, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 55)
        req.httpMethod = method
        if let body = body {
            req.httpBody = body.data(using: .utf8)
            req.setValue("text/plain;charset=utf-8", forHTTPHeaderField: "Content-Type")
        }
        headers?.forEach { req.setValue($0.value, forHTTPHeaderField: $0.key) }
        URLSession.shared.dataTask(with: req) { data, response, _ in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let text = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            // 응답 글자를 JSON 문자열로 감싸 그대로 넘긴다
            let quoted = (try? JSONSerialization.data(withJSONObject: [text], options: []))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
            self.js("window.__httpDone && __httpDone(\(id), \(status), \(quoted)[0])")
        }.resume()
    }

    // MARK: - 페이지 로드

    private func loadPage() {
        let fm = FileManager.default
        try? fm.createDirectory(at: pageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: pageURL.path),
           let bundled = Bundle.main.url(forResource: "index", withExtension: "html") {
            try? fm.copyItem(at: bundled, to: pageURL)
        }

        let request = URLRequest(url: Self.remoteURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 4)
        URLSession.shared.dataTask(with: request) { data, response, _ in
            if let data = data, (response as? HTTPURLResponse)?.statusCode == 200, data.count > 1000 {
                try? data.write(to: self.pageURL, options: .atomic)
            }
            DispatchQueue.main.async {
                self.webView.loadFileURL(self.pageURL, allowingReadAccessTo: self.pageURL.deletingLastPathComponent())
            }
        }.resume()
    }

    // MARK: - 웹페이지 → 앱

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        switch type {
        case "save": save(images: body["images"] as? [String] ?? [], original: body["original"] as? Bool ?? false,
                          originalId: body["originalId"] as? Int)
        case "geoStart":
            if location.authorizationStatus == .notDetermined { location.requestWhenInUseAuthorization() }
            location.startUpdatingLocation()
        case "geoStop": location.stopUpdatingLocation()
        case "camStart": startCamera()
        case "camStop": stopCamera()
        case "camCapture": capturePhoto(maxW: CGFloat(body["maxW"] as? Double ?? 0), id: body["id"] as? Int ?? 0)
        case "camFlash":
            let on = body["on"] as? Bool ?? false
            camQueue.async { self.flashOn = on }
        case "camFocus":
            if let x = body["x"] as? Double, let y = body["y"] as? Double {
                focus(at: CGPoint(x: x, y: y), lock: body["lock"] as? Bool ?? false)
            }
        case "camBias": setBias(Float(body["bias"] as? Double ?? 0))
        case "http":
            httpRequest(id: body["id"] as? Int ?? 0, url: body["url"] as? String ?? "",
                        method: body["method"] as? String ?? "GET", body: body["body"] as? String,
                        headers: body["headers"] as? [String: String])
        case "orient": setOrientation(body["mode"] as? String == "landscape" ? .landscape : .portrait)
        case "openPhotos":
            if let url = URL(string: "photos-redirect://") { UIApplication.shared.open(url) }
        case "camZoom":
            if let z = body["z"] as? Double { setZoom(z) }
        case "snips":
            snipBar.setItems(body["list"] as? [String] ?? [])
        case "camRect":
            if let x = body["x"] as? Double, let y = body["y"] as? Double,
               let w = body["w"] as? Double, let h = body["h"] as? Double, w > 0, h > 0 {
                camRect = CGRect(x: x, y: y, width: w, height: h)
                applyPreviewFrame()
            }
        default: break
        }
    }

    // MARK: - 화면 방향

    private func setOrientation(_ mask: UIInterfaceOrientationMask) {
        guard mask != orientMask else { return }
        orientMask = mask
        setNeedsUpdateOfScreenEdgesDeferringSystemGestures()
        if #available(iOS 16.0, *) {
            setNeedsUpdateOfSupportedInterfaceOrientations()
            view.window?.windowScene?.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { _ in }
        } else {
            let o: UIInterfaceOrientation = mask == .portrait ? .portrait : .landscapeRight
            UIDevice.current.setValue(o.rawValue, forKey: "orientation")
            UIViewController.attemptRotationToDeviceOrientation()
        }
    }

    // MARK: - 실시간 카메라

    /// 켜기·끄기 요청이 엇갈려도 마지막 요청대로 되게 한다.
    /// wantCamera는 camQueue에서만, cameraOnScreen은 메인에서만 읽고 쓴다.
    private var wantCamera = false
    private var cameraOnScreen = false

    private func startCamera() {
        cameraOnScreen = true
        if motion.isAccelerometerAvailable && !motion.isAccelerometerActive {
            motion.accelerometerUpdateInterval = 0.2
            motion.startAccelerometerUpdates()
        }
        camQueue.async { self.wantCamera = true }
        AVCaptureDevice.requestAccess(for: .video) { granted in
            guard granted else { return self.js("window.__camState && window.__camState(false)") }
            self.camQueue.async {
                guard self.wantCamera else { return }
                if !self.camConfigured { self.configureCamera() }
                guard self.camConfigured else { return self.js("window.__camState && window.__camState(false)") }
                if !self.session.isRunning { self.session.startRunning() }
                // 켤 때마다 기본 카메라처럼 1× 로 시작
                self.applyZoom(self.zoomBase)
                self.resetFocus()
                let minD = Double((self.camDevice?.minAvailableVideoZoomFactor ?? 1) / self.zoomBase)
                let maxD = Double(self.maxZoomFactor / self.zoomBase)
                let presets = self.zoomPresets.map { String($0) }.joined(separator: ",")
                let hasFlash = self.photoOutput.supportedFlashModes.contains(.on)
                DispatchQueue.main.async {
                    guard self.cameraOnScreen else { return }   // 그 사이 촬영 화면을 나갔으면 그대로 둔다
                    self.previewLayer?.isHidden = false
                    self.setShutterButtons(true)
                    self.updateCameraOrientation()
                    self.webView.evaluateJavaScript("window.__camState && window.__camState(true)")
                    self.webView.evaluateJavaScript("window.__camZoom && window.__camZoom(\(minD), \(maxD), 1, [\(presets)])")
                    self.webView.evaluateJavaScript("window.__camFlash && window.__camFlash(\(hasFlash))")
                }
            }
        }
    }

    private func configureCamera() {
        // 렌즈가 여러 개인 폰은 기본 카메라처럼 배율에 따라 초광각·광각·망원을 알아서 바꿔 쓰는 가상 카메라를 쓴다
        let types: [AVCaptureDevice.DeviceType] = [.builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera, .builtInWideAngleCamera]
        let found = AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: .back).devices
        guard let device = types.lazy.compactMap({ t in found.first { $0.deviceType == t } }).first
                ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device) else { return }
        camDevice = device
        NotificationCenter.default.addObserver(self, selector: #selector(subjectAreaChanged),
                                               name: .AVCaptureDeviceSubjectAreaDidChange, object: device)
        let switchOver = device.virtualDeviceSwitchOverVideoZoomFactors.map { CGFloat($0.doubleValue) }
        let hasUltraWide = device.constituentDevices.contains { $0.deviceType == .builtInUltraWideCamera }
        zoomBase = hasUltraWide ? (switchOver.first ?? 2) : 1
        var presets: [Double] = []
        if hasUltraWide { presets.append(Double(device.minAvailableVideoZoomFactor / zoomBase)) }
        presets.append(1)
        for f in switchOver where f > zoomBase + 0.01 { presets.append(Double((f / zoomBase * 10).rounded() / 10)) }
        if presets.last ?? 1 <= 1 { presets.append(2) }
        zoomPresets = presets
        session.beginConfiguration()
        session.sessionPreset = .photo
        let ok = session.canAddInput(input) && session.canAddOutput(photoOutput)
        if ok { session.addInput(input); session.addOutput(photoOutput) }
        session.commitConfiguration()
        guard ok else { return }   // 실패하면 다음에 다시 시도
        camConfigured = true
        DispatchQueue.main.async {
            let layer = AVCaptureVideoPreviewLayer(session: self.session)
            layer.videoGravity = .resizeAspectFill
            self.view.layer.insertSublayer(layer, at: 0)
            self.previewLayer = layer
            self.applyPreviewFrame()
        }
    }

    // MARK: - 초점·밝기 (기본 카메라처럼: 누르면 그 자리 초점·노출, 길게 누르면 잠금, 위아래로 밝기)

    private var focusLocked = false

    /// 웹페이지 뷰파인더 안의 비율 좌표(0~1)를 받아 카메라 좌표로 바꿔 초점·노출을 맞춘다
    private func focus(at rel: CGPoint, lock: Bool) {
        DispatchQueue.main.async {
            guard let layer = self.previewLayer else { return }
            let p = CGPoint(x: rel.x * layer.bounds.width, y: rel.y * layer.bounds.height)
            let devPoint = layer.captureDevicePointConverted(fromLayerPoint: p)
            self.camQueue.async {
                guard let d = self.camDevice, (try? d.lockForConfiguration()) != nil else { return }
                if d.isFocusPointOfInterestSupported { d.focusPointOfInterest = devPoint }
                if d.isExposurePointOfInterestSupported { d.exposurePointOfInterest = devPoint }
                if d.isFocusModeSupported(.autoFocus) { d.focusMode = .autoFocus }
                if d.isExposureModeSupported(.autoExpose) { d.exposureMode = .autoExpose }
                d.setExposureTargetBias(0, completionHandler: nil)
                d.isSubjectAreaChangeMonitoringEnabled = !lock
                d.unlockForConfiguration()
                self.focusLocked = lock
                if lock {
                    // 맞춘 뒤 잠근다 (AE/AF 잠금)
                    self.camQueue.asyncAfter(deadline: .now() + 0.6) {
                        guard self.focusLocked, (try? d.lockForConfiguration()) != nil else { return }
                        if d.isFocusModeSupported(.locked) { d.focusMode = .locked }
                        if d.isExposureModeSupported(.locked) { d.exposureMode = .locked }
                        d.unlockForConfiguration()
                    }
                }
            }
        }
    }

    private func setBias(_ bias: Float) {
        camQueue.async {
            guard let d = self.camDevice, (try? d.lockForConfiguration()) != nil else { return }
            d.setExposureTargetBias(max(d.minExposureTargetBias, min(d.maxExposureTargetBias, bias)), completionHandler: nil)
            d.unlockForConfiguration()
        }
    }

    /// 화면 가운데 자동 초점·자동 노출로 되돌린다
    private func resetFocus() {
        guard let d = camDevice, (try? d.lockForConfiguration()) != nil else { return }
        let center = CGPoint(x: 0.5, y: 0.5)
        if d.isFocusPointOfInterestSupported { d.focusPointOfInterest = center }
        if d.isExposurePointOfInterestSupported { d.exposurePointOfInterest = center }
        if d.isFocusModeSupported(.continuousAutoFocus) { d.focusMode = .continuousAutoFocus }
        if d.isExposureModeSupported(.continuousAutoExposure) { d.exposureMode = .continuousAutoExposure }
        d.setExposureTargetBias(0, completionHandler: nil)
        d.isSubjectAreaChangeMonitoringEnabled = false
        d.unlockForConfiguration()
        focusLocked = false
    }

    /// 누른 자리 초점 후 장면이 크게 바뀌면 기본 카메라처럼 자동으로 돌아간다 (잠금 중이면 그대로)
    @objc private func subjectAreaChanged() {
        camQueue.async {
            guard !self.focusLocked else { return }
            self.resetFocus()
            self.js("window.__camFocusReset && window.__camFocusReset()")
        }
    }

    private var maxZoomFactor: CGFloat {
        guard let d = camDevice else { return 1 }
        return min(d.maxAvailableVideoZoomFactor, zoomBase * zoomMaxDisplay)
    }

    /// 웹페이지 배율(1 = 1×)을 받아 카메라 zoomFactor로 바꾼다
    private func setZoom(_ display: Double) {
        camQueue.async { self.applyZoom(CGFloat(display) * self.zoomBase) }
    }

    private func applyZoom(_ factor: CGFloat) {
        guard let d = camDevice, (try? d.lockForConfiguration()) != nil else { return }
        d.videoZoomFactor = max(d.minAvailableVideoZoomFactor, min(maxZoomFactor, factor))
        d.unlockForConfiguration()
    }

    // MARK: - 볼륨 버튼 셔터

    private func setupShutterButtons() {
        if #available(iOS 17.2, *) {
            // 카메라가 켜져 있는 동안만 볼륨 버튼이 셔터가 되고, 그 외에는 원래대로 볼륨 조절
            let interaction = AVCaptureEventInteraction { [weak self] event in
                if event.phase == .began { self?.hardwareShutter() }
            }
            interaction.isEnabled = false
            view.addInteraction(interaction)
            shutterInteraction = interaction
        } else {
            volumeView.alpha = 0.01
            view.addSubview(volumeView)
        }
    }

    private func setShutterButtons(_ on: Bool) {
        if #available(iOS 17.2, *) {
            (shutterInteraction as? AVCaptureEventInteraction)?.isEnabled = on
            return
        }
        let audio = AVAudioSession.sharedInstance()
        if on {
            try? audio.setCategory(.ambient, options: [.mixWithOthers])
            try? audio.setActive(true)
            volumeObservation = audio.observe(\.outputVolume, options: [.new]) { [weak self] _, change in
                guard let self = self, let v = change.newValue else { return }
                DispatchQueue.main.async {
                    if self.resettingVolume { self.resettingVolume = false; return }
                    self.hardwareShutter()
                    // 다음 누름도 감지되게 볼륨을 가운데로 되돌린다 (끝까지 올라가 있으면 변화가 없어서)
                    if v > 0.9 || v < 0.1, let slider = self.volumeView.subviews.compactMap({ $0 as? UISlider }).first {
                        self.resettingVolume = true
                        slider.value = 0.5
                    }
                }
            }
        } else {
            volumeObservation = nil
            try? audio.setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    private func hardwareShutter() {
        js("window.__hwShutter && window.__hwShutter()")
    }

    private func stopCamera() {
        motion.stopAccelerometerUpdates()
        cameraOnScreen = false
        setShutterButtons(false)
        previewLayer?.isHidden = true
        camQueue.async {
            self.wantCamera = false
            if self.session.isRunning { self.session.stopRunning() }
        }
    }

    /// 화면이 왼쪽·오른쪽 가로 중 어느 쪽인지에 맞춰 미리보기와 사진 방향을 돌린다.
    private func updateCameraOrientation() {
        let orientation: AVCaptureVideoOrientation =
            view.window?.windowScene?.interfaceOrientation == .landscapeLeft ? .landscapeLeft : .landscapeRight
        previewLayer?.connection?.videoOrientation = orientation
        camQueue.async { self.photoOutput.connection(with: .video)?.videoOrientation = orientation }
    }

    /// 폰을 실제로 든 방향(가로 왼쪽·오른쪽). 화면이 반대로 돌아가 있어도(회전 잠금 등) 사진은 바로 선 방향으로 찍히게 한다.
    /// 중력(x)이 음수면 폰 오른쪽 옆면이 위 = 홈 쪽이 오른쪽인 가로 → 카메라 방향 .landscapeRight(홈 버튼 오른쪽)
    private func heldOrientation() -> AVCaptureVideoOrientation? {
        guard let a = motion.accelerometerData?.acceleration, abs(a.x) > 0.5, abs(a.x) > abs(a.y) else { return nil }
        return a.x < 0 ? .landscapeRight : .landscapeLeft
    }

    private func capturePhoto(maxW: CGFloat, id: Int) {
        let held = heldOrientation()
        camQueue.async {
            guard self.session.isRunning else { return self.js("window.__camShot && window.__camShot(null, false, \(id))") }
            if let held = held { self.photoOutput.connection(with: .video)?.videoOrientation = held }
            let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
            self.captures[settings.uniqueID] = (maxW, id)
            if self.photoOutput.supportedFlashModes.contains(.on) { settings.flashMode = self.flashOn ? .on : .off }
            self.photoOutput.capturePhoto(with: settings, delegate: self)
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let key = photo.resolvedSettings.uniqueID
        let (maxW, id) = camQueue.sync { self.captures.removeValue(forKey: key) ?? (0, 0) }
        guard error == nil, let data = photo.fileDataRepresentation() else {
            return js("window.__camShot && window.__camShot(null, false, \(id))")
        }
        // 저장(save)은 메인에서 읽는다. 번호를 같이 둬서 다른 사진의 원본이 붙지 않게 한다
        DispatchQueue.main.async { self.lastPhoto = data; self.lastPhotoId = id }
        // 웹페이지에는 보드판을 찍을 크기로 줄여서 보낸다 (원본 12MP를 문자열로 넘기면 느려지고 메모리가 쌓임)
        let small = Self.downscale(data, maxWidth: maxW) ?? data
        js("window.__camShot && window.__camShot('data:image/jpeg;base64,\(small.base64EncodedString())', true, \(id))")
    }

    private static func downscale(_ data: Data, maxWidth: CGFloat) -> Data? {
        guard maxWidth > 0, let image = UIImage(data: data) else { return nil }
        let size = image.size
        guard size.width > maxWidth else { return nil }
        let target = CGSize(width: maxWidth, height: (size.height * maxWidth / size.width).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let scaled = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        return scaled.jpegData(compressionQuality: 0.92)
    }

    // MARK: - 사진 저장

    private func save(images: [String], original: Bool, originalId: Int?) {
        let photos = images.compactMap { url -> Data? in
            guard let comma = url.firstIndex(of: ",") else { return nil }
            return Data(base64Encoded: String(url[url.index(after: comma)...]))
        }
        // 보드판 사진이 빠지면 원본만 저장되지 않도록 아예 저장하지 않는다
        guard !photos.isEmpty, photos.count == images.count else { return finishSave(false, "보드판 사진을 만들지 못했습니다") }
        var all = photos
        if original, let orig = lastPhoto, originalId == nil || originalId == lastPhotoId {
            all.append(orig)
            lastPhoto = nil
        }

        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                return self.finishSave(false, "설정 > 현장 보드판에서 사진 접근을 허용해 주세요")
            }
            PHPhotoLibrary.shared().performChanges({
                for data in all {
                    PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: nil)
                }
            }) { ok, _ in self.finishSave(ok, ok ? nil : "저장 실패") }
        }
    }

    private func finishSave(_ ok: Bool, _ message: String?) {
        let msg = message.map { "'\($0)'" } ?? "null"
        DispatchQueue.main.async {
            self.webView.evaluateJavaScript("window.__boardSaved && window.__boardSaved(\(ok), \(msg))")
        }
    }

    // MARK: - GPS

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let l = locations.last else { return }
        let alt = l.verticalAccuracy >= 0 ? "\(l.altitude)" : "null"
        webView.evaluateJavaScript("window.__boardGeo(\(l.coordinate.latitude), \(l.coordinate.longitude), \(alt), \(l.horizontalAccuracy))")
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        guard (error as? CLError)?.code == .denied else { return }
        webView.evaluateJavaScript("window.__boardGeo(0, 0, null, 0, 'denied')")
    }

    /// 웹페이지의 navigator.geolocation을 아이폰 위치 기능으로 바꿔 끼운다.
    private static let geoShim = """
    (function(){
      var cbs = {}, next = 1, last = null;
      function post(t){ window.webkit.messageHandlers.board.postMessage({ type: t }); }
      window.__boardGeo = function(lat, lon, alt, acc, err){
        if(err){
          Object.keys(cbs).forEach(function(k){ if(cbs[k].e) cbs[k].e({ code: 1, message: err }); });
          return;
        }
        last = { coords: { latitude: lat, longitude: lon, altitude: alt, accuracy: acc,
                           altitudeAccuracy: null, heading: null, speed: null }, timestamp: Date.now() };
        Object.keys(cbs).forEach(function(k){ cbs[k].s(last); });
      };
      var geo = {
        watchPosition: function(s, e){
          var id = next++;
          cbs[id] = { s: s, e: e };
          if(last) setTimeout(function(){ s(last); }, 0);
          post('geoStart');
          return id;
        },
        clearWatch: function(id){
          delete cbs[id];
          if(!Object.keys(cbs).length) post('geoStop');
        },
        getCurrentPosition: function(s, e){
          if(last){ setTimeout(function(){ s(last); }, 0); return; }
          var id = geo.watchPosition(function(p){ geo.clearWatch(id); s(p); },
                                     function(x){ geo.clearWatch(id); if(e) e(x); });
        }
      };
      try { Object.defineProperty(navigator, 'geolocation', { get: function(){ return geo; }, configurable: true }); } catch(_){}
    })();
    """

    // MARK: - alert / confirm / prompt

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let a = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "확인", style: .default) { _ in completionHandler() })
        present(a, animated: true)
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let a = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "취소", style: .cancel) { _ in completionHandler(false) })
        a.addAction(UIAlertAction(title: "확인", style: .default) { _ in completionHandler(true) })
        present(a, animated: true)
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        let a = UIAlertController(title: nil, message: prompt, preferredStyle: .alert)
        a.addTextField { $0.text = defaultText }
        a.addAction(UIAlertAction(title: "취소", style: .cancel) { _ in completionHandler(nil) })
        a.addAction(UIAlertAction(title: "확인", style: .default) { _ in completionHandler(a.textFields?.first?.text) })
        present(a, animated: true)
    }
}

/// WKUserContentController가 화면을 강하게 붙잡지 않도록 중간에 끼우는 약한 참조
private final class WeakScriptHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}

/// 키보드 위 막대: 바로가기 버튼(옆으로 밀기) + 오른쪽 끝 [완료]
final class SnipBar: UIInputView {
    var onPick: ((Int) -> Void)?
    var onDone: (() -> Void)?
    private let scroll = UIScrollView()
    private let stack = UIStackView()

    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: 320, height: 46), inputViewStyle: .keyboard)
        autoresizingMask = .flexibleWidth
        allowsSelfSizing = true
        let done = UIButton(type: .system)
        done.setTitle("완료", for: .normal)
        done.titleLabel?.font = .systemFont(ofSize: 17, weight: .semibold)
        done.addTarget(self, action: #selector(doneTap), for: .touchUpInside)
        scroll.showsHorizontalScrollIndicator = false
        stack.axis = .horizontal
        stack.spacing = 8
        stack.alignment = .center
        scroll.addSubview(stack)
        for v in [scroll, stack, done] as [UIView] { v.translatesAutoresizingMaskIntoConstraints = false }
        addSubview(scroll); addSubview(done)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 46),
            done.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -14),
            done.centerYAnchor.constraint(equalTo: centerYAnchor),
            scroll.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: 8),
            scroll.trailingAnchor.constraint(equalTo: done.leadingAnchor, constant: -10),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            stack.heightAnchor.constraint(equalToConstant: 34),
        ])
        setItems(["mm", "cm", "(H=cm)", "(T=cm)", "(B=cm)"])
    }
    required init?(coder: NSCoder) { fatalError() }

    func setItems(_ items: [String]) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (i, t) in items.enumerated() {
            let b = UIButton(type: .system)
            b.setTitle(t, for: .normal)
            b.setTitleColor(.label, for: .normal)
            b.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
            b.backgroundColor = UIColor.secondarySystemFill
            b.layer.cornerRadius = 8
            b.contentEdgeInsets = UIEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
            b.tag = i
            b.addTarget(self, action: #selector(pick(_:)), for: .touchUpInside)
            b.heightAnchor.constraint(equalToConstant: 34).isActive = true
            stack.addArrangedSubview(b)
        }
    }
    @objc private func pick(_ b: UIButton) {
        UIDevice.current.playInputClick()
        onPick?(b.tag)
    }
    @objc private func doneTap() { onDone?() }
}

extension SnipBar: UIInputViewAudioFeedback {
    var enableInputClicksWhenVisible: Bool { true }
}
