// Renders the Usage Monitor app icon (a battery gauge on a slate squircle) at any
// size. Usage: swift icon.swift <size> <out.png>
import AppKit

func srgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: r/255, green: g/255, blue: b/255, alpha: a)
}

func iconImage(_ N: CGFloat) -> NSImage {
    NSImage(size: NSSize(width: N, height: N), flipped: false) { _ in
        let ctx = NSGraphicsContext.current!.cgContext

        // Rounded-square "squircle" plate, inset from the canvas edges.
        let margin = N * 0.086
        let side = N - margin * 2
        let plate = NSRect(x: margin, y: margin, width: side, height: side)
        let r = side * 0.225
        let clip = NSBezierPath(roundedRect: plate, xRadius: r, yRadius: r)
        clip.addClip()

        // Slate vertical gradient background.
        let bg = NSGradient(colors: [srgb(54, 64, 84), srgb(24, 28, 38)])!
        bg.draw(in: plate, angle: -90)
        // Soft top-left sheen for depth.
        let sheen = NSGradient(colors: [srgb(255, 255, 255, 0.14), srgb(255, 255, 255, 0)])!
        sheen.draw(fromCenter: NSPoint(x: plate.minX + side*0.28, y: plate.maxY - side*0.22), radius: 0,
                   toCenter: NSPoint(x: plate.minX + side*0.28, y: plate.maxY - side*0.22), radius: side*0.6,
                   options: [])

        // Battery, centred in the plate.
        let bw = side * 0.60, bh = side * 0.34
        let bx = plate.midX - bw/2 - side*0.02   // leave room for the cap on the right
        let by = plate.midY - bh/2
        let body = NSRect(x: bx, y: by, width: bw, height: bh)
        let stroke = side * 0.030
        let corner = bh * 0.30

        // Empty track inside the shell.
        let inset = body.insetBy(dx: stroke, dy: stroke)
        srgb(255, 255, 255, 0.12).setFill()
        NSBezierPath(roundedRect: inset, xRadius: corner*0.7, yRadius: corner*0.7).fill()

        // Colour charge: green→amber→red gradient filling ~78% of the track.
        let fillW = inset.width * 0.78
        let fillRect = NSRect(x: inset.minX, y: inset.minY, width: fillW, height: inset.height)
        ctx.saveGState()
        NSBezierPath(roundedRect: fillRect, xRadius: corner*0.7, yRadius: corner*0.7).addClip()
        NSGradient(colors: [srgb(48, 209, 89), srgb(255, 158, 10), srgb(255, 69, 59)],
                   atLocations: [0.0, 0.55, 1.0], colorSpace: .sRGB)!
            .draw(in: inset, angle: 0)
        ctx.restoreGState()

        // Shell outline.
        let shell = NSBezierPath(roundedRect: body, xRadius: corner, yRadius: corner)
        shell.lineWidth = stroke
        srgb(255, 255, 255, 0.95).setStroke()
        shell.stroke()

        // Cap nub.
        let capW = side * 0.032, capH = bh * 0.42
        let cap = NSRect(x: body.maxX + side*0.018, y: body.midY - capH/2, width: capW, height: capH)
        srgb(255, 255, 255, 0.95).setFill()
        NSBezierPath(roundedRect: cap, xRadius: capW*0.5, yRadius: capW*0.5).fill()

        return true
    }
}

func savePNG(_ image: NSImage, _ N: Int, _ path: String) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: N, pixelsHigh: N, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: N, height: N)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: N, height: N))
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

let size = CommandLine.arguments.count > 1 ? Int(CommandLine.arguments[1])! : 1024
let out = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "icon.png"
savePNG(iconImage(CGFloat(size)), size, out)
print("wrote \(out) @ \(size)px")
