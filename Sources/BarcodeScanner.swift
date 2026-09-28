import UIKit
import AVFoundation
import VisionKit
import Vision

/// Full-screen native barcode scanner (EAN-13, EAN-8, UPC-A, UPC-E).
/// VisionKit's DataScanner where the phone supports it, AVFoundation otherwise.
final class BarcodeScanner: NSObject, DataScannerViewControllerDelegate {
    enum Result {
        case code(String, String)
        case cancelled
        case error(String)
    }

    private static var current: BarcodeScanner?
    private var done: ((Result) -> Void)?
    private weak var presented: UIViewController?
    private var finished = false
    private let tint: UIColor

    private init(tint: UIColor) {
        self.tint = tint
    }

    static func start(tint: UIColor, done: @escaping (Result) -> Void) {
        guard current == nil else { return done(.error("unavailable")) }
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else { return done(.error("unavailable")) }
        let scanner = BarcodeScanner(tint: tint)
        scanner.done = done
        current = scanner
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            scanner.present()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { ok in
                DispatchQueue.main.async { ok ? scanner.present() : scanner.finish(.error("denied")) }
            }
        default:
            scanner.finish(.error("denied"))
        }
    }

    private func present() {
        guard let top = UIHelpers.topViewController() else { return finish(.error("unavailable")) }
        let overlay = ScannerOverlay(tint: tint)
        overlay.closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)

        if DataScannerViewController.isSupported && DataScannerViewController.isAvailable {
            let ds = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.ean13, .ean8, .upce])],
                                               isGuidanceEnabled: false,
                                               isHighlightingEnabled: true)
            ds.delegate = self
            ds.modalPresentationStyle = .fullScreen
            overlay.translatesAutoresizingMaskIntoConstraints = false
            ds.overlayContainerView.addSubview(overlay)
            pin(overlay, to: ds.overlayContainerView)
            presented = ds
            top.present(ds, animated: true) {
                do { try ds.startScanning() } catch { self.finish(.error("unavailable")) }
            }
        } else {
            let av = AVScannerViewController()
            av.onCode = { [weak self] code, format in self?.found(code, format) }
            av.onFail = { [weak self] in self?.finish(.error("unavailable")) }
            av.modalPresentationStyle = .fullScreen
            av.loadViewIfNeeded()
            overlay.translatesAutoresizingMaskIntoConstraints = false
            av.view.addSubview(overlay)
            pin(overlay, to: av.view)
            presented = av
            top.present(av, animated: true)
        }
    }

    private func pin(_ v: UIView, to parent: UIView) {
        NSLayoutConstraint.activate([
            v.leadingAnchor.constraint(equalTo: parent.leadingAnchor),
            v.trailingAnchor.constraint(equalTo: parent.trailingAnchor),
            v.topAnchor.constraint(equalTo: parent.topAnchor),
            v.bottomAnchor.constraint(equalTo: parent.bottomAnchor)
        ])
    }

    @objc private func closeTapped() {
        finish(.cancelled)
    }

    private func found(_ rawCode: String, _ rawFormat: String) {
        guard !finished else { return }
        var code = rawCode, format = rawFormat
        // Scanners report UPC-A as EAN-13 with a leading 0.
        if format == "ean13" && code.count == 13 && code.hasPrefix("0") {
            code = String(code.dropFirst())
            format = "upca"
        }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        finish(.code(code, format))
    }

    private func finish(_ result: Result) {
        guard !finished else { return }
        finished = true
        (presented as? DataScannerViewController)?.stopScanning()
        let callback = done
        if let vc = presented {
            vc.dismiss(animated: true) {
                BarcodeScanner.current = nil
                callback?(result)
            }
        } else {
            BarcodeScanner.current = nil
            callback?(result)
        }
    }

    // MARK: DataScanner

    func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
        for item in addedItems {
            if case .barcode(let barcode) = item, let code = barcode.payloadStringValue {
                found(code, Self.formatName(barcode.observation.symbology, code: code))
                return
            }
        }
    }

    func dataScanner(_ dataScanner: DataScannerViewController, becameUnavailableWithError error: DataScannerViewController.ScanningUnavailable) {
        finish(.error("unavailable"))
    }

    static func formatName(_ s: VNBarcodeSymbology, code: String) -> String {
        switch s {
        case .ean8: return "ean8"
        case .upce: return "upce"
        default: return code.count == 12 ? "upca" : "ean13"
        }
    }
}

/// Dark overlay with a guide frame and a close button.
final class ScannerOverlay: UIView {
    let closeButton = UIButton(type: .system)
    private let dim = CAShapeLayer()
    private let frameLayer = CAShapeLayer()
    private let label = UILabel()

    init(tint: UIColor) {
        super.init(frame: .zero)
        isUserInteractionEnabled = true
        dim.fillRule = .evenOdd
        dim.fillColor = UIColor.black.withAlphaComponent(0.55).cgColor
        layer.addSublayer(dim)
        frameLayer.fillColor = UIColor.clear.cgColor
        frameLayer.strokeColor = UIColor.white.cgColor
        frameLayer.lineWidth = 3
        layer.addSublayer(frameLayer)

        let cfg = UIImage.SymbolConfiguration(pointSize: 20, weight: .semibold)
        closeButton.setImage(UIImage(systemName: "xmark", withConfiguration: cfg), for: .normal)
        closeButton.tintColor = .white
        closeButton.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        closeButton.layer.cornerRadius = 22
        closeButton.accessibilityLabel = "Close"
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(closeButton)

        label.text = "Point at the barcode"
        label.textColor = .white
        label.font = .preferredFont(forTextStyle: .headline)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        NSLayoutConstraint.activate([
            closeButton.widthAnchor.constraint(equalToConstant: 44),
            closeButton.heightAnchor.constraint(equalToConstant: 44),
            closeButton.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: 16),
            closeButton.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 12),
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -40)
        ])
        _ = tint
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private var guideRect: CGRect {
        let w = min(bounds.width - 64, 320)
        let h = w * 0.55
        return CGRect(x: (bounds.width - w) / 2, y: (bounds.height - h) / 2 - 40, width: w, height: h)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let path = UIBezierPath(rect: bounds)
        path.append(UIBezierPath(roundedRect: guideRect, cornerRadius: 14))
        dim.path = path.cgPath
        dim.frame = bounds
        frameLayer.path = UIBezierPath(roundedRect: guideRect, cornerRadius: 14).cgPath
        frameLayer.frame = bounds
    }

    /// Let touches through except on the close button.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === closeButton || hit?.isDescendant(of: closeButton) == true ? hit : nil
    }
}

/// Fallback scanner for phones without VisionKit's DataScanner.
final class AVScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onCode: ((String, String) -> Void)?
    var onFail: (() -> Void)?
    private let session = AVCaptureSession()
    private var preview: AVCaptureVideoPreviewLayer?
    private var failed = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            failed = true
            return
        }
        session.addInput(input)
        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else {
            failed = true
            return
        }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.ean13, .ean8, .upce].filter { output.availableMetadataObjectTypes.contains($0) }
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        layer.frame = view.bounds
        view.layer.insertSublayer(layer, at: 0)
        preview = layer
        let s = session
        DispatchQueue.global(qos: .userInitiated).async { s.startRunning() }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if failed { onFail?() }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        preview?.frame = view.bounds
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        let s = session
        DispatchQueue.global(qos: .userInitiated).async { s.stopRunning() }
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard let obj = metadataObjects.first as? AVMetadataMachineReadableCodeObject, let code = obj.stringValue else { return }
        let format: String
        switch obj.type {
        case .ean8: format = "ean8"
        case .upce: format = "upce"
        default: format = code.count == 12 ? "upca" : "ean13"
        }
        onCode?(code, format)
    }
}
