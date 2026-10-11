import UIKit
import WebKit
import Photos
import CoreLocation
import AVFoundation

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
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var camConfigured = false

    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .landscape }
    override var preferredInterfaceOrientationForPresentation: UIInterfaceOrientation { .landscapeRight }

    private var pageURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("www/index.html")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        let content = WKUserContentController()
        content.add(self, name: "board")
        content.addUserScript(WKUserScript(source: Self.geoShim, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let config = WKWebViewConfiguration()
        config.userContentController = content
        config.allowsInlineMediaPlayback = true

        webView = WKWebView(frame: view.bounds, configuration: config)
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.uiDelegate = self
        view.addSubview(webView)

        location.delegate = self
        location.desiredAccuracy = kCLLocationAccuracyBest
        loadPage()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        coordinator.animate(alongsideTransition: nil) { _ in self.updateCameraOrientation() }
    }

    private func js(_ code: String) {
        DispatchQueue.main.async { self.webView.evaluateJavaScript(code) }
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
        case "save": save(images: body["images"] as? [String] ?? [])
        case "geoStart":
            if location.authorizationStatus == .notDetermined { location.requestWhenInUseAuthorization() }
            location.startUpdatingLocation()
        case "geoStop": location.stopUpdatingLocation()
        case "camStart": startCamera()
        case "camStop": stopCamera()
        case "camCapture": capturePhoto()
        default: break
        }
    }

    // MARK: - 실시간 카메라

    private func startCamera() {
        AVCaptureDevice.requestAccess(for: .video) { granted in
            guard granted else { return self.js("window.__camState && window.__camState(false)") }
            self.camQueue.async {
                if !self.camConfigured { self.configureCamera() }
                guard self.camConfigured else { return self.js("window.__camState && window.__camState(false)") }
                if !self.session.isRunning { self.session.startRunning() }
                DispatchQueue.main.async {
                    self.previewLayer?.isHidden = false
                    self.updateCameraOrientation()
                    self.webView.evaluateJavaScript("window.__camState && window.__camState(true)")
                }
            }
        }
    }

    private func configureCamera() {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device) else { return }
        session.beginConfiguration()
        session.sessionPreset = .photo
        if session.canAddInput(input) { session.addInput(input) }
        if session.canAddOutput(photoOutput) { session.addOutput(photoOutput) }
        session.commitConfiguration()
        camConfigured = true
        DispatchQueue.main.async {
            let layer = AVCaptureVideoPreviewLayer(session: self.session)
            layer.videoGravity = .resizeAspectFill
            layer.frame = self.view.bounds
            self.view.layer.insertSublayer(layer, at: 0)
            self.previewLayer = layer
        }
    }

    private func stopCamera() {
        previewLayer?.isHidden = true
        camQueue.async { if self.session.isRunning { self.session.stopRunning() } }
    }

    /// 화면이 왼쪽·오른쪽 가로 중 어느 쪽인지에 맞춰 미리보기와 사진 방향을 돌린다.
    private func updateCameraOrientation() {
        let orientation: AVCaptureVideoOrientation =
            view.window?.windowScene?.interfaceOrientation == .landscapeLeft ? .landscapeLeft : .landscapeRight
        previewLayer?.connection?.videoOrientation = orientation
        photoOutput.connection(with: .video)?.videoOrientation = orientation
    }

    private func capturePhoto() {
        camQueue.async {
            guard self.session.isRunning else { return self.js("window.__camShot && window.__camShot(null)") }
            let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
            self.photoOutput.capturePhoto(with: settings, delegate: self)
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard error == nil, let data = photo.fileDataRepresentation() else {
            return js("window.__camShot && window.__camShot(null)")
        }
        js("window.__camShot && window.__camShot('data:image/jpeg;base64,\(data.base64EncodedString())')")
    }

    // MARK: - 사진 저장

    private func save(images: [String]) {
        let photos = images.compactMap { url -> Data? in
            guard let comma = url.firstIndex(of: ",") else { return nil }
            return Data(base64Encoded: String(url[url.index(after: comma)...]))
        }
        guard !photos.isEmpty else { return finishSave(false, "저장할 사진이 없습니다") }

        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                return self.finishSave(false, "설정 > 현장 보드판에서 사진 접근을 허용해 주세요")
            }
            PHPhotoLibrary.shared().performChanges({
                for data in photos {
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
