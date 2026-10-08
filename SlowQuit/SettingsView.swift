// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @ObservedObject var service: QuitProtectionService
    @ObservedObject var preferences: Preferences
    @ObservedObject var loginItem: LoginItemManager
    @State private var selection: String?
    @State private var applicationError: String?
    @State private var showingLicense = false
    @State private var confirmingCountReset = false

    private var delayBinding: Binding<Double> {
        Binding(get: { preferences.delay }, set: { preferences.delay = $0 })
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Image(nsImage: StatusIcon.image(for: .protecting))
                    .resizable().renderingMode(.template)
                    .frame(width: 42, height: 42).foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("SlowQuit").font(.title2.bold())
                    Text("给 ⌘Q 留一点确认的时间").foregroundStyle(.secondary)
                }
                Spacer()
                Text("⌘Q").font(.system(size: 26, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            .padding(24)

            Form {
                Section {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: service.status.symbol)
                            .foregroundStyle(service.status == .protecting ? Color.green : Color.orange)
                            .font(.title3)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(service.status.rawValue).font(.headline)
                            Text(service.statusDetail).font(.callout).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                    }
                    if service.status == .needsPermission || service.status == .failed {
                        HStack {
                            Button("打开辅助功能设置") { service.openAccessibilitySettings() }
                                .buttonStyle(.borderedProminent)
                            Button("重新检查") { service.checkHealth() }
                            Button("定位当前应用") { service.revealCurrentApplication() }
                        }
                        Text("在辅助功能列表中添加并开启当前应用。若开关已开启但仍需要授权，请用“−”移除旧条目，再用“＋”添加此副本。")
                            .font(.caption).foregroundStyle(.secondary)
                        Text(Bundle.main.bundleURL.path)
                            .font(.caption2).foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Toggle("启用 ⌘Q 保护", isOn: $service.isEnabled)
                } header: {
                    Text("保护状态")
                }

                Section {
                    HStack {
                        Text("长按时长")
                        Spacer()
                        TextField("秒", value: delayBinding, format: .number.precision(.fractionLength(1)))
                            .labelsHidden()
                            .multilineTextAlignment(.trailing)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 68)
                            .accessibilityLabel("长按时长，单位秒")
                        Text("秒").foregroundStyle(.secondary)
                    }
                    Slider(value: delayBinding, in: DelaySettings.range, step: 0.1) {
                        Text("长按时长")
                    } minimumValueLabel: {
                        Text("0.3 秒").font(.caption)
                    } maximumValueLabel: {
                        Text("5 秒").font(.caption)
                    }
                    .labelsHidden()
                    Text("提前松开 Command 或 Q 即可取消。新时长从下一次长按生效。")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("显示确认进度浮层", isOn: $preferences.showOverlay)
                } header: {
                    Text("长按确认")
                }

                Section {
                    Picker("保护模式", selection: $preferences.protectionMode) {
                        ForEach(ProtectionMode.allCases) { mode in Text(mode.title).tag(mode) }
                    }
                    .pickerStyle(.radioGroup)
                    .onChange(of: preferences.protectionMode) { _, _ in selection = nil }
                    Text(preferences.protectionMode == .allExceptListed ? "不保护的应用" : "需要保护的应用")
                        .font(.headline)
                    if preferences.activeRules.isEmpty {
                        Text(preferences.protectionMode == .allExceptListed ? "所有应用均受保护" : "尚未选择应用，当前不会延迟退出")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 68)
                    } else {
                        List(preferences.activeRules, selection: $selection) { app in
                            HStack(spacing: 10) {
                                Image(nsImage: applicationIcon(app.bundleIdentifier))
                                    .resizable().frame(width: 28, height: 28)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(app.name)
                                    Text(app.bundleIdentifier).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 3)
                            .tag(app.id)
                        }
                        .frame(height: 112)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    HStack {
                        Button("添加应用…", systemImage: "plus") { chooseApplications() }
                        Button("移除", systemImage: "minus") {
                            if let selection { preferences.removeRule(id: selection) }
                            selection = nil
                        }
                        .disabled(selection == nil)
                        Spacer()
                    }
                    Text(preferences.protectionMode == .allExceptListed
                         ? "名单中的应用立即响应 ⌘Q，其余应用需要长按。两种模式分别保存名单。"
                         : "只有名单中的应用需要长按，其余应用立即响应 ⌘Q。两种模式分别保存名单。")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("保护开启时，一次按住最多触发一次 ⌘Q，避免连续影响后面的应用。")
                        .font(.caption).foregroundStyle(.secondary)
                } header: {
                    Text("保护范围")
                }

                Section {
                    HStack {
                        Text("已拦截短按")
                        Spacer()
                        Text("\(preferences.blockedShortPressCount.formatted()) 次").monospacedDigit()
                        Button("清零…") { confirmingCountReset = true }
                            .disabled(preferences.blockedShortPressCount == 0)
                    }
                    Text("仅统计长按达标前因松开 Q 或 Command 而取消的次数。累计值会在重启后保留。")
                        .font(.caption).foregroundStyle(.secondary)
                } header: {
                    Text("拦截统计")
                }

                Section {
                    Toggle("登录时启动", isOn: Binding(get: { loginItem.isEnabled }, set: { loginItem.setEnabled($0) }))
                    if loginItem.requiresApproval {
                        HStack {
                            Text("需要在系统设置中允许登录启动。").font(.caption)
                            Button("打开登录项设置") { loginItem.openSystemSettings() }
                        }
                    }
                    if let error = loginItem.errorMessage {
                        Text(error).font(.caption).foregroundStyle(.red)
                    }
                } header: {
                    Text("启动")
                }
            }
            .formStyle(.grouped)

            HStack {
                Text("SlowQuit 1.0 · GPL-2.0-or-later").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("开源许可") { showingLicense = true }
                .buttonStyle(.link)
                Link("参考项目", destination: URL(string: "https://github.com/dteoh/SlowQuitApps")!)
                    .font(.caption)
            }
            .padding(.horizontal, 24).padding(.vertical, 14)
        }
        .frame(width: 550)
        .frame(minHeight: 540, idealHeight: 740, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            loginItem.refresh()
            service.checkHealth()
        }
        .sheet(isPresented: $showingLicense) {
            VStack(alignment: .leading, spacing: 16) {
                Text("开源许可与致谢").font(.title2.bold())
                Text("SlowQuit · GPL-2.0-or-later\nCopyright © 2026 SlowQuit contributors.")
                ScrollView {
                    Text(licenseText).font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
                Button("完成") { showingLicense = false }.keyboardShortcut(.defaultAction)
            }
            .padding(24).frame(width: 500, height: 500)
        }
        .alert("无法添加应用", isPresented: Binding(get: { applicationError != nil }, set: { if !$0 { applicationError = nil } })) {
            Button("好", role: .cancel) { applicationError = nil }
        } message: {
            Text(applicationError ?? "")
        }
        .alert("清零拦截次数？", isPresented: $confirmingCountReset) {
            Button("取消", role: .cancel) { }
            Button("清零", role: .destructive) { preferences.resetBlockedShortPressCount() }
        } message: {
            Text("累计次数将重新从 0 开始。")
        }
    }

    private var licenseText: String {
        [("THIRD_PARTY_NOTICES", "md" as String?), ("LICENSE", nil)].compactMap { name, extensionName in
            Bundle.main.url(forResource: name, withExtension: extensionName)
                .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        }.joined(separator: "\n\n────────────────────────\n\n")
    }

    private func chooseApplications() {
        let panel = NSOpenPanel()
        panel.title = preferences.protectionMode == .allExceptListed ? "选择不需要保护的应用" : "选择需要保护的应用"
        panel.prompt = "添加"
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            guard let bundle = Bundle(url: url), let identifier = bundle.bundleIdentifier else {
                applicationError = "“\(url.lastPathComponent)”没有有效的应用标识。"
                continue
            }
            let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
                ?? url.deletingPathExtension().lastPathComponent
            preferences.addRule(.init(bundleIdentifier: identifier, name: name))
        }
    }

    private func applicationIcon(_ identifier: String) -> NSImage {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return NSImage(systemSymbolName: "app", accessibilityDescription: nil) ?? NSImage()
    }
}
