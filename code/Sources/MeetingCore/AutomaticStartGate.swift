import Foundation

/// A detection episode survives task restarts; permission prompts carry its generation.
public struct AutomaticStartGate {
    public private(set) var generation: UInt64 = 0
    public private(set) var active = false
    public private(set) var suppressed = false
    private var rejectableEpisode = false
    private var absentSince: Date?
    public init() {}
    public mutating func began() -> UInt64 { generation &+= 1; active = true; rejectableEpisode = true; absentSince = nil; return generation }
    public mutating func ended() { generation &+= 1; active = false; rejectableEpisode = false; suppressed = false; absentSince = nil }
    public mutating func disabled() { generation &+= 1; active = false; absentSince = nil }
    public mutating func suppressCurrent() { if active || rejectableEpisode { suppressed = true } }
    public func permits(_ token: UInt64, enabled: Bool) -> Bool { enabled && active && !suppressed && token == generation }
    public mutating func observe(_ present: Bool?, at date: Date) {
        guard present == false else { absentSince = nil; return }
        if absentSince == nil { absentSince = date }
        if date.timeIntervalSince(absentSince!) >= 8, active || suppressed || rejectableEpisode { ended() }
    }
}
