//
//  DashboardView.swift
//  desktop
//

import SwiftUI
import SwiftData
import AppKit

struct DashboardView: View {
    @Environment(TranscriptionCoordinator.self) var coordinator
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \TranscriptionRecord.createdAt, order: .reverse) private var history: [TranscriptionRecord]

    @AppStorage(HotkeyManager.keyCodeDefaultsKey) private var hotkeyKeyCode: Int = HotkeyManager.KeyCode.rightShift
    @State private var showClearAllConfirmation = false

    private static let groupDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    var body: some View {
        VStack(spacing: 0) {
            heroSection
            
            historySection
                .padding(.top, 16)
        }
        .background(Color.spinozaBg)
    }

    // MARK: - Hero Section

    private var heroSection: some View {
        VStack(spacing: 16) {
            // Stats Row
            HStack(spacing: 16) {
                StatCard(title: "Dictations", value: "\(history.count)", icon: "waveform", color: Color.spinozaBlue)
                
                StatCard(title: "Words Saved", value: "\(wordCount)", icon: "text.quote", color: .purple)
                
                // Heuristic: ~15 s of typing time saved per dictation (industry average ~40 wpm).
                let estimatedTimeSavedSeconds = history.count * 15
                let mins = estimatedTimeSavedSeconds / 60
                StatCard(title: "Time Saved", value: "\(mins)m", icon: "clock.fill", color: .green)
            }
            .padding(.horizontal, 20)
            .padding(.top, 24)

            // Dynamic Hotkey Banner
            enhancedHotkeyBanner
                .padding(.horizontal, 20)
        }
    }
    
    private var enhancedHotkeyBanner: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(LinearGradient(colors: [Color.spinozaBlue, Color.purple.opacity(0.8)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 40, height: 40)
                    .shadow(color: Color.spinozaBlue.opacity(0.3), radius: 6, y: 2)
                
                if let icon = coordinator.targetAppIcon {
                    Image(nsImage: icon)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 20, height: 20)
                        .cornerRadius(4)
                } else {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
            
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Text("Hold")
                        .font(.system(size: 14))
                        .foregroundStyle(Color.spinozaTextSub)
                    Text(HotkeyManager.shortLabel(keyCode: hotkeyKeyCode))
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color.spinozaText)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.08)))
                    Text("to dictate")
                        .font(.system(size: 14))
                        .foregroundStyle(Color.spinozaTextSub)
                }
                
                if coordinator.isRecording {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 6, height: 6)
                        Text(coordinator.currentTranscription.isEmpty ? "Listening..." : coordinator.currentTranscription)
                            .font(.system(size: 13))
                            .lineLimit(1)
                            .foregroundStyle(Color.spinozaText)
                    }
                    .transition(.opacity)
                } else {
                    Text(coordinator.statusMessage)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.spinozaTextSub)
                }
            }
            Spacer()
        }
        .spinozaCard(shadowY: 3)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: coordinator.isRecording)
        .animation(.easeInOut(duration: 0.15), value: coordinator.currentTranscription)
    }

    // MARK: - History Section

    private var historySection: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 8) {
                Text("Activity Timeline")
                    .font(.system(.title3, design: .rounded).weight(.semibold))
                    .foregroundStyle(Color.spinozaText)

                if !history.isEmpty {
                    Text("\(history.count)")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Color.spinozaBlue)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.spinozaBlue.opacity(0.12)))
                }

                Spacer()

                if !history.isEmpty {
                    Button {
                        showClearAllConfirmation = true
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "trash")
                                .font(.system(size: 11, weight: .medium))
                            Text("Clear All")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .foregroundStyle(Color.spinozaTextSub)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.primary.opacity(0.04))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .stroke(Color.primary.opacity(0.06), lineWidth: 1)
                                )
                        )
                    }
                    .buttonStyle(.plain)
                    .alert("Clear All History?", isPresented: $showClearAllConfirmation) {
                        Button("Cancel", role: .cancel) { }
                        Button("Clear All", role: .destructive) {
                            coordinator.clearHistory()
                        }
                    } message: {
                        Text("This will permanently delete all \(history.count) transcription records. This action cannot be undone.")
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(Color.spinozaBg)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Color.primary.opacity(0.05)).frame(height: 1)
            }

            // List
            if history.isEmpty {
                emptyState
            } else {
                historyList
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "waveform.circle.fill")
                .symbolRenderingMode(.multicolor)
                .font(.system(size: 56))
                .foregroundStyle(Color.spinozaBlue, Color.spinozaBlue.opacity(0.2))
            
            VStack(spacing: 4) {
                Text("No dictations yet")
                    .font(.system(.headline, design: .rounded))
                    .foregroundStyle(Color.spinozaText)
                Text("Your transcriptions will securely appear here.")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.spinozaTextTertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var historyList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                let grouped = groupedByDay(history)
                ForEach(grouped, id: \.0) { (dayLabel, entries) in
                    // Day header
                    HStack {
                        Text(dayLabel.uppercased())
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Color.spinozaTextSub)
                            .tracking(0.5)
                        
                        Rectangle()
                            .fill(Color.primary.opacity(0.05))
                            .frame(height: 1)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 24)
                    .padding(.bottom, 16)

                    // Entries
                    ForEach(entries) { entry in
                        HistoryRow(entry: entry, isLast: entry.id == entries.last?.id) {
                            withAnimation(.easeInOut(duration: 0.25)) {
                                modelContext.delete(entry)
                                try? modelContext.save()
                            }
                        }
                    }
                }
            }
            .padding(.bottom, 32)
        }
        .background(Color.spinozaBg)
    }

    // MARK: - Helpers

    private var wordCount: Int {
        history.reduce(0) { $0 + $1.text.split(whereSeparator: \.isWhitespace).count }
    }

    private func groupedByDay(_ records: [TranscriptionRecord]) -> [(String, [TranscriptionRecord])] {
        let cal = Calendar.current
        var groups: [(String, [TranscriptionRecord])] = []

        for record in records {
            let label: String
            if cal.isDateInToday(record.createdAt) {
                label = "Today"
            } else if cal.isDateInYesterday(record.createdAt) {
                label = "Yesterday"
            } else {
                label = Self.groupDateFormatter.string(from: record.createdAt)
            }

            if let idx = groups.firstIndex(where: { $0.0 == label }) {
                groups[idx].1.append(record)
            } else {
                groups.append((label, [record]))
            }
        }
        return groups
    }
}

// MARK: - Components

private struct StatCard: View {
    let title: String
    let value: String
    let icon: String
    let color: Color
    
    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(color.opacity(0.12))
                    .frame(width: 36, height: 36)
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(color)
            }
            
            VStack(alignment: .leading, spacing: 2) {
                Text(value)
                    .font(.system(.title3, design: .rounded).weight(.bold))
                    .foregroundStyle(Color.spinozaText)
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.spinozaTextSub)
            }
            Spacer()
        }
        .spinozaCard(
            cornerRadius: 12,
            padding: 12,
            shadowOpacity: 0.02,
            shadowRadius: 5,
            shadowY: 2,
            stroke: Color.primary.opacity(0.04)
        )
    }
}

// MARK: - History Row

private struct HistoryRow: View {
    let entry: TranscriptionRecord
    let isLast: Bool
    let onDelete: () -> Void

    @State private var isHovered = false

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f
    }()

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            // Timeline Node
            VStack(spacing: 0) {
                Circle()
                    .fill(Color.spinozaBlue)
                    .frame(width: 8, height: 8)
                    .overlay(Circle().stroke(.white, lineWidth: 2))
                    .padding(.top, 6)
                
                if !isLast {
                    Rectangle()
                        .fill(Color.primary.opacity(0.08))
                        .frame(width: 2)
                        .padding(.vertical, 4)
                }
            }
            .frame(width: 16)

            // Content Card
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(Self.timeFormatter.string(from: entry.createdAt))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.spinozaTextSub)
                    
                    Spacer()
                    
                    if isHovered {
                        HStack(spacing: 6) {
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(entry.text, forType: .string)
                            } label: {
                                Image(systemName: "doc.on.doc")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(Color.spinozaBlue)
                                    .padding(6)
                                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.spinozaBlue.opacity(0.1)))
                            }
                            .buttonStyle(.plain)

                            Button(action: onDelete) {
                                Image(systemName: "trash")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(.red.opacity(0.8))
                                    .padding(6)
                                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.red.opacity(0.08)))
                            }
                            .buttonStyle(.plain)
                        }
                        .transition(.opacity)
                    }
                }

                Text(entry.text)
                    .font(.system(size: 14))
                    .foregroundStyle(Color.spinozaText)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(isHovered ? Color.primary.opacity(0.03) : Color.spinozaCard)
                    .shadow(color: isHovered ? .black.opacity(0.04) : .clear, radius: 4, y: 2)
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.04), lineWidth: 1))
            )
            .animation(.easeInOut(duration: 0.15), value: isHovered)
            .padding(.bottom, isLast ? 0 : 12)
        }
        .padding(.horizontal, 20)
        .onHover { isHovered = $0 }
    }
}
