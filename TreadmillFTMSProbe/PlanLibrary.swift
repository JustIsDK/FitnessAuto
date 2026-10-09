import SwiftUI
import UniformTypeIdentifiers

final class PlanLibrary: ObservableObject {
    @Published private(set) var custom: [WorkoutPlan] = []
    @Published var error: String?
    @Published var importMessage: String?
    var plans: [WorkoutPlan] { WorkoutPlan.presets + custom }
    private let url = URL.applicationSupportDirectory.appending(path: "FitnessAuto/plans.json")

    init() {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let loaded = try JSONDecoder().decode([WorkoutPlan].self, from: Data(contentsOf: url))
            guard loaded.allSatisfy({ $0.validationError == nil && $0.id > 2 }),
                  Set(loaded.map(\.id)).count == loaded.count else { throw CocoaError(.fileReadCorruptFile) }
            custom = loaded
        } catch { self.error = "读取自定义计划失败：\(error.localizedDescription)" }
    }

    func save(_ plan: WorkoutPlan) throws {
        if let message = plan.validationError { throw NSError(domain: "Plan", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
        guard plan.id > 2 else { throw CocoaError(.validationMissingMandatoryProperty) }
        var updated = custom.filter { $0.id != plan.id }
        updated.append(plan)
        try persist(updated)
    }

    func delete(_ id: Int) {
        do { try persist(custom.filter { $0.id != id }) }
        catch { self.error = "删除失败：\(error.localizedDescription)" }
    }

    func importFile(_ file: URL) {
        let access = file.startAccessingSecurityScopedResource()
        defer { if access { file.stopAccessingSecurityScopedResource() } }
        do {
            if let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 1_048_576 {
                throw PlanImportError(message: "文件不能超过 1 MB")
            }
            let firstID = max(Int(Date().timeIntervalSince1970 * 1000), (custom.map(\.id).max() ?? 2) + 1)
            let imported = try PlanImportDocument.decode(Data(contentsOf: file), firstID: firstID)
            // Validate the entire batch before writing; existing plans are retained.
            try persist(custom + imported)
            importMessage = "已导入 \(imported.count) 套计划，可在首页选择"
        } catch { self.error = "导入失败：\(error.localizedDescription)" }
    }

    private func persist(_ plans: [WorkoutPlan]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(plans).write(to: url, options: .atomic)
        custom = plans
    }

    func draft(from plan: WorkoutPlan? = nil) -> WorkoutPlan {
        let id = max(Int(Date().timeIntervalSince1970 * 1000), (custom.map(\.id).max() ?? 2) + 1)
        return WorkoutPlan(id: id, title: plan.map { $0.title + " · 自定义" } ?? "我的训练",
                           steps: plan?.steps ?? [WorkoutStep(id: 0, start: 0, duration: 300, title: "阶段 1", speed: 4, incline: 0)])
    }
}

struct PlanLibraryView: View {
    @EnvironmentObject private var library: PlanLibrary
    @EnvironmentObject private var bluetooth: TreadmillBluetooth
    @State private var draft: WorkoutPlan?
    @State private var importing = false
    var body: some View {
        List {
            Section {
                PageIntro(eyebrow: "YOUR ROUTINE", title: "找到自己的节奏。", subtitle: "选择、编辑或导入一套训练计划。")
            }.listRowBackground(Color.clear).listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 8, trailing: 4))
            Section("内置计划 · 可复制后修改") {
                ForEach(WorkoutPlan.presets) { plan in
                    Button { draft = library.draft(from: plan) } label: {
                        PlanSummaryRow(plan: plan, icon: "doc.on.doc")
                    }
                }
            }
            Section("自定义计划") {
                ForEach(library.custom) { plan in
                    Button { draft = plan } label: {
                        PlanSummaryRow(plan: plan, icon: "list.bullet.rectangle")
                    }
                    .swipeActions {
                        Button("删除", role: .destructive) { library.delete(plan.id) }
                    }
                }
                Button("新建计划", systemImage: "plus") { draft = library.draft() }
            }
            Section("导入计划") {
                Button("导入计划", systemImage: "square.and.arrow.down") { importing = true }
                Text("选择 JSON 计划文件，包含计划名称和各阶段的时长、速度、坡度。")
                    .font(.footnote).foregroundStyle(.secondary)
                if let message = library.importMessage { Text(message).font(.subheadline).foregroundStyle(.green) }
            }
        }
        .disabled(bluetooth.workoutBusy || bluetooth.workoutPaused)
        .appListStyle()
        .navigationTitle("计划库")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $draft) { plan in PlanEditor(plan: plan).environmentObject(library) }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            switch result {
            case .success(let file): library.importFile(file)
            case .failure(let error): library.error = "无法打开文件：\(error.localizedDescription)"
            }
        }
        .alert("计划保存", isPresented: Binding(get: { library.error != nil }, set: { if !$0 { library.error = nil } })) {
            Button("知道了") { library.error = nil }
        } message: { Text(library.error ?? "") }
    }
}

struct PlanEditor: View {
    @EnvironmentObject private var library: PlanLibrary
    @Environment(\.dismiss) private var dismiss
    @State var plan: WorkoutPlan
    @State private var error: String?
    var body: some View {
        NavigationStack {
            List {
                Section { TextField("计划名称", text: $plan.title) }
                ForEach($plan.steps) { $step in
                    Section {
                        TextField("阶段名称", text: $step.title)
                        Stepper("时长 \(clock(step.duration))", value: $step.duration, in: 10...3600, step: 10)
                        HStack {
                            Text("时长（秒）")
                            TextField("秒", value: $step.duration, format: .number).keyboardType(.numberPad).multilineTextAlignment(.trailing)
                        }
                        Stepper(String(format: "速度 %.1f km/h", step.speed), value: $step.speed, in: 1...18, step: 0.1)
                        Stepper("坡度 \(step.incline)%", value: $step.incline, in: 0...25)
                    } header: { Text("阶段 \((plan.steps.firstIndex { $0.id == step.id } ?? 0) + 1)") }
                }
                .onDelete { plan.steps.remove(atOffsets: $0) }
                .onMove { plan.steps.move(fromOffsets: $0, toOffset: $1) }
                Button("添加阶段", systemImage: "plus") {
                    plan.steps.append(WorkoutStep(id: (plan.steps.map(\.id).max() ?? -1) + 1, start: 0,
                                                  duration: 60, title: "新阶段", speed: 4, incline: 0))
                }.disabled(plan.steps.count >= 100)
                Text("总时长 \(clock(plan.duration)) · 点击编辑可调整阶段顺序或删除。开始前还会核对跑步机实际支持范围。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .appListStyle()
            .navigationTitle("编辑计划")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .primaryAction) { EditButton() }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        var start = 0
                        for index in plan.steps.indices {
                            plan.steps[index].start = start
                            // Validate duration before adding, including overflow protection.
                            guard (1...3600).contains(plan.steps[index].duration) else { error = "每个阶段需要 1–3600 秒"; return }
                            start += plan.steps[index].duration
                        }
                        do { try library.save(plan); dismiss() }
                        catch { self.error = error.localizedDescription }
                    }
                }
            }
            .alert("无法保存", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("知道了") { error = nil }
            } message: { Text(error ?? "") }
        }
    }
}
