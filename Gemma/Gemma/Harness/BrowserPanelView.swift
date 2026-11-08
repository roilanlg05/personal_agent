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
            // Nada antes de oír al relé: sin i3 detrás el panel no aparece (spec §6.2(e), §8).
            if !state.hasReceivedMessage { EmptyView() }
            else if state.isCollapsed { collapsed } else { live }
        }
        // `lastFrameAt` identifica el frame con una comparación de fechas; usar el JPEG como id
        // obligaría a SwiftUI a comparar los bytes enteros en el hilo principal en cada evaluación.
        .task(id: Self.frameID(jpeg: state.jpeg, lastFrameAt: state.lastFrameAt)) {
            guard let jpeg = state.jpeg else { image = nil; return }
            // ImageIO fuera del hilo principal: un frame de 1280x720 decodificado aquí haría saltar el chat.
            let decoded = await Self.decodeOffMain(jpeg)
            // Un frame viejo que termina tarde no debe pintarse encima de uno nuevo.
            if !Task.isCancelled { image = decoded }
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
            Text(state.host.map { "\(state.phrase) · \($0)" } ?? state.phrase)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if let reason = state.closedReason {
                // El usuario tiene que poder leer por qué el panel está muerto sin ir a Ajustes.
                Text(reason.isEmpty ? "Conexión con el navegador cerrada (sin motivo)." : "Conexión con el navegador cerrada: \(reason)")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }
            Group {
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .scaledToFit()
                } else {
                    Color.secondary.opacity(0.1)
                }
            }
            // Altura estable: el primer frame no debe mover el resto del historial.
            .frame(maxWidth: .infinity)
            .frame(height: 220)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            HStack(spacing: 6) {
                Spacer()
                // Presentación y nada más (spec §8(2)): si está vivo lo dice el i3.
                if let last = state.lastFrameAt {
                    TimelineView(.periodic(from: .now, by: 1)) { ctx in
                        let age = ctx.date.timeIntervalSince(last)
                        if age > 2 {
                            Text("último cambio hace \(Int(age)) s")
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

    /// Id del `.task` que decodifica. Es opcional A PROPÓSITO: debe pasar a `nil` cuando el estado
    /// suelta el JPEG (panel plegado), o el efecto no se reejecuta y la imagen decodificada
    /// sobrevive en la vista (secreto en reposo, §6.2(g)). No simplificar a `lastFrameAt` a secas.
    static func frameID(jpeg: Data?, lastFrameAt: Date?) -> Date? {
        jpeg == nil ? nil : lastFrameAt
    }

    /// Decodifica el JPEG en una tarea de fondo. `nil` si los bytes no son una imagen.
    @concurrent static func decodeOffMain(_ jpeg: Data) async -> CGImage? {
        // `@concurrent` obliga a correr en el ejecutor global. Un `nonisolated async` a secas NO basta
        // aquí: con la ejecución no aislada heredada del llamador (valor por omisión del proyecto)
        // correría en el hilo principal; el `assert` de abajo lo detecta si alguien lo quita.
        // Llamada desde el `.task(id:)`, hereda su cancelación.
        assert(!Thread.isMainThread, "la decodificación del JPEG no puede ocurrir en el hilo principal")
        guard let src = CGImageSourceCreateWithData(jpeg as CFData, nil) else { return nil }
        // `ShouldCacheImmediately` fuerza la decodificación aquí, no al pintar en el hilo principal.
        return CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }
}
