import SwiftUI

struct HarnessView: View {
    @State private var model = HarnessModel()
    var body: some View {
        AgentChatView(model: model)
    }
}
