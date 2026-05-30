import SwiftUI

struct AgentView: View {
    @Bindable var model: HarnessModel
    @State private var prompt = "What time is it?"

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(model.agentLog.enumerated()), id: \.offset) { _, line in
                            Text(line).font(.callout).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }.padding()
                }
                HStack {
                    TextField("Ask the agent…", text: $prompt)
                        .textFieldStyle(.roundedBorder)
                    Button("Send") { let p = prompt; Task { await model.runAgentTurn(p) } }
                        .disabled(model.agentRunning || prompt.isEmpty)
                }.padding(.horizontal)
            }
            .navigationTitle("Agent")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { model.showAgent = false } } }
        }
    }
}
