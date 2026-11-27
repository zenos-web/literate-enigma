import UIKit

final class BMSVoltageTrendView: UIView, UIGestureRecognizerDelegate {
    private var selectedElapsed: TimeInterval?
    var points: [ANTBMSSessionStatistics.Point] = [] {
        didSet {
            if !points.contains(where: { $0.elapsed == selectedElapsed }) { selectedElapsed = nil }
            refreshAccessibilityValue()
            setNeedsDisplay()
        }
    }
    private func refreshAccessibilityValue() {
        if let point = points.first(where: { $0.elapsed == selectedElapsed }) {
            accessibilityValue = selectionDescription(point)
        } else {
            if let low = points.map(\.lowerVoltage).min(), let high = points.map(\.upperVoltage).max() {
                let source = points.allSatisfy { $0.minimumVoltage != nil } ? CWL("包含区间极值") : CWL("旧版抽样，可能遗漏瞬时压降")
                accessibilityValue = String(format: "曲线范围 %.2f 至 %.2f 伏，%@", low, high, source)
            } else { accessibilityValue = CWL("等待电压数据") }
        }
    }
    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false; isAccessibilityElement = true; accessibilityLabel = CWL("本次电压趋势")
        accessibilityTraits.insert(.adjustable)
        accessibilityHint = "左右滑动查看区间；VoiceOver 下向上或向下轻扫切换区间。"
        heightAnchor.constraint(equalToConstant: 250).isActive = true
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(selectInterval(_:))))
        let pan = UIPanGestureRecognizer(target: self, action: #selector(scrubInterval(_:)))
        pan.delegate = self
        addGestureRecognizer(pan)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func selectInterval(_ recognizer: UITapGestureRecognizer) {
        let position = recognizer.location(in: self)
        guard bounds.inset(by: UIEdgeInsets(top: 30, left: 48, bottom: 100, right: 8)).contains(position) else { return }
        selectInterval(at: position, announce: true)
    }

    @objc private func scrubInterval(_ recognizer: UIPanGestureRecognizer) {
        selectInterval(at: recognizer.location(in: self), announce: recognizer.state == .ended)
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
        let velocity = pan.velocity(in: self)
        let area = bounds.inset(by: UIEdgeInsets(top: 30, left: 48, bottom: 100, right: 8))
        return abs(velocity.x) > abs(velocity.y) && area.contains(pan.location(in: self))
    }

    private func selectInterval(at position: CGPoint, announce: Bool) {
        guard let first = points.first, let last = points.last else { return }
        let area = bounds.inset(by: UIEdgeInsets(top: 30, left: 48, bottom: 100, right: 8))
        guard area.width > 0 else { return }
        let fraction = Double(min(1, max(0, (position.x - area.minX) / area.width)))
        let time = first.elapsed + fraction * max(1, last.latestElapsed - first.elapsed)
        let point = points.first { time >= $0.elapsed && time <= $0.latestElapsed }
            ?? points.min { abs($0.latestElapsed - time) < abs($1.latestElapsed - time) }
        select(point, announce: announce)
    }

    private func selectionDescription(_ point: ANTBMSSessionStatistics.Point) -> String {
        if point.minimumVoltage == nil {
            return String(format: "第 %.0f 秒，抽样 %.2f 伏，未保存区间极值", point.elapsed, point.voltage)
        }
        return String(format: "第 %.0f 至 %.0f 秒，最低 %.2f 伏，最高 %.2f 伏，最新 %.2f 伏",
            point.elapsed, point.latestElapsed, point.lowerVoltage, point.upperVoltage, point.voltage)
    }

    private func select(_ point: ANTBMSSessionStatistics.Point?, announce: Bool) {
        guard let point else { return }
        selectedElapsed = point.elapsed
        refreshAccessibilityValue()
        setNeedsDisplay()
        if announce { UIAccessibility.post(notification: .announcement, argument: selectionDescription(point)) }
    }

    override func accessibilityIncrement() { stepSelection(1) }
    override func accessibilityDecrement() { stepSelection(-1) }
    private func stepSelection(_ step: Int) {
        guard !points.isEmpty else { return }
        if let index = points.firstIndex(where: { $0.elapsed == selectedElapsed }) {
            select(points[min(points.count - 1, max(0, index + step))], announce: false)
        } else {
            select(step > 0 ? points.first : points.last, announce: false)
        }
    }

    override func draw(_ rect: CGRect) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular),
            .foregroundColor: UIColor.secondaryLabel]
        guard let first = points.first, let last = points.last,
              let minimum = points.map(\.lowerVoltage).min(), let maximum = points.map(\.upperVoltage).max() else {
            (CWL("收到数据后显示电压趋势") as NSString).draw(at: CGPoint(x: 8, y: 80), withAttributes: attributes)
            return
        }
        let hasExtrema = points.allSatisfy { $0.minimumVoltage != nil && $0.maximumVoltage != nil }
        let title = String(format: hasExtrema ? "趋势范围 %.2f–%.2f V" : "旧版抽样 %.2f–%.2f V", minimum, maximum)
        (title as NSString).draw(at: CGPoint(x: 4, y: 4), withAttributes: attributes)
        let padding = max(0.05, (maximum - minimum) * 0.08)
        let low = minimum - padding, high = maximum + padding
        let area = bounds.inset(by: UIEdgeInsets(top: 30, left: 48, bottom: 100, right: 8))
        guard area.width > 0, area.height > 0 else { return }
        let duration = max(last.latestElapsed - first.elapsed, 1)
        func x(_ elapsed: Double) -> CGFloat {
            area.minX + CGFloat((elapsed - first.elapsed) / duration) * area.width
        }
        func y(_ voltage: Double) -> CGFloat {
            area.maxY - CGFloat((voltage - low) / (high - low)) * area.height
        }
        for voltage in [high, (high + low) / 2, low] {
            let line = UIBezierPath()
            line.move(to: CGPoint(x: area.minX, y: y(voltage)))
            line.addLine(to: CGPoint(x: area.maxX, y: y(voltage)))
            UIColor.separator.withAlphaComponent(0.35).setStroke(); line.lineWidth = 0.5; line.stroke()
            (String(format: "%.2f", voltage) as NSString)
                .draw(at: CGPoint(x: 0, y: y(voltage) - 7), withAttributes: attributes)
        }
        let path = UIBezierPath()
        var previous: ANTBMSSessionStatistics.Point?
        for point in points {
            let position = CGPoint(x: x(point.latestElapsed), y: y(point.voltage))
            if previous == nil || point.startsSegment == true
                || point.elapsed - previous!.latestElapsed > 10 { path.move(to: position) }
            else { path.addLine(to: position) }
            if point.minimumVoltage != nil {
                let range = UIBezierPath()
                range.move(to: CGPoint(x: position.x, y: y(point.lowerVoltage)))
                range.addLine(to: CGPoint(x: position.x, y: y(point.upperVoltage)))
                UIColor.systemBlue.withAlphaComponent(0.35).setStroke()
                range.lineWidth = min(6, max(2, area.width / CGFloat(points.count) * 0.35))
                range.lineCapStyle = .round
                range.stroke()
            }
            previous = point
        }
        UIColor.systemBlue.setStroke(); path.lineWidth = 2; path.stroke()
        UIColor.systemBlue.setFill()
        UIBezierPath(ovalIn: CGRect(x: x(last.latestElapsed) - 2.5, y: y(last.voltage) - 2.5, width: 5, height: 5)).fill()
        if let point = points.first(where: { $0.elapsed == selectedElapsed }) {
            let cursor = UIBezierPath()
            cursor.move(to: CGPoint(x: x(point.latestElapsed), y: area.minY))
            cursor.addLine(to: CGPoint(x: x(point.latestElapsed), y: area.maxY))
            UIColor.label.withAlphaComponent(0.5).setStroke(); cursor.lineWidth = 1; cursor.stroke()
            let detail = point.minimumVoltage == nil
                ? String(format: "第 %.0f 秒 · 抽样 %.2f V", point.elapsed, point.voltage)
                : String(format: "%.0f–%.0f 秒 · 最低 %.2f V · 最高 %.2f V\n最新 %.2f V", point.elapsed,
                    point.latestElapsed, point.lowerVoltage, point.upperVoltage, point.voltage)
            (detail as NSString).draw(in: CGRect(x: 4, y: bounds.height - 66, width: bounds.width - 8, height: 42), withAttributes: attributes)
        } else {
            ("轻点或左右滑动查看区间电压" as NSString).draw(at: CGPoint(x: 4, y: bounds.height - 58), withAttributes: attributes)
        }
        func elapsedLabel(_ seconds: Double) -> NSString {
            String(format: "%02d:%02d", Int(seconds) / 60, Int(seconds) % 60) as NSString
        }
        let start = elapsedLabel(first.elapsed), end = elapsedLabel(last.latestElapsed)
        start.draw(at: CGPoint(x: area.minX, y: area.maxY + 5), withAttributes: attributes)
        end.draw(at: CGPoint(x: max(area.minX, area.maxX - end.size(withAttributes: attributes).width), y: area.maxY + 5), withAttributes: attributes)
        let note = hasExtrema ? "蓝线：区间最新电压 · 竖条：最低至最高" : "旧记录仅保存抽样，无法补回瞬时压降"
        (note as NSString).draw(in: CGRect(x: 4, y: bounds.height - 22, width: bounds.width - 8, height: 20), withAttributes: attributes)
    }
}
