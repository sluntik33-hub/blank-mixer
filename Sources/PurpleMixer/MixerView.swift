import SwiftUI

// MARK: - Тема «Graphite / Mint»

enum Theme {
    static let bg          = Color(red: 0.067, green: 0.074, blue: 0.086)
    static let card        = Color(red: 0.105, green: 0.114, blue: 0.130)
    static let cardHover   = Color(red: 0.135, green: 0.146, blue: 0.165)
    static let stroke      = Color.white.opacity(0.06)
    static let track       = Color.white.opacity(0.09)
    static let mint        = Color(red: 0.24, green: 0.90, blue: 0.69)
    static let sky         = Color(red: 0.23, green: 0.72, blue: 0.96)
    static let coral       = Color(red: 1.00, green: 0.45, blue: 0.42)
    static let text        = Color.white.opacity(0.94)
    static let textDim     = Color.white.opacity(0.48)
    static let textFaint   = Color.white.opacity(0.28)

    static let accent = LinearGradient(colors: [mint, sky], startPoint: .leading, endPoint: .trailing)
    static let muted  = LinearGradient(colors: [textFaint, textFaint], startPoint: .leading, endPoint: .trailing)
}

// MARK: - Главное окно

struct MixerView: View {
    @EnvironmentObject var mixer: AppAudioMixer

    private var playingCount: Int { mixer.apps.filter(\.isPlayingAudio).count }

    var body: some View {
        VStack(spacing: 12) {
            header

            if mixer.permissionDenied { PermissionBanner() }

            MasterCard(value: $mixer.systemVolume)

            appsList

            footer
        }
        .padding(14)
        .frame(width: 340)
        .background(Theme.bg)
        .preferredColorScheme(.dark)
        .onAppear { mixer.refresh() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Theme.accent)
                    .frame(width: 28, height: 28)
                Image(systemName: "dial.medium.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Theme.bg)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text("BLANK")
                    .font(.system(size: 14, weight: .heavy, design: .rounded))
                    .foregroundStyle(Theme.text)
                Text("\(mixer.apps.count) прил. · \(playingCount) со звуком")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Theme.textDim)
            }
            Spacer()
            IconButton(symbol: "speaker.slash", help: "Заглушить все") { mixer.muteAll(true) }
            IconButton(symbol: "arrow.counterclockwise", help: "Сбросить всё на 100%") { mixer.resetAll() }
        }
    }

    @ViewBuilder
    private var appsList: some View {
        if mixer.apps.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "waveform.slash")
                    .font(.system(size: 20))
                    .foregroundStyle(Theme.textFaint)
                Text("Нет приложений со звуком")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textDim)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 22)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.card))
        } else {
            // Порядок строк стабилен (см. AppAudioMixer.apps) и без
            // анимаций перестановки — строка всегда на своём месте.
            let rows = VStack(spacing: 6) {
                ForEach(mixer.apps) { AppRow(item: $0) }
            }
            if mixer.apps.count <= 6 {
                rows
            } else {
                ScrollView(.vertical, showsIndicators: false) { rows }
                    .frame(height: 380)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Text("v3.0")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(Theme.textFaint)
            Spacer()
            PillButton(title: "Связь", symbol: "paperplane.fill") {
                NSWorkspace.shared.open(URL(string: "https://t.me/mik44er")!)
            }
            PillButton(title: "Выйти", symbol: "power") { NSApp.terminate(nil) }
        }
    }
}

// MARK: - Карточка общей громкости

private struct MasterCard: View {
    @Binding var value: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("ОБЩАЯ ГРОМКОСТЬ")
                    .font(.system(size: 9.5, weight: .bold))
                    .tracking(1.2)
                    .foregroundStyle(Theme.textDim)
                Spacer()
                Text("\(Int((value * 100).rounded()))")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.text)
                    + Text("%")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.textDim)
            }
            HStack(spacing: 10) {
                Image(systemName: "speaker.fill").font(.system(size: 10)).foregroundStyle(Theme.textDim)
                VolumeSlider(value: $value, thickness: 8)
                Image(systemName: "speaker.wave.3.fill").font(.system(size: 10)).foregroundStyle(Theme.textDim)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Theme.card)
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.stroke))
        )
    }
}

// MARK: - Строка приложения

private struct AppRow: View {
    @ObservedObject var item: AudioAppItem
    @State private var hover = false

    var body: some View {
        HStack(spacing: 10) {
            ZStack(alignment: .bottomTrailing) {
                Image(nsImage: item.icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 30, height: 30)
                    .saturation(item.isMuted ? 0 : 1)
                    .opacity(item.isMuted ? 0.5 : 1)
                Circle()
                    .fill(item.isPlayingAudio ? Theme.mint : Theme.textFaint)
                    .frame(width: 8, height: 8)
                    .overlay(Circle().stroke(Theme.card, lineWidth: 2))
                    .offset(x: 2, y: 2)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(item.name)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if item.isPlayingAudio && !item.isMuted { EqualizerBars() }
                    Spacer(minLength: 4)
                    Button { item.volume = 1.0 } label: {
                        Text(item.isMuted ? "MUTE" : "\(Int((item.volume * 100).rounded()))%")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(item.isMuted ? Theme.coral : Theme.textDim)
                            .frame(minWidth: 38)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.white.opacity(0.05)))
                    }
                    .buttonStyle(.plain)
                    .help("Нажмите, чтобы вернуть 100%")
                }
                VolumeSlider(value: $item.volume, thickness: 5, dimmed: item.isMuted)
            }

            Button { item.isMuted.toggle() } label: {
                Image(systemName: item.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(item.isMuted ? Theme.coral : Theme.text)
                    .frame(width: 28, height: 28)
                    .background(
                        Circle().fill(item.isMuted ? Theme.coral.opacity(0.15) : Color.white.opacity(0.06))
                    )
            }
            .buttonStyle(.plain)
            .help(item.isMuted ? "Включить звук" : "Выключить звук")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(hover ? Theme.cardHover : Theme.card)
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.stroke))
        )
        .onHover { hover = $0 }
    }
}

// MARK: - Собственный слайдер

/// Свой слайдер вместо системного: толстый трек с градиентной заливкой и
/// ручкой, которая увеличивается при наведении/перетаскивании.
private struct VolumeSlider: View {
    @Binding var value: Double
    var thickness: CGFloat = 6
    var dimmed: Bool = false

    @State private var hover = false
    @State private var dragging = false

    var body: some View {
        GeometryReader { geo in
            let knob: CGFloat = (hover || dragging) ? thickness + 8 : thickness + 5
            let usable = max(1, geo.size.width - knob)
            let x = CGFloat(max(0, min(1, value))) * usable

            ZStack(alignment: .leading) {
                Capsule().fill(Theme.track).frame(height: thickness)
                Capsule()
                    .fill(dimmed ? Theme.muted : Theme.accent)
                    .frame(width: x + knob / 2, height: thickness)
                Circle()
                    .fill(Color.white)
                    .frame(width: knob, height: knob)
                    .shadow(color: .black.opacity(0.4), radius: 2, y: 1)
                    .offset(x: x)
            }
            .frame(height: geo.size.height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        dragging = true
                        let v = Double((g.location.x - knob / 2) / usable)
                        value = max(0, min(1, v))
                    }
                    .onEnded { _ in dragging = false }
            )
            .onHover { hover = $0 }
            .animation(.easeOut(duration: 0.12), value: hover || dragging)
        }
        .frame(height: thickness + 10)
        .accessibilityElement()
        .accessibilityLabel("Громкость")
        .accessibilityValue("\(Int(value * 100)) процентов")
        .accessibilityAdjustableAction { dir in
            switch dir {
            case .increment: value = min(1, value + 0.05)
            case .decrement: value = max(0, value - 0.05)
            @unknown default: break
            }
        }
    }
}

// MARK: - Мелкие элементы

private struct EqualizerBars: View {
    @State private var phase = false
    var body: some View {
        HStack(alignment: .bottom, spacing: 1.5) {
            ForEach(0..<3, id: \.self) { i in
                Capsule()
                    .fill(Theme.mint)
                    .frame(width: 2, height: phase ? [7, 4, 9][i] : [3, 8, 4][i])
            }
        }
        .frame(height: 9, alignment: .bottom)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.45).repeatForever(autoreverses: true)) { phase = true }
        }
    }
}

private struct IconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(hover ? Theme.text : Theme.textDim)
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.white.opacity(hover ? 0.10 : 0.05)))
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hover = $0 }
    }
}

private struct PillButton: View {
    let title: String
    let symbol: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 9, weight: .bold))
                Text(title).font(.system(size: 10.5, weight: .semibold))
            }
            .foregroundStyle(hover ? Theme.text : Theme.textDim)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(Color.white.opacity(hover ? 0.10 : 0.05)))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

private struct PermissionBanner: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.shield.fill").foregroundStyle(Theme.coral)
            Text("Нужен доступ к записи системного звука")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.text)
            Spacer()
            PillButton(title: "Открыть", symbol: "gearshape.fill") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.coral.opacity(0.12)))
    }
}
