import Foundation

struct BMSRideRecord: Codable, Identifiable {
    let id: UUID
    let startedAt: Date
    let endedAt: Date
    let vehicleName: String
    let statistics: ANTBMSSessionStatistics
    let completed: Bool
    /// Optional so records saved before build 25 remain readable.
    var vehicleID: UUID? = nil
    var bmsID: UUID? = nil
    var bmsName: String? = nil
}

struct BMSRecordFilter {
    enum Period: Int, CaseIterable {
        case all, today, last7Days, last30Days
        var title: String { [CWL("全部时间"), CWL("今天"), CWL("最近 7 天"), CWL("最近 30 天")][rawValue] }
    }
    enum Completion: Int, CaseIterable {
        case all, finished, fragments, recording
        var title: String { [CWL("全部状态"), CWL("已结束"), CWL("已保存片段"), CWL("记录中")][rawValue] }
    }
    var vehicleID: UUID?
    var vehicleName: String?
    var bmsID: UUID?
    var period: Period = .all
    var completion: Completion = .all

    func matches(_ record: BMSRideRecord, now: Date = Date(), calendar: Calendar = .current,
                 activeRecordID: UUID? = nil) -> Bool {
        if let bmsID, record.bmsID != bmsID { return false }
        if let vehicleName {
            if let vehicleID, let recordID = record.vehicleID {
                guard recordID == vehicleID else { return false }
            } else {
                guard record.vehicleName == vehicleName else { return false }
            }
        }
        let active = record.id == activeRecordID
        switch completion {
        case .all: break
        case .finished: guard record.completed && !active else { return false }
        case .fragments: guard !record.completed && !active else { return false }
        case .recording: guard active else { return false }
        }
        if period != .all {
            let days = period == .today ? 0 : period == .last7Days ? 6 : 29
            let startOfToday = calendar.startOfDay(for: now)
            guard let lower = calendar.date(byAdding: .day, value: -days, to: startOfToday),
                  let upper = calendar.date(byAdding: .day, value: 1, to: startOfToday),
                  record.startedAt >= lower, record.startedAt < upper else { return false }
        }
        return true
    }
}

struct BMSRideRecordStore {
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    private let key = "bmsRideRecords.v1"
    func records() -> [BMSRideRecord] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([BMSRideRecord].self, from: data)) ?? []
    }
    func save(_ record: BMSRideRecord) throws {
        var values = records().filter { $0.id != record.id }; values.insert(record, at: 0)
        defaults.set(try JSONEncoder().encode(Array(values.prefix(20))), forKey: key)
    }
    func remove(_ id: UUID) throws {
        defaults.set(try JSONEncoder().encode(records().filter { $0.id != id }), forKey: key)
    }
}
