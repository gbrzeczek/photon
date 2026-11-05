import AppKit
import ImageIO
import Libmpv
import OpenGL.GL3
import QuartzCore
import UniformTypeIdentifiers

/// Path A: vo=libmpv, OpenGL render API, drawing into a CAOpenGLLayer.
/// mpv's update callback schedules `display()` on one serial queue, so GL work stays off the main thread.
final class GLVideoLayer: CAOpenGLLayer, @unchecked Sendable {
    private var pf: CGLPixelFormatObj?
    private var ctx: CGLContextObj?
    private let renderLock = NSLock()
    private var render: OpaquePointer?
    private let queue = DispatchQueue(label: "mpv-spike.gl", qos: .userInteractive)
    private let stateLock = NSLock()
    private var pending = false

    private(set) var renders = 0
    private(set) var maxRenderMs = 0.0
    private(set) var glInfo = ""
    private var readback: ((Int, Int, Data) -> Void)?

    init(core: MpvCore, tagSRGB: Bool) throws {
        super.init()
        // Untagged GL output goes straight to the panel, so sRGB content looks oversaturated on P3.
        if tagSRGB { colorspace = CGColorSpace(name: CGColorSpace.sRGB) }
        let attrs: [CGLPixelFormatAttribute] = [
            kCGLPFAOpenGLProfile, CGLPixelFormatAttribute(rawValue: UInt32(kCGLOGLPVersion_3_2_Core.rawValue)),
            kCGLPFAAccelerated, kCGLPFADoubleBuffer, kCGLPFAAllowOfflineRenderers,
            CGLPixelFormatAttribute(rawValue: 0),
        ]
        var n: GLint = 0
        var format: CGLPixelFormatObj?
        var err = CGLChoosePixelFormat(attrs, &format, &n)
        guard err == kCGLNoError, let format else { throw MpvError("CGLChoosePixelFormat: \(err.rawValue)") }
        var context: CGLContextObj?
        err = CGLCreateContext(format, nil, &context)
        guard err == kCGLNoError, let context else { throw MpvError("CGLCreateContext: \(err.rawValue)") }
        pf = format
        ctx = context
        isAsynchronous = false
        needsDisplayOnBoundsChange = false
        isOpaque = true
        contentsGravity = .resize

        CGLSetCurrentContext(context)
        defer { CGLSetCurrentContext(nil) }
        func glString(_ e: Int32) -> String {
            guard let p = glGetString(GLenum(e)) else { return "?" }
            return String(cString: p)
        }
        glInfo = "\(glString(GL_VERSION)) / \(glString(GL_RENDERER))"

        var initParams = mpv_opengl_init_params(
            get_proc_address: { _, name in
                guard let name else { return nil }
                let sym = CFStringCreateWithCString(nil, name, CFStringBuiltInEncodings.ASCII.rawValue)
                let bundle = CFBundleGetBundleWithIdentifier("com.apple.opengl" as CFString)
                return CFBundleGetFunctionPointerForName(bundle, sym)
            },
            get_proc_address_ctx: nil
        )
        var rc: OpaquePointer?
        let code: Int32 = "opengl".withCString { api in
            withUnsafeMutablePointer(to: &initParams) { ip in
                var params = [
                    mpv_render_param(type: MPV_RENDER_PARAM_API_TYPE, data: UnsafeMutableRawPointer(mutating: api)),
                    mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, data: ip),
                    mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil),
                ]
                return mpv_render_context_create(&rc, core.handle, &params)
            }
        }
        if code < 0 { throw MpvError("mpv_render_context_create", code) }
        render = rc
        mpv_render_context_set_update_callback(rc, { me in
            guard let me else { return }
            Unmanaged<GLVideoLayer>.fromOpaque(me).takeUnretainedValue().scheduleDraw()
        }, Unmanaged.passUnretained(self).toOpaque())
    }

    /// Core Animation can still display this layer after mpv is gone, so the context must live
    /// exactly as long as the layer. Releasing it in freeRender crashes in CAOpenGLLayerDraw.
    deinit {
        if let ctx { CGLReleaseContext(ctx) }
        if let pf { CGLReleasePixelFormat(pf) }
    }

    /// Core Animation copies layers for its presentation tree.
    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError() }

    func scheduleDraw() {
        let enqueue = stateLock.withLock { () -> Bool in
            if pending { return false }
            pending = true
            return true
        }
        guard enqueue else { return }
        queue.async { [self] in
            stateLock.withLock { pending = false }
            display()
            CATransaction.flush()
        }
    }

    override func copyCGLPixelFormat(forDisplayMask mask: UInt32) -> CGLPixelFormatObj {
        CGLRetainPixelFormat(pf!)
    }
    override func copyCGLContext(forPixelFormat pf: CGLPixelFormatObj) -> CGLContextObj {
        CGLRetainContext(ctx!)
    }
    override func releaseCGLContext(_ ctx: CGLContextObj) { CGLReleaseContext(ctx) }
    override func releaseCGLPixelFormat(_ pf: CGLPixelFormatObj) { CGLReleasePixelFormat(pf) }
    override func canDraw(inCGLContext ctx: CGLContextObj, pixelFormat pf: CGLPixelFormatObj,
                          forLayerTime t: CFTimeInterval, displayTime ts: UnsafePointer<CVTimeStamp>?) -> Bool { true }

    override func draw(inCGLContext ctx: CGLContextObj, pixelFormat pf: CGLPixelFormatObj,
                       forLayerTime t: CFTimeInterval, displayTime ts: UnsafePointer<CVTimeStamp>?) {
        renderLock.lock()
        defer { renderLock.unlock() }
        guard let render else {
            glClearColor(0, 0, 0, 1)
            glClear(GLbitfield(GL_COLOR_BUFFER_BIT))
            return
        }
        var fbo: GLint = 0
        glGetIntegerv(GLenum(GL_DRAW_FRAMEBUFFER_BINDING), &fbo)
        var vp = [GLint](repeating: 0, count: 4)
        glGetIntegerv(GLenum(GL_VIEWPORT), &vp)
        var target = mpv_opengl_fbo(fbo: fbo, w: vp[2], h: vp[3], internal_format: 0)
        var flip: Int32 = 1
        let start = DispatchTime.now().uptimeNanoseconds
        withUnsafeMutablePointer(to: &target) { tp in
            withUnsafeMutablePointer(to: &flip) { fp in
                var params = [
                    mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_FBO, data: tp),
                    mpv_render_param(type: MPV_RENDER_PARAM_FLIP_Y, data: fp),
                    mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil),
                ]
                _ = mpv_render_context_render(render, &params)
            }
        }
        renders += 1
        maxRenderMs = max(maxRenderMs, Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
        if let cb = readback {
            readback = nil
            // mpv leaves framebuffer 0 bound after rendering, so point reads back at the layer's FBO.
            glBindFramebuffer(GLenum(GL_FRAMEBUFFER), GLuint(fbo))
            var bytes = Data(count: Int(vp[2]) * Int(vp[3]) * 4)
            bytes.withUnsafeMutableBytes {
                glReadPixels(0, 0, vp[2], vp[3], GLenum(GL_RGBA), GLenum(GL_UNSIGNED_BYTE), $0.baseAddress)
            }
            cb(Int(vp[2]), Int(vp[3]), bytes)
        }
        glFlush()
        mpv_render_context_report_swap(render)
    }

    /// Reads back what mpv just drew into the layer's framebuffer.
    func readPixels(_ done: @escaping @Sendable (Int, Int, Data) -> Void) {
        queue.async { [self] in
            renderLock.withLock { readback = done }
            display()
            CATransaction.flush()
        }
    }

    /// mpv_render_context_free needs the GL context current, and must run before mpv_terminate_destroy.
    func freeRender(_ done: @escaping @Sendable () -> Void) {
        queue.async { [self] in
            renderLock.withLock {
                if let rc = render {
                    mpv_render_context_set_update_callback(rc, nil, nil)
                    CGLLockContext(ctx!)
                    CGLSetCurrentContext(ctx)
                    mpv_render_context_free(rc)
                    CGLSetCurrentContext(nil)
                    CGLUnlockContext(ctx!)
                    render = nil
                }
            }
            done()
        }
    }
}

@MainActor final class PathASurface: Surface {
    let core: MpvCore
    let hostView = HostView()
    private let glLayer: GLVideoLayer

    init(logURL: URL?, logLevel: String, hwdec: String, tagSRGB: Bool) throws {
        core = try MpvCore(options: commonOptions(hwdec: hwdec) + [("vo", "libmpv")],
                           wid: nil, logURL: logURL, logLevel: logLevel)
        glLayer = try GLVideoLayer(core: core, tagSRGB: tagSRGB)
        hostView.layer = glLayer
        hostView.wantsLayer = true
        hostView.onResize = { [weak self] size, scale in self?.resized(size, scale) }
    }

    private func resized(_ size: CGSize, _ scale: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        glLayer.contentsScale = scale
        glLayer.frame = CGRect(origin: .zero, size: size)
        CATransaction.commit()
        glLayer.scheduleDraw()
    }

    var extra: [String: Any] {
        ["gl": glLayer.glInfo, "renders": glLayer.renders, "maxRenderMs": glLayer.maxRenderMs]
    }

    func captureRendered(to url: URL) async -> [String: Any]? {
        // Core Animation skips draw for a layer that isn't on screen, so never wait forever.
        let layer = glLayer
        let once = Once()
        return await withCheckedContinuation { c in
            layer.readPixels { w, h, data in
                if once.claim() { c.resume(returning: writeReadback(w, h, data, to: url)) }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
                if once.claim() { c.resume(returning: ["error": "readback timed out: layer never drew"]) }
            }
        }
    }

    func teardown() async {
        let layer = glLayer
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            layer.freeRender { c.resume() }
        }
        hostView.layer = nil
        await core.destroy()
    }
}

final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool { lock.withLock { defer { done = true }; return !done } }
}

/// GL rows are bottom-up. Writes a PNG and returns simple content statistics.
func writeReadback(_ w: Int, _ h: Int, _ data: Data, to url: URL) -> [String: Any] {
    var flipped = Data(count: data.count)
    let stride = w * 4
    var lumaSum = 0.0, lumaSq = 0.0, nonBlack = 0
    data.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
        flipped.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) in
            for y in 0..<h {
                memcpy(dst.baseAddress! + y * stride, src.baseAddress! + (h - 1 - y) * stride, stride)
            }
        }
        let n = w * h
        for i in Swift.stride(from: 0, to: n, by: 37) {
            let r = Double(src[i * 4]), g = Double(src[i * 4 + 1]), b = Double(src[i * 4 + 2])
            let l = 0.2126 * r + 0.7152 * g + 0.0722 * b
            lumaSum += l; lumaSq += l * l
            if l > 16 { nonBlack += 1 }
        }
    }
    let samples = Double(max(1, (w * h) / 37))
    let mean = lumaSum / samples
    let provider = CGDataProvider(data: flipped as CFData)!
    let image = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: stride,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    if let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) {
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
    }
    return ["w": w, "h": h, "lumaMean": mean, "lumaStd": (max(0, lumaSq / samples - mean * mean)).squareRoot(),
            "nonBlackFrac": Double(nonBlack) / samples, "file": url.lastPathComponent]
}
