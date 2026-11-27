import UIKit

/// A compact overview of fresh telemetry. Missing data never retains old values.
final class BMSLiveSummaryView: UIView {
    private var values: [ANTBMSCardConfiguration.Field: UILabel] = [:]
    private var tiles: [ANTBMSCardConfiguration.Field: UIView] = [:]
    private var rows: [UIStackView] = []

    init(fields: [ANTBMSCardConfiguration.Field] = [.charge, .voltage, .current, .power, .temperature, .cellDelta]) {
        super.init(frame: .zero)
        let grid = UIStackView(); grid.axis = .vertical; grid.spacing = 8
        grid.translatesAutoresizingMaskIntoConstraints = false
        addSubview(grid)
        NSLayoutConstraint.activate([grid.leadingAnchor.constraint(equalTo: leadingAnchor),
            grid.trailingAnchor.constraint(equalTo: trailingAnchor), grid.topAnchor.constraint(equalTo: topAnchor),
            grid.bottomAnchor.constraint(equalTo: bottomAnchor)])
        for offset in stride(from: 0, to: fields.count, by: 2) {
            let row = UIStackView(); row.spacing = 8; row.distribution = .fillEqually
            for field in fields[offset..<min(offset + 2, fields.count)] {
                let label = UILabel(); label.text = field.title
                label.font = .preferredFont(forTextStyle: .caption1); label.textColor = .secondaryLabel
                label.adjustsFontForContentSizeCategory = true; label.numberOfLines = 0
                let value = UILabel(); value.text = "--"; value.font = .preferredFont(forTextStyle: .title3)
                value.adjustsFontForContentSizeCategory = true; value.numberOfLines = 0
                value.adjustsFontSizeToFitWidth = true; value.minimumScaleFactor = 0.65
                let tile = UIStackView(arrangedSubviews: [label, value])
                tile.axis = .vertical; tile.spacing = 4
                tile.isLayoutMarginsRelativeArrangement = true
                tile.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12)
                tile.backgroundColor = .tertiarySystemFill; tile.layer.cornerRadius = 12
                tile.isAccessibilityElement = true; tile.accessibilityLabel = field.title
                values[field] = value; tiles[field] = tile; row.addArrangedSubview(tile)
            }
            grid.addArrangedSubview(row); rows.append(row)
        }
        updateLayoutForTextSize()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if previousTraitCollection?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory {
            updateLayoutForTextSize()
        }
    }
    private func updateLayoutForTextSize() {
        let accessible = traitCollection.preferredContentSizeCategory.isAccessibilityCategory
        for row in rows { row.axis = accessible ? .vertical : .horizontal }
        for value in values.values { value.adjustsFontSizeToFitWidth = !accessible }
        NotificationCenter.default.post(name: StatusLabel.didChange, object: self)
    }

    func update(_ reading: ANTBMSReading?, visibleFields: [ANTBMSCardConfiguration.Field]? = nil) {
        let fields = visibleFields.map { Set($0) }
        var changed = false
        for (field, tile) in tiles {
            let hidden = fields.map { !$0.contains(field) } ?? false
            if tile.isHidden != hidden { tile.isHidden = hidden; changed = true }
        }
        for row in rows { row.isHidden = row.arrangedSubviews.allSatisfy(\.isHidden) }
        isHidden = rows.allSatisfy(\.isHidden)
        if changed { NotificationCenter.default.post(name: StatusLabel.didChange, object: self) }
        for (field, label) in values {
            let text = reading.map { field.text($0).replacingOccurrences(of: "压差 ", with: "") } ?? "--"
            label.text = text
            label.textColor = reading == nil ? .secondaryLabel : .label
            tiles[field]?.accessibilityValue = reading == nil ? "没有实时数据" : text
        }
    }
}
