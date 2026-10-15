import SwiftUI
import UIKit

private struct ShareFile: Identifiable {
    let url: URL
    var id: URL { url }
}

struct WorkoutRecordDetailView: View {
    let record: WorkoutRecord
    @State private var shareFile: ShareFile?
    @State private var temporaryShareURL: URL?
    @State private var shareError: String?

    var body: some View {
        List {
            Section {
                Label(record.title, systemImage: record.running ? "figure.run" : "figure.walk")
                    .font(.title2.weight(.semibold))
                if let start = record.start {
                    Text(start, format: .dateTime.month().day().hour().minute())
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
            Section("运动数据") {
                LabeledContent("运动类型", value: record.activityTitle)
                LabeledContent("时长", value: record.durationText)
                LabeledContent("距离", value: record.distanceText)
                LabeledContent("消耗热量", value: record.energyText)
            }
            Section {
                Button {
                    Task { await prepareShare() }
                } label: {
                    Label("分享运动记录图片", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity, alignment: .center)
                }
                .accessibilityIdentifier("workoutShare")
            }
        }
        .appListStyle()
        .navigationTitle("运动详情")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await prepareShare() }
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .accessibilityLabel("分享运动记录图片")
                .accessibilityIdentifier("workoutShareToolbar")
            }
        }
        .sheet(item: $shareFile, onDismiss: {
            if let url = temporaryShareURL { try? FileManager.default.removeItem(at: url) }
            temporaryShareURL = nil
        }) { file in
            WorkoutShareSheet(url: file.url)
        }
        .alert("无法生成分享图片", isPresented: Binding(
            get: { shareError != nil }, set: { if !$0 { shareError = nil } })) {
                Button("知道了") { shareError = nil }
            } message: {
                Text(shareError ?? "")
            }
    }

    @MainActor private func prepareShare() async {
        do {
            guard shareFile == nil else { return }
            let url = try WorkoutShareRenderer.render(record: record)
            temporaryShareURL = url
            shareFile = ShareFile(url: url)
        } catch {
            shareError = error.localizedDescription
        }
    }
}

struct WorkoutShareCard: View {
    let record: WorkoutRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 30) {
            HStack(spacing: 24) {
                Image(systemName: record.running ? "figure.run" : "figure.walk")
                    .font(.system(size: 80, weight: .medium))
                    .foregroundStyle(AppDesign.accent)
                Text(record.title)
                    .font(.system(size: 72, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
            }
            Text(record.startText)
                .font(.system(size: 40, weight: .regular))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 26) {
                Text("\(record.activityTitle) · \(record.durationText)")
                    .font(.system(size: 50, weight: .medium))
                shareMetric("距离", value: record.distanceText)
                shareMetric("消耗热量", value: record.energyText)
            }
        }
        .padding(72)
        .frame(width: 1080, height: 1350, alignment: .topLeading)
        .background(Color.white)
        .environment(\.colorScheme, .light)
        .foregroundStyle(.black)
    }

    private func shareMetric(_ title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 20) {
            Text(title).foregroundStyle(.secondary)
            Text(value).fontWeight(.medium)
        }.font(.system(size: 42))
    }
}

@MainActor enum WorkoutShareRenderer {
    static func render(record: WorkoutRecord) throws -> URL {
        let renderer = ImageRenderer(content: WorkoutShareCard(record: record))
        renderer.scale = 1
        guard let image = renderer.uiImage, let data = image.pngData() else {
            throw NSError(domain: "FitnessAuto.Share", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "分享图片生成失败，请重试"])
        }
        let url = FileManager.default.temporaryDirectory
            .appending(path: "FitnessAuto-\(record.id.uuidString)-\(UUID().uuidString).png")
        try data.write(to: url, options: .atomic)
        return url
    }
}

private struct WorkoutShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, _ in
            try? FileManager.default.removeItem(at: url)
        }
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) { }
}
