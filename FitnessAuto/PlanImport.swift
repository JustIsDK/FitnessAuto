import Foundation

struct PlanImportError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct PlanImportDocument: Decodable {
    let format: String
    let version: Int
    let plans: [Plan]

    struct Plan: Decodable {
        let title: String
        let steps: [Step]
    }
    struct Step: Decodable {
        let title: String
        let durationSeconds: Int
        let speedKmh: Double
        let inclinePercent: Int
    }

    static func decode(_ data: Data, firstID: Int) throws -> [WorkoutPlan] {
        guard data.count <= 1_048_576 else { throw PlanImportError(message: "文件不能超过 1 MB") }
        let document: PlanImportDocument
        do { document = try JSONDecoder().decode(Self.self, from: data) }
        catch { throw PlanImportError(message: "JSON 格式或字段类型错误，请按计划导入文档检查文件") }
        guard document.format == "fitnessauto.plan", document.version == 1 else {
            throw PlanImportError(message: "不支持此文件格式或版本；需要 fitnessauto.plan，version 为 1")
        }
        guard (1...50).contains(document.plans.count) else { throw PlanImportError(message: "每个文件需要 1–50 套计划") }
        guard firstID > 2, firstID <= Int.max - document.plans.count else { throw PlanImportError(message: "无法分配计划编号") }
        return try document.plans.enumerated().map { planIndex, imported in
            guard !imported.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  imported.title.count <= 100, (1...100).contains(imported.steps.count) else {
                throw PlanImportError(message: "第 \(planIndex + 1) 套计划名称需要 1–100 字，阶段数需要 1–100")
            }
            var start = 0
            let steps = try imported.steps.enumerated().map { index, step in
                guard (1...3600).contains(step.durationSeconds),
                      !step.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      step.title.count <= 100 else {
                    throw PlanImportError(message: "\(imported.title) 第 \(index + 1) 阶段：名称需要 1–100 字，时长需要 1–3600 秒")
                }
                defer { start += step.durationSeconds }
                return WorkoutStep(id: index, start: start, duration: step.durationSeconds,
                                   title: step.title, speed: step.speedKmh, incline: step.inclinePercent)
            }
            let plan = WorkoutPlan(id: firstID + planIndex, title: imported.title, steps: steps)
            if let error = plan.validationError { throw PlanImportError(message: "\(plan.title)：\(error)") }
            return plan
        }
    }
}
