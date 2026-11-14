import Foundation

/// Cambia el nombre de un lugar guardado.
///
/// `save_place` ya actualizaba las coordenadas de un lugar existente (busca por nombre),
/// pero el nombre era la clave: guardar "Casa de mamá" cuando ya existía "Casa de Mamá
/// Ana" creaba un segundo lugar en el mismo sitio, y el usuario acababa con dos pines
/// idénticos y Gemma sin saber a cuál se refería.
public final class RenamePlaceTool: AgentTool, Sendable {
    public static let name = "rename_place"
    public static let description = """
    Cambia el nombre de un lugar que Gemma ya tiene guardado, conservando sus \
    coordenadas y sus visitas. Pásale 'name' (el nombre actual) y 'new_name'. Úsalo \
    cuando el usuario quiera llamar de otra forma a un sitio ya guardado; si lo que \
    cambia son las coordenadas, usa save_place, y si el lugar ya no hace falta, \
    delete_place. Lee 'status': 'renamed' = hecho; 'not_found' = no hay ningún lugar con \
    ese nombre, mira 'known' y no digas que lo cambiaste; 'name_taken' = ya existe otro \
    lugar con el nombre nuevo, dile al usuario que elija otro o que borre el repetido; \
    'missing_fields' = falta 'name' o 'new_name'; 'unchanged' = el nombre nuevo es el \
    mismo. Usa list_places para ver los nombres exactos.
    """
    public static let parameters: [AgentToolParam] = [
        AgentToolParam(name: "name", type: .string, description: "Nombre actual del lugar, tal como aparece en list_places", required: true),
        AgentToolParam(name: "new_name", type: .string, description: "Nombre nuevo del lugar", required: true)
    ]

    private let placeStore: PlaceStore

    public init(placeStore: PlaceStore = .shared) {
        self.placeStore = placeStore
    }

    public func run(argsJSON: String) async -> String {
        let name = CreateNoteTool.parseString(named: "name", from: argsJSON)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let newName = CreateNoteTool.parseString(named: "new_name", from: argsJSON)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        var missing: [String] = []
        if name?.isEmpty != false { missing.append("name") }
        if newName?.isEmpty != false { missing.append("new_name") }
        guard missing.isEmpty, let name, let newName else {
            return ToolJSONOutput.object([
                "status": "missing_fields",
                "required": missing,
                "message": "Faltan datos: \(missing.joined(separator: ", "))."
            ])
        }

        guard let existing = placeStore.place(named: name) else {
            return ToolJSONOutput.object([
                "status": "not_found",
                "requested": name,
                "known": placeStore.list().prefix(20).map(\.name),
                "message": "No hay ningún lugar guardado llamado '\(name)'. En 'known' están los que sí hay."
            ])
        }

        if let clash = placeStore.place(named: newName), clash.id != existing.id {
            // Dos lugares con el mismo nombre hacen imposible resolver cuál quiere el
            // usuario, que es justo el problema que esta herramienta viene a evitar.
            return ToolJSONOutput.object([
                "status": "name_taken",
                "requested": newName,
                "message": "Ya hay otro lugar llamado '\(clash.name)'. Dile al usuario que elija otro nombre, o que borre el repetido con delete_place."
            ])
        }

        guard PlaceStore.normalize(existing.name) != PlaceStore.normalize(newName) else {
            return ToolJSONOutput.object([
                "status": "unchanged",
                "name": existing.name,
                "message": "Ya se llamaba así; no había nada que cambiar."
            ])
        }

        var renamed = existing
        renamed.name = newName
        placeStore.save(place: renamed)

        return ToolJSONOutput.object([
            "status": "renamed",
            "id": renamed.id,
            "name": newName,
            "previous_name": existing.name,
            "latitude": renamed.latitude,
            "longitude": renamed.longitude,
            "message": "El lugar «\(existing.name)» ahora se llama «\(newName)». Conserva sus coordenadas y sus \(renamed.visitCount) visita(s)."
        ])
    }
}
