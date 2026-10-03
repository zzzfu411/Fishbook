import SwiftUI
import AppKit

// Use the existing property wrapper, without the new SDK macro plug-in.
typealias StoredState<Value> = SwiftUI.State<Value>

// Semantic colors keep the reader, native PDF canvas and popovers in one palette.
enum StudyTheme {
    private static func rgb(_ hex:UInt32)->NSColor {
        NSColor(srgbRed:CGFloat((hex >> 16) & 255)/255,
                green:CGFloat((hex >> 8) & 255)/255,
                blue:CGFloat(hex & 255)/255,alpha:1)
    }
    private static func adaptive(_ light:UInt32,_ dark:UInt32)->NSColor {
        NSColor(name:nil) { appearance in
            rgb(appearance.bestMatch(from:[.aqua,.darkAqua]) == .darkAqua ? dark : light)
        }
    }
    static let canvasNS = adaptive(0xEBEFF1,0x161C20)
    static let paperNS = adaptive(0xFFFFFF,0x1D2429)
    static let sidebarNS = adaptive(0xF3F6F7,0x192329)
    static let surfaceNS = adaptive(0xFFFFFF,0x29333A)
    static let textNS = adaptive(0x22343E,0xE9EFF2)
    static let mutedNS = adaptive(0x60717B,0xA6B8C2)
    static let accentNS = adaptive(0x146E85,0x7CCADC)
    static let accentSoftNS = adaptive(0xE6F2F5,0x253F49)
    static let lineNS = adaptive(0xDFE6E9,0x38474F)
    // Paper-colored PDF presets use a dark accent; night reading supplies light ink.
    static let pdfMarkerNS = rgb(0x176B86)

    static let canvas = Color(nsColor:canvasNS)
    static let paper = Color(nsColor:paperNS)
    static let sidebar = Color(nsColor:sidebarNS)
    static let surface = Color(nsColor:surfaceNS)
    static let text = Color(nsColor:textNS)
    static let muted = Color(nsColor:mutedNS)
    static let accent = Color(nsColor:accentNS)
    static let accentSoft = Color(nsColor:accentSoftNS)
    static let line = Color(nsColor:lineNS)
}

enum ReaderAppearance:String,CaseIterable {
    case system,light,dark
    var title:String {
        switch self {case .system:return "跟随系统";case .light:return "浅色 · 海盐";case .dark:return "深色 · 深海"}
    }
    var scheme:ColorScheme? {
        switch self {case .system:return nil;case .light:return .light;case .dark:return .dark}
    }
    @MainActor func apply() {
        switch self {
        case .system:NSApp.appearance=nil
        case .light:NSApp.appearance=NSAppearance(named:.aqua)
        case .dark:NSApp.appearance=NSAppearance(named:.darkAqua)
        }
    }
}

struct BrandMark:View {
    var size:CGFloat=40
    private static let artwork: NSImage? = {
        guard let url=Bundle.main.url(forResource:"Logo",withExtension:"png") else {return nil}
        return NSImage(contentsOf:url)
    }()
    var body:some View {
        Group {
            if let artwork=Self.artwork { Image(nsImage:artwork).resizable().interpolation(.high).scaledToFit() }
            else { Image(systemName:"book.closed").resizable().scaledToFit().padding(size*0.2).foregroundStyle(StudyTheme.accent) }
        }.frame(width:size*1.5,height:size).background(.white)
            .clipShape(RoundedRectangle(cornerRadius:size*0.18)).accessibilityHidden(true)
    }
}

struct ReadingRule:View {
    var body:some View { StudyTheme.line.opacity(0.7).frame(height:0.5).accessibilityHidden(true) }
}

// Let macOS sample the real desktop behind the sidebar. The reading surfaces
// remain opaque, so translucency never competes with paper text or figures.
private struct NativeReaderMaterial:NSViewRepresentable {
    let material:NSVisualEffectView.Material
    let blending:NSVisualEffectView.BlendingMode
    func makeNSView(context:Context)->NSVisualEffectView {
        let view=NSVisualEffectView()
        view.material=material
        view.blendingMode=blending
        view.state = .followsWindowActiveState
        return view
    }
    func updateNSView(_ view:NSVisualEffectView,context:Context) {
        view.material=material
        view.blendingMode=blending
    }
}

struct ReaderSidebarBackground:View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var body:some View {
        Group {
            if reduceTransparency { StudyTheme.sidebar }
            else { NativeReaderMaterial(material:.sidebar,blending:.behindWindow) }
        }.ignoresSafeArea().allowsHitTesting(false).accessibilityHidden(true)
    }
}

struct ReaderChromeBackground:View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var body:some View {
        Group {
            if reduceTransparency { StudyTheme.sidebar }
            else {
                NativeReaderMaterial(material:.headerView,blending:.withinWindow)
                    .overlay(StudyTheme.canvas.opacity(0.24))
            }
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
}

private struct ReaderCapsuleSurface:ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    func body(content:Content)->some View {
        if reduceTransparency {
            content.background(StudyTheme.surface,in:Capsule())
                .overlay(Capsule().strokeBorder(StudyTheme.line,lineWidth:0.5).allowsHitTesting(false))
        } else {
            material(content)
        }
    }
    @ViewBuilder private func material(_ content: Content) -> some View {
        // Runtime availability alone cannot make an older SDK parse this API.
        #if FISHBOOK_GLASS_EFFECT
        if #available(macOS 26.0, *) { content.glassEffect(.regular, in: Capsule()) }
        else { fallback(content) }
        #else
        fallback(content)
        #endif
    }
    private func fallback(_ content: Content) -> some View {
        content.background(.thinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(StudyTheme.line.opacity(0.75), lineWidth: 0.5).allowsHitTesting(false))
            .shadow(color: .black.opacity(0.035), radius: 3, y: 1)
    }
}

struct ReaderControlGroup<Content:View>:View {
    private let content:Content
    init(@ViewBuilder content:()->Content) { self.content=content() }
    var body:some View { content.padding(3).modifier(ReaderCapsuleSurface()) }
}

struct ReaderChromeButtonStyle:ButtonStyle {
    var selected=false
    func makeBody(configuration:Configuration)->some View {
        ChromeButtonBody(configuration:configuration,selected:selected)
    }
    private struct ChromeButtonBody:View {
        let configuration:ButtonStyle.Configuration
        let selected:Bool
        @Environment(\.isEnabled) private var enabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @StoredState<Bool> private var hovered=false
        var body:some View {
            configuration.label
                .foregroundStyle(selected ? StudyTheme.accent : StudyTheme.text)
                .background {
                    Capsule().fill(selected ? StudyTheme.accentSoft : StudyTheme.text.opacity(configuration.isPressed ? 0.12 : hovered && enabled ? 0.06 : 0))
                }
                .contentShape(Capsule())
                .opacity(enabled ? 1 : 0.32)
                .onHover { hovered=$0 }
                .animation(reduceMotion ? nil : .easeOut(duration:0.12),value:hovered)
                .animation(reduceMotion ? nil : .easeOut(duration:0.12),value:configuration.isPressed)
        }
    }
}

struct ReaderModePicker:View {
    @Binding var selection:String
    private let modes=[("explanation","深度理解"),("translation","全文翻译"),("notes","我的记录")]
    var body:some View {
        ReaderControlGroup {
            HStack(spacing:2) {
                ForEach(modes,id:\.0) { mode in
                    Button { selection=mode.0 } label: {
                        Text(mode.1).font(.system(size:12,weight:selection == mode.0 ? .semibold : .medium))
                            .frame(maxWidth:.infinity,minHeight:30)
                    }.buttonStyle(ReaderChromeButtonStyle(selected:selection == mode.0))
                        .accessibilityAddTraits(selection == mode.0 ? [.isSelected] : [])
                }
            }
        }.accessibilityElement(children:.contain).accessibilityLabel("阅读辅助")
    }
}

struct Eyebrow:View {
    let text:String
    var body:some View {
        Text(text).font(.system(size:11,weight:.semibold)).tracking(0.6).foregroundStyle(StudyTheme.accent)
    }
}

struct ReadingLinkStyle:ButtonStyle {
    func makeBody(configuration:Configuration)->some View {
        configuration.label
            .font(.system(size:12,weight:.medium))
            .foregroundStyle(StudyTheme.accent)
            .padding(.horizontal,10).padding(.vertical,7)
            .background(StudyTheme.accentSoft.opacity(configuration.isPressed ? 0.65 : 1),in:RoundedRectangle(cornerRadius:6))
    }
}
