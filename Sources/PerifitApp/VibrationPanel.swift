import SwiftUI
import AppKit
import PerifitCore

struct VibrationPanel: View {
    @ObservedObject var model: SessionModel
    @ObservedObject var usb: ArduinoUSB
    @Binding var editingOrgasm: Bool
    init(model: SessionModel, usb: ArduinoUSB, editingOrgasm: Binding<Bool> = .constant(false)) {
        self.model = model; self.usb = usb; self._editingOrgasm = editingOrgasm
    }
    private func channel(_ index: Int) -> Binding<VibrationChannel> {
        Binding(get: { (editingOrgasm ? model.preferences.effectiveOrgasmVibration : model.preferences.effectiveVibration).channels[index] },
                set: { model.setVibrationChannel(index, value: $0, forOrgasm: editingOrgasm) })
    }
    var body: some View {
        Group {
            GroupBox(model.useUSB ? "Arduino Uno · L293D shield" : "Three-channel vibration preview") {
                VStack(alignment: .leading, spacing: 12) {
                    if model.useUSB {
                        HStack { Button("Refresh ports") { usb.refreshPorts() }; Button(model.usbReconnecting ? "Cancel reconnect" : "Disconnect") { model.disconnectUSB() } }
                            .disabled(model.configurationLocked && !model.usbReconnecting)
                        Picker("USB port", selection: Binding(get: { model.preferences.arduinoPort ?? "" }, set: { model.preferences.arduinoPort = $0 })) {
                            Text("Select…").tag("")
                            ForEach(usb.ports, id: \.self) { Text($0).tag($0) }
                            if let path = model.preferences.arduinoPort, !path.isEmpty, !usb.ports.contains(path) { Text(path).tag(path) }
                        }.disabled(model.configurationLocked || model.usbReconnecting)
                        Button("Connect PE1 firmware") { model.connectUSB() }.disabled(model.configurationLocked || model.usbReconnecting)
                        if model.usbReconnecting {
                            HStack { ProgressView().controlSize(.small); Text("Reconnecting · settings retained").font(.caption) }
                        }
                        Text(usb.status).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    Text("115200 baud · \(usb.limits.channelCount) channels · watchdog 1s").font(.caption).foregroundStyle(.secondary)
                    USBDebugControls(model: model, capture: usb.debugLog)
                    XToysControls(model: model, bridge: model.xtoys, third: model.xtoysM3)
                    ForEach(model.usbDebugContext.warnings, id: \.self) { warning in
                        Text(warning).font(.caption).foregroundStyle(.orange)
                    }
                        Button("Discover motor ranges… (optional)") { model.beginDiscovery() }
                            .disabled(model.configurationLocked || !usb.ready || !usb.supportsDiscovery)
                        if usb.ready && !usb.supportsDiscovery {
                            Text("Update Arduino firmware to support TEST250 discovery.").font(.caption).foregroundStyle(.orange)
                        }
                        if let setup = model.motorCalibration {
                        Text("Saved at \(setup.supplyVoltage, specifier: "%.1f") V · M1 \(setup.minimums.one)–\(setup.maximums.one) · M2 \(setup.minimums.two)–\(setup.maximums.two) · M3 \(setup.minimums.three)–\(model.vibrationLimits.three) PWM")
                            .font(.caption).monospacedDigit()
                        if setup.boardLimits.three == 0 && usb.limits.three > 0 {
                            Text("Saved discovery covers M1/M2 only. M3 uses the board range until you repeat discovery.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        } else if let saved = model.preferences.motorCalibration {
                            Text("Saved motor ranges: M1 \(saved.minimums.one)–\(saved.maximums.one) · M2 \(saved.minimums.two)–\(saved.maximums.two) PWM")
                                .font(.caption).monospacedDigit()
                            Text("Reconnect the saved Arduino port with matching firmware limits to restore these ranges.")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                        Text("Full board PWM range: M1 0–\(usb.limits.one), M2 0–\(usb.limits.two), M3 0–\(usb.limits.three). Discovery is optional.")
                            .font(.caption).monospacedDigit()
                    }
                    Toggle("Same motors, wiring and supply for this connection", isOn: $model.motorSetupConfirmed)
                        .font(.caption).disabled(model.configurationLocked || !usb.ready)
                }
            if model.timedEdging != nil && !model.finderEnabled {
                Picker("Vibration preset", selection: $editingOrgasm) {
                    Text("Edging").tag(false); Text("Orgasm mode").tag(true)
                }.pickerStyle(.segmented)
                Text(editingOrgasm ? "Editing the separate Orgasm mode preset. It starts when timed edging completes." : "Editing the edging preset. Orgasm mode has independent M1/M2 settings.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(0..<3, id: \.self) { index in
                        let value = channel(index)
                        let requested = model.vibrationRequested[index]
                        let applied = model.vibrationReported?[index]
                        let limit = model.vibrationLimits[index]
                        VStack(alignment: .leading, spacing: 8) {
                            HStack { Text("M\(index+1) · Vibrator \(index+1)").font(.headline); Spacer(); Text("\(value.wrappedValue.target, specifier: "%.0f")%").monospacedDigit() }
                            Slider(value: Binding(get: { value.wrappedValue.target },
                                                  set: { model.setVibrationTarget(channel: index, value: $0, forOrgasm: editingOrgasm) }), in: 0...100, step: 1)
                                .accessibilityLabel("Vibrator \(index+1) target percentage")
                                .disabled(!model.canEditVibration)
                            HStack {
                                Button("Zero active M\(index+1)") { model.setVibrationTarget(channel: index, value: 0) }
                                    .disabled(!model.canEditVibration)
                                Text("Request \(requested) · \(model.useUSB ? "board" : "simulated") \(applied.map(String.init) ?? "unknown") / \(limit)")
                                    .font(.caption).monospacedDigit()
                            }
                            if !model.useUSB || !model.xtoysEnabled {
                            VStack(alignment: .leading, spacing: 7) {
                                Picker("Mode", selection: value.mode) { ForEach(VibrationMode.allCases, id: \.self) { Text($0.title).tag($0) } }
                                if value.wrappedValue.mode == .ramp || value.wrappedValue.mode == .steps {
                                    field("Starting level (%)", value.start)
                                }
                                if value.wrappedValue.mode == .ramp { field("Ramp to target (s)", value.rampSeconds) }
                                if value.wrappedValue.mode == .steps {
                                    field("Step size (%)", value.stepPercent)
                                    field("Step interval (s)", value.stepSeconds)
                                }
                            }.disabled(!model.canEditVibration)
                            if value.wrappedValue.mode.isPattern {
                                VibrationPatternControls(channel: value)
                                    .disabled(!model.canEditVibration)
                            }
                            }
                        }.disabled(model.useUSB && usb.ready && index == 2 && usb.limits.three == 0)
                        if model.useUSB && index == 2 && usb.ready && usb.limits.three == 0 {
                            Text("Flash the M3 firmware to enable this motor. M1/M2 remain available.").font(.caption).foregroundStyle(.secondary)
                        }
                        if index < 2 { Divider() }
                    }
                    Text("Vibration settings apply live and save automatically. Threshold, count and timer locks do not lock these controls.").font(.caption).foregroundStyle(.secondary)
            Text("Targets change independently; risk cutoffs stop both. USB percentages use saved discovery limits when present, otherwise the full board range. Zero stays OFF. PWM is not measured voltage or strength.")
                        .font(.caption).foregroundStyle(.secondary)
                    if !model.useUSB { Text("Preview only. Select USB to connect the Uno after programming its PE1 firmware.").font(.caption).foregroundStyle(.secondary) }
                }.padding(5)
            }.onAppear { usb.refreshPorts(); editingOrgasm = model.usesOrgasmPreset }
                .onChange(of: model.usesOrgasmPreset) { _, value in editingOrgasm = value }
                .onChange(of: model.timedEdging == nil) { _, missing in if missing { editingOrgasm = false } }
                .sheet(isPresented: Binding(get: { model.isDiscovering }, set: { if !$0 && model.isDiscovering { model.stop() } })) {
                    MotorDiscoveryView(model: model, usb: usb)
                }
        }
    }
    private func field(_ title: String, _ value: Binding<Double>) -> some View {
        HStack { Text(title); Spacer(); TextField(title, value: value, format: .number).textFieldStyle(.roundedBorder).frame(width: 65) }.font(.caption)
    }
}

struct USBDebugControls: View {
    @ObservedObject var model: SessionModel
    @ObservedObject var capture: USBDebugLog
    var body: some View {
        DisclosureGroup("Arduino debug / firmware handoff") {
            VStack(alignment: .leading, spacing: 6) {
                Toggle("Record USB debug log (starts a new capture)", isOn: Binding(
                    get: { capture.enabled }, set: { model.setUSBDebugLogging($0) }))
                Text(capture.status).foregroundStyle(.secondary)
                Text("Includes serial traffic, motor settings and faults. No pressure readings or feedback marks. Up to 20,000 events / 8 MB; export before quitting.")
                    .foregroundStyle(.secondary)
                Button("Export firmware handoff…") { model.exportUSBDebugLog() }
                    .disabled(!capture.hasCapture || model.debugExportBusy)
                if !model.debugExportMessage.isEmpty { Text(model.debugExportMessage).textSelection(.enabled) }
            }.font(.caption).padding(.top, 4)
        }
    }
}

struct XToysControls: View {
    @ObservedObject var model: SessionModel
    @ObservedObject var bridge: XToysBridge
    @ObservedObject var third: XToysBridge
    @State private var expanded = false
    var body: some View {
        DisclosureGroup("XToys pattern control", isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 7) {
                Toggle("Use XToys for M1/M2/M3 vibration", isOn: Binding(
                    get: { model.xtoysEnabled }, set: { model.setXToysEnabled($0) }))
                    .disabled(model.configurationLocked)
                Text(bridge.status).textSelection(.enabled)
                if model.xtoysEnabled {
                    Text(bridge.endpoint).monospaced().textSelection(.enabled)
                    Button("Copy WebSocket URL") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(bridge.endpoint, forType: .string)
                    }.disabled(bridge.endpoint.isEmpty)
                    Text("M3: \(third.status)").textSelection(.enabled)
                    Text(third.endpoint).monospaced().textSelection(.enabled)
                    Button("Copy M3 WebSocket URL") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(third.endpoint, forType: .string)
                    }.disabled(third.endpoint.isEmpty)
                    Link("Open XToys Custom Toys", destination: URL(string: "https://xtoys.app/me/custom-toys")!)
                    Text("Create a Websocket toy: 2 Channel Vibrator, JSON format, Steps 100, Max Message Frequency 10. Paste this URL into Websocket Info, save and connect it in XToys on this Mac.")
                    Text("Add a second Websocket toy for M3: 1 Channel Vibrator, JSON, Steps 100, Frequency 10. Use the M3 URL. Connect each toy before Start.")
                    Text("Start in Perifit Edge, then play a vibration pattern in XToys. M1 and M2 match XToys channels 1 and 2. Target sliders here remain the motor ceilings; XToys supplies the waveform.")
                    Text("XToys request: M1 \(bridge.demand.one, specifier: "%.0f")% · M2 \(bridge.demand.two, specifier: "%.0f")% · M3 \(third.demand.three, specifier: "%.0f")%")
                        .monospacedDigit()
                    Text("Perifit Edge still controls arming, threshold cutoffs, cooldowns, pressure-loss stops and Stop. XToys disconnect or invalid commands stop all motors. This motor-control connection is local. Pressure export is a separate, optional control on Main.")
                }
            }.font(.caption).padding(.top, 4)
        }.onAppear { expanded = bridge.enabled }
            .onChange(of: bridge.enabled) { _, enabled in if enabled { expanded = true } }
    }
}

struct VibrationPatternControls: View {
    @Binding var channel: VibrationChannel
    private var pattern: Binding<VibrationPattern> {
        Binding(get: { channel.effectivePattern }, set: { channel.pattern = $0 })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            let settings = channel.effectivePattern
            Text("Pattern levels are percentages of this channel's target.").font(.caption).foregroundStyle(.secondary)
            field("Minimum (%)", pattern.minimum)
            field("Maximum (%)", pattern.maximum)
            field(channel.mode == .wave ? "Rise time (s)" : "High time (s)", pattern.riseSeconds)
            field(channel.mode == .wave ? "Fall time (s)" : "Low time (s)", pattern.fallSeconds)
            if channel.mode == .wave {
                Picker("Curve", selection: pattern.curve) {
                    ForEach(WaveCurve.allCases, id: \.self) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented)
            }
            Canvas { context, size in
                var path = Path()
                for i in 0...100 {
                    let t = settings.duration * Double(i) / 100
                    let level = (try? settings.level(at: t, mode: channel.mode)) ?? 0
                    let point = CGPoint(x: size.width * Double(i) / 100, y: size.height * (1 - level/100))
                    if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
                }
                context.stroke(path, with: .color(.teal), lineWidth: 2)
            }.frame(height: 65).padding(4).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
                .accessibilityLabel("Repeating \(channel.mode.title), \(settings.minimum.formatted()) to \(settings.maximum.formatted()) percent over \(settings.duration.formatted()) seconds")
            Text("Repeats every \(settings.duration, specifier: "%.1f")s. Live edits apply next cycle; lower maximums and target changes apply immediately. A cutoff resets the pattern.")
                .font(.caption).foregroundStyle(.secondary)
            if channel.mode == .wave {
                Link("Based on XToys Customizable Waves", destination: URL(string: "https://xtoys.app/patterns/-N9RvlWLTGrirxi7jCrc")!).font(.caption)
            }
        }
    }
    private func field(_ title: String, _ value: Binding<Double>) -> some View {
        HStack {
            Text(title); Spacer()
            TextField(title, value: value, format: .number).textFieldStyle(.roundedBorder).frame(width: 65)
        }.font(.caption)
    }
}

struct MotorDiscoveryView: View {
    @ObservedObject var model: SessionModel
    @ObservedObject var usb: ArduinoUSB
    private var hasTested: Bool { model.discoveryChannels.contains { $0.highestTested > 0 } }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("JETT · motor discovery").font(.title2.bold())
                Spacer()
                Button("Stop / Cancel") { model.stop() }.tint(.red).keyboardShortcut(.cancelAction)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Bench test only, with the motors off your body. This deliberately powers one motor even with Demo input selected. Identify which cut lead belongs to Treble and Bass; keep that M1/M2 assignment.")
                    Text("Four AA batteries describe the original controller's supply, not each motor's rating. The shield cannot measure voltage, current, rotation or temperature. Use external current limiting and measurement; do not raise voltage to compensate for driver loss.")
                        .foregroundStyle(.secondary)
                    HStack {
                        Text("Measured motor supply (4.5–6.2 V)")
                        TextField("Volts", value: $model.discoverySupplyVoltage, format: .number)
                            .textFieldStyle(.roundedBorder).frame(width: 70)
                    }.disabled(hasTested || model.discoveryPulseBusy)
                    Toggle("I verified two-wire DC leads, disconnected the original controller, and checked wiring, current limiting and motor/driver current compatibility with instruments.", isOn: $model.discoveryElectricalChecked)
                        .disabled(hasTested || model.discoveryPulseBusy)
                    Text("L293D: 600 mA continuous per channel is a ceiling, not a test-current setting. Check startup current and shared package heating. Without those checks, leave tests disabled.")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(model.discoveryChannels.indices, id: \.self) { index in
                        let channel = model.discoveryChannels[index]
                        let limit = usb.limits[index]
                        GroupBox("M\(index+1)") {
                            VStack(alignment: .leading, spacing: 10) {
                                HStack {
                                    Text("Test level (1–\(limit) PWM)")
                                    Spacer()
                                    TextField("M\(index+1) test PWM", value: $model.discoveryChannels[index].pwm, format: .number)
                                        .textFieldStyle(.roundedBorder).frame(width: 70)
                                        .accessibilityLabel("Motor \(index+1) test PWM, 1 to \(limit)")
                                    Stepper("Adjust test level", value: $model.discoveryChannels[index].pwm, in: 1...max(1, limit))
                                        .labelsHidden().accessibilityLabel("Adjust motor \(index+1) test level")
                                }.disabled(model.discoveryPulseBusy || channel.awaitingObservation != nil)
                                Button("Pulse M\(index+1) for 250 ms") { model.testMotor(index) }
                                    .disabled(model.discoveryPulseBusy || !model.discoveryElectricalChecked ||
                                              model.discoveryChannels.contains { $0.awaitingObservation != nil })
                                if let pwm = channel.awaitingObservation {
                                    Text("Both OFF. At \(pwm) PWM:")
                                    HStack {
                                        Button("Started and ran normally") { model.observeMotor(index, runsNormally: true) }
                                        Button("No motion") { model.observeMotor(index, runsNormally: false) }
                                    }
                                }
                                Text("Observed start: \(channel.minimum) · chosen maximum: \(channel.maximum)").font(.caption).monospacedDigit()
                            }.padding(5).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    Text("Enter any test level within the channel's firmware limit. Wait two seconds OFF between pulses. Stop immediately for heating, unusual noise or a current-limit trip. Repeat successful starts from rest. A lower successful retest lowers the saved maximum; reaching full PWM is unnecessary.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("A short pulse cannot prove continuous-use or simultaneous-load safety. Verify those separately before enabling sessions. Repeat discovery after any motor, supply or wiring change.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Text(model.message).font(.caption).textSelection(.enabled)
            HStack {
                if model.discoveryPulseBusy { ProgressView().controlSize(.small); Text("Testing…").font(.caption) }
                Spacer()
                Button("Save motor ranges") { model.saveMotorDiscovery() }.buttonStyle(.borderedProminent)
                    .disabled(model.discoveryPulseBusy || model.discoveryChannels.contains { $0.minimum == 0 || $0.awaitingObservation != nil })
            }
        }.padding(22).frame(width: 630, height: 740)
            .background(Color(nsColor: .windowBackgroundColor)).interactiveDismissDisabled()
    }
}
