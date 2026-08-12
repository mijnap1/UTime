//
//  UofTimetableLiveActivityWidget.swift
//  UofTimetableWidget
//

import ActivityKit
import SwiftUI
import WidgetKit

struct UofTimetableLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ClassActivityAttributes.self) { context in
            LockScreenClassActivityView(context: context)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    ExpandedCourseView(state: context.state)
                }

                DynamicIslandExpandedRegion(.center) {
                    ExpandedTimerView(state: context.state)
                }

                DynamicIslandExpandedRegion(.trailing) {
                    ExpandedRoomView(state: context.state)
                }

                DynamicIslandExpandedRegion(.bottom) {
                    ExpandedInfoRow(state: context.state)
                        .padding(.top, 2)
                }
            } compactLeading: {
                CompactCountdownLeadingView(
                    state: context.state,
                    isStale: context.isStale
                )
            } compactTrailing: {
                CompactLocationView(state: context.state)
            } minimal: {
                MinimalCountdownView(target: context.state.countdownTarget())
            }
            .keylineTint(ClassActivityTheme.color(for: context.state.countdownTarget()).accent)
        }
    }
}

private struct ExpandedCourseView: View {
    let state: ClassActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(state.displayCourseCode)
                .font(.system(size: 19, weight: .semibold, design: .default))
                .foregroundStyle(ActivityStyle.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.68)

            if !state.expandedCourseSubtitle.isEmpty {
                Text(state.expandedCourseSubtitle)
                    .font(.system(size: 12, weight: .medium, design: .default))
                    .foregroundStyle(ActivityStyle.muted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
        }
        .frame(width: 122, alignment: .leading)
        .padding(.leading, 20)
    }
}

private struct ExpandedTimerView: View {
    let state: ClassActivityAttributes.ContentState

    var body: some View {
        VStack(spacing: 0) {
            Text(state.phaseLabel())
                .font(.system(size: 12, weight: .semibold, design: .default))
                .foregroundStyle(ClassActivityTheme.color(for: state.countdownTarget()).accent)
                .frame(width: 112, alignment: .center)

            ExpandedCountdownView(target: state.countdownTarget())
                .frame(width: 112, alignment: .center)
        }
        .frame(width: 112, alignment: .center)
    }
}

private struct ExpandedRoomView: View {
    let state: ClassActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            Text(state.expandedLocationTitle)
                .font(.system(size: 19, weight: .semibold, design: .default))
                .foregroundStyle(ActivityStyle.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.68)

            if !state.expandedLocationSubtitle.isEmpty {
                Text(state.expandedLocationSubtitle)
                    .font(.system(size: 12, weight: .medium, design: .default))
                    .foregroundStyle(ActivityStyle.muted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
        }
        .frame(width: 122, alignment: .trailing)
        .padding(.trailing, 20)
    }
}

private struct ExpandedInfoRow: View {
    let state: ClassActivityAttributes.ContentState

    var body: some View {
        Text(state.expandedFooterText)
            .font(.system(size: 12, weight: .medium, design: .default))
            .foregroundStyle(ActivityStyle.muted)
            .lineLimit(1)
            .minimumScaleFactor(0.72)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, 28)
    }
}

private struct LockScreenClassActivityView: View {
    let context: ActivityViewContext<ClassActivityAttributes>

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { timeline in
            let theme = ClassActivityTheme.color(
                for: context.state.countdownTarget(now: timeline.date),
                now: timeline.date
            )

            ZStack {
                LockScreenActivityBackground()

                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .top, spacing: 14) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(context.state.displayCourseCode)
                                .font(.system(size: 23, weight: .semibold, design: .default))
                                .foregroundStyle(ActivityStyle.primary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.72)

                            Text(context.state.meetingSummary)
                                .font(.system(size: 12, weight: .medium, design: .default))
                                .foregroundStyle(ActivityStyle.muted)
                                .lineLimit(1)
                                .minimumScaleFactor(0.75)
                        }

                        Spacer(minLength: 8)

                        VStack(alignment: .trailing, spacing: 3) {
                            Text(context.state.phaseLabel(now: timeline.date).uppercased())
                                .font(.system(size: 11, weight: .bold, design: .default))
                                .foregroundStyle(theme.accent)
                                .tracking(0.6)

                            LockScreenCountdownView(target: context.state.countdownTarget(now: timeline.date))
                        }
                        .frame(width: 118, alignment: .trailing)
                    }

                    HStack(alignment: .center, spacing: 10) {
                        HStack(spacing: 8) {
                            Image(systemName: context.state.locationIconName)
                                .font(.system(size: 12, weight: .bold, design: .default))
                                .foregroundStyle(theme.accent)

                            Text(context.state.location)
                                .font(.system(size: 18, weight: .semibold, design: .default))
                                .foregroundStyle(ActivityStyle.primary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.72)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(ActivityStyle.primary.opacity(0.075), in: Capsule())
                        .overlay {
                            Capsule()
                                .stroke(.white.opacity(0.05), lineWidth: 1)
                        }

                        Spacer(minLength: 8)

                        Text(context.state.timeSummary(now: timeline.date))
                            .font(.system(size: 13, weight: .medium, design: .default))
                            .foregroundStyle(ActivityStyle.muted)
                            .lineLimit(1)
                            .minimumScaleFactor(0.82)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 15)
            }
            .activityBackgroundTint(theme.background)
            .activitySystemActionForegroundColor(theme.accent)
        }
    }
}

private struct LockScreenActivityBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    ActivityStyle.cardSurfaceTop,
                    ActivityStyle.softNavy,
                    ActivityStyle.cardSurfaceBottom
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            RadialGradient(
                colors: [.white.opacity(0.055), .clear],
                center: .topLeading,
                startRadius: 18,
                endRadius: 220
            )

            RadialGradient(
                colors: [ActivityStyle.blue.opacity(0.10), .clear],
                center: .topTrailing,
                startRadius: 12,
                endRadius: 185
            )

            LinearGradient(
                colors: [.white.opacity(0.065), .clear, .black.opacity(0.08)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }
}

private struct LockScreenCountdownView: View {
    let target: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            if target > timeline.date {
                Text(timerInterval: timeline.date...target, countsDown: true)
                    .font(.system(size: 20, weight: .bold, design: .default).monospacedDigit())
                    .foregroundStyle(ActivityStyle.primary)
                    .multilineTextAlignment(.trailing)
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
                    .frame(width: 82, alignment: .trailing)
            } else {
                Text("NOW")
                    .font(.system(size: 20, weight: .bold, design: .default))
                    .foregroundStyle(ActivityStyle.primary)
                    .lineLimit(1)
                    .frame(width: 82, alignment: .trailing)
            }
        }
    }
}

private struct CourseCodeView: View {
    let state: ClassActivityAttributes.ContentState

    var body: some View {
        Text(state.displayCourseCode)
            .font(.system(size: 17, weight: .semibold, design: .default))
            .foregroundStyle(ActivityStyle.primary)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
    }
}

private struct LocationView: View {
    let state: ClassActivityAttributes.ContentState

    var body: some View {
        Label(state.location, systemImage: state.locationIconName)
            .font(.system(size: 15, weight: .medium, design: .default))
            .foregroundStyle(ActivityStyle.primary)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
    }
}

private struct CountdownView: View {
    let target: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            if target > timeline.date {
                Text(timerInterval: timeline.date...target, countsDown: true)
                    .font(.system(size: 20, weight: .bold, design: .default).monospacedDigit())
                    .foregroundStyle(ActivityStyle.primary)
                    .multilineTextAlignment(.trailing)
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
                    .frame(width: 82, alignment: .trailing)
            } else {
                Text("NOW")
                    .font(.system(size: 20, weight: .bold, design: .default))
                    .foregroundStyle(ActivityStyle.primary)
                    .lineLimit(1)
                    .frame(width: 82, alignment: .trailing)
            }
        }
    }
}

private struct ExpandedCountdownView: View {
    let target: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            if target > timeline.date {
                Text(timerInterval: timeline.date...target, countsDown: true)
                    .font(.system(size: 32, weight: .semibold, design: .default).monospacedDigit())
                    .foregroundStyle(ActivityStyle.primary)
                    .contentTransition(.numericText())
                    .multilineTextAlignment(.center)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(width: 112, alignment: .center)
            } else {
                Text("NOW")
                    .font(.system(size: 26, weight: .semibold, design: .default))
                    .foregroundStyle(ActivityStyle.primary)
                    .lineLimit(1)
                    .frame(width: 112, alignment: .center)
            }
        }
    }
}

private struct CompactCountdownLeadingView: View {
    let state: ClassActivityAttributes.ContentState
    let isStale: Bool

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            let showCountdown = isStale || state.shouldShowCompactCountdown(now: timeline.date)

            ZStack(alignment: .leading) {
                if showCountdown {
                    compactTimer
                        .transition(.compactCue)
                } else {
                    compactCourse
                        .transition(.compactCue)
                }
            }
            .frame(width: 56, height: 18, alignment: .leading)
            .offset(x: 3)
            .animation(.spring(response: 0.42, dampingFraction: 0.82), value: showCountdown)
        }
    }

    private var compactCourse: some View {
        Text(state.compactCourseCode)
            .font(.system(size: 13, weight: .semibold, design: .default))
            .foregroundStyle(ActivityStyle.primary)
            .lineLimit(1)
    }

    private var compactTimer: some View {
        HStack(spacing: 3) {
            Image(systemName: "clock.fill")
                .font(.system(size: 9, weight: .semibold, design: .default))

            Text(timerInterval: Date.now...state.startTime, countsDown: true)
                .font(.system(size: 13, weight: .semibold, design: .default).monospacedDigit())
                .lineLimit(1)
                .frame(width: 34, alignment: .leading)
        }
        .foregroundStyle(ActivityStyle.red)
    }
}

private struct CompactLocationView: View {
    let state: ClassActivityAttributes.ContentState

    var body: some View {
        Text(state.compactLocation)
            .font(.system(size: 13, weight: .semibold, design: .default))
            .foregroundStyle(ActivityStyle.primary)
            .lineLimit(1)
            .minimumScaleFactor(0.68)
            .frame(width: 54, height: 18, alignment: .trailing)
            .offset(x: -1)
    }
}

private struct MinimalCountdownView: View {
    let target: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { timeline in
            let minutes = max(0, Int(ceil(target.timeIntervalSince(timeline.date) / 60)))

            Text("\(minutes)m")
                .font(.system(size: 11, weight: .bold, design: .default).monospacedDigit())
                .foregroundStyle(ActivityStyle.gold)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }
}

private enum ClassActivityTheme {
    static func color(for endTime: Date, now: Date = .now) -> (background: Color, accent: Color) {
        let remainingSeconds = endTime.timeIntervalSince(now)
        let urgentThreshold: TimeInterval = 5 * 60
        let soonThreshold: TimeInterval = 15 * 60

        switch remainingSeconds {
        case soonThreshold...:
            return (ActivityStyle.softNavy, ActivityStyle.blue)
        case urgentThreshold..<soonThreshold:
            return (ActivityStyle.softNavy, ActivityStyle.gold)
        default:
            return (ActivityStyle.softNavy, ActivityStyle.red)
        }
    }
}

private enum ActivityStyle {
    static let navy = Color(red: 0.0, green: 0.16, blue: 0.36)
    static let softNavy = Color(red: 0.010, green: 0.060, blue: 0.12)
    static let cardTop = Color(red: 0.012, green: 0.095, blue: 0.18)
    static let cardBottom = Color(red: 0.006, green: 0.045, blue: 0.10)
    static let cardSurfaceTop = Color(red: 0.018, green: 0.074, blue: 0.135)
    static let cardSurfaceBottom = Color(red: 0.006, green: 0.035, blue: 0.075)
    static let blue = Color(red: 0.0, green: 0.42, blue: 0.78)
    static let gold = Color(red: 0.98, green: 0.72, blue: 0.25)
    static let red = Color(red: 0.82, green: 0.16, blue: 0.20)
    static let deepRed = Color(red: 0.22, green: 0.035, blue: 0.055)
    static let primary = Color(red: 0.94, green: 0.96, blue: 0.98)
    static let muted = Color(red: 0.66, green: 0.70, blue: 0.76)
}

private extension ClassActivityAttributes.ContentState {
    var locationIconName: String {
        if isAsynchronous {
            return "clock.fill"
        }

        if isOnline {
            return "wifi"
        }

        return "location.fill"
    }
}

private extension AnyTransition {
    static var compactCue: AnyTransition {
        .asymmetric(
            insertion: .modifier(
                active: CompactCueTransitionModifier(yOffset: 15, scale: 0.82, opacity: 0.15, blur: 0.25),
                identity: CompactCueTransitionModifier(yOffset: 0, scale: 1, opacity: 1, blur: 0)
            ),
            removal: .modifier(
                active: CompactCueTransitionModifier(yOffset: -13, scale: 1.10, opacity: 0.10, blur: 0.25),
                identity: CompactCueTransitionModifier(yOffset: 0, scale: 1, opacity: 1, blur: 0)
            )
        )
    }
}

private struct CompactCueTransitionModifier: ViewModifier {
    let yOffset: CGFloat
    let scale: CGFloat
    let opacity: Double
    let blur: CGFloat

    func body(content: Content) -> some View {
        content
            .offset(y: yOffset)
            .scaleEffect(scale)
            .opacity(opacity)
            .blur(radius: blur)
    }
}
