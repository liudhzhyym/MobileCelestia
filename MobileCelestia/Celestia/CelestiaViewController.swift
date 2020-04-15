//
//  CelestiaViewController.swift
//  MobileCelestia
//
//  Created by 李林峰 on 2020/2/20.
//  Copyright © 2020 李林峰. All rights reserved.
//

import UIKit
import CelestiaCore
import GLKit

enum CelestiaLoadingError: Error {
    case openGLError
    case celestiaError
}

enum CelestiaAction: Int8 {
    case goto = 103
    case center = 99
    case playpause = 32
    case backward = 107
    case forward = 108
    case currentTime = 33
    case syncOrbit = 121
    case lock = 58
    case chase = 34
    case follow = 102
    case runDemo = 100
    case cancelScript = 27
}

extension CelestiaAction {
    static var allCases: [CelestiaAction] {
        return [.goto, .center, .follow, .chase, .syncOrbit, .lock]
    }
}

extension CelestiaAppCore {
    func receive(_ action: CelestiaAction) {
        charEnter(action.rawValue)
    }
}

protocol CelestiaViewControllerDelegate: class {
    func celestiaController(_ celestiaController: CelestiaViewController, selection: BodyInfo?)
}

class CelestiaViewController: UIViewController {
    private enum DragMode {
        case rotate
        case move

        var button: MouseButton {
            return self == .rotate ? .right : .left
        }
    }

    private enum ZoomMode {
        case `in`
        case out

        var distance: CGFloat {
            return self == .out ? 1 : -1
        }
    }

    private var core: CelestiaAppCore!

    // MARK: rendering
    private var currentSize: CGSize = .zero
    private var ready = false
    private var displayLink: CADisplayLink?

    private lazy var glView = GLKView(frame: .zero)

    // MARK: gesture
    private var oneFingerStartPoint: CGPoint?
    private var currentPanDistance: CGFloat?

    private var dataDirectoryURL: UniformedURL!
    private var configFileURL: UniformedURL!

    weak var celestiaDelegate: CelestiaViewControllerDelegate!

    private var currentDragMode = DragMode.move
    private var zoomMode: ZoomMode? = nil

    override func loadView() {
        let container = UIView()
        container.backgroundColor = .darkBackground

        glView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(glView)

        NSLayoutConstraint.activate([
            glView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            glView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            glView.topAnchor.constraint(equalTo: container.topAnchor),
            glView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        glView.delegate = self
        glView.contentScaleFactor = 1

        let controlView = CelestiaControlView(items: [
            CelestiaControlButton.toggle(offImage: #imageLiteral(resourceName: "control_rotate_off"), offAction: .switchToMove, onImage: #imageLiteral(resourceName: "control_rotate_on"), onAction: .switchToRotate),
            CelestiaControlButton.pressAndHold(image: #imageLiteral(resourceName: "control_zoom_in"), action: .zoomIn),
            CelestiaControlButton.pressAndHold(image: #imageLiteral(resourceName: "control_zoom_out"), action: .zoomOut),
            CelestiaControlButton.tap(image: #imageLiteral(resourceName: "control_action_menu"), action: .showMenu),
        ])
        controlView.delegate = self
        controlView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(controlView)
        NSLayoutConstraint.activate([
            controlView.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])

        if #available(iOS 11.0, *) {
            NSLayoutConstraint.activate([
                controlView.trailingAnchor.constraint(equalTo: container.safeAreaLayoutGuide.trailingAnchor, constant: -8),
            ])
        } else {
            NSLayoutConstraint.activate([
                controlView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            ])
        }

        view = container
    }
}

extension CelestiaViewController: GLKViewDelegate {
    func glkView(_ view: GLKView, drawIn rect: CGRect) {
        guard ready else { return }

        let size = CGSize(width: CGFloat(view.drawableWidth), height: CGFloat(view.drawableHeight))
        if size != currentSize {
            currentSize = size
            core.resize(to: currentSize)
        }

        core.draw()
        core.tick()
    }
}

extension CelestiaViewController: CelestiaControlViewDelegate {
    func celestiaControlView(_ celestiaControlView: CelestiaControlView, pressDidStartWith action: CelestiaControlAction) {
        zoomMode = action == .zoomIn ? .in : .out
    }

    func celestiaControlView(_ celestiaControlView: CelestiaControlView, pressDidEndWith action: CelestiaControlAction) {
        zoomMode = nil
    }

    func celestiaControlView(_ celestiaControlView: CelestiaControlView, didTapWith action: CelestiaControlAction) {
        switch action {
        case .showMenu:
            let sel = core.simulation.selection
            let info = sel.isEmpty ? nil : BodyInfo(selection: sel)
            celestiaDelegate.celestiaController(self, selection: info)
        default:
            break
        }
    }

    func celestiaControlView(_ celestiaControlView: CelestiaControlView, didToggleTo action: CelestiaControlAction) {
        currentDragMode = action == .switchToMove ? .move : .rotate
    }
}

extension CelestiaViewController {
    @objc private func handlePan(_ pan: UIPanGestureRecognizer) {
        let location = pan.location(in: pan.view)
        switch pan.state {
        case .possible:
            break
        case .began:
            oneFingerStartPoint = location
            core.mouseButtonDown(at: location, modifiers: 0, with: currentDragMode.button)
        case .changed:
            let current = oneFingerStartPoint!
            let offset = CGPoint(x: location.x - current.x, y: location.y - current.y)
            oneFingerStartPoint = location
            core.mouseMove(by: offset, modifiers: 0, with: currentDragMode.button)
        case .ended, .cancelled, .failed:
            fallthrough
        @unknown default:
            core.mouseButtonUp(at: location, modifiers: 0, with: currentDragMode.button)
            oneFingerStartPoint = nil
        }
    }

    @objc private func handlePinch(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .possible:
            break
        case .began:
            if gesture.numberOfTouches < 2 {
                // cancel the gesture recognizer
                gesture.isEnabled = false
                gesture.isEnabled = true
                break
            }
            let point1 = gesture.location(ofTouch: 0, in: view)
            let point2 = gesture.location(ofTouch: 1, in: view)
            let length = hypot(abs(point1.x - point2.x), abs(point1.y - point2.y))
            let center = CGPoint(x: (point1.x + point2.x) / 2, y: (point1.y + point2.y) / 2)
            currentPanDistance = length
            core.mouseButtonDown(at: center, modifiers: 0, with: .left)
        case .changed:
            if gesture.numberOfTouches < 2 {
                // cancel the gesture recognizer
                gesture.isEnabled = false
                gesture.isEnabled = true
                break
            }
            let point1 = gesture.location(ofTouch: 0, in: view)
            let point2 = gesture.location(ofTouch: 1, in: view)
            let length = hypot(abs(point1.x - point2.x), abs(point1.y - point2.y))
            let delta = length / currentPanDistance!
            // FIXME: 8 is a magic number
            core.mouseWheel(by: (1 - delta) * currentPanDistance! / 8, modifiers: 0)
            currentPanDistance = length
        case .ended, .cancelled, .failed:
            fallthrough
        @unknown default:
            currentPanDistance = nil
        }
    }

    @objc private func handleTap(_ tap: UITapGestureRecognizer) {
        switch tap.state {
        case .ended:
            let location = tap.location(in: tap.view)
            core.mouseButtonDown(at: location, modifiers: 0, with: .left)
            core.mouseButtonUp(at: location, modifiers: 0, with: .left)
        default:
            break
        }
    }

    @objc private func handleEdgePan(_ pan: UIScreenEdgePanGestureRecognizer) {
        switch pan.state {
        case .ended:
            let sel = core.simulation.selection
            let info = sel.isEmpty ? nil : BodyInfo(selection: sel)
            celestiaDelegate.celestiaController(self, selection: info)
        default:
            break
        }
    }
}

extension CelestiaViewController {
    @objc private func handleDisplayLink(_ sender: CADisplayLink) {
        if let mode = zoomMode {
            core.mouseWheel(by: mode.distance, modifiers: 0)
        }
        glView.display()
    }
}

extension CelestiaViewController {
    private func setupOpenGL() -> Bool {
        guard let context = EAGLContext(api: .openGLES2) else { return false }

        EAGLContext.setCurrent(context)

        glView.context = context
        glView.enableSetNeedsDisplay = false
        glView.drawableDepthFormat = .format24

        return true
    }

    private func setupCelestia(statusUpdater: @escaping (String) -> Void, errorHandler: @escaping () -> Bool, completionHandler: @escaping (Bool) -> Void) {
        _ = CelestiaAppCore.initGL()

        core = CelestiaAppCore.shared

        let context = glView.context
        DispatchQueue.global().async { [unowned self] in
            var success = false
            var shouldRetry = true

            EAGLContext.setCurrent(context)

            while !success && shouldRetry {
                self.dataDirectoryURL = currentDataDirectory()
                self.configFileURL = currentConfigFile()

                FileManager.default.changeCurrentDirectoryPath(self.dataDirectoryURL.url.path)
                CelestiaAppCore.setLocaleDirectory(self.dataDirectoryURL.url.path + "/locale")

                guard self.core.startSimulation(configFileName: self.configFileURL.url.path, extraDirectories: [extraDirectory].compactMap{$0?.path}, progress: { (st) in
                    DispatchQueue.main.async { statusUpdater(st) }
                }) else {
                    shouldRetry = errorHandler()
                    continue
                }

                guard self.core.startRenderer() else {
                    print("Failed to start renderer.")
                    shouldRetry = errorHandler()
                    continue
                }

                self.core.loadUserDefaultsWithAppDefaults(atPath: Bundle.main.path(forResource: "defaults", ofType: "plist"))
                success = true
            }

            DispatchQueue.main.async { completionHandler(success) }
        }
    }

    private func setupGestures() {
        let pan1 = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan1.minimumNumberOfTouches = 1
        pan1.maximumNumberOfTouches = 1
        pan1.delegate = self
        glView.addGestureRecognizer(pan1)

        let pinch = UIPanGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        pinch.minimumNumberOfTouches = 2
        pinch.maximumNumberOfTouches = 2
        pinch.delegate = self
        glView.addGestureRecognizer(pinch)

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tap.delegate = self
        glView.addGestureRecognizer(tap)

        let rightEdge = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(handleEdgePan(_:)))
        rightEdge.edges = .right
        pan1.require(toFail: rightEdge)
        glView.addGestureRecognizer(rightEdge)
    }

    private func setupDisplayLink() {
        displayLink = CADisplayLink(target: self, selector: #selector(handleDisplayLink(_:)))
        displayLink?.add(to: .current, forMode: .default)
    }
}

extension CelestiaViewController: UIGestureRecognizerDelegate {
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        var area = gestureRecognizer.view!.bounds
        if #available(iOS 11.0, *) {
            area = area.inset(by: gestureRecognizer.view!.safeAreaInsets)
        }
        // reserve area
        area = area.insetBy(dx: 16, dy: 16)
        if !area.contains(gestureRecognizer.location(in: gestureRecognizer.view)) {
            return false
        }
        if gestureRecognizer is UIPinchGestureRecognizer {
            return gestureRecognizer.numberOfTouches == 2
        }
        return true
    }
}

extension CelestiaViewController {
    func load(statusUpdater: @escaping (String) -> Void, errorHandler: @escaping () -> Bool, completionHandler: @escaping (Result<Void, CelestiaLoadingError>) -> Void) {
        guard setupOpenGL() else {
            completionHandler(.failure(.openGLError))
            return
        }
        setupCelestia(statusUpdater: { (st) in
            statusUpdater(st)
        }, errorHandler: {
            return errorHandler()
        }, completionHandler: { (success) in
            guard success else {
                completionHandler(.failure(.celestiaError))
                return
            }

            self.start()

            self.setupGestures()

            self.setupDisplayLink()

            self.ready = true

            completionHandler(.success(()))
        })
    }

    private func start() {
        core.tick()
        core.start()
    }
}

extension CelestiaViewController {
    func receive(action: CelestiaAction) {
        core.receive(action)
    }

    func select(_ bodyInfo: BodyInfo) {
        core.selection = bodyInfo
    }

    var currentURL: URL {
        return URL(string: core.currentURL)!
    }

    func screenshot() -> UIImage {
        return UIGraphicsImageRenderer(size: glView.bounds.size).image { (_) in
            self.glView.drawHierarchy(in: self.glView.bounds, afterScreenUpdates: false)
        }
    }

    func openURL(_ url: UniformedURL) {
        if url.url.isFileURL {
            core.runScript(at: url.url.path)
        } else {
            core.go(to: url.url.absoluteString)
        }
    }
}