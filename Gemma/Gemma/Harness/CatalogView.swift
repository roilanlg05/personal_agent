import SwiftUI

struct CatalogView: View {
    @Bindable var model: HarnessModel

    var body: some View {
        NavigationStack {
            List {
                Section("Device") {
                    HStack {
                        Text("Total RAM")
                        Spacer()
                        Text(formattedGiB(model.deviceCapability.totalRAMBytes))
                    }
                    HStack {
                        Text("Free disk")
                        Spacer()
                        Text(formattedGiB(model.deviceCapability.freeDiskBytes))
                    }
                }
                Section("Models") {
                    ForEach(model.catalog) { descriptor in
                        ModelRow(descriptor: descriptor, model: model)
                    }
                }
            }
            .navigationTitle("Models")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { model.showCatalog = false }
                }
            }
        }
    }

    private func formattedGiB(_ bytes: UInt64) -> String {
        String(format: "%.2f GiB", Double(bytes) / (1024.0 * 1024.0 * 1024.0))
    }
}

private struct ModelRow: View {
    let descriptor: ModelDescriptor
    @Bindable var model: HarnessModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading) {
                    Text(descriptor.displayName).font(.headline)
                    Text(String(format: "%.2f GiB · min %d GB RAM · ctx %d", descriptor.sizeInGB, descriptor.minDeviceMemoryGB, descriptor.maxContextLength))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                actionButton
            }
            if let progress = model.downloads[descriptor.id], progress.isActive {
                ProgressView(value: progress.fractionCompleted)
                Text(String(format: "%.1f / %.1f MiB", Double(progress.bytesDownloaded) / 1_048_576.0, Double(progress.totalBytes) / 1_048_576.0))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if let error = model.downloads[descriptor.id]?.error {
                Text("Error: \(error)").font(.caption2).foregroundStyle(.red)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var actionButton: some View {
        if model.installedModels.contains(descriptor) {
            Button("Remove") { model.removeInstalled(descriptor) }
                .tint(.red)
        } else if model.downloads[descriptor.id]?.isActive == true {
            Button("Cancel") { model.cancelDownload(descriptor.id) }
                .tint(.orange)
        } else {
            Button("Download") { model.startDownload(descriptor) }
                .tint(.blue)
        }
    }
}

#Preview {
    CatalogView(model: HarnessModel())
}
