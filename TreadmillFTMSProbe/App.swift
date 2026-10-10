import SwiftUI

@main
struct TreadmillFTMSProbeApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("fitnessauto.weight.health.auto") private var autoWeightHealth = true
    @StateObject private var bluetooth = TreadmillBluetooth()

    @StateObject private var library = PlanLibrary()
    @StateObject private var scale = ScaleBluetooth()
    @StateObject private var weightHealth = WeightHealthStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(bluetooth)
                .environmentObject(library)
                .environmentObject(bluetooth.recorder)
                .environmentObject(scale)
                .environmentObject(weightHealth)
                .tint(AppDesign.accent)
                .task {
                    scale.setAppActive(scenePhase == .active)
                    await weightHealth.refreshProfile()
                }
                .onChange(of: scenePhase) { _, phase in
                    scale.setAppActive(phase == .active)
                    if phase == .active {
                        weightHealth.refreshAuthorization()
                        Task { await weightHealth.refreshProfile() }
                    }
                }
                .onChange(of: scale.reading) { _, reading in
                    guard reading?.stable == true, scale.canSave else { return }
                    let height = weightHealth.profileHeight.flatMap { (90...240).contains($0) ? $0 : nil }
                    scale.save(heightCm: height)
                    if autoWeightHealth, let record = scale.records.first {
                        Task { await weightHealth.save(record, requestPermission: false) }
                    }
                }
                .alert(item: $weightHealth.duplicateReview) { review in
                    Alert(title: Text("可能已有同一次测量"),
                          message: Text("苹果健康中已有时间和数值接近的记录，来源：\(review.sources)。是否仍然写入？"),
                          primaryButton: .cancel(Text("取消")),
                          secondaryButton: .default(Text("仍然写入")) {
                              Task { await weightHealth.save(review.record, allowDuplicate: true) }
                          })
                }
        }
    }
}
