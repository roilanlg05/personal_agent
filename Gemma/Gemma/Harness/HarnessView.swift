import SwiftUI

struct HarnessView: View {
    @State private var model = HarnessModel()
    var body: some View {
        VStack { Text("Gemma (macOS) — M0 build OK").font(.headline) }
            .frame(minWidth: 480, minHeight: 320)
    }
}
