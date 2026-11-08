import XCTest
@testable import Gemma

/// EL ORDEN DE LAS CLAVES DE LA SALIDA DE UN TOOL ES ESTABLE.
///
/// EL DEFECTO QUE ARREGLA. `ToolJSONOutput.object` serializaba un `Dictionary` de Swift sin
/// pedir `.sortedKeys`, y el orden de iteración de un diccionario de Swift no es una propiedad
/// del contenido: depende de la semilla de hash del PROCESO (aleatoria por arranque) y de la
/// CAPACIDAD de la tabla, que cambia según cómo se construyó el diccionario. Las dos cosas
/// están medidas, con el mismo par de claves `["status", "message"]`:
///
///   - Entre procesos: seis arranques del mismo programa dieron `{"message":…,"status":…}` en
///     tres y `{"status":…,"message":…}` en los otros tres. O sea que CUALQUIER aserción que
///     compare la salida de un tool byte a byte es intermitente run a run, con una moneda al
///     aire por cada ejecución de la suite.
///   - Dentro de un mismo proceso: dos diccionarios con las MISMAS claves pero distinta
///     capacidad (`[:]` recién creado contra `[String: Any?](minimumCapacity: 64)`) se
///     serializaron en órdenes distintos en la misma ejecución.
///
/// POR QUÉ IMPORTA MÁS QUE LA PRUEBA QUE LO DELATÓ. La suite es el instrumento con el que se
/// mide todo lo demás de este proyecto (la línea base de fallos preexistentes, cada tabla de
/// mutaciones). Una suite que no da el mismo resultado dos veces no mide: adivina. Por eso el
/// orden estable es una propiedad de producción y no una precaución de los tests.
///
/// CÓMO SE AFIRMA SIN UNA MONEDA AL AIRE. Afirmar «dos llamadas dan lo mismo» sería un test
/// intermitente para detectar una intermitencia: con las claves de un tool real pasaría la
/// mitad de las veces. Lo que se afirma es la propiedad fuerte —las claves salen en orden
/// ALFABÉTICO— con ocho claves cuyo orden alfabético NO es el de inserción: un orden de hash
/// que coincidiese por casualidad con el alfabético tiene 1 posibilidad entre 8! = 40320.
final class ToolJSONOutputOrderTests: XCTestCase {

    /// Ocho claves cuyo orden alfabético (`a_…` → `h_…`) es el inverso del de inserción, para
    /// que ni el orden de inserción ni el de hash puedan pasar por el alfabético.
    private static let claves = ["h_status", "g_message", "f_url", "e_title",
                                 "d_count", "c_value", "b_what", "a_content"]

    private func clavesEnOrdenDeAparicion(_ json: String) -> [String] {
        // Se localiza cada clave por su forma de clave JSON (`"<clave>":`) y se ordenan por la
        // posición en la que aparecen. No se parsea: lo que se mide es el TEXTO, que es
        // precisamente lo que un parser descarta.
        Self.claves
            .compactMap { clave -> (String, String.Index)? in
                guard let r = json.range(of: "\"\(clave)\":") else { return nil }
                return (clave, r.lowerBound)
            }
            .sorted { $0.1 < $1.1 }
            .map(\.0)
    }

    /// LA PROPIEDAD: las claves salen en orden alfabético, luego el orden no depende del
    /// proceso ni de la capacidad de la tabla.
    func test_las_claves_salen_en_orden_alfabetico() {
        var campos: [String: Any?] = [:]
        for clave in Self.claves { campos[clave] = clave }
        let json = ToolJSONOutput.object(campos)
        let aparicion = clavesEnOrdenDeAparicion(json)
        XCTAssertEqual(aparicion.count, Self.claves.count,
                       "faltan claves en la salida: \(json)")
        XCTAssertEqual(aparicion, Self.claves.sorted(),
                       "el orden de las claves no es estable (no es alfabético): \(json)")
    }

    /// El mismo contenido construido de DOS maneras distintas —capacidad por omisión contra
    /// capacidad reservada— da la MISMA cadena. Es la inestabilidad dentro de un solo proceso,
    /// la que hace intermitente una prueba que compara dos salidas entre sí.
    func test_la_capacidad_de_la_tabla_no_cambia_la_salida() {
        var porOmision: [String: Any?] = [:]
        for clave in Self.claves { porOmision[clave] = clave }
        var conCapacidad = [String: Any?](minimumCapacity: 256)
        for clave in Self.claves.reversed() { conCapacidad[clave] = clave }
        XCTAssertEqual(ToolJSONOutput.object(porOmision), ToolJSONOutput.object(conCapacidad),
                       "el mismo contenido tiene que dar la misma cadena")
    }

    /// Y la forma REAL que produce el bucle para una herramienta inexistente —el resultado que
    /// delató el defecto— empieza por la clave que el orden alfabético pone primero. Ancla la
    /// propiedad a una salida de producción, no solo a claves inventadas.
    func test_la_forma_real_del_resultado_de_herramienta_inexistente() {
        let resultado = Agent.resultadoDeHerramientaInexistente(nombre: "browser_open")
        XCTAssertTrue(resultado.hasPrefix(#"{"message":"#),
                      "alfabéticamente `message` va antes de `status`: \(resultado)")
        // Y sigue siendo JSON legible con las dos claves del contrato.
        XCTAssertEqual(Agent.estadoDelResultado(resultado), "error")
        XCTAssertNotNil(Agent.motivoDelResultado(resultado))
    }

    /// El orden estable NO se consigue a costa de las barras: `.withoutEscapingSlashes` sigue
    /// puesto, que es lo que mantiene legibles las URLs en el prompt del modelo.
    func test_las_barras_siguen_sin_escaparse() {
        XCTAssertEqual(ToolJSONOutput.object(["url": "https://a.test/x"]),
                       #"{"url":"https://a.test/x"}"#)
    }
}
