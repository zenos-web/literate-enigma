import UIKit
import CoreGraphics

/// Owns read-only battery telemetry and settings independently of CarPlay connection configuration.
/// CoreBluetooth callbacks and all UI work stay on the main queue.
final class ANTBMSController: NSObject {
    var onImage: ((CGImage?, ANTBMSCardConfiguration) -> Void)?
    var onLog: ((String) -> Void)?
    var aspectRatio: CGFloat = 848 / 480 { didSet { if aspectRatio != oldValue { refreshBMS() } } }
    private var receiving = false
    var recordingVehicleName: String = CWL("电池记录")
    var recordingVehicleID: UUID?
    private let bmsRecordStore = BMSRideRecordStore()
    private let bmsSessionStatus = StatusLabel()
    private let bmsTrend = BMSVoltageTrendView()
    private var bmsSession = ANTBMSSessionStatistics()
    private var bmsSessionStartedAt: Date?
    private var bmsSessionVehicle = ""
    private var bmsSessionVehicleID: UUID?
    private var bmsSessionDevice: UUID?
    private var bmsSessionDeviceName: String?
    private var bmsRecordFilter = BMSRecordFilter()
    private weak var liveBMSRecordSummary: StatusLabel?
    private weak var liveBMSRecordTrend: BMSVoltageTrendView?
    private var liveBMSRecordID: UUID?
    private var bmsSessionMinimumUptime = 0.0
    private var bmsSessionRecordID = UUID()
    private var lastBMSSaveUptime = 0.0
    private weak var rootPage: SettingsPageController?
    private var bmsSessionFamily: BMSFamily?
    private var bmsStructureKey = ""
    private let bmsClient = ANTBMSClient()
    private let bmsOverlay = BMSOverlayPresenter()
    private let bmsEnabledSwitch = UISwitch()
    private let bmsPosition = ChoiceMenu(items: ANTBMSCardConfiguration.Position.allCases.map(\.title))
    private let bmsCardSize = ChoiceMenu(items: ANTBMSCardConfiguration.Size.allCases.map(\.title))
    private let bmsCardBackground = ChoiceMenu(items: ANTBMSCardConfiguration.Background.allCases.map(\.title))
    private var bmsCardConfiguration = ANTBMSCardConfiguration()
    private var bmsFieldSwitches: [ANTBMSCardConfiguration.Field: UISwitch] = [:]
    private let bmsCardPreview = BMSCardPreviewView()
    private let bmsCardPreviewStatus = StatusLabel()
    private let bmsStatus = StatusLabel()
    private let bmsDetails = StatusLabel()
    private let bmsLiveSummary = BMSLiveSummaryView()
    private var bmsDeviceList: [UUID] = []

    override init() {
        super.init()
        configureBMS()
    }

    /// Called for all receiver modes, including sending local CarPlay to an iPad.
    func setReceiving(_ active: Bool) {
        receiving = active
        if active { beginBMSSessionIfNeeded() } else { finishBMSSession() }
    }

    func attach(to surface: UIView) {
        bmsOverlay.attach(to: surface)
        refreshBMS()
    }

    private func page(_ title: String, _ build: @escaping () -> [SettingsSection]) -> SettingsPageController {
        SettingsPageController(title: title, build: build)
    }
    private func reloadVisibleSettings() {
        (rootPage?.navigationController?.topViewController as? SettingsPageController)?.reload()
    }
    private func alert(_ title: String, _ message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "好", style: .default))
        let presenter: UIViewController? = rootPage?.navigationController ?? rootPage
        presenter?.present(alert, animated: true)
    }

    private func configureBMS() {
        bmsEnabledSwitch.isOn = UserDefaults.standard.bool(forKey: "antBMSEnabled")
        bmsEnabledSwitch.addTarget(self, action: #selector(bmsSettingsChanged), for: .valueChanged)
        bmsPosition.addTarget(self, action: #selector(bmsCardAppearanceChanged), for: .valueChanged)
        bmsCardBackground.addTarget(self, action: #selector(bmsCardAppearanceChanged), for: .valueChanged)
        bmsCardConfiguration = ANTBMSCardConfiguration(
            savedFields: UserDefaults.standard.stringArray(forKey: "antBMSCardFields"),
            sizeRawValue: UserDefaults.standard.object(forKey: "antBMSCardSize") as? Int,
            positionRawValue: UserDefaults.standard.object(forKey: "antBMSPosition") as? Int,
            backgroundRawValue: UserDefaults.standard.object(forKey: "antBMSCardBackground") as? Int)
        bmsCardSize.selectedSegmentIndex = bmsCardConfiguration.size.rawValue
        bmsPosition.selectedSegmentIndex = bmsCardConfiguration.position.rawValue
        bmsCardBackground.selectedSegmentIndex = bmsCardConfiguration.background.rawValue
        bmsCardSize.addTarget(self, action: #selector(bmsCardSizeChanged), for: .valueChanged)
        for field in ANTBMSCardConfiguration.Field.allCases {
            let control = UISwitch()
            control.isOn = bmsCardConfiguration.fields.contains(field)
            control.addAction(UIAction { [weak self, weak control] _ in
                guard let self, let control else { return }
                guard self.bmsCardConfiguration.set(field, visible: control.isOn) else {
                    control.setOn(true, animated: true)
                    self.alert("至少显示一项", "如需隐藏整张卡片，请关闭「读取并显示 BMS」。")
                    return
                }
                self.saveBMSCardConfiguration()
            }, for: .valueChanged)
            bmsFieldSwitches[field] = control
        }
        bmsDetails.numberOfLines = 0
        bmsDetails.font = .monospacedDigitSystemFont(ofSize: 14, weight: .regular)
        bmsOverlay.onImage = { [weak self] image, configuration in
            self?.onImage?(image, configuration)
        }
        bmsClient.onLog = { [weak self] message in self?.onLog?("BMS：" + message) }
        bmsClient.onChange = { [weak self] in self?.refreshBMS() }
        if bmsEnabledSwitch.isOn { bmsClient.start() }
        refreshBMS()
    }

    @objc private func bmsSettingsChanged() {
        UserDefaults.standard.set(bmsEnabledSwitch.isOn, forKey: "antBMSEnabled")
        if bmsEnabledSwitch.isOn {
            bmsClient.start()
            if receiving { beginBMSSessionIfNeeded() }
        } else { finishBMSSession(); bmsClient.stop() }
        refreshBMS()
        reloadVisibleSettings()
    }

    @objc private func bmsCardSizeChanged() {
        bmsCardConfiguration.size = ANTBMSCardConfiguration.Size(rawValue: bmsCardSize.selectedSegmentIndex) ?? .medium
        saveBMSCardConfiguration()
    }

    @objc private func bmsCardAppearanceChanged() {
        bmsCardConfiguration.position = ANTBMSCardConfiguration.Position(rawValue: bmsPosition.selectedSegmentIndex) ?? .topRight
        bmsCardConfiguration.background = ANTBMSCardConfiguration.Background(rawValue: bmsCardBackground.selectedSegmentIndex) ?? .standard
        saveBMSCardConfiguration()
    }

    private func saveBMSCardConfiguration() {
        UserDefaults.standard.set(bmsCardConfiguration.fields.map(\.rawValue), forKey: "antBMSCardFields")
        UserDefaults.standard.set(bmsCardConfiguration.size.rawValue, forKey: "antBMSCardSize")
        UserDefaults.standard.set(bmsCardConfiguration.position.rawValue, forKey: "antBMSPosition")
        UserDefaults.standard.set(bmsCardConfiguration.background.rawValue, forKey: "antBMSCardBackground")
        refreshBMS()
        reloadVisibleSettings()
    }

    private func applyBMSCardPreset(_ fields: [ANTBMSCardConfiguration.Field]) {
        bmsCardConfiguration = ANTBMSCardConfiguration(savedFields: fields.map(\.rawValue),
            sizeRawValue: bmsCardConfiguration.size.rawValue,
            positionRawValue: bmsCardConfiguration.position.rawValue,
            backgroundRawValue: bmsCardConfiguration.background.rawValue)
        for (field, control) in bmsFieldSwitches { control.isOn = bmsCardConfiguration.fields.contains(field) }
        saveBMSCardConfiguration()
    }

    private func refreshBMS() {
        let reading = bmsClient.freshReading
        if bmsSessionStartedAt != nil, bmsSessionDevice != bmsClient.selectedID || bmsSessionFamily != bmsClient.selectedFamily || bmsClient.isConfirmingSelection {
            finishBMSSession()
            if receiving, bmsEnabledSwitch.isOn { beginBMSSessionIfNeeded() }
        }
        if bmsSessionStartedAt != nil { bmsSession.advanceRecording(to: ProcessInfo.processInfo.systemUptime) }
        if bmsSessionStartedAt != nil, !bmsClient.isConfirmingSelection, let sample = bmsClient.sample, sample.uptime >= bmsSessionMinimumUptime,
           bmsSession.append(sample, now: ProcessInfo.processInfo.systemUptime) {
            bmsTrend.points = bmsSession.points
            if sample.uptime - lastBMSSaveUptime >= 15 {
                checkpointBMSSession(completed: false)
                lastBMSSaveUptime = sample.uptime
                reloadVisibleSettings()
            }
        }
        bmsSessionStatus.text = bmsStatisticsText(bmsSession)
        refreshLiveBMSRecord()
        bmsStatus.text = bmsEnabledSwitch.isOn ? bmsClient.status : "BMS 显示已关闭"
        bmsLiveSummary.update(reading)
        if let reading {
            let card = ANTBMSCardConfiguration.Field.allCases.map { $0.title + " " + $0.text(reading) }.joined(separator: " · ")
            let temperature = reading.maximumTemperature.map { String(format: "%.0f°C", $0) } ?? "--"
            let mos = reading.mosTemperature.map { String(format: "%.0f°C", $0) } ?? "--"
            let capacity = reading.available.contains("capacity") ? String(format: "%.2f Ah", reading.capacityAh) : "--"
            let remaining = reading.available.contains("remaining") ? String(format: "%.2f Ah", reading.remainingAh) : "--"
            let states = [0: "无状态", 1: "静止", 2: "充电", 3: "待机", 4: "放电", 5: "异常"]
            let state = reading.available.contains("state") ? states[reading.stateCode] ?? "未知" : CWL("未提供")
            let protection = reading.available.contains("protection") ? String(format: "0x%llX", reading.protectionBits) : CWL("未提供")
            let warnings = reading.available.contains("warnings") ? String(format: "0x%llX", reading.alarmBits) : CWL("未提供")
            let cells = reading.cells.isEmpty ? CWL("未提供逐串数据") : "电芯槽位 \(reading.cells.count) 串"
            let extra = reading.extraDetails.sorted { $0.key < $1.key }.map { $0.key + "：" + $0.value }.joined(separator: "\n")
            bmsDetails.text = card + "\n剩余 " + remaining + " / 容量 " + capacity +
                "\n最高温度 " + temperature + " · MOS " + mos + "\n" + cells +
                "\n状态：" + state + "\n保护位：" + protection + " · 告警位：" + warnings +
                (extra.isEmpty ? "" : "\n" + extra)
        } else {
            bmsDetails.text = "电量 -- · 电压 -- · 电流 -- · 功率 --\n等待所选板型的有效实时数据。"
        }
        bmsOverlay.update(enabled: bmsEnabledSwitch.isOn, reading: reading, status: bmsClient.status,
                          configuration: bmsCardConfiguration)
        bmsCardPreview.update(reading: reading, configuration: bmsCardConfiguration,
                             aspectRatio: aspectRatio, family: bmsClient.selectedFamily)
        bmsCardPreviewStatus.text = reading == nil ? "示例数据 · 当前没有实时读数" : "实时数据 · " + bmsClient.selectedFamily.title
        let ids = bmsClient.devices.map(\.id)
        let key = "\(bmsClient.selectedID?.uuidString ?? "")|\(bmsClient.selectedFamily.rawValue)|\(bmsClient.isConfirmingSelection)|\(reading != nil)|\(bmsClient.isScanning)"
        if ids != bmsDeviceList || key != bmsStructureKey {
            bmsStructureKey = key
            bmsDeviceList = ids
            reloadVisibleSettings()
        }
    }
    func settingsPage() -> SettingsPageController {
        let root = page("电池与 BMS") { [unowned self] in
            [SettingsSection(CWL("电池与保护板"), [
                .control("读取并显示 BMS", self.bmsEnabledSwitch),
                .note(self.bmsStatus),
                .page("连接设备", icon: ("antenna.radiowaves.left.and.right", .systemBlue), detail: { [unowned self] in
                    self.bmsClient.selectedName
                }) { [unowned self] in self.bmsDevicesPage() }
            ]),
            SettingsSection("实时电池", footer: "只显示最近 5 秒内的有效数据，断开后自动清空旧值。", [.view(self.bmsLiveSummary)]),
            SettingsSection("显示与记录", [
                .page(CWL("板型与支持范围"), icon: ("cpu", .systemBlue), detail: { [unowned self] in
                    self.bmsClient.selectedFamily.title
                }) { [unowned self] in self.bmsFamilyPage() },
                .page("卡片显示", icon: ("rectangle.topthird.inset.filled", .systemBlue), detail: { [unowned self] in
                    "\(self.bmsCardConfiguration.fields.count) 项 · \(self.bmsCardConfiguration.size.title)号"
                }) { [unowned self] in self.bmsCardPage() },
                .page("本次统计与记录", icon: ("chart.xyaxis.line", .systemGreen)) { [unowned self] in self.bmsStatisticsPage() },
                .page("电池详情", icon: ("list.bullet.rectangle", .systemGray)) { [unowned self] in
                    self.page("电池详情") { [unowned self] in
                        [SettingsSection("实时参数", footer: "仅显示所选协议已返回的字段。蚂蚁、蓝宝和陆行保留原厂电流符号；其他适配器以放电为正。", [.note(self.bmsDetails)])]
                    }
                }
            ])]
        }
        root.onLeave = { [weak self, weak root] in
            guard let self, let root, root.navigationController?.presentingViewController == nil,
                  self.bmsClient.isConfirmingSelection else { return }
            self.bmsClient.cancelSelection()
            if self.receiving { self.beginBMSSessionIfNeeded() }
        }
        rootPage = root
        return root
    }

    private func bmsDevicesPage() -> SettingsPageController {
        page("BMS 连接设备") { [unowned self] in
            var sections = [SettingsSection("当前设备", [
                .info("已记住的设备", self.bmsClient.selectedName),
                .note(self.bmsStatus)
            ])]
            guard self.bmsEnabledSwitch.isOn else {
                sections.append(SettingsSection(footer: "开启读取后搜索并选择自己的保护板或电量计。", [
                    .action("开启读取并查找设备", icon: ("antenna.radiowaves.left.and.right", .systemBlue)) { [unowned self] in
                        self.bmsEnabledSwitch.setOn(true, animated: false)
                        self.bmsSettingsChanged()
                    }
                ]))
                return sections
            }
            if self.bmsClient.isConfirmingSelection {
                sections.append(SettingsSection([.page(CWL("继续核对并保存电池")) { [unowned self] in self.bmsSetupPage() }]))
            }
            sections.append(SettingsSection(footer: "选择后先核对板型与实时读数，确认后记住并自动重连。连接不上时，先断开其他 BMS App。", [
                .action("扫描附近 BMS", icon: ("antenna.radiowaves.left.and.right", .systemBlue)) { [unowned self] in self.bmsClient.scan() },
                .action("忘记当前 BMS", destructive: true) { [unowned self] in
                    self.bmsClient.forget()
                    self.reloadVisibleSettings()
                }
            ]))
            let devices = self.bmsClient.devices.map { device in
                var row = SettingsRow.action(device.name, detail: { "\(device.rssi) dBm" }) { [unowned self] in
                    self.chooseBMSFamily(for: device.id)
                }
                row.subtitle = { device.family?.title ?? CWL("通用蓝牙串口 · 请选择实际板型") }
                row.checked = { [weak self] in self?.bmsClient.savedID == device.id }
                return row
            }
            sections.append(SettingsSection("附近设备", footer: "名称和服务仅提供板型提示。通用 FFE0 不代表协议兼容，收到所选协议有效实时数据后才确认连接。",
                devices.isEmpty ? [.info("暂无设备", "点击上方扫描")] : devices))
            return sections
        }
    }

    private func bmsFamilyPage() -> SettingsPageController {
        page(CWL("板型与支持范围")) { [unowned self] in
            var sections = [SettingsSection("当前设备", footer: self.bmsClient.selectedFamily.supportDescription, [
                .info("设备", self.bmsClient.selectedName),
                .info(CWL("协议型号"), self.bmsClient.freshReading?.extraDetails["协议"] ?? self.bmsClient.selectedFamily.protocolDescription),
                .note(self.bmsStatus)
            ])]
            if self.bmsClient.selectedID != nil {
                if [.jbd, .lanbao].contains(self.bmsClient.selectedFamily) {
                    sections.append(SettingsSection(footer: "只使用你已有的模块密码或匹配码，保存在本机 Keychain，不进入日志或导出。", [
                        .action(CWL("设置模块登录信息"), icon: ("key", .systemBlue)) { [unowned self] in self.configureBMSAccess() }
                    ]))
                }
                let rows = BMSFamily.allCases.map { family -> SettingsRow in
                    var row = SettingsRow.action(family.title) { [unowned self] in
                        self.bmsClient.setFamily(family); self.reloadVisibleSettings()
                    }
                    row.checked = { [unowned self] in self.bmsClient.selectedFamily == family }
                    row.subtitle = { family.supportDescription }
                    return row
                }
                sections.append(SettingsSection(CWL("指定当前设备板型"), footer: "更改后按所选协议重新连接。各品牌仅接入实时读取，不提供改参数、校准或 MOS 开关。新增板型仍需真机核验。", rows))
            } else {
                sections.append(SettingsSection(CWL("支持范围"), BMSFamily.allCases.map {
                    .info($0.title, $0.supportDescription)
                }))
            }
            return sections
        }
    }

    private func chooseBMSFamily(for id: UUID) {
        let suggested = bmsClient.devices.first { $0.id == id }?.family
        let prompt = UIAlertController(title: CWL("确认保护板型号"), message: "名称和服务只能提供提示，请按实际保护板选择。连接后核对读数，再保存到此设备。", preferredStyle: .actionSheet)
        let families = BMSFamily.allCases.sorted { left, right in
            if left == right { return false }
            if left == suggested { return true }
            if right == suggested { return false }
            return BMSFamily.allCases.firstIndex(of: left)! < BMSFamily.allCases.firstIndex(of: right)!
        }
        for family in families {
            let title = family.title + (family == suggested ? "（设备提示）" : "")
            prompt.addAction(UIAlertAction(title: title, style: .default) { [weak self] _ in
                guard let self else { return }
                guard self.bmsClient.select(id, family: family, requiresConfirmation: true) else {
                    self.alert(CWL("设备列表已更新"), CWL("请重新扫描并选择设备。")); return
                }
                self.rootPage?.navigationController?.pushViewController(self.bmsSetupPage(), animated: true)
            })
        }
        prompt.addAction(UIAlertAction(title: "取消", style: .cancel))
        guard let rootPage else { return }
        let presenter: UIViewController = rootPage.navigationController ?? rootPage
        prompt.popoverPresentationController?.sourceView = presenter.view
        prompt.popoverPresentationController?.sourceRect = CGRect(x: presenter.view.bounds.midX, y: presenter.view.bounds.midY, width: 1, height: 1)
        presenter.present(prompt, animated: true)
    }

    private func configureBMSAccess() {
        let jbd = bmsClient.selectedFamily == .jbd
        let prompt = UIAlertController(title: jbd ? CWL("JBD 模块登录") : CWL("蓝宝匹配码"),
            message: jbd ? "先尝试普通读取；需登录时使用你已有的六位密码。真实 MAC 仅旧挑战模块需要，可留空。留空密码可清除本机凭据。" :
                "填写已有的六位数字或十二位十六进制匹配码。留空使用协议默认匹配码；不会修改电量计。", preferredStyle: .alert)
        prompt.addTextField { $0.placeholder = jbd ? CWL("已有的六位密码") : CWL("已有匹配码"); $0.isSecureTextEntry = true; $0.autocapitalizationType = .none }
        if jbd { prompt.addTextField { $0.placeholder = CWL("真实 MAC（可留空）"); $0.autocapitalizationType = .allCharacters } }
        prompt.addAction(UIAlertAction(title: "取消", style: .cancel))
        prompt.addAction(UIAlertAction(title: CWL("保存并重连"), style: .default) { [weak self, weak prompt] _ in
            do {
                try self?.bmsClient.saveAccess(password: prompt?.textFields?.first?.text ?? "", mac: jbd ? prompt?.textFields?.last?.text ?? "" : "")
                self?.reloadVisibleSettings()
            } catch { self?.alert("未保存", error.localizedDescription) }
        })
        guard let rootPage else { return }
        (rootPage.navigationController ?? rootPage).present(prompt, animated: true)
    }

    private func bmsSetupPage() -> SettingsPageController {
        let controller = page(CWL("核对并保存电池")) { [unowned self] in
            var rows: [SettingsRow] = [.note(self.bmsStatus), .view(self.bmsLiveSummary),
                .page(CWL("调整板型")) { [unowned self] in self.bmsFamilyPage() }]
            if [.jbd, .lanbao].contains(self.bmsClient.selectedFamily) {
                rows.append(.action(CWL("模块登录信息"), icon: ("key", .systemBlue)) { [unowned self] in self.configureBMSAccess() })
            }
            if self.bmsClient.freshReading != nil {
                rows.append(.action(CWL("读数正确，保存此设备"), icon: ("checkmark.circle", .systemGreen)) { [unowned self] in
                    guard self.bmsClient.confirmSelection() else { return }
                    if self.receiving { self.beginBMSSessionIfNeeded() }
                    self.rootPage?.navigationController?.popViewController(animated: true)
                })
            }
            rows.append(.action(CWL("取消添加"), destructive: true) { [unowned self] in
                self.bmsClient.cancelSelection()
                if self.receiving { self.beginBMSSessionIfNeeded() }
                self.rootPage?.navigationController?.popViewController(animated: true)
            })
            return [SettingsSection(CWL("核对首批实时读数"), footer: "确认总压、电量等与实际电池一致。只有收到有效实时数据才能保存；核对中的数据不写入记录。", rows)]
        }
        controller.onLeave = { [weak self, weak controller] in
            guard let self, let controller, self.bmsClient.isConfirmingSelection else { return }
            let navigation = self.rootPage?.navigationController
            let inStack = navigation?.viewControllers.contains { $0 === controller } ?? false
            if !inStack || navigation?.presentingViewController == nil {
                self.bmsClient.cancelSelection()
                if self.receiving { self.beginBMSSessionIfNeeded() }
            }
        }
        return controller
    }

    private func bmsCardPage() -> SettingsPageController {
        bmsCardPreview.update(reading: bmsClient.freshReading, configuration: bmsCardConfiguration,
                             aspectRatio: aspectRatio, family: bmsClient.selectedFamily)
        return page("BMS 卡片显示") { [unowned self] in
            var sections = [SettingsSection("布局", footer: "修改后立即同步到手机、九号 4.3/5/7 寸和极核 5/6.2 寸投屏，并自动保存。卡片最多两行；减少显示项可留出更多地图空间。", [
                .control("字号", self.bmsCardSize),
                .control("显示位置", self.bmsPosition),
                .control("背景", self.bmsCardBackground),
                .page("字段顺序", icon: ("arrow.up.arrow.down", .systemBlue)) { [unowned self] in
                    BMSCardOrderViewController(fields: self.bmsCardConfiguration.fields) { [weak self] field, destination in
                        guard let self else { return }
                        self.bmsCardConfiguration.move(field, to: destination)
                        self.saveBMSCardConfiguration()
                    }
                }
            ])]
            sections.append(SettingsSection("布局预览", footer: "背景为布局示意，比例随所选仪表变化。没有实时读数时使用示例数据，示例不会写入电池记录或投屏画面。", [
                .note(self.bmsCardPreviewStatus), .view(self.bmsCardPreview)
            ]))
            sections.append(SettingsSection("快捷布局", [
                .action("精简：电量、总压、压差", icon: ("minus.circle", .systemBlue)) { [unowned self] in
                    self.applyBMSCardPreset(ANTBMSCardConfiguration.compactFields)
                },
                .action("常用：显示全部六项", icon: ("square.grid.2x2", .systemBlue)) { [unowned self] in
                    self.applyBMSCardPreset(ANTBMSCardConfiguration.Field.allCases)
                }
            ]))
            let fields = ANTBMSCardConfiguration.Field.allCases.compactMap { field -> SettingsRow? in
                guard let control = self.bmsFieldSwitches[field] else { return nil }
                return .control(field.title, control)
            }
            sections.append(SettingsSection("显示内容", footer: "至少保留一项。单体压差以 mV 显示；未知读数显示 --，BMS 告警会保留提示。", fields))
            return sections
        }
    }

    private func reportPreviewPage(title: String, name: String, format: String = "JSON",
                                   footer: String = "以下为本次导出的完整内容。", data: () throws -> Data) -> SettingsPageController {
        do {
            let snapshot = try data()
            let text = UITextView(); text.isEditable = false; text.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            text.text = String(data: snapshot, encoding: .utf8)
            text.heightAnchor.constraint(equalToConstant: 360).isActive = true
            return page(title) { [weak self] in
                [SettingsSection(footer: footer, [.view(text)]), SettingsSection([
                    .action(CWL("复制内容"), icon: ("doc.on.doc", .systemBlue)) { UIPasteboard.general.string = text.text },
                    .action("分享 \(format) 文件", icon: ("square.and.arrow.up", .systemBlue)) {
                        self?.shareReport(snapshot, name: name)
                    }
                ])]
            }
        } catch {
            return page(title) { [SettingsSection([.info(CWL("报告生成失败"), error.localizedDescription)])] }
        }
    }

    private func shareReport(_ data: Data, name: String) {
        do {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CarWithinReports", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appendingPathComponent(name)
            try data.write(to: file, options: .atomic)
            let sheet = UIActivityViewController(activityItems: [file], applicationActivities: nil)
            guard let rootPage else { return }
            let presenter: UIViewController = rootPage.navigationController ?? rootPage
            sheet.popoverPresentationController?.sourceView = presenter.view
            sheet.popoverPresentationController?.sourceRect = CGRect(x: presenter.view.bounds.midX, y: presenter.view.bounds.midY, width: 1, height: 1)
            presenter.present(sheet, animated: true)
        } catch { alert(CWL("无法导出"), error.localizedDescription) }
    }

    private func beginBMSSessionIfNeeded() {
        guard bmsEnabledSwitch.isOn, !bmsClient.isConfirmingSelection, bmsSessionStartedAt == nil else { return }
        bmsSession = ANTBMSSessionStatistics(); bmsTrend.points = []
        bmsSessionMinimumUptime = ProcessInfo.processInfo.systemUptime
        bmsSession.startRecording(at: bmsSessionMinimumUptime)
        bmsSessionFamily = bmsClient.selectedFamily
        lastBMSSaveUptime = bmsSessionMinimumUptime
        bmsSessionRecordID = UUID()
        bmsSessionStartedAt = Date(); bmsSessionVehicle = recordingVehicleName
        bmsSessionVehicleID = recordingVehicleID; bmsSessionDevice = bmsClient.selectedID
        bmsSessionDeviceName = bmsSessionDevice == nil ? nil : bmsClient.selectedName
        bmsSessionStatus.text = CWL("等待新的 BMS 实时数据")
    }

    private func finishBMSSession() {
        guard bmsSessionStartedAt != nil else { return }
        bmsSession.finishRecording(at: ProcessInfo.processInfo.systemUptime)
        checkpointBMSSession(completed: true)
        bmsSessionStartedAt = nil
        reloadVisibleSettings()
    }

    private func checkpointBMSSession(completed: Bool) {
        guard var record = currentBMSRecord else { return }
        record = BMSRideRecord(id: record.id, startedAt: record.startedAt, endedAt: record.endedAt,
            vehicleName: record.vehicleName, statistics: record.statistics, completed: completed,
            vehicleID: record.vehicleID, bmsID: record.bmsID, bmsName: record.bmsName)
        do { try bmsRecordStore.save(record) }
        catch { onLog?("BMS 记录保存失败，本次统计仍可导出：\(error.localizedDescription)") }
    }

    private var currentBMSRecord: BMSRideRecord? {
        guard let startedAt = bmsSessionStartedAt, bmsSession.sampleCount > 0 else { return nil }
        return BMSRideRecord(id: bmsSessionRecordID, startedAt: startedAt, endedAt: Date(),
            vehicleName: bmsSessionVehicle, statistics: bmsSession, completed: false,
            vehicleID: bmsSessionVehicleID, bmsID: bmsSessionDevice, bmsName: bmsSessionDeviceName)
    }

    private func bmsHistoryRecords() -> [BMSRideRecord] {
        var records = bmsRecordStore.records()
        if let current = currentBMSRecord {
            records.removeAll { $0.id == current.id }; records.insert(current, at: 0)
        }
        return records
    }

    private func resolvedBMSRecord(_ fallback: BMSRideRecord) -> BMSRideRecord {
        bmsHistoryRecords().first { $0.id == fallback.id } ?? fallback
    }

    private func refreshLiveBMSRecord() {
        guard liveBMSRecordID == bmsSessionRecordID else { return }
        liveBMSRecordSummary?.text = bmsStatisticsText(bmsSession)
        liveBMSRecordTrend?.points = bmsSession.points
    }

    private func bmsRecordSubtitle(_ record: BMSRideRecord, active: Bool) -> String {
        let state = active ? CWL("记录中") : record.completed ? CWL("已结束") : CWL("已保存片段")
        let statistics = record.statistics
        let charge = statistics.firstCharge.flatMap { first in statistics.lastCharge.map { " · \(first)% → \($0)%" } } ?? ""
        let voltage = statistics.minimumVoltage.flatMap { low in statistics.maximumVoltage.map {
            String(format: "\n全程 %.2f–%.2f V", low, $0)
        } } ?? ""
        let seconds = Int(statistics.sampledSeconds)
        let device = record.bmsName.map { " · " + $0 } ?? ""
        return "\(state) · 有效 \(seconds / 60) 分 \(seconds % 60) 秒\(charge)\(device)\(voltage)"
    }

    private func bmsCoverageText(_ statistics: ANTBMSSessionStatistics) -> String {
        guard let coverage = statistics.coverage else { return "旧记录未保存数据完整度" }
        let duration = max(0, Int(coverage.recordingSeconds))
        let ratio = statistics.coverageRatio.map { String(format: "%.0f%%", $0 * 100) } ?? "--"
        let longest = coverage.longestInterruption > 0 ? Int(ceil(coverage.longestInterruption)) : 0
        return "记录时长 \(duration / 60) 分 \(duration % 60) 秒 · 有效覆盖 \(ratio)" +
            "\n数据中断 \(coverage.interruptionCount) 次 · 最长 \(longest) 秒"
    }

    private func bmsStatisticsText(_ statistics: ANTBMSSessionStatistics) -> String {
        guard statistics.sampleCount > 0 else {
            return (statistics.coverage == nil ? "" : bmsCoverageText(statistics) + "\n") + "暂无有效样本。开启 BMS 并连接电池后等待数据，也可手动开始记录。"
        }
        let charge = statistics.firstCharge.flatMap { first in statistics.lastCharge.map { "\(first)% → \($0)%" } } ?? "--"
        let voltage = statistics.minimumVoltage.flatMap { low in statistics.maximumVoltage.map {
            String(format: "%.2f–%.2f V", low, $0)
        } } ?? CWL("未提供")
        let current = statistics.peakAbsoluteCurrent.map { String(format: "%.1f A", $0) } ?? CWL("未提供")
        let power = statistics.peakAbsolutePower.map { "\($0) W" } ?? CWL("未提供")
        let temperature = statistics.maximumTemperature.map { String(format: "%.0f°C", $0) } ?? "--"
        let delta = statistics.maximumCellDelta.map { String(format: "%.0f mV", $0 * 1000) } ?? "--"
        return bmsCoverageText(statistics) + "\n" + String(format: "有效采样 %.0f 秒 · %d 帧", statistics.sampledSeconds, statistics.sampleCount) +
            "\n电量 " + charge + "\n全程电压 " + voltage + "\n峰值电流 |I| " + current +
            " · 峰值功率 |P| " + power + "\n最高温度 " + temperature + " · 最大压差 " + delta
    }

    private func bmsStatisticsPage() -> SettingsPageController {
        let period = ChoiceMenu(items: BMSRecordFilter.Period.allCases.map(\.title))
        period.selectedSegmentIndex = bmsRecordFilter.period.rawValue
        period.addAction(UIAction { [weak self, weak period] _ in
            guard let self, let period else { return }
            self.bmsRecordFilter.period = BMSRecordFilter.Period(rawValue: period.selectedSegmentIndex) ?? .all
            self.reloadVisibleSettings()
        }, for: .valueChanged)
        let completion = ChoiceMenu(items: BMSRecordFilter.Completion.allCases.map(\.title))
        completion.selectedSegmentIndex = bmsRecordFilter.completion.rawValue
        completion.addAction(UIAction { [weak self, weak completion] _ in
            guard let self, let completion else { return }
            self.bmsRecordFilter.completion = BMSRecordFilter.Completion(rawValue: completion.selectedSegmentIndex) ?? .all
            self.reloadVisibleSettings()
        }, for: .valueChanged)
        return page(CWL("BMS 统计与记录")) { [unowned self] in
            var sections = [SettingsSection(self.bmsSessionStartedAt == nil ? CWL("本次统计") : CWL("正在记录"), footer:
                "有效采样时长不计入断线间隔；峰值取绝对值。记录电池读数，不计算里程或预计续航。", [.note(self.bmsSessionStatus), .view(self.bmsTrend)])]
            var controls: [SettingsRow] = []
            if self.bmsSessionStartedAt != nil {
                controls.append(.action(CWL("结束并保存本次记录"), icon: ("stop.circle", .systemBlue)) { [unowned self] in
                    self.finishBMSSession(); self.reloadVisibleSettings()
                })
            } else {
                controls.append(.action(CWL("开始新记录"), icon: ("record.circle", .systemBlue)) { [unowned self] in
                    guard self.bmsEnabledSwitch.isOn else { self.alert(CWL("先开启 BMS"), "在电池与 BMS 页面开启读取并连接自己的设备。"); return }
                    self.beginBMSSessionIfNeeded(); self.reloadVisibleSettings()
                })
            }
            controls.append(.page(CWL("预览并导出本次统计"), icon: ("square.and.arrow.up", .systemBlue)) { [unowned self] in
                self.reportPreviewPage(title: CWL("BMS 统计预览"), name: "CarWithin-bms-statistics.json", data: {
                    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                    return try encoder.encode(self.bmsSession)
                })
            })
            if !self.bmsSession.points.isEmpty { controls.append(self.bmsCSVRow { [unowned self] in self.bmsSession }) }
            sections.append(SettingsSection(controls))
            sections.append(SettingsSection(CWL("筛选历史"), [
                .page("车辆", detail: { [unowned self] in self.bmsRecordFilter.vehicleName ?? CWL("全部车辆") }) { [unowned self] in self.bmsRecordVehiclePage() },
                .page(CWL("电池设备"), detail: { [unowned self] in
                    guard let id = self.bmsRecordFilter.bmsID else { return CWL("全部设备") }
                    return self.bmsHistoryRecords().first { $0.bmsID == id }?.bmsName ?? CWL("已保存设备")
                }) { [unowned self] in self.bmsRecordDevicePage() },
                .control(CWL("时间"), period), .control(CWL("状态"), completion)
            ]))
            let all = self.bmsHistoryRecords()
            let activeID = self.bmsSessionStartedAt == nil ? nil : self.bmsSessionRecordID
            let now = Date()
            let records = all.filter { self.bmsRecordFilter.matches($0, now: now, activeRecordID: activeID) }
            var history = records.map { record -> SettingsRow in
                let date = DateFormatter.localizedString(from: record.startedAt, dateStyle: .short, timeStyle: .short)
                let active = record.id == activeID
                var row = SettingsRow.page("\(record.vehicleName) · \(date)") { [unowned self] in self.bmsRecordPage(record) }
                row.subtitle = { [unowned self] in self.bmsRecordSubtitle(record, active: active) }
                if !active {
                    row.onDelete = { [unowned self] in
                        do { try bmsRecordStore.remove(record.id) } catch { self.alert(CWL("删除失败"), error.localizedDescription) }
                    }
                }
                return row
            }
            if history.isEmpty {
                history.append(.info(all.isEmpty ? "还没有电池记录" : "没有符合条件的记录",
                    all.isEmpty ? "连接 BMS 后开始记录" : "可调整上方筛选条件"))
            }
            sections.append(SettingsSection("最近记录 · \(records.count)/\(all.count)", footer:
                "本机最多保存 20 次，每 15 秒保存片段。趋势保留最近 120 个五秒区间，全程范围包含全部有效帧。停止 CarPlay 或关闭 BMS 时完成记录。", history))
            return sections
        }
    }

    private func bmsRecordVehiclePage() -> SettingsPageController {
        page("按车辆筛选") { [unowned self] in
            var choices: [(id: UUID?, name: String)] = []
            choices.append(contentsOf: self.bmsHistoryRecords().map { ($0.vehicleID, $0.vehicleName) })
            var unique: [(id: UUID?, name: String)] = []
            for choice in choices where !unique.contains(where: { $0.id != nil ? $0.id == choice.id : $0.id == choice.id && $0.name == choice.name }) {
                unique.append(choice)
            }
            var all = SettingsRow.action(CWL("全部车辆")) { [unowned self] in
                self.bmsRecordFilter.vehicleID = nil; self.bmsRecordFilter.vehicleName = nil
                self.rootPage?.navigationController?.popViewController(animated: true)
            }
            all.checked = { [unowned self] in self.bmsRecordFilter.vehicleName == nil }
            let rows = unique.map { choice -> SettingsRow in
                var row = SettingsRow.action(choice.name) { [unowned self] in
                    self.bmsRecordFilter.vehicleID = choice.id; self.bmsRecordFilter.vehicleName = choice.name
                    self.rootPage?.navigationController?.popViewController(animated: true)
                }
                row.checked = { [unowned self] in
                    self.bmsRecordFilter.vehicleID == choice.id && self.bmsRecordFilter.vehicleName == choice.name
                }
                if choice.id == nil { row.subtitle = { "旧记录按保存时的车辆名称匹配" } }
                return row
            }
            return [SettingsSection(footer: "记录按启动时的仪表名称归类；有车辆标识时优先按标识匹配。BMS 设备筛选可进一步区分同名车辆，旧记录仍按保存时的名称匹配。", [all] + rows)]
        }
    }

    private func bmsRecordDevicePage() -> SettingsPageController {
        page("按电池设备筛选") { [unowned self] in
            var seen = Set<UUID>()
            var all = SettingsRow.action(CWL("全部设备")) { [unowned self] in
                self.bmsRecordFilter.bmsID = nil
                self.rootPage?.navigationController?.popViewController(animated: true)
            }
            all.checked = { [unowned self] in self.bmsRecordFilter.bmsID == nil }
            let rows = self.bmsHistoryRecords().compactMap { record -> SettingsRow? in
                guard let id = record.bmsID, seen.insert(id).inserted else { return nil }
                var row = SettingsRow.action(record.bmsName ?? "已保存设备 · \(id.uuidString.prefix(8))") { [unowned self] in
                    self.bmsRecordFilter.bmsID = id
                    self.rootPage?.navigationController?.popViewController(animated: true)
                }
                row.checked = { [unowned self] in self.bmsRecordFilter.bmsID == id }
                return row
            }
            return [SettingsSection(footer: "按已记录的 BMS 设备区分同名车辆。没有设备标识的旧记录仅在全部设备中显示。", [all] + rows)]
        }
    }

    private func bmsCSVRow(_ statistics: @escaping () -> ANTBMSSessionStatistics) -> SettingsRow {
        .page(CWL("预览并导出电压 CSV"), icon: ("tablecells", .systemGreen)) { [unowned self] in
            self.reportPreviewPage(title: CWL("电压 CSV 预览"), name: "CarWithin-bms-voltage-\(UUID().uuidString).csv",
                format: "CSV", footer: "仅导出曲线保留的最近 120 个区间，含最低、最高与最新电压，并非全程逐帧数据。旧版缺少的极值留空；时间单位为秒，电压单位为伏。") {
                    Data(statistics().voltageCSV.utf8)
                }
        }
    }

    private func bmsRecordPage(_ record: BMSRideRecord) -> SettingsPageController {
        let summary = StatusLabel(), trend = BMSVoltageTrendView()
        if record.id == bmsSessionRecordID {
            liveBMSRecordID = record.id; liveBMSRecordSummary = summary; liveBMSRecordTrend = trend
        }
        return page(record.vehicleName) { [unowned self] in
            let current = self.resolvedBMSRecord(record)
            summary.text = self.bmsStatisticsText(current.statistics); trend.points = current.statistics.points
            let active = self.bmsSessionStartedAt != nil && record.id == self.bmsSessionRecordID
            let date = DateFormatter.localizedString(from: current.startedAt, dateStyle: .medium, timeStyle: .short)
            return [SettingsSection("电池记录 · \(date)", footer: active ? "正在记录，读数与曲线持续更新。" : current.completed ? "已结束并保存。" : "这是最近保存的片段，可能尚未正常结束。", [.note(summary), .view(trend)]),
             SettingsSection([
                .page(CWL("预览并导出完整统计 JSON"), icon: ("square.and.arrow.up", .systemBlue)) { [unowned self] in
                    self.reportPreviewPage(title: CWL("记录预览"), name: "CarWithin-bms-\(record.id.uuidString).json", data: {
                        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
                        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                        return try encoder.encode(self.resolvedBMSRecord(record))
                    })
                },
                self.bmsCSVRow { [unowned self] in self.resolvedBMSRecord(record).statistics }
             ])]
        }
    }


}
