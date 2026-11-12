import SwiftUI

/// La tarjeta del chat con la que el usuario contesta un formulario que pidió el agente.
///
/// Compartida por iOS y macOS. Dos estados:
///   - abierta (`enviado == false`): campos editables sobre un `FormDraft` en `@State`;
///   - resuelta: SOLO el título y «Enviado» / «Cancelado». No recibe ni pinta ningún valor, y
///     por eso el borrador solo existe mientras la tarjeta está abierta: al resolverse se vuelve a
///     construir la vista con otra rama y el `@State` del borrador se descarta con ella. Un secreto
///     tecleado no puede quedarse en memoria dentro de una fila del chat que dura toda la sesión.
///
/// NINGÚN valor se repite en otro sitio: ni `accessibilityValue`, ni logs, ni `Text` de resumen.
struct FormCardView: View {
    let spec: FormSpec
    /// `true` cuando el formulario ya está resuelto (enviado o cancelado/caducado).
    let enviado: Bool
    /// Distingue «Cancelado» de «Enviado» en el estado resuelto.
    var cancelado: Bool = false
    let onEnviar: ([String: String]) -> Void
    let onCancelar: () -> Void

    var body: some View {
        if enviado {
            resuelta
        } else {
            FormCardAbierta(spec: spec, onEnviar: onEnviar, onCancelar: onCancelar)
        }
    }

    private var resuelta: some View {
        HStack(spacing: 8) {
            Image(systemName: cancelado ? "xmark.circle" : "checkmark.circle.fill")
                .foregroundStyle(cancelado ? Color.secondary : Color.green)
            VStack(alignment: .leading, spacing: 2) {
                Text(spec.title).font(.subheadline.weight(.medium))
                Text(cancelado ? "Cancelado" : "Enviado").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(10)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// La parte con estado de la tarjeta; separada para que el borrador (con los valores) viva solo
/// mientras el formulario está abierto.
private struct FormCardAbierta: View {
    let spec: FormSpec
    let onEnviar: ([String: String]) -> Void
    let onCancelar: () -> Void

    @State private var draft: FormDraft
    /// Los errores solo se enseñan tras un primer intento de enviar: no gritar «Obligatorio» en
    /// campos que el usuario todavía no ha tocado.
    @State private var intentado = false

    init(spec: FormSpec, onEnviar: @escaping ([String: String]) -> Void, onCancelar: @escaping () -> Void) {
        self.spec = spec
        self.onEnviar = onEnviar
        self.onCancelar = onCancelar
        _draft = State(initialValue: FormDraft(spec: spec))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(spec.title).font(.headline)
            if let d = spec.description, !d.isEmpty {
                Text(d).font(.callout).foregroundStyle(.secondary)
            }
            ForEach(spec.fields, id: \.id) { campo in
                campoView(campo)
            }
            HStack {
                Button("Cancelar", role: .cancel, action: onCancelar)
                Spacer()
                Button(spec.submitLabel ?? "Enviar") {
                    intentado = true
                    guard draft.puedeEnviar else { return }
                    onEnviar(draft.paraEnviar)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(12)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func binding(_ id: String) -> Binding<String> {
        Binding(get: { draft.values[id] ?? "" }, set: { draft.set(id, $0) })
    }

    @ViewBuilder
    private func campoView(_ campo: FormField) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if campo.kind != .confirm {
                Text(campo.label + (campo.required ? "" : " (opcional)")).font(.subheadline)
            }
            entrada(campo)
            if let h = campo.help, !h.isEmpty {
                Text(h).font(.caption).foregroundStyle(.secondary)
            }
            if intentado, let e = draft.errores[campo.id] {
                Text(e).font(.caption).foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder
    private func entrada(_ campo: FormField) -> some View {
        switch campo.kind {
        case .text:
            TextField(campo.placeholder ?? "", text: binding(campo.id))
                .textFieldStyle(.roundedBorder)
                .textContentType(.none)
                .autocorrectionDisabled()
        case .secret:
            // `SecureField`: el valor no se pinta y el sistema no lo ofrece a autocompletado.
            SecureField(campo.placeholder ?? "", text: binding(campo.id))
                .textFieldStyle(.roundedBorder)
                .textContentType(.none)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
        case .number:
            TextField(campo.placeholder ?? "", text: binding(campo.id))
                .textFieldStyle(.roundedBorder)
                .textContentType(.none)
                .autocorrectionDisabled()
                #if os(iOS)
                .keyboardType(.decimalPad)
                #endif
        case .choice:
            Picker(campo.label, selection: binding(campo.id)) {
                if !campo.required { Text("—").tag("") }
                else if (draft.values[campo.id] ?? "").isEmpty { Text("Elige…").tag("") }
                ForEach(campo.options ?? [], id: \.value) { Text($0.label).tag($0.value) }
            }
            .labelsHidden()
        case .multichoice:
            VStack(alignment: .leading, spacing: 2) {
                ForEach(campo.options ?? [], id: \.value) { o in
                    Toggle(o.label, isOn: Binding(
                        get: { FormDraft.elegidos(draft.values[campo.id] ?? "").contains(o.value) },
                        set: { marcado in
                            var actuales = FormDraft.elegidos(draft.values[campo.id] ?? "")
                            actuales.removeAll { $0 == o.value }
                            if marcado { actuales.append(o.value) }
                            // Orden de las opciones, no de los clics: la respuesta es estable.
                            let orden = (campo.options ?? []).map(\.value).filter(actuales.contains)
                            draft.set(campo.id, orden.joined(separator: "\n"))
                        }))
                }
            }
        case .confirm:
            Toggle(campo.label, isOn: Binding(
                get: { draft.values[campo.id] == "true" },
                set: { draft.set(campo.id, $0 ? "true" : "false") }))
        case .date:
            let fecha = FormDraft.fecha(draft.values[campo.id] ?? "")
            if fecha == nil {
                Button("Elegir fecha…") { draft.set(campo.id, FormDraft.textoDeFecha(Date())) }
            } else {
                DatePicker(campo.label, selection: Binding(
                    get: { fecha ?? Date() },
                    set: { draft.set(campo.id, FormDraft.textoDeFecha($0)) }),
                    displayedComponents: .date)
                .labelsHidden()
            }
        }
    }
}
