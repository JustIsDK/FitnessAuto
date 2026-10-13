import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class PlanLibrary: ObservableObject {
    @Published private(set) var custom: [WorkoutPlan] = []
    @Published var error: String?
    @Published var importMessage: String?
    @Published private(set) var pendingImports: [PendingPlanImport] = []
    var plans: [WorkoutPlan] { custom + WorkoutPlan.presets }
    private let url: URL
    private var pendingURL: URL { url.deletingLastPathComponent().appending(path: "pending-imports.json") }
    private func stagedURL(_ id: UUID) -> URL {
        url.deletingLastPathComponent().appending(path: "Imports/\(id.uuidString).json")
    }

    init(directory: URL = URL.applicationSupportDirectory.appending(path: "FitnessAuto")) {
        url = directory.appending(path: "plans.json")
        if let data = try? Data(contentsOf: pendingURL),
           let pending = try? JSONDecoder().decode([PendingPlanImport].self, from: data) {
            pendingImports = pending.map { item in
                var item = item
                if item.receiving { item.failure = "上次文件接收未完成，请重新打开文件" }
                return item
            }
        }
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let loaded = try JSONDecoder().decode([WorkoutPlan].self, from: Data(contentsOf: url))
            guard loaded.allSatisfy({ $0.validationError == nil && $0.id > 2 }),
                  Set(loaded.map(\.id)).count == loaded.count else { throw CocoaError(.fileReadCorruptFile) }
            custom = loaded
            let savedIDs = Set(loaded.map(\.id))
            let completed = pendingImports.filter { item in
                item.committedPlanIDs.map { !$0.isEmpty && Set($0).isSubset(of: savedIDs) } == true
            }
            for item in completed { discardImport(item.id) }
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

    func receiveImport(_ file: URL) {
        let key = file.standardizedFileURL.absoluteString
        guard !pendingImports.contains(where: { $0.sourceKey == key }) else { return }
        let request = PendingPlanImport(id: UUID(), fileName: file.lastPathComponent, sourceKey: key)
        let access = file.startAccessingSecurityScopedResource()
        pendingImports.append(request)
        persistPending()
        let staged = stagedURL(request.id)
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            guard let self, let index = self.pendingImports.firstIndex(where: { $0.id == request.id }),
                  self.pendingImports[index].receiving else { return }
            self.pendingImports[index].failure = "读取文件超时，请确认文件已下载后重新打开"
            self.persistPending()
        }
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result { try PlanImportFile.prepare(file, staged: staged) }
            }.value
            if access { file.stopAccessingSecurityScopedResource() }
            guard let index = pendingImports.firstIndex(where: { $0.id == request.id }), pendingImports[index].receiving else {
                try? FileManager.default.removeItem(at: staged)
                return
            }
            switch result {
            case .success(let plans): pendingImports[index].plans = plans
            case .failure(let error): pendingImports[index].failure = error.localizedDescription
            }
            persistPending()
        }
    }

    @discardableResult func confirmImport(_ id: UUID) -> Bool {
        guard let request = pendingImports.first, request.id == id, let preview = request.plans else { return false }
        let lastID = custom.map(\.id).max() ?? 2
        guard lastID < Int.max else { error = "无法分配计划编号"; return false }
        let firstID = max(Int(Date().timeIntervalSince1970 * 1000), lastID + 1)
        guard firstID <= Int.max - preview.count else {
            error = "无法分配计划编号"; return false
        }
        let imported = preview.enumerated().map { index, plan in
            WorkoutPlan(id: firstID + index, title: plan.title, steps: plan.steps)
        }
        do {
            // Validate and allocate against the current library, not a stale preview snapshot.
            guard imported.allSatisfy({ $0.validationError == nil }) else {
                throw PlanImportError(message: "计划参数无效，请重新打开文件")
            }
            // Journal the assigned IDs so a crash after saving cannot import the batch twice.
            pendingImports[0].committedPlanIDs = imported.map(\.id)
            guard persistPending() else {
                pendingImports[0].committedPlanIDs = nil
                return false
            }
            try persist(custom + imported)
            importMessage = "已导入 \(imported.count) 套计划，可在训练页选择"
            discardImport(id)
            return true
        } catch {
            pendingImports[0].committedPlanIDs = nil
            persistPending()
            self.error = "保存失败，请检查存储空间后重试"
            return false
        }
    }

    func discardImport(_ id: UUID) {
        pendingImports.removeAll { $0.id == id }
        try? FileManager.default.removeItem(at: stagedURL(id))
        persistPending()
    }

    @discardableResult private func persistPending() -> Bool {
        do {
            try FileManager.default.createDirectory(at: pendingURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(pendingImports).write(to: pendingURL, options: .atomic)
            return true
        } catch {
            self.error = "待导入文件暂存失败，请检查存储空间，保持 APP 打开后重试"
            return false
        }
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

private enum PlanLibrarySheet: Identifiable {
    case editor(WorkoutPlan), importReview
    var id: String {
        switch self {
        case .editor(let plan): return "edit-\(plan.id)"
        case .importReview: return "import"
        }
    }
}

struct PlanLibraryView: View {
    @EnvironmentObject private var library: PlanLibrary
    @EnvironmentObject private var bluetooth: TreadmillBluetooth
    var isSelected = true
    var presentationBlocked = false
    @State private var activeSheet: PlanLibrarySheet?
    @State private var importing = false
    private var importBlocked: Bool { bluetooth.workoutBusy || bluetooth.workoutPaused || bluetooth.stopNeedsRetry }
    private func presentPendingImport() {
        guard isSelected, !presentationBlocked, !importBlocked, !importing, activeSheet == nil, library.error == nil,
              !library.pendingImports.isEmpty else { return }
        activeSheet = .importReview
    }
    var body: some View {
        List {
            Section("自定义计划") {
                ForEach(library.custom) { plan in
                    Button { activeSheet = .editor(plan) } label: {
                        PlanSummaryRow(plan: plan, icon: "list.bullet.rectangle")
                    }
                    .swipeActions {
                        Button("删除", role: .destructive) { library.delete(plan.id) }
                    }
                }
                Button("新建计划", systemImage: "plus") { activeSheet = .editor(library.draft()) }
            }
            Section("内置计划 · 可复制后修改") {
                ForEach(WorkoutPlan.presets) { plan in
                    Button { activeSheet = .editor(library.draft(from: plan)) } label: {
                        PlanSummaryRow(plan: plan, icon: "doc.on.doc")
                    }
                }
            }
            Section("导入计划") {
                Button("导入计划", systemImage: "square.and.arrow.down") { importing = true }
                Text("选择 JSON 文件，或从文件分享菜单中用 FitnessAuto 打开。")
                    .font(.footnote).foregroundStyle(.secondary)
                if !library.pendingImports.isEmpty {
                    Button("待导入文件（\(library.pendingImports.count) 个）") { presentPendingImport() }
                }
                if let message = library.importMessage { Text(message).font(.subheadline).foregroundStyle(AppDesign.accent) }
            }
        }
        .disabled(importBlocked)
        .appListStyle()
        .navigationTitle("计划库")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $activeSheet, onDismiss: presentPendingImport) { sheet in
            switch sheet {
            case .editor(let plan):
                PlanEditor(plan: plan).environmentObject(library)
                    .safeAreaInset(edge: .bottom) {
                        if !library.pendingImports.isEmpty {
                            Text("已收到文件，完成或取消编辑后可导入")
                                .font(.footnote).padding().frame(maxWidth: .infinity).background(.regularMaterial)
                        }
                    }
            case .importReview:
                PlanImportReview().environmentObject(library)
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            switch result {
            case .success(let file): library.receiveImport(file)
            case .failure(let error):
                let failure = error as NSError
                if failure.domain != NSCocoaErrorDomain || failure.code != NSUserCancelledError {
                    library.error = "无法打开文件，请确认文件已下载后重试"
                }
            }
            // The provider's own sheet must finish dismissing before showing the preview.
            DispatchQueue.main.async { presentPendingImport() }
        }
        .alert("计划保存", isPresented: Binding(get: { library.error != nil && activeSheet == nil },
            set: { if !$0 { library.error = nil } })) {
                Button("知道了") { library.error = nil }
            } message: { Text(library.error ?? "") }
        .onAppear { presentPendingImport() }
        .onChange(of: isSelected) { _, selected in if selected { presentPendingImport() } }
        .onChange(of: presentationBlocked) { _, blocked in if !blocked { presentPendingImport() } }
        .onChange(of: library.pendingImports.map(\.id)) { _, _ in presentPendingImport() }
        .onChange(of: library.error) { _, error in if error == nil { presentPendingImport() } }
        .onChange(of: importing) { _, shown in if !shown { presentPendingImport() } }
        .onChange(of: importBlocked) { _, blocked in
            if blocked, activeSheet?.id == "import" { activeSheet = nil }
            else { presentPendingImport() }
        }
    }
}

private struct PlanImportReview: View {
    @EnvironmentObject private var library: PlanLibrary
    @Environment(\.dismiss) private var dismiss
    @State private var saving = false
    private var request: PendingPlanImport? { library.pendingImports.first }
    private func cancel() {
        if let request { library.discardImport(request.id) }
        dismiss()
    }
    var body: some View {
        NavigationStack {
            List {
                if let request {
                    Section("接收的文件") { Text(request.fileName).textSelection(.enabled) }
                    if request.receiving {
                        Section { ProgressView("正在解析计划…") }
                    } else if let failure = request.failure {
                        Section("无法导入计划") { Text(failure).foregroundStyle(.secondary) }
                        Section { Button("关闭") { cancel() } }
                    } else if let plans = request.plans {
                        Section("已解析 \(plans.count) 套计划") {
                            ForEach(plans) { plan in PlanSummaryRow(plan: plan, icon: "list.bullet.rectangle", showsChevron: false) }
                        }
                        Section {
                            if Set(plans.map(\.title)).count != plans.count || plans.contains(where: { plan in library.plans.contains { $0.title == plan.title } }) {
                                Text("将新增同名计划，不会覆盖已有计划").font(.footnote)
                            } else {
                                Text("将新增到自定义计划，不覆盖已有计划").font(.footnote).foregroundStyle(.secondary)
                            }
                            Button(saving ? "正在导入…" : "导入 \(plans.count) 套计划") {
                                guard !saving else { return }
                                saving = true
                                if library.confirmImport(request.id) { dismiss() }
                                saving = false
                            }.buttonStyle(AppPrimaryButtonStyle()).disabled(saving)
                                .accessibilityIdentifier("confirmPlanImport")
                        }
                    }
                    if library.pendingImports.count > 1 {
                        Section { Text("另有 \(library.pendingImports.count - 1) 个文件等待处理").font(.footnote) }
                    }
                }
            }
            .appListStyle()
            .navigationTitle("导入计划")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { cancel() }.disabled(saving) } }
            .interactiveDismissDisabled()
            .alert("导入未完成", isPresented: Binding(get: { library.error != nil }, set: { if !$0 { library.error = nil } })) {
                Button("知道了") { library.error = nil }
            } message: { Text(library.error ?? "") }
        }
    }
}

struct PlanEditor: View {
    @EnvironmentObject private var library: PlanLibrary
    @Environment(\.dismiss) private var dismiss
    @State var plan: WorkoutPlan
    @State private var error: String?
    @State private var arrangingStages = false
    private enum Field: Hashable {
        case planTitle, stageTitle(Int), duration(Int)
    }
    @FocusState private var focusedField: Field?
    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("计划名称", text: $plan.title)
                        .focused($focusedField, equals: .planTitle)
                }
                ForEach($plan.steps) { $step in
                    Section {
                        TextField("阶段名称", text: $step.title)
                            .focused($focusedField, equals: .stageTitle(step.id))
                        Stepper("时长 \(clock(step.duration))", value: $step.duration, in: 10...3600, step: 10)
                        HStack {
                            Text("时长（秒）")
                            TextField("秒", value: $step.duration, format: .number).keyboardType(.numberPad).multilineTextAlignment(.trailing)
                                .focused($focusedField, equals: .duration(step.id))
                        }
                        Stepper(String(format: "速度 %.1f km/h", step.speed), value: $step.speed, in: 1...18, step: 0.1)
                        Stepper("坡度 \(step.incline)%", value: $step.incline, in: 0...25)
                    } header: { Text("阶段 \((plan.steps.firstIndex { $0.id == step.id } ?? 0) + 1)") }
                }
                Button("添加阶段", systemImage: "plus") {
                    plan.steps.append(WorkoutStep(id: (plan.steps.map(\.id).max() ?? -1) + 1, start: 0,
                                                  duration: 60, title: "新阶段", speed: 4, incline: 0))
                }.disabled(plan.steps.count >= 100)
                Text("总时长 \(clock(plan.duration)) · 点击调整阶段可排序或删除。开始前还会核对跑步机实际支持范围。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .appListStyle()
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("编辑计划")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button("调整阶段") {
                        focusedField = nil
                        arrangingStages = true
                    }
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("完成") { focusedField = nil }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        focusedField = nil
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
            .sheet(isPresented: $arrangingStages) {
                PlanStageOrderView(steps: $plan.steps)
            }
            .alert("无法保存", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("知道了") { error = nil }
            } message: { Text(error ?? "") }
        }
    }
}

private struct PlanStageOrderView: View {
    @Binding var steps: [WorkoutStep]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("第\(index + 1)阶段 · \(step.title)").font(.headline)
                        Text(String(format: "%@ · %.1f km/h · 坡度 %d%%", clock(step.duration), step.speed, step.incline))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .onDelete { steps.remove(atOffsets: $0) }
                .onMove { steps.move(fromOffsets: $0, toOffset: $1) }
            }
            .environment(\.editMode, .constant(.active))
            .appListStyle()
            .navigationTitle("调整阶段")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}
