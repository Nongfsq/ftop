// Screen-compositing load: a large window of translucent Core Animation layers moving every frame,
// so WindowServer recomposites continuously while no app runs GPU compute. Quits after the given seconds.
import AppKit

let seconds = Double(CommandLine.arguments.dropFirst().first ?? "40") ?? 40
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let frame = NSRect(x: 80, y: 80, width: 1800, height: 1100)
let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
window.title = "ftop compositing load"
let view = NSView(frame: NSRect(origin: .zero, size: frame.size))
view.wantsLayer = true
view.layer?.backgroundColor = NSColor.black.cgColor
window.contentView = view
for i in 0..<60 {
    let l = CALayer()
    l.frame = CGRect(x: CGFloat(i * 29 % 1500), y: CGFloat(i * 17 % 800), width: 300, height: 300)
    l.cornerRadius = 150
    l.backgroundColor = NSColor(hue: CGFloat(i) / 60, saturation: 0.9, brightness: 0.9, alpha: 0.35).cgColor
    l.shadowOpacity = 0.8; l.shadowRadius = 30; l.shadowColor = l.backgroundColor
    let a = CABasicAnimation(keyPath: "position")
    a.toValue = NSValue(point: NSPoint(x: CGFloat((i * 211) % 1700), y: CGFloat((i * 97) % 1000)))
    a.duration = 0.9 + Double(i % 7) * 0.13; a.autoreverses = true; a.repeatCount = .infinity
    l.add(a, forKey: "move")
    let r = CABasicAnimation(keyPath: "transform.rotation")
    r.toValue = Double.pi * 2; r.duration = 1.7; r.repeatCount = .infinity
    l.add(r, forKey: "spin")
    view.layer?.addSublayer(l)
}
window.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps: true)
DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { app.terminate(nil) }
app.run()
