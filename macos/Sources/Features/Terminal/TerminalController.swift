import Foundation
import Cocoa
import SwiftUI
import GhosttyKit

class TerminalController: NSWindowController, NSWindowDelegate, TerminalViewDelegate, TerminalViewModel {
    override var windowNibName: NSNib.Name? { "Terminal" }
    
    /// The app instance that this terminal view will represent.
    let ghostty: Ghostty.AppState
    
    /// The base configuration for the new window
    let baseConfig: Ghostty.SurfaceConfiguration?
    
    /// The currently focused surface.
    var focusedSurface: Ghostty.SurfaceView? = nil

    /// The surface tree for this window.
    @Published var surfaceTree: Ghostty.SplitNode? = nil
    
    /// Fullscreen state management.
    private let fullscreenHandler = FullScreenHandler()
    
    /// The style mask to use for the new window
    private var styleMask: NSWindow.StyleMask {
        var mask: NSWindow.StyleMask = [.resizable, .closable, .miniaturizable]
        if (ghostty.windowDecorations) { mask.insert(.titled) }
        return mask
    }
    
    init(_ ghostty: Ghostty.AppState, withBaseConfig base: Ghostty.SurfaceConfiguration? = nil) {
        self.ghostty = ghostty
        self.baseConfig = base
        super.init(window: nil)
        
        // Initialize our initial surface.
        guard let ghostty_app = ghostty.app else { preconditionFailure("app must be loaded") }
        self.surfaceTree = .noSplit(.init(ghostty_app, base))
        
        // Setup our notifications for behaviors
        let center = NotificationCenter.default
        center.addObserver(
            self,
            selector: #selector(onToggleFullscreen),
            name: Ghostty.Notification.ghosttyToggleFullscreen,
            object: nil)
        center.addObserver(
            self,
            selector: #selector(onGotoTab),
            name: Ghostty.Notification.ghosttyGotoTab,
            object: nil)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported for this view")
    }
    
    deinit {
        // Remove all of our notificationcenter subscriptions
        let center = NotificationCenter.default
        center.removeObserver(self)
    }
    
    //MARK: - NSWindowController
    
    override func windowWillLoad() {
        // We want every new terminal window to cascade so they don't directly overlap.
        shouldCascadeWindows = true
        
        // TODO: The cascade is messed up with tabs.
    }
    
    override func windowDidLoad() {
        guard let window = window else { return }
        window.styleMask = self.styleMask
        
        // Terminals typically operate in sRGB color space and macOS defaults
        // to "native" which is typically P3. There is a lot more resources
        // covered in thie GitHub issue: https://github.com/mitchellh/ghostty/pull/376
        window.colorSpace = NSColorSpace.sRGB
        
        // Center the window to start, we'll move the window frame automatically
        // when cascading.
        window.center()
        
        // Initialize our content view to the SwiftUI root
        window.contentView = NSHostingView(rootView: TerminalView(
            ghostty: self.ghostty,
            viewModel: self,
            delegate: self
        ))
    }
    
    // Shows the "+" button in the tab bar, responds to that click.
    override func newWindowForTab(_ sender: Any?) {
        // Trigger the ghostty core event logic for a new tab.
        guard let surface = self.focusedSurface?.surface else { return }
        ghostty.newTab(surface: surface)
    }
    
    //MARK: - NSWindowDelegate
    
    func windowWillClose(_ notification: Notification) {
        // I don't know if this is required anymore. We previously had a ref cycle between
        // the view and the window so we had to nil this out to break it but I think this
        // may now be resolved. We should verify that no memory leaks and we can remove this.
        self.window?.contentView = nil
    }
    
    //MARK: - TerminalViewDelegate
    
    func focusedSurfaceDidChange(to: Ghostty.SurfaceView?) {
        self.focusedSurface = to
    }
    
    func titleDidChange(to: String) {
        self.window?.title = to
    }
    
    func cellSizeDidChange(to: NSSize) {
        guard ghostty.windowStepResize else { return }
        self.window?.contentResizeIncrements = to
    }
    
    func lastSurfaceDidClose() {
        self.window?.close()
    }
    
    //MARK: - Notifications
    
    @objc private func onGotoTab(notification: SwiftUI.Notification) {
        guard let target = notification.object as? Ghostty.SurfaceView else { return }
        guard target == self.focusedSurface else { return }
        guard let window = self.window else { return }
        
        // Get the tab index from the notification
        guard let tabIndexAny = notification.userInfo?[Ghostty.Notification.GotoTabKey] else { return }
        guard let tabIndex = tabIndexAny as? Int32 else { return }
        
        guard let windowController = window.windowController else { return }
        guard let tabGroup = windowController.window?.tabGroup else { return }
        let tabbedWindows = tabGroup.windows
        
        // This will be the index we want to actual go to
        let finalIndex: Int
        
        // An index that is invalid is used to signal some special values.
        if (tabIndex <= 0) {
            guard let selectedWindow = tabGroup.selectedWindow else { return }
            guard let selectedIndex = tabbedWindows.firstIndex(where: { $0 == selectedWindow }) else { return }
            
            if (tabIndex == GHOSTTY_TAB_PREVIOUS.rawValue) {
                finalIndex = selectedIndex - 1
            } else if (tabIndex == GHOSTTY_TAB_NEXT.rawValue) {
                finalIndex = selectedIndex + 1
            } else {
                return
            }
        } else {
            // Tabs are 0-indexed here, so we subtract one from the key the user hit.
            finalIndex = Int(tabIndex - 1)
        }
        
        guard finalIndex >= 0 && finalIndex < tabbedWindows.count else { return }
        let targetWindow = tabbedWindows[finalIndex]
        targetWindow.makeKeyAndOrderFront(nil)
    }

    
    @objc private func onToggleFullscreen(notification: SwiftUI.Notification) {
        guard let target = notification.object as? Ghostty.SurfaceView else { return }
        guard target == self.focusedSurface else { return }
        
        // We need a window to fullscreen
        guard let window = self.window else { return }
        
        // Check whether we use non-native fullscreen
        guard let useNonNativeFullscreenAny = notification.userInfo?[Ghostty.Notification.NonNativeFullscreenKey] else { return }
        guard let useNonNativeFullscreen = useNonNativeFullscreenAny as? ghostty_non_native_fullscreen_e else { return }
        self.fullscreenHandler.toggleFullscreen(window: window, nonNativeFullscreen: useNonNativeFullscreen)
        
        // For some reason focus always gets lost when we toggle fullscreen, so we set it back.
        if let focusedSurface {
            Ghostty.moveFocus(to: focusedSurface)
        }
    }
}
