#!/bin/sh
# 把 Artwork/treadmill-launch.svg 渲染成启动页素材，输出到 LaunchIllustration.imageset。
#
# 为什么不用 ImageMagick（render-icon.sh 那种做法）：本机的 ImageMagick 没有 librsvg 后端，
# 内置的 SVG 渲染器不支持圆头线帽和 <g> 变换，画出来会缺笔断划。这里改用系统自带的
# WebKit 渲染，与 iOS 上看到的 SVG 效果一致，并且导出的是真正的矢量 PDF。
#
# 用法：
#   ./Artwork/render-launch.sh            更新素材目录里的 LaunchIllustration.pdf
#   ./Artwork/render-launch.sh --preview  同时生成 Artwork/launch-preview.png（透明背景，2 倍图）
set -eu
cd "$(dirname "$0")/.."

SVG="Artwork/treadmill-launch.svg"
PDF="TreadmillFTMSProbe/Assets.xcassets/LaunchIllustration.imageset/LaunchIllustration.pdf"
PREVIEW="Artwork/launch-preview.png"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/render-svg.swift" <<'SWIFT'
import AppKit
import WebKit

// 用法: swift render-svg.swift <input.svg> <output.pdf|output.png> <宽> <高>
let args = CommandLine.arguments
guard args.count == 5 else {
    FileHandle.standardError.write("用法: render-svg.swift <svg> <out.pdf|out.png> <宽> <高>\n".data(using: .utf8)!)
    exit(2)
}
let (svgPath, outPath) = (args[1], args[2])
let (width, height) = (Double(args[3])!, Double(args[4])!)
let isPNG = outPath.lowercased().hasSuffix(".png")
let svg = try! String(contentsOfFile: svgPath, encoding: .utf8)

// 画布保持透明，底色由启动页的 LaunchBackground 负责
let html = """
<!doctype html><html><head><meta charset="utf-8"><style>
html,body{margin:0;padding:0;background:transparent;overflow:hidden;}
svg{display:block;width:\(width)px;height:\(height)px;}
</style></head><body>\(svg)</body></html>
"""

final class Driver: NSObject, WKNavigationDelegate {
    let webView: WKWebView
    init(webView: WKWebView) { self.webView = webView }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            let box = CGRect(x: 0, y: 0, width: width, height: height)
            let done: (Result<Data, Error>) -> Void = { result in
                switch result {
                case .success(let data):
                    try? data.write(to: URL(fileURLWithPath: outPath))
                    print("✓ \(outPath)")
                    exit(0)
                case .failure(let error):
                    FileHandle.standardError.write("渲染失败: \(error)\n".data(using: .utf8)!)
                    exit(1)
                }
            }
            if isPNG {
                let cfg = WKSnapshotConfiguration()
                cfg.rect = box
                webView.takeSnapshot(with: cfg) { image, error in
                    guard let image,
                          let tiff = image.tiffRepresentation,
                          let rep = NSBitmapImageRep(data: tiff),
                          let png = rep.representation(using: .png, properties: [:])
                    else { done(.failure(error ?? NSError(domain: "render-svg", code: 1))); return }
                    done(.success(png))
                }
            } else {
                let cfg = WKPDFConfiguration()
                cfg.rect = box
                webView.createPDF(configuration: cfg, completionHandler: done)
            }
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: width, height: height))
webView.setValue(false, forKey: "drawsBackground")
if #available(macOS 12.0, *) { webView.underPageBackgroundColor = .clear }
let driver = Driver(webView: webView)
webView.navigationDelegate = driver
webView.loadHTMLString(html, baseURL: nil)
app.run()
SWIFT

swift "$TMP/render-svg.swift" "$SVG" "$PDF" 640 560
if [ "${1:-}" = "--preview" ]; then
    swift "$TMP/render-svg.swift" "$SVG" "$PREVIEW" 1280 1120
    # 快照会跟随屏幕缩放（Retina 上是 4 倍），这里统一到 2 倍图
    sips -z 1120 1280 "$PREVIEW" >/dev/null
fi
