//
//  StatusBarPlugin.swift
//  tauri-plugin-status-bar
//
//  Created by wtto on 2024/12/16.
//

import ObjectiveC.runtime
import OSLog
import SwiftRs
import Tauri
import UIKit
import WebKit

let log = OSLog(subsystem: "com.tauri.dev", category: "plugin.status_bar")

class SetStatusBarArgs: Decodable {
  let overlay: Bool?
  let backgroundColor: String?
  let lightStyle: Bool?
}

private var lightStyleKey: UInt8 = 0
private var statusBarHiddenKey: UInt8 = 0

extension UIViewController {
  fileprivate var pluginLightStyle: Bool {
    get { (objc_getAssociatedObject(self, &lightStyleKey) as? Bool) ?? false }
    set { objc_setAssociatedObject(self, &lightStyleKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
  }
  fileprivate var pluginStatusBarHidden: Bool {
    get { (objc_getAssociatedObject(self, &statusBarHiddenKey) as? Bool) ?? false }
    set { objc_setAssociatedObject(self, &statusBarHiddenKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
  }
}

class StatusBarPlugin: Plugin {
  private var backgroundColor: UIColor = .clear
  private var lightStyle: Bool = false
  private var overlay: Bool = true
  private weak var hostViewController: UIViewController?
  private weak var backgroundView: UIView?

  override func load(webview: WKWebView) {
    super.load(webview: webview)
    // No UI work here — touching scenes/windows during load() disrupts the
    // host webview's presentation on iOS 26. Everything is set up lazily
    // on the first setStatusBar/hide call, by which time the host's window
    // is fully attached.
  }

  /// Take ownership of status bar appearance on the host VC. Idempotent.
  private func attachIfNeeded() {
    guard hostViewController == nil, let vc = manager.viewController else { return }
    Self.installStatusBarOverrides(on: vc)
    hostViewController = vc
  }

  /// Insert a tinted view behind the status bar area on the host's view, or
  /// update its color if already present.
  private func applyBackgroundTint() {
    guard let host = hostViewController else { return }
    if let existing = backgroundView {
      existing.backgroundColor = backgroundColor
      return
    }
    let view = UIView()
    view.translatesAutoresizingMaskIntoConstraints = false
    view.backgroundColor = backgroundColor
    view.isUserInteractionEnabled = false
    host.view.addSubview(view)
    NSLayoutConstraint.activate([
      view.topAnchor.constraint(equalTo: host.view.topAnchor),
      view.leadingAnchor.constraint(equalTo: host.view.leadingAnchor),
      view.trailingAnchor.constraint(equalTo: host.view.trailingAnchor),
      view.bottomAnchor.constraint(equalTo: host.view.safeAreaLayoutGuide.topAnchor),
    ])
    backgroundView = view
  }

  @objc public func setStatusBar(_ invoke: Invoke) throws {
    let args = try invoke.parseArgs(SetStatusBarArgs.self)

    if let value = args.overlay {
      overlay = value
    }
    if let value = args.lightStyle {
      lightStyle = value
    }
    if let color = args.backgroundColor {
      if color == "transparent" {
        backgroundColor = UIColor.clear
      } else {
        backgroundColor = UIColor(hexString: color) ?? backgroundColor
      }
    }

    DispatchQueue.main.async { [weak self] in
      guard let self = self else {
        invoke.resolve()
        return
      }
      self.attachIfNeeded()
      if let host = self.hostViewController {
        host.pluginLightStyle = self.lightStyle
        host.pluginStatusBarHidden = false
        host.setNeedsStatusBarAppearanceUpdate()
        self.applyBackgroundTint()
      }
      invoke.resolve()
    }
  }

  @objc public func isVisible(_ invoke: Invoke) throws {
    invoke.resolve(visible())
  }

  @objc public func hide(_ invoke: Invoke) throws {
    DispatchQueue.main.async { [weak self] in
      guard let self = self else {
        invoke.resolve()
        return
      }
      self.attachIfNeeded()
      if let host = self.hostViewController {
        host.pluginStatusBarHidden = true
        host.setNeedsStatusBarAppearanceUpdate()
      }
      invoke.resolve()
    }
  }

  func visible() -> Bool {
    if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
       let manager = windowScene.statusBarManager {
      return !manager.isStatusBarHidden
    }
    return true
  }

  // MARK: - isa-swizzling

  /// Reparent the host VC into a dynamic subclass that overrides
  /// preferredStatusBarStyle / prefersStatusBarHidden. Affects only this
  /// instance — same trick KVO uses.
  private static func installStatusBarOverrides(on vc: UIViewController) {
    let originalClass: AnyClass = object_getClass(vc)!
    let originalName = NSStringFromClass(originalClass)
    if originalName.hasPrefix("TauriStatusBar_") { return }

    let dynamicName = "TauriStatusBar_" + originalName
    if let existing = NSClassFromString(dynamicName) {
      object_setClass(vc, existing)
      return
    }

    guard let subclass: AnyClass = objc_allocateClassPair(originalClass, dynamicName, 0) else {
      return
    }

    let styleSel = #selector(getter: UIViewController.preferredStatusBarStyle)
    let styleBlock: @convention(block) (UIViewController) -> UIStatusBarStyle = { vc in
      return vc.pluginLightStyle ? .lightContent : .darkContent
    }
    let styleImp = imp_implementationWithBlock(styleBlock)
    let styleTypes = class_getInstanceMethod(originalClass, styleSel).flatMap { method_getTypeEncoding($0) }
    class_addMethod(subclass, styleSel, styleImp, styleTypes)

    let hiddenSel = #selector(getter: UIViewController.prefersStatusBarHidden)
    let hiddenBlock: @convention(block) (UIViewController) -> Bool = { vc in
      return vc.pluginStatusBarHidden
    }
    let hiddenImp = imp_implementationWithBlock(hiddenBlock)
    let hiddenTypes = class_getInstanceMethod(originalClass, hiddenSel).flatMap { method_getTypeEncoding($0) }
    class_addMethod(subclass, hiddenSel, hiddenImp, hiddenTypes)

    objc_registerClassPair(subclass)
    object_setClass(vc, subclass)
  }
}

@_cdecl("init_plugin_status_bar")
func initPlugin() -> Plugin {
  return StatusBarPlugin()
}

extension UIColor {
  /// - Parameters:
  ///   - hexString: `#RGB`、`#RRGGBB`、`#AARRGGBB`
  convenience init?(hexString: String) {
    var hex = hexString.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()

    if hex.hasPrefix("#") {
      hex.removeFirst()
    }

    var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 1
    switch hex.count {
      case 3: // #RGB
        red = CGFloat(Int(String(hex[hex.startIndex]), radix: 16) ?? 0) / 15
        green = CGFloat(Int(String(hex[hex.index(hex.startIndex, offsetBy: 1)]), radix: 16) ?? 0) / 15
        blue = CGFloat(Int(String(hex[hex.index(hex.startIndex, offsetBy: 2)]), radix: 16) ?? 0) / 15
      case 6: // #RRGGBB
        red = CGFloat(Int(hex.prefix(2), radix: 16) ?? 0) / 255
        green = CGFloat(Int(hex.dropFirst(2).prefix(2), radix: 16) ?? 0) / 255
        blue = CGFloat(Int(hex.dropFirst(4).prefix(2), radix: 16) ?? 0) / 255
      case 8: // #AARRGGBB
        alpha = CGFloat(Int(hex.prefix(2), radix: 16) ?? 0) / 255
        red = CGFloat(Int(hex.dropFirst(2).prefix(2), radix: 16) ?? 0) / 255
        green = CGFloat(Int(hex.dropFirst(4).prefix(2), radix: 16) ?? 0) / 255
        blue = CGFloat(Int(hex.dropFirst(6).prefix(2), radix: 16) ?? 0) / 255
      default:
        os_log(.error, log: log, "Invalid hexString argument, use f.i. '#999999'")
        return nil
    }

    self.init(red: red, green: green, blue: blue, alpha: alpha)
  }
}
