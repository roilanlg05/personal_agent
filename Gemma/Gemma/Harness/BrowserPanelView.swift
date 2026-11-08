import SwiftUI
import ImageIO

/// Panel del chat con lo que el navegador del agente está haciendo. Dos estados: en vivo
/// (frame + frase + «en vivo») y colapsado (una línea con el resumen y sin imagen).
/// Todo lo que muestra sale del estado; la vista no deduce «vivo» de que lleguen frames.
struct BrowserPanelView: View {
    let state: BrowserPanelState
    @State private var image: CGImage?

    var body: some View {
        Group {
            if state.isCollapsed { collapsed } else { live }
        }
        .task(id: state.jpeg) {
            guard let jpeg = state.jpeg else { image = nil; return }
            // ImageIO fuera del hilo principal: un frame de 1280x720 decodificado aquí haría saltar el chat.
            image = await Self.decodeOffMain(jpeg)
        }
    }

    private var collapsed: some View {
        HStack(spacing: 6) {
            Image(systemName: "globe").font(.caption)
            Text(state.summary.isEmpty ? "navegador" : state.summary)
                .font(.caption.monospaced())
                .lineLimit(1)
            Spacer()
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Color.secondary.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var live: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(state.phrase)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Group {
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .scaledToFit()
                } else {
                    Color.secondary.opacity(0.1)
                        .frame(height: 120)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: 360)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            HStack(spacing: 6) {
                Spacer()
                // Presentación y nada más (spec §8(2)): si está vivo lo dice el i3.
                if let last = state.lastFrameAt {
                    TimelineView(.periodic(from: .now, by: 1)) { ctx in
                        let age = ctx.date.timeIntervalSince(last)
                        if age > 2 {
                            Text("hace \(Int(age)) s")
                                .font(.caption2)
                                .foregroundStyle(.gray)
                        }
                    }
                }
                if state.isLive {
                    Circle().fill(Color.green).frame(width: 7, height: 7)
                    Text("en vivo").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .padding(8)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    /// Decodifica el JPEG en una tarea de fondo. `nil` si los bytes no son una imagen.
    nonisolated static func decodeOffMain(_ jpeg: Data) async -> CGImage? {
        await Task.detached(priority: .userInitiated) {
            guard let src = CGImageSourceCreateWithData(jpeg as CFData, nil) else { return nil }
            // `ShouldCacheImmediately` fuerza la decodificación aquí, no al pintar en el hilo principal.
            return CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        }.value
    }
}
