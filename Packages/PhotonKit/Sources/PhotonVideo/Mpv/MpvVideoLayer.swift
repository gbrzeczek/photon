import CMpv
import Foundation
import OpenGL.GL3
import QuartzCore
import Synchronization

/// Draws mpv's frames through its OpenGL render API, as Spike 2 chose.
///
/// - Every mpv call happens on `drawQueue`, never the main thread. mpv's update callback schedules a
///   draw there, and `display()` asked for on the main thread is passed there too, so Core Animation's
///   own redraws never reach mpv.
/// - Nothing waits on a draw. Core Animation stops drawing while the display sleeps, so a wait could
///   last until it wakes.
/// - The layer is tagged sRGB, or colors are oversaturated on P3 displays.
/// - The GL context lives exactly as long as the layer: Core Animation can still display it after mpv
///   is gone, so the context is released in `deinit`, after `detach` has freed the render context and
///   the playback has destroyed the core.
final class MpvVideoLayer: CAOpenGLLayer {
    private var pixelFormat: CGLPixelFormatObj?
    private var context: CGLContextObj?
    private let drawQueue = DispatchQueue(label: "app.photon.mpv.draw", qos: .userInteractive)
    private let lock = NSLock()
    private var api: MpvLibrary?
    private var render: OpaquePointer?
    private var drawPending = false
    private var drawsFrame = false
    private var shownFrame = false
    /// Called on the draw queue the first time a frame of video reaches the layer.
    var onFirstFrame: (@Sendable () -> Void)?

    override init() {
        super.init()
        colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        isAsynchronous = false
        needsDisplayOnBoundsChange = false
        // mpv draws the bars around the picture transparent, so the viewer's backdrop shows there.
        isOpaque = false
        contentsGravity = .resizeAspect
        actions = ["bounds": NSNull(), "position": NSNull(), "contents": NSNull(), "opacity": NSNull()]

        if let made = Self.makeContext(accelerated: true) ?? Self.makeContext(accelerated: false) {
            pixelFormat = made.0
            context = made.1
        }
    }

    /// A GL context on the GPU, or else on Apple's software renderer. A Mac always has the first; a
    /// virtual machine, such as CI's, may have only the second, which is slower but plays.
    private static func makeContext(accelerated: Bool) -> (CGLPixelFormatObj, CGLContextObj)? {
        var attributes: [CGLPixelFormatAttribute] = [
            kCGLPFAOpenGLProfile, CGLPixelFormatAttribute(rawValue: UInt32(kCGLOGLPVersion_3_2_Core.rawValue)),
            kCGLPFADoubleBuffer,
            kCGLPFAColorSize, CGLPixelFormatAttribute(rawValue: 24),
            kCGLPFAAlphaSize, CGLPixelFormatAttribute(rawValue: 8),
        ]
        if accelerated {
            attributes += [kCGLPFAAccelerated, kCGLPFAAllowOfflineRenderers]
        } else {
            attributes += [kCGLPFARendererID, CGLPixelFormatAttribute(rawValue: UInt32(kCGLRendererGenericFloatID))]
        }
        // PHOTON_MPV_SOFTWARE_GL=1 skips the GPU, to try CI's path on a Mac.
        if accelerated, ProcessInfo.processInfo.environment["PHOTON_MPV_SOFTWARE_GL"] == "1" { return nil }
        attributes.append(CGLPixelFormatAttribute(rawValue: 0))
        var count: GLint = 0
        var format: CGLPixelFormatObj?
        guard CGLChoosePixelFormat(attributes, &format, &count) == kCGLNoError, let format else { return nil }
        var made: CGLContextObj?
        guard CGLCreateContext(format, nil, &made) == kCGLNoError, let made else {
            CGLReleasePixelFormat(format)
            return nil
        }
        return (format, made)
    }

    /// Core Animation copies layers for its presentation tree.
    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit {
        if let context { CGLReleaseContext(context) }
        if let pixelFormat { CGLReleasePixelFormat(pixelFormat) }
    }

    var hasFrame: Bool { lock.withLock { shownFrame } }

    // MARK: mpv

    /// Creates the render context for `core`. Call before loading a file, off the main thread.
    func attach(core: MpvCore) throws {
        try drawQueue.sync {
            guard let context else { throw MpvError(description: "No OpenGL context") }
            CGLLockContext(context)
            CGLSetCurrentContext(context)
            defer {
                CGLSetCurrentContext(nil)
                CGLUnlockContext(context)
            }
            var initParams = mpv_opengl_init_params(
                get_proc_address: { _, name in
                    guard let name else { return nil }
                    let symbol = CFStringCreateWithCString(nil, name, CFStringBuiltInEncodings.ASCII.rawValue)
                    let bundle = CFBundleGetBundleWithIdentifier("com.apple.opengl" as CFString)
                    return CFBundleGetFunctionPointerForName(bundle, symbol)
                },
                get_proc_address_ctx: nil)
            var made: OpaquePointer?
            let code: Int32 = MPV_RENDER_API_TYPE_OPENGL.withCString { type in
                withUnsafeMutablePointer(to: &initParams) { initPointer in
                    var params = [
                        mpv_render_param(type: MPV_RENDER_PARAM_API_TYPE, data: UnsafeMutableRawPointer(mutating: type)),
                        mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, data: initPointer),
                        mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil),
                    ]
                    return core.api.renderContextCreate(&made, core.handle, &params)
                }
            }
            guard code >= 0, let made else {
                throw MpvError(description: "mpv_render_context_create: \(core.api.describe(code))")
            }
            lock.withLock {
                api = core.api
                render = made
            }
            core.api.renderContextSetUpdateCallback(
                made,
                { layer in
                    guard let layer else { return }
                    Unmanaged<MpvVideoLayer>.fromOpaque(layer).takeUnretainedValue().scheduleDraw()
                }, Unmanaged.passUnretained(self).toOpaque())
        }
    }

    /// Frees the render context, with the GL context current, as mpv requires. Must run before the
    /// core is destroyed, and off the main thread. The layer keeps its last frame.
    func detach() {
        drawQueue.sync {
            let (api, render) = lock.withLock { () -> (MpvLibrary?, OpaquePointer?) in
                defer {
                    self.render = nil
                    self.api = nil
                }
                return (self.api, self.render)
            }
            guard let api, let render, let context else { return }
            api.renderContextSetUpdateCallback(render, nil, nil)
            CGLLockContext(context)
            CGLSetCurrentContext(context)
            api.renderContextFree(render)
            CGLSetCurrentContext(nil)
            CGLUnlockContext(context)
        }
    }

    /// mpv has shown a frame: the next draw shows video, not just the background. The update flag
    /// alone can miss it, because a frame that arrives between `update()` and the draw that follows is
    /// drawn without a flag, and a paused video sends no other.
    func frameIsShown() {
        lock.withLock { drawsFrame = true }
        scheduleDraw()
    }

    /// Asks for a draw on the draw queue. Coalesced, so a burst of updates is one draw.
    func scheduleDraw() {
        let enqueue = lock.withLock { () -> Bool in
            if drawPending { return false }
            drawPending = true
            return true
        }
        guard enqueue else { return }
        let box = DrawingLayer(self)
        drawQueue.async { box.layer.drawPendingUpdate() }
    }

    /// Runs on the draw queue.
    private func drawPendingUpdate() {
        let (api, render) = lock.withLock { () -> (MpvLibrary?, OpaquePointer?) in
            drawPending = false
            return (self.api, self.render)
        }
        if let api, let render {
            // mpv asks for this after every update callback, on the render thread. A frame flag only
            // comes once there's video to draw. Before that, mpv draws only the transparent background.
            let flags = api.renderContextUpdate(render)
            if flags & UInt64(MPV_RENDER_UPDATE_FRAME.rawValue) != 0 { lock.withLock { drawsFrame = true } }
        }
        drawNow()
        CATransaction.flush()
    }

    private func drawNow() { super.display() }

    override func display() {
        // Core Animation asks on the main thread when the layer first appears or changes size. mpv is
        // never called there, so the draw moves to the draw queue, and the old frame stays meanwhile.
        if Thread.isMainThread {
            scheduleDraw()
        } else {
            super.display()
        }
    }

    override var bounds: CGRect {
        didSet {
            guard bounds.size != oldValue.size else { return }
            if Thread.isMainThread, let scale = superlayer?.contentsScale, scale != contentsScale {
                contentsScale = scale
            }
            scheduleDraw()
        }
    }

    /// Matches the window's backing scale, which the layer can only learn from its parent.
    @MainActor func matchScale() {
        guard let scale = superlayer?.contentsScale, scale != contentsScale else { return }
        contentsScale = scale
        scheduleDraw()
    }

    // MARK: CAOpenGLLayer

    override func copyCGLPixelFormat(forDisplayMask mask: UInt32) -> CGLPixelFormatObj {
        guard let pixelFormat else { return super.copyCGLPixelFormat(forDisplayMask: mask) }
        return CGLRetainPixelFormat(pixelFormat)
    }

    override func copyCGLContext(forPixelFormat format: CGLPixelFormatObj) -> CGLContextObj {
        guard let context else { return super.copyCGLContext(forPixelFormat: format) }
        return CGLRetainContext(context)
    }

    override func releaseCGLContext(_ context: CGLContextObj) { CGLReleaseContext(context) }
    override func releaseCGLPixelFormat(_ format: CGLPixelFormatObj) { CGLReleasePixelFormat(format) }

    override func canDraw(
        inCGLContext context: CGLContextObj, pixelFormat: CGLPixelFormatObj, forLayerTime time: CFTimeInterval,
        displayTime: UnsafePointer<CVTimeStamp>?
    ) -> Bool { !Thread.isMainThread }

    override func draw(
        inCGLContext context: CGLContextObj, pixelFormat: CGLPixelFormatObj, forLayerTime time: CFTimeInterval,
        displayTime: UnsafePointer<CVTimeStamp>?
    ) {
        let (api, render, isFrame) = lock.withLock { (self.api, self.render, drawsFrame) }
        guard let api, let render, !Thread.isMainThread else {
            glClearColor(0, 0, 0, 0)
            glClear(GLbitfield(GL_COLOR_BUFFER_BIT))
            return
        }
        var framebuffer: GLint = 0
        glGetIntegerv(GLenum(GL_DRAW_FRAMEBUFFER_BINDING), &framebuffer)
        var viewport = [GLint](repeating: 0, count: 4)
        glGetIntegerv(GLenum(GL_VIEWPORT), &viewport)
        var target = mpv_opengl_fbo(fbo: framebuffer, w: viewport[2], h: viewport[3], internal_format: 0)
        var flip: Int32 = 1
        withUnsafeMutablePointer(to: &target) { targetPointer in
            withUnsafeMutablePointer(to: &flip) { flipPointer in
                var params = [
                    mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_FBO, data: targetPointer),
                    mpv_render_param(type: MPV_RENDER_PARAM_FLIP_Y, data: flipPointer),
                    mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil),
                ]
                _ = api.renderContextRender(render, &params)
            }
        }
        glFlush()
        api.renderContextReportSwap(render)
        if isFrame {
            let first = lock.withLock { () -> Bool in
                defer { shownFrame = true }
                return !shownFrame
            }
            if first { onFirstFrame?() }
        }
    }
}
