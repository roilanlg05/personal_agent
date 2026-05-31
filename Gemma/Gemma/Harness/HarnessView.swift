import SwiftUI

struct HarnessView: View {
    let model: HarnessModel
    var body: some View {
        AgentChatView(model: model)
            .task { model.startServer() }
    }
}
