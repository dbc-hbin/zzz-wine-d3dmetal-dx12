import SwiftUI

struct ContentView: View {
    @StateObject private var engine = InstallerEngine()
    @State private var showingAlert = false
    @State private var alertTitle = ""
    @State private var alertMessage = ""
    @State private var supportPathWasEdited = false

    private var targetSelection: Binding<String> {
        Binding(
            get: { engine.selectedTarget?.rawValue ?? "custom" },
            set: { value in
                guard let target = InstallerEngine.Target(rawValue: value) else { return }
                supportPathWasEdited = false
                engine.selectTarget(target)
            }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 16) {
                Image(systemName: "gamecontroller.fill")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 48, height: 48)
                    .foregroundColor(.accentColor)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Wine 11.17 ZZZ DX12 Installer")
                        .font(.title2)
                        .fontWeight(.bold)
                    Text("Install and register the prebuilt D3DMetal (GPTK 4.0b2) Wine runtime for Yaagl")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor))

            Divider()

            // Main Content
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Status Card
                    GroupBox(label: Label("Environment Status", systemImage: "info.circle")) {
                        VStack(alignment: .leading, spacing: 8) {
                            Picker("Yaagl Target", selection: targetSelection) {
                                ForEach(InstallerEngine.Target.allCases) { target in
                                    Text(target.title).tag(target.rawValue)
                                }
                                if engine.selectedTarget == nil {
                                    Text("Custom Paths").tag("custom")
                                }
                            }
                            .disabled(engine.isWorking)

                            HStack {
                                Image(systemName: engine.status.yaaglAppExists ? "checkmark.circle.fill" : "xmark.circle.fill")
                                    .foregroundColor(engine.status.yaaglAppExists ? .green : .red)
                                Text("Yaagl App:")
                                TextField("Yaagl application path", text: Binding(
                                    get: { engine.appPath },
                                    set: { engine.setPaths(appPath: $0, supportPath: supportPathWasEdited ? engine.supportPath : nil) }
                                ))
                                    .font(.caption)
                                    .textFieldStyle(.roundedBorder)
                                    .disabled(engine.isWorking)
                                    .onSubmit { engine.refreshStatus() }
                                    .accessibilityLabel("Yaagl application path")
                                Spacer()
                            }

                            HStack {
                                Image(systemName: engine.status.yaaglSupportExists ? "checkmark.circle.fill" : "xmark.circle.fill")
                                    .foregroundColor(engine.status.yaaglSupportExists ? .green : .red)
                                Text("Support Folder:")
                                TextField("Yaagl support folder path", text: Binding(
                                    get: { engine.supportPath },
                                    set: {
                                        supportPathWasEdited = true
                                        engine.setPaths(appPath: nil, supportPath: $0)
                                    }
                                ))
                                    .font(.caption)
                                    .textFieldStyle(.roundedBorder)
                                    .disabled(engine.isWorking)
                                    .onSubmit { engine.refreshStatus() }
                                    .accessibilityLabel("Yaagl support folder path")
                                Spacer()
                            }

                            if !engine.status.currentWineTag.isEmpty {
                                HStack {
                                    Image(systemName: "cube.fill")
                                        .foregroundColor(.blue)
                                    Text("Yaagl Wine Selection:")
                                    Text(engine.status.currentWineTag)
                                        .font(.caption)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                            }

                            if engine.status.hasBackup {
                                HStack {
                                    Image(systemName: "arrow.uturn.backward.circle.fill")
                                        .foregroundColor(.blue)
                                    Text("Yaagl resources and Wine backup available")
                                        .font(.callout)
                                }
                            }

                            if engine.status.yaaglIsRunning {
                                HStack {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .foregroundColor(.orange)
                                    Text("Quit Yaagl and Wine before installing or restoring.")
                                        .font(.callout)
                                        .foregroundColor(.orange)
                                    Spacer()
                                }
                                .padding(8)
                                .background(Color.orange.opacity(0.1))
                                .cornerRadius(6)
                            }
                        }
                        .padding(6)
                    }

                    // Features Card
                    GroupBox(label: Label("Prebuilt Runtime", systemImage: "archivebox.fill")) {
                        VStack(alignment: .leading, spacing: 6) {
                            FeatureRow(icon: "list.bullet.rectangle", title: "Yaagl Wine Menu Registration", desc: "Adds Wine 11.17 ZZZ DX12 (GPTK4.0b2) to Yaagl's Wine menu using the prebuilt archive")
                            FeatureRow(icon: "arrow.uturn.backward.circle", title: "Backup & Restore", desc: "Preserves Yaagl resources, Wine selection, and Wine directory before installation")
                            FeatureRow(icon: "bolt.fill", title: "Direct3D 12 (GPTK 4.0b2)", desc: "Native D3D12 hardware acceleration via Apple Metal IR")
                            FeatureRow(icon: "cpu.fill", title: "Apple Silicon Native ARM64 Server", desc: "Native arm64 wineserver eliminates Rosetta translation latency")
                            FeatureRow(icon: "memorychip.fill", title: "High-Performance MSync", desc: "Low-overhead synchronization via Mach semaphores and shared memory")
                            FeatureRow(icon: "archivebox.fill", title: "Metal PSO Cache & Cache Warmup", desc: "Device-lifetime PSO caching to minimize in-game shader micro-stutters")
                            FeatureRow(icon: "cursorarrow.rays", title: "Cursor Rollback & RawInput Fix", desc: "Resolves game cursor switching and focus freezes on initial launch")
                        }
                        .padding(6)
                    }

                    // Progress Section
                    if engine.isWorking {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(engine.currentStep)
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                                Spacer()
                                Text("\(Int(engine.progress * 100))%")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            ProgressView(value: engine.progress)
                        }
                        .padding()
                        .background(Color.accentColor.opacity(0.08))
                        .cornerRadius(8)
                    }

                    // Log View
                    GroupBox(label: Label("Activity Log", systemImage: "terminal")) {
                        ScrollViewReader { proxy in
                            ScrollView {
                                VStack(alignment: .leading, spacing: 2) {
                                    ForEach(Array(engine.logs.enumerated()), id: \.offset) { index, log in
                                        Text(log)
                                            .font(.system(.caption2, design: .monospaced))
                                            .foregroundColor(.secondary)
                                            .id(index)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(4)
                            }
                            .frame(height: 120)
                            .onChange(of: engine.logs.count) {
                                if let last = engine.logs.indices.last {
                                    proxy.scrollTo(last, anchor: .bottom)
                                }
                            }
                        }
                    }
                }
                .padding()
            }

            Divider()

            // Footer / Actions
            HStack {
                Button("Refresh") {
                    engine.refreshStatus()
                }
                .disabled(engine.isWorking)

                if engine.status.hasBackup {
                    Button("Restore Backup") {
                        engine.restore { success, message in
                            alertTitle = success ? "Restore Complete" : "Restore Failed"
                            alertMessage = message
                            showingAlert = true
                        }
                    }
                    .disabled(engine.isWorking || engine.status.yaaglIsRunning)
                }

                Spacer()

                Button(action: {
                    engine.install { success, message in
                        alertTitle = success ? "Installation Complete" : "Installation Failed"
                        alertMessage = message
                        showingAlert = true
                    }
                }) {
                    HStack {
                        Image(systemName: engine.status.currentWineTag == RuntimePackage.targetRuntimeId ? "arrow.triangle.2.circlepath.circle.fill" : "arrow.down.circle.fill")
                        Text(engine.status.currentWineTag == RuntimePackage.targetRuntimeId ? "Reinstall / Update Wine" : "Install Wine 11.17 ZZZ DX12")
                            .fontWeight(.semibold)
                    }
                    .padding(.horizontal, 8)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(engine.isWorking || engine.status.yaaglIsRunning || !engine.status.yaaglAppExists || !engine.status.yaaglSupportExists)
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor))
        }
        .frame(minWidth: 620, minHeight: 640)
        .onAppear {
            engine.refreshStatus()
        }
        .alert(isPresented: $showingAlert) {
            Alert(
                title: Text(alertTitle),
                message: Text(alertMessage),
                dismissButton: .default(Text("OK"))
            )
        }
    }
}

struct FeatureRow: View {
    let icon: String
    let title: String
    let desc: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundColor(.accentColor)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption)
                    .fontWeight(.semibold)
                Text(desc)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
    }
}
