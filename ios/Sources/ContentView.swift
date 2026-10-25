import SwiftUI

struct ContentView: View {
    @StateObject private var ble = BLEManager()
    @State private var showCfg = false

    var body: some View {
        ZStack {
            Color(red: 0.043, green: 0.043, blue: 0.051).ignoresSafeArea()

            VStack(spacing: 16) {
                Text("宿 舍 门 锁")
                    .font(.system(size: 17, weight: .regular))
                    .tracking(6)
                    .foregroundColor(Color(white: 0.53))

                Text(ble.status)
                    .font(.system(size: 13))
                    .foregroundColor(statusColor)

                Button {
                    ble.start()
                } label: {
                    Text(ble.ok == true ? "已开" : "开锁")
                        .font(.system(size: 26, weight: .semibold))
                        .tracking(6)
                        .foregroundColor(.white)
                        .frame(width: 195, height: 195)
                        .background(
                            Circle().fill(
                                RadialGradient(
                                    gradient: Gradient(colors: ringColors),
                                    center: UnitPoint(x: 0.35, y: 0.30),
                                    startRadius: 4,
                                    endRadius: 140
                                )
                            )
                        )
                        .shadow(color: Color.black.opacity(0.65), radius: 22, x: 0, y: 12)
                }
                .buttonStyle(.plain)
                .disabled(ble.busy)
                .padding(.vertical, 6)

                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(ble.lines.enumerated()), id: \.offset) { _, line in
                                Text(line)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(Color(white: 0.54))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            Color.clear.frame(height: 1).id("bottom")
                        }
                        .padding(12)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 230)
                    .background(Color(red: 0.082, green: 0.082, blue: 0.102))
                    .cornerRadius(12)
                    .onChange(of: ble.lines.count) { _ in
                        withAnimation(.easeOut(duration: 0.15)) {
                            proxy.scrollTo("bottom", anchor: .bottom)
                        }
                    }
                }

                HStack(spacing: 18) {
                    Button("设置") { showCfg = true }
                    Button("再开一次") { ble.start() }
                }
                .font(.system(size: 13))
                .foregroundColor(Color(white: 0.55))
                .padding(.top, 4)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 30)
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showCfg) {
            ConfigView(ble: ble)
        }
        .onAppear {
            ble.autoStart()
        }
    }

    private var statusColor: Color {
        if ble.ok == true { return Color(red: 0.37, green: 0.85, blue: 0.50) }
        if ble.ok == false { return Color(red: 1.0, green: 0.42, blue: 0.42) }
        if ble.busy { return Color(red: 1.0, green: 0.82, blue: 0.40) }
        return Color(white: 0.55)
    }

    private var ringColors: [Color] {
        if ble.ok == true {
            return [Color(red: 0.13, green: 0.48, blue: 0.28), Color(red: 0.05, green: 0.27, blue: 0.15)]
        }
        if ble.ok == false {
            return [Color(red: 0.54, green: 0.18, blue: 0.18), Color(red: 0.29, green: 0.08, blue: 0.08)]
        }
        return [Color(white: 0.23), Color(white: 0.10)]
    }
}

struct ConfigView: View {
    @ObservedObject var ble: BLEManager
    @Environment(\.dismiss) private var dismiss

    @State private var key = ""
    @State private var name = ""

    var body: some View {
        NavigationView {
            Form {
                Section {
                    TextField("32 位 hex", text: $key)
                        .font(.system(.footnote, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                } header: {
                    Text("activationKey")
                } footer: {
                    Text("从官方 App 抓：门口点一次开锁，然后 adb logcat | grep \"unlock: macAddress\"")
                }

                Section {
                    TextField("TmallLock", text: $name)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                } header: {
                    Text("设备名关键字")
                } footer: {
                    Text("iOS 拿不到蓝牙 MAC 地址，只能按广播名匹配。门锁广播名形如 ~vTmallLock。首次连上后会记住这台设备的 UUID，之后直连不再扫描。")
                }

                Section {
                    Button("保存") {
                        ble.activationKey = key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                        ble.nameHint = name.trimmingCharacters(in: .whitespacesAndNewlines)
                        ble.log("配置已保存")
                        dismiss()
                    }
                    Button("清除已记住的设备", role: .destructive) {
                        UserDefaults.standard.removeObject(forKey: "voc_uuid")
                        ble.log("已清除设备记忆")
                    }
                }
            }
            .navigationTitle("配置")
            .navigationBarTitleDisplayMode(.inline)
        }
        .preferredColorScheme(.dark)
        .onAppear {
            key = ble.activationKey
            name = ble.nameHint
        }
    }
}
