//
// CelestiaViewController.swift
//
// Copyright © 2020 Celestia Development Team. All rights reserved.
//
// This program is free software; you can redistribute it and/or
// modify it under the terms of the GNU General Public License
// as published by the Free Software Foundation; either version 2
// of the License, or (at your option) any later version.
//

import UIKit
import CelestiaCore

#if !USE_MGL
import GLKit
#endif

enum CelestiaLoadingError: Error {
    case openGLError
    case celestiaError
}

enum CelestiaAction: Int8 {
    case goto = 103
    case center = 99
    case playpause = 32
    case reverse = 106
    case slower = 107
    case faster = 108
    case currentTime = 33
    case syncOrbit = 121
    case lock = 58
    case chase = 34
    case follow = 102
    case runDemo = 100
    case cancelScript = 27
    case home = 104
}

extension CelestiaAction {
    static var allCases: [CelestiaAction] {
        return [.goto, .center, .follow, .chase, .syncOrbit, .lock]
    }
}

extension CelestiaAppCore {
    func receive(_ action: CelestiaAction) {
        if textEnterMode != .normal {
            textEnterMode = .normal
        }
        charEnter(action.rawValue)
    }
}

protocol CelestiaViewControllerDelegate: class {
    func celestiaController(_ celestiaController: CelestiaViewController, requestShowActionMenuWithSelection selection: CelestiaSelection)
    func celestiaController(_ celestiaController: CelestiaViewController, requestShowInfoWithSelection selection: CelestiaSelection)
    func celestiaController(_ celestiaController: CelestiaViewController, requestWebInfo webURL: URL)
}

private class PanGestureRecognizer: UIPanGestureRecognizer {
    @available(iOS 13.4, *)
    var supportedMouseButtons: UIEvent.ButtonMask {
        get { return UIEvent.ButtonMask(rawValue: supportedMouseButtonsRawValue) }
        set { supportedMouseButtonsRawValue = newValue.rawValue }
    }

    private var supportedMouseButtonsRawValue: Int = {
        if #available(iOS 13.4, *) {
            return UIEvent.ButtonMask.primary.rawValue
        }
        return 1
    }()

    // HACK, support other buttons by override this private method in UIKit
    @objc private var _defaultAllowedMouseButtons: Int {
        return supportedMouseButtonsRawValue
    }
}

class CelestiaViewController: UIViewController {
    private enum InteractionMode {
        case object
        case camera

        var button: MouseButton {
            return self == .object ? .right : .left
        }

        var next: InteractionMode {
            return self == .object ? .camera : .object
        }
    }

    private enum ZoomMode {
        case `in`
        case out

        var distance: CGFloat {
            return self == .out ? 1 : -1
        }
    }

    struct Constant {
        static let controlViewTrailingMargin: CGFloat = 8
        static let controlViewHideAnimationDuration: TimeInterval = 0.2
        static let controlViewShowAnimationDuration: TimeInterval = 0.2
    }

    private var core: CelestiaAppCore!

    // MARK: rendering
    private var currentSize: CGSize = .zero
    private var ready = false
    private var displayLink: CADisplayLink?
    private var displaySource: DispatchSourceUserDataAdd?

    #if USE_MGL
    private lazy var glView = MGLKView(frame: .zero)
    #else
    private lazy var glView = GLKView(frame: .zero)
    #endif

    private var pendingSelection: CelestiaSelection?

    // MARK: gesture
    private var oneFingerStartPoint: CGPoint?
    private var currentPanDistance: CGFloat?

    private var dataDirectoryURL: UniformedURL!
    private var configFileURL: UniformedURL!

    weak var celestiaDelegate: CelestiaViewControllerDelegate!

    private var interactionMode = InteractionMode.object { didSet { currentInteractionMode = interactionMode } }
    private var currentInteractionMode = InteractionMode.object
    private var zoomMode: ZoomMode? = nil

    private lazy var activeControlView = CelestiaControlView(items: [
        CelestiaControlButton.toggle(offImage: #imageLiteral(resourceName: "control_mode_object"), offAction: .switchToObject, onImage: #imageLiteral(resourceName: "control_mode_camera"), onAction: .switchToCamera),
        CelestiaControlButton.pressAndHold(image: #imageLiteral(resourceName: "control_zoom_in"), action: .zoomIn),
        CelestiaControlButton.pressAndHold(image: #imageLiteral(resourceName: "control_zoom_out"), action: .zoomOut),
        CelestiaControlButton.tap(image: #imageLiteral(resourceName: "control_info"), action: .info),
        CelestiaControlButton.tap(image: #imageLiteral(resourceName: "control_action_menu"), action: .showMenu),
        CelestiaControlButton.tap(image: #imageLiteral(resourceName: "control_hide"), action: .hide),
    ])

    private lazy var inactiveControlView = CelestiaControlView(items: [
        CelestiaControlButton.tap(image: #imageLiteral(resourceName: "control_show"), action: .show),
    ])

    private var currentControlView: CelestiaControlView?

    override func loadView() {
        let container = UIView()
        container.backgroundColor = .darkBackground

        glView.translatesAutoresizingMaskIntoConstraints = false
        if UserDefaults.app[.fullDPI] == true {
            glView.contentScaleFactor = UIScreen.main.scale
        } else {
            glView.contentScaleFactor = 1
        }

        container.addSubview(glView)

        NSLayoutConstraint.activate([
            glView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            glView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            glView.topAnchor.constraint(equalTo: container.topAnchor),
            glView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        setupOpenGL()
        glView.delegate = self

        activeControlView.delegate = self
        inactiveControlView.delegate = self
        activeControlView.translatesAutoresizingMaskIntoConstraints = false
        inactiveControlView.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(activeControlView)
        container.addSubview(inactiveControlView)

        NSLayoutConstraint.activate([
            activeControlView.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            activeControlView.trailingAnchor.constraint(equalTo: container.safeAreaLayoutGuide.trailingAnchor, constant: -Constant.controlViewTrailingMargin),
            inactiveControlView.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            inactiveControlView.leadingAnchor.constraint(equalTo: container.trailingAnchor)
        ])

        currentControlView = activeControlView

        view = container
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()

        guard ready else { return }

        core?.setSafeAreaInsets(view.safeAreaInsets.scale(by: glView.contentScaleFactor))
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard ready else { return }

        if #available(iOS 13.4, *), let key = presses.first?.key {
            core.keyDown(with: key.input, modifiers: UInt(key.modifierFlags.rawValue))
        } else {
            super.pressesBegan(presses, with: event)
        }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard ready else { return }

        if #available(iOS 13.4, *), let key = presses.first?.key {
            core.keyUp(with: key.input, modifiers: UInt(key.modifierFlags.rawValue))
        } else {
            super.pressesEnded(presses, with: event)
        }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard ready else { return }

        if #available(iOS 13.4, *), let key = presses.first?.key {
            core.keyUp(with: key.input, modifiers: UInt(key.modifierFlags.rawValue))
        } else {
            super.pressesCancelled(presses, with: event)
        }
    }
}

#if targetEnvironment(macCatalyst)
@available(iOS 13.0, *)
extension CelestiaViewController: UIContextMenuInteractionDelegate {
    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        core.mouseButtonDown(at: interaction.location(in: glView).scale(by: glView.contentScaleFactor), modifiers: 0, with: .right)
        core.mouseButtonUp(at: interaction.location(in: glView).scale(by: glView.contentScaleFactor), modifiers: 0, with: .right)

        guard let selection = pendingSelection else { return nil }
        pendingSelection = nil

        guard let core = self.core else { return nil }

        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { (_) -> UIMenu? in
            var actions: [UIMenuElement] = [
                UIAction(title: core.simulation.universe.name(for: selection), handler: { [weak self] _ in
                    guard let self = self else { return }
                    self.celestiaDelegate.celestiaController(self, requestShowInfoWithSelection: selection)
                })
            ]

            actions.append(UIMenu(title: "", options: .displayInline, children: CelestiaAction.allCases.map { action in
                return UIAction(title: action.description) { (_) in
                    core.simulation.selection = selection
                    core.receive(action)
                }
            }))

            if let entry = selection.object {
                let browserItem = CelestiaBrowserItem(name: core.simulation.universe.name(for: selection), catEntry: entry, provider: core.simulation.universe)
                actions.append(UIMenu(title: "", options: .displayInline, children: browserItem.children.compactMap { $0.createMenuItems(additionalItemName: CelestiaString("Go", comment: "")) { (selection) in
                    core.simulation.selection = selection
                    core.receive(.goto)
                    }
                }))
            }

            if let alternativeSurfaces = selection.body?.alternateSurfaceNames, alternativeSurfaces.count > 0 {
                let displaySurface = core.simulation.activeObserver.displayedSurface
                let defaultSurfaceItem = UIAction(title: CelestiaString("Default", comment: "")) { _ in
                    core.simulation.activeObserver.displayedSurface = ""
                }
                defaultSurfaceItem.state = displaySurface == "" ? .on : .off
                let otherSurfaces = alternativeSurfaces.map { name -> UIAction in
                    let action = UIAction(title: name) { _ in
                        core.simulation.activeObserver.displayedSurface = name
                    }
                    action.state = displaySurface == name ? .on : .off
                    return action
                }
                let menu = UIMenu(title: "Alternate Surfaces", children: [defaultSurfaceItem] + otherSurfaces)
                actions.append(menu)
            }

            let markerOptions = (0...CelestiaMarkerRepresentation.crosshair.rawValue).map { CelestiaMarkerRepresentation(rawValue: $0)?.localizedTitle ?? "" } + [CelestiaString("Unmark", comment: "")]
            let markerMenu = UIMenu(title: CelestiaString("Mark", comment: ""), children: markerOptions.enumerated().map() { index, name -> UIAction in
                    return UIAction(title: name) { [weak self] _ in
                        guard let self = self else { return }
                        if let marker = CelestiaMarkerRepresentation(rawValue: UInt(index)) {
                            self.core.simulation.universe.mark(selection, with: marker)
                            self.core.showMarkers = true
                        } else {
                            self.core.simulation.universe.unmark(selection)
                        }
                    }
                }
            )
            actions.append(UIMenu(title: "", options: .displayInline, children: [markerMenu]))

            if selection.body != nil {
                
            }

            if let webInfo = selection.webInfoURL, let url = URL(string: webInfo) {
                actions.append(UIMenu(title: "", options: .displayInline, children: [UIAction(title: CelestiaString("Web Info", comment: ""), handler: { [weak self] (_) in
                    guard let self = self else { return }
                    self.celestiaDelegate?.celestiaController(self, requestWebInfo: url)
                })]))
            }

            #if !targetEnvironment(macCatalyst)
            actions.append(UIMenu(title: "", options: .displayInline, children: [
                UIAction(title: CelestiaString("Cancel", comment: ""), handler: { _ in })
            ]))
            #endif

            return UIMenu(title: "", children: actions)
        }
    }
}
#endif

extension CelestiaViewController: CelestiaAppCoreDelegate {
    func celestiaAppCoreFatalErrorHappened(_ error: String) {}

    func celestiaAppCoreCursorShapeChanged(_ shape: CursorShape) {}

    func celestiaAppCoreCursorDidRequestContextMenu(at location: CGPoint, with selection: CelestiaSelection) {
        pendingSelection = selection
    }

    func celestiaAppCoreWatchedFlagDidChange(_ changedFlag: CelestiaWatcherFlag) {}
}

private extension CelestiaAppCore {
    func setSafeAreaInsets(_ safeAreaInsets: UIEdgeInsets) {
        setSafeAreaInsets(left: safeAreaInsets.left, top: safeAreaInsets.top, right: safeAreaInsets.right, bottom: safeAreaInsets.bottom)
    }
}

@available(iOS 13.0, *)
extension CelestiaBrowserItem {
    func createMenuItems(additionalItemName: String, with callback: @escaping (CelestiaSelection) -> Void) -> UIMenu? {
        var items = [UIMenuElement]()

        if let ent = entry {
            items.append(UIAction(title: CelestiaString(additionalItemName, comment: ""), handler: { (_) in
                guard let selection = CelestiaSelection(object: ent) else { return }
                callback(selection)
            }))
        }

        var childItems = [UIMenuElement]()
        for i in 0..<children.count {

            let subItemName = childName(at: Int(i))!
            let child = self.child(with: subItemName)!
            if let childMenu = child.createMenuItems(additionalItemName: additionalItemName, with: callback) {
                childItems.append(childMenu)
            }
        }
        if childItems.count > 0 {
            items.append(UIMenu(title: "", options: .displayInline, children: childItems))
        }
        return items.count == 0 ? nil : UIMenu(title: name, children: items)
    }
}

@available(iOS 13.4, *)
private extension UIKey {
    var input: String? {
        let c = characters
        if c.count > 0 {
            return c
        }
        return charactersIgnoringModifiers
    }
}

#if USE_MGL
extension CelestiaViewController: MGLKViewDelegate {
    func mglkView(_ view: MGLKView!, drawIn rect: CGRect) {
        guard ready else { return }

        let size = view.drawableSize
        if size != currentSize {
            currentSize = size
            core.resize(to: currentSize)
        }

        core.draw()
        core.tick()
    }
}
#else
extension CelestiaViewController: GLKViewDelegate {
    func glkView(_ view: GLKView, drawIn rect: CGRect) {
        guard ready else { return }

        let size = CGSize(width: view.drawableWidth, height: view.drawableHeight)
        if size != currentSize {
            currentSize = size
            core.resize(to: currentSize)
        }

        core.draw()
        core.tick()
    }
}
#endif

extension CelestiaViewController: CelestiaControlViewDelegate {
    func celestiaControlView(_ celestiaControlView: CelestiaControlView, pressDidStartWith action: CelestiaControlAction) {
        zoomMode = action == .zoomIn ? .in : .out
    }

    func celestiaControlView(_ celestiaControlView: CelestiaControlView, pressDidEndWith action: CelestiaControlAction) {
        zoomMode = nil
    }

    func celestiaControlView(_ celestiaControlView: CelestiaControlView, didTapWith action: CelestiaControlAction) {
        let sel = core.simulation.selection
        switch action {
        case .showMenu:
            celestiaDelegate.celestiaController(self, requestShowActionMenuWithSelection: sel)
        case .info:
            celestiaDelegate.celestiaController(self, requestShowInfoWithSelection: sel)
        case .hide:
            hideCurrentControlViewToShow(inactiveControlView)
        case .show:
            hideCurrentControlViewToShow(activeControlView)
        default:
            break
        }
    }

    private func hideCurrentControlViewToShow(_ anotherView: CelestiaControlView) {
        guard let activeView = currentControlView else { return }
        guard let superview = activeView.superview else { return }
        guard anotherView != activeView else { return }

        guard let activeViewConstraint = activeView.constraintsAffectingLayout(for: .horizontal).filter({ ($0.firstItem as? UIView) == activeView && ($0.secondItem as? NSObject) == superview.safeAreaLayoutGuide }).first else {
            return
        }
        guard let anotherViewConstrant = anotherView.constraintsAffectingLayout(for: .horizontal).filter({ ($0.firstItem as? UIView) == anotherView && ($0.secondItem as? UIView) == superview }).first else {
            return
        }

        activeViewConstraint.isActive = false
        activeView.leadingAnchor.constraint(equalTo: superview.trailingAnchor).isActive = true
        let hideAnimator = UIViewPropertyAnimator(duration: Constant.controlViewHideAnimationDuration, curve: .linear) { [weak self] in
            self?.view.setNeedsLayout()
            self?.view.layoutIfNeeded()
        }

        let showAnimator = UIViewPropertyAnimator(duration: Constant.controlViewShowAnimationDuration, curve: .linear) { [weak self] in
            self?.view.setNeedsLayout()
            self?.view.layoutIfNeeded()
        }

        hideAnimator.addCompletion { (_) in
            anotherViewConstrant.isActive = false
            anotherView.trailingAnchor.constraint(equalTo: superview.safeAreaLayoutGuide.trailingAnchor, constant: -Constant.controlViewTrailingMargin).isActive = true
            showAnimator.startAnimation()
        }

        showAnimator.addAnimations { [weak self] in
            self?.currentControlView = anotherView
        }

        hideAnimator.startAnimation()
    }

    func celestiaControlView(_ celestiaControlView: CelestiaControlView, didToggleTo action: CelestiaControlAction) {
        let toastDuration: TimeInterval = 1
        interactionMode = action == .switchToObject ? .object : .camera
        switch action {
        case .switchToObject:
            interactionMode = .object
            if let window = view.window {
                Toast.show(text: CelestiaString("Switched to object mode", comment: ""), in: window, duration: toastDuration)
            }
        case .switchToCamera:
            interactionMode = .camera
            if let window = view.window {
                Toast.show(text: CelestiaString("Switched to camera mode", comment: ""), in: window, duration: toastDuration)
            }
        default:
            fatalError("Unknown mode found: \(action)")
        }
    }
}

extension CelestiaViewController {
    @objc private func handlePanZoom(_ pan: UIPanGestureRecognizer) {
        switch pan.state {
        case .changed:
            callZoom(deltaY: pan.translation(in: glView).y * glView.contentScaleFactor / 400)
        case .possible, .began, .ended, .cancelled, .failed:
            fallthrough
        @unknown default:
            break
        }
    }

    @objc private func handlePan(_ pan: UIPanGestureRecognizer) {
        let location = pan.location(in: pan.view).scale(by: glView.contentScaleFactor)
        switch pan.state {
        case .possible:
            break
        case .began:
            #if targetEnvironment(macCatalyst)
            NSCursor.hide()
            #endif
            if #available(iOS 13.4, *) {
                if pan.modifierFlags.contains(.control) || pan.buttonMask.contains(.secondary) {
                    // When control is clicked, use next drag mode
                    currentInteractionMode = interactionMode.next
                } else {
                    currentInteractionMode = interactionMode
                }
            } else {
                currentInteractionMode = interactionMode
            }
            oneFingerStartPoint = location
            core.mouseButtonDown(at: location, modifiers: 0, with: currentInteractionMode.button)
        case .changed:
            let current = oneFingerStartPoint!
            let offset = CGPoint(x: location.x - current.x, y: location.y - current.y)
            oneFingerStartPoint = location
            core.mouseMove(by: offset, modifiers: 0, with: currentInteractionMode.button)
        case .ended, .cancelled, .failed:
            fallthrough
        @unknown default:
            #if targetEnvironment(macCatalyst)
            NSCursor.unhide()
            #endif
            currentInteractionMode = interactionMode
            core.mouseButtonUp(at: location, modifiers: 0, with: currentInteractionMode.button)
            oneFingerStartPoint = nil
        }
    }

    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
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
            let point1 = gesture.location(ofTouch: 0, in: view).scale(by: glView.contentScaleFactor)
            let point2 = gesture.location(ofTouch: 1, in: view).scale(by: glView.contentScaleFactor)
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
            let point1 = gesture.location(ofTouch: 0, in: view).scale(by: glView.contentScaleFactor)
            let point2 = gesture.location(ofTouch: 1, in: view).scale(by: glView.contentScaleFactor)
            let length = hypot(abs(point1.x - point2.x), abs(point1.y - point2.y))
            let delta = length / currentPanDistance!
            // FIXME: 8 is a magic number
            let y = (1 - delta) * currentPanDistance! / 8
            callZoom(deltaY: y)
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
            let location = tap.location(in: tap.view).scale(by: glView.contentScaleFactor)
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
            celestiaDelegate.celestiaController(self, requestShowActionMenuWithSelection: sel)
        default:
            break
        }
    }

    private func callZoom(deltaY: CGFloat) {
        if currentInteractionMode == .camera {
            core.mouseMove(by: CGPoint(x: 0, y: deltaY), modifiers: UInt(UIKeyModifierFlags.shift.rawValue), with: .left)
        } else {
            core.mouseWheel(by: deltaY, modifiers: 0)
        }
    }
}

extension CelestiaViewController {
    @objc private func handleDisplayLink(_ sender: CADisplayLink) {
        displaySource?.add(data: 1)
    }

    private func displaySourceCallback() {
        if let mode = zoomMode {
            callZoom(deltaY: mode.distance)
        }
        glView.display()
    }
}

extension CelestiaViewController {
    @discardableResult private func setupOpenGL() -> Bool {
        #if USE_MGL
        let context = MGLContext(api: kMGLRenderingAPIOpenGLES2)
        MGLContext.setCurrent(context)

        glView.context = context
        glView.drawableDepthFormat = MGLDrawableDepthFormat24

        glView.drawableMultisample = UserDefaults.app[.msaa] == true ? MGLDrawableMultisample4X : MGLDrawableMultisampleNone
        #else
        let context = EAGLContext(api: .openGLES2)!

        EAGLContext.setCurrent(context)

        glView.context = context
        glView.enableSetNeedsDisplay = false
        glView.drawableDepthFormat = .format24

        glView.drawableMultisample = UserDefaults.app[.msaa] == true ? .multisample4X : .multisampleNone
        #endif

        return true
    }

    private func setupCelestia(statusUpdater: @escaping (String) -> Void, errorHandler: @escaping () -> Bool, completionHandler: @escaping (Bool) -> Void) {

        #if !USE_MGL
        let context = glView.context
        EAGLContext.setCurrent(context)
        #endif

        _ = CelestiaAppCore.initGL()

        core = CelestiaAppCore.shared

        DispatchQueue.global().async { [unowned self] in
            #if !USE_MGL
            EAGLContext.setCurrent(context)
            #endif

            var success = false
            var shouldRetry = true

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
        let pan1 = PanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan1.minimumNumberOfTouches = 1
        pan1.maximumNumberOfTouches = 1
        pan1.delegate = self
        if #available(iOS 13.4, *) {
            pan1.supportedMouseButtons = [.primary, .secondary]
        }
        glView.addGestureRecognizer(pan1)

        if #available(iOS 13.4, *) {
            let pan2 = UIPanGestureRecognizer(target: self, action: #selector(handlePanZoom(_:)))
            pan2.allowedScrollTypesMask = [.discrete, .continuous]
            pan2.delegate = self
            glView.addGestureRecognizer(pan2)
            pan2.require(toFail: pan1)
        }

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        pinch.delegate = self
        glView.addGestureRecognizer(pinch)

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tap.delegate = self
        glView.addGestureRecognizer(tap)

        let rightEdge = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(handleEdgePan(_:)))
        rightEdge.edges = .right
        pan1.require(toFail: rightEdge)
        glView.addGestureRecognizer(rightEdge)

        #if targetEnvironment(macCatalyst)
        glView.addInteraction(UIContextMenuInteraction(delegate: self))

        if let clickGesture = glView.gestureRecognizers?.filter({ String(cString: object_getClassName($0)) == "_UISecondaryClickDriverGestureRecognizer" }).first {
            clickGesture.require(toFail: pan1)
        }
        #endif
    }

    private func setupDisplayLink() {
        displaySource = DispatchSource.makeUserDataAddSource(queue: .main)
        displaySource?.setEventHandler() { [weak self] in
            self?.displaySourceCallback()
        }
        displaySource?.resume()

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
        core.delegate = self

        core.setSafeAreaInsets(view.safeAreaInsets.scale(by: glView.contentScaleFactor))

        #if targetEnvironment(macCatalyst)
        let selector = NSSelectorFromString("scaleFactor")
        var applicationScalingFactor: CGFloat = 1
        if let clazz = NSClassFromString("_UIiOSMacIdiomManager") as? NSObject.Type, clazz.responds(to: selector), let value = clazz.value(forKey: "scaleFactor") as? CGFloat {
            applicationScalingFactor = value
        }
        #else
        let applicationScalingFactor: CGFloat = 1
        #endif

        core.setDPI(Int(96.0 * glView.contentScaleFactor / applicationScalingFactor))

        let locale = LocalizedString("LANGUAGE", "celestia")
        if let (font, boldFont) = getInstalledFontFor(locale: locale) {
            core.setFont(font.filePath, collectionIndex: font.collectionIndex, fontSize: 9)
            core.setTitleFont(boldFont.filePath, collectionIndex: boldFont.collectionIndex, fontSize: 15)
            core.setRendererFont(font.filePath, collectionIndex: font.collectionIndex, fontSize: 9, fontStyle: .normal)
            core.setRendererFont(boldFont.filePath, collectionIndex: boldFont.collectionIndex, fontSize: 15, fontStyle: .large)
        } else if let font = GetFontForLocale(locale, .system),
            let boldFont = GetFontForLocale(locale, .emphasizedSystem) {
            core.setFont(font.filePath, collectionIndex: font.collectionIndex, fontSize: 9)
            core.setTitleFont(boldFont.filePath, collectionIndex: boldFont.collectionIndex, fontSize: 15)
            core.setRendererFont(font.filePath, collectionIndex: font.collectionIndex, fontSize: 9, fontStyle: .normal)
            core.setRendererFont(boldFont.filePath, collectionIndex: boldFont.collectionIndex, fontSize: 15, fontStyle: .large)
        }

        core.tick()
        core.start()
    }
}

private func getInstalledFontFor(locale: String) -> (font: FallbackFont, boldFont: FallbackFont)? {
    guard let fontDir = Bundle.main.path(forResource: "Fonts", ofType: nil) else { return nil }
    let fontFallback = [
        "ja": (
            font: FallbackFont(filePath: "\(fontDir)/NotoSansCJK-Regular.ttc", collectionIndex: 0),
            boldFont: FallbackFont(filePath: "\(fontDir)/NotoSansCJK-Bold.ttc", collectionIndex: 0)
        ),
        "ko": (
            font: FallbackFont(filePath: "\(fontDir)/NotoSansCJK-Regular.ttc", collectionIndex: 1),
            boldFont: FallbackFont(filePath: "\(fontDir)/NotoSansCJK-Bold.ttc", collectionIndex: 1)
        ),
        "zh_CN": (
            font: FallbackFont(filePath: "\(fontDir)/NotoSansCJK-Regular.ttc", collectionIndex: 2),
            boldFont: FallbackFont(filePath: "\(fontDir)/NotoSansCJK-Bold.ttc", collectionIndex: 2)
        ),
        "zh_TW": (
            font: FallbackFont(filePath: "\(fontDir)/NotoSansCJK-Regular.ttc", collectionIndex: 3),
            boldFont: FallbackFont(filePath: "\(fontDir)/NotoSansCJK-Bold.ttc", collectionIndex: 3)
        ),
        "ar": (
            font: FallbackFont(filePath: "\(fontDir)/NotoSansArabic-Regular.ttf", collectionIndex: 0),
            boldFont: FallbackFont(filePath: "\(fontDir)/NotoSansArabic-Bold.ttf", collectionIndex: 0)
        )
    ]
    let def = (
        font: FallbackFont(filePath: "\(fontDir)/NotoSans-Regular.ttf", collectionIndex: 0),
        boldFont: FallbackFont(filePath: "\(fontDir)/NotoSans-Bold.ttf", collectionIndex: 0)
    )
    return fontFallback[locale] ?? def
}

extension CelestiaViewController {
    func screenshot() -> UIImage {
        return UIGraphicsImageRenderer(size: glView.bounds.size).image { (_) in
            self.glView.drawHierarchy(in: self.glView.bounds, afterScreenUpdates: false)
        }
    }

    func openURL(_ url: URL, external: Bool) {
        if url.isFileURL {
            #if targetEnvironment(macCatalyst)
            let uniformed = UniformedURL(url: url, securityScoped: false)
            #else
            let uniformed = UniformedURL(url: url, securityScoped: external)
            #endif
            core.runScript(at: uniformed.url.path)
        } else {
            core.go(to: url.absoluteString)
        }
    }
}

private extension CGPoint {
    func scale(by factor: CGFloat) -> CGPoint {
        return applying(CGAffineTransform(scaleX: factor, y: factor))
    }
}

private extension UIEdgeInsets {
    func scale(by factor: CGFloat) -> UIEdgeInsets {
        return UIEdgeInsets(top: top * factor, left: left * factor, bottom: bottom * factor, right: right * factor)
    }
}
