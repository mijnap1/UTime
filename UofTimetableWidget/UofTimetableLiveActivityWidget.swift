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

                DynamicIslandExpandedRegion(.trailing) {
                    ExpandedTimerView(state: context.state)
                }

                DynamicIslandExpandedRegion(.bottom) {
                    ExpandedInfoRow(state: context.state)
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
        VStack(alignment: .leading, spacing: 2) {
            Text(state.displayCourseCode)
                .font(.system(size: 22, weight: .semibold, design: .default))
                .foregroundStyle(ActivityStyle.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            if !state.meetingCode.isEmpty {
                Text(state.meetingCode)
                    .font(.system(size: 13, weight: .medium, design: .default))
                    .foregroundStyle(ActivityStyle.muted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 10)
        .padding(.top, 6)
    }
}

/// Countdown on the right with a small label above it, like the Lock Screen card; it turns red once the red cue starts.
private struct ExpandedTimerView: View {
    let state: ClassActivityAttributes.ContentState

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            let now = timeline.date
            let target = state.countdownTarget(now: now)
            let isInClass = now >= state.startTime
            let isRedCue = !isInClass && now >= state.compactCueStart

            VStack(alignment: .trailing, spacing: 0) {
                Text(isInClass ? "ends in" : "starts in")
                    .font(.system(size: 13, weight: .medium, design: .default))
                    .foregroundStyle(ActivityStyle.muted)
                    .lineLimit(1)

                Group {
                    if target > now {
                        Text(timerInterval: now...target, countsDown: true)
                    } else {
                        Text("Now")
                    }
                }
                .font(.system(size: 26, weight: .semibold, design: .default).monospacedDigit())
                .foregroundStyle(isRedCue ? ActivityStyle.brightRed : ActivityStyle.primary)
                .multilineTextAlignment(.trailing)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            }
            .frame(width: 104, alignment: .trailing)
            .padding(.trailing, 10)
            .padding(.top, 6)
        }
    }
}

/// Class progress, then the room and time underneath.
private struct ExpandedInfoRow: View {
    let state: ClassActivityAttributes.ContentState

    var body: some View {
        VStack(spacing: 10) {
            if !state.isAsynchronous && state.endTime > state.startTime {
                // Sits empty before class and fills on its own once class starts.
                ProgressView(timerInterval: state.startTime...state.endTime, countsDown: false) {
                    EmptyView()
                } currentValueLabel: {
                    EmptyView()
                }
                .progressViewStyle(.linear)
                .tint(ActivityStyle.primary)
                .labelsHidden()
            }

            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: state.locationIconName)
                        .font(.system(size: 12, weight: .semibold, design: .default))
                        .foregroundStyle(ActivityStyle.muted)

                    Text(state.location)
                        .font(.system(size: 15, weight: .semibold, design: .default))
                        .foregroundStyle(ActivityStyle.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }

                Spacer(minLength: 8)

                if !state.isAsynchronous {
                    Text(state.classTimeRange)
                        .font(.system(size: 13, weight: .medium, design: .default).monospacedDigit())
                        .foregroundStyle(ActivityStyle.muted)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 12)
        .padding(.bottom, 6)
    }
}

/// Lock Screen card in the app's "Up next" style: the countdown and the room lead, the rest stays quiet.
private struct LockScreenClassActivityView: View {
    let context: ActivityViewContext<ClassActivityAttributes>

    private var state: ClassActivityAttributes.ContentState { context.state }

    /// Class type and delivery, e.g. "Lecture · In Person". Delivery is skipped when the room line already says it.
    private var subtitle: String {
        [state.meetingCode, state.physicalLocation.isEmpty ? "" : state.deliveryLabel]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            let now = timeline.date
            let isInClass = now >= state.startTime
            let isRedCue = !isInClass && now >= state.compactCueStart

            VStack(spacing: 0) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(state.displayCourseCode)
                            .font(ActivityFont.demiBold(21))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)

                        if !subtitle.isEmpty {
                            Text(subtitle)
                                .font(ActivityFont.regular(13))
                                .foregroundStyle(.white.opacity(0.7))
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                    }

                    Spacer(minLength: 8)

                    VStack(alignment: .trailing, spacing: -2) {
                        Text(isInClass ? "ends in" : "starts in")
                            .font(ActivityFont.regular(13))
                            .foregroundStyle(.white.opacity(0.75))

                        countdown(now: now, isRedCue: isRedCue)
                    }
                }

                Spacer(minLength: 10)

                // Room on the left, the short class time across from it under the countdown.
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    HStack(spacing: 6) {
                        Image(systemName: state.locationIconName)
                            .font(.system(size: 13, weight: .medium, design: .default))
                            .foregroundStyle(.white.opacity(0.75))

                        Text(state.location)
                            .font(ActivityFont.medium(21))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    .layoutPriority(1)

                    Spacer(minLength: 8)

                    if !state.isAsynchronous {
                        Text(state.shortTimeRange)
                            .font(ActivityFont.regular(13).monospacedDigit())
                            .foregroundStyle(.white.opacity(0.7))
                            .lineLimit(1)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
            .frame(maxWidth: .infinity, alignment: .leading)
            // Painted here because the system tint alone lets the wallpaper show through.
            .background(LockScreenActivityBackground())
            .overlay(alignment: .bottomTrailing) {
                Image(systemName: state.typeSymbolName)
                    .font(.system(size: 76, weight: .semibold, design: .default))
                    .foregroundStyle(.white.opacity(0.045))
                    .offset(x: 14, y: 22)
            }
            .clipped()
        }
        .activityBackgroundTint(ActivityStyle.uoftNavy)
        .activitySystemActionForegroundColor(.white)
    }

    private func countdown(now: Date, isRedCue: Bool) -> some View {
        let target = state.countdownTarget(now: now)

        return Group {
            if target > now {
                Text(timerInterval: now...target, countsDown: true)
            } else {
                Text("0:00")
            }
        }
        .font(ActivityFont.medium(32).monospacedDigit())
        .tracking(-0.5)
        .foregroundStyle(isRedCue ? ActivityStyle.brightRed : .white)
        .multilineTextAlignment(.trailing)
        .lineLimit(1)
        .minimumScaleFactor(0.6)
        // The timer text claims its widest width, so pin it to the right edge.
        .frame(width: 100, alignment: .trailing)
    }
}

/// Quiet navy depth: a low-contrast fall from UofT navy, a faint light from the top right,
/// a soft sheen and a fine highlight along the top edge, and a gentle shade in the bottom corner.
private struct LockScreenActivityBackground: View {
    var body: some View {
        LinearGradient(
            colors: [ActivityStyle.uoftNavy, ActivityStyle.deepNavy],
            startPoint: .top,
            endPoint: .bottom
        )
        .overlay {
            RadialGradient(
                colors: [ActivityStyle.periwinkle.opacity(0.16), .clear],
                center: .topTrailing,
                startRadius: 0,
                endRadius: 340
            )
        }
        .overlay {
            RadialGradient(
                colors: [.black.opacity(0.22), .clear],
                center: .bottomLeading,
                startRadius: 0,
                endRadius: 260
            )
        }
        .overlay(alignment: .top) {
            LinearGradient(
                colors: [.white.opacity(0.07), .clear],
                startPoint: .top,
                endPoint: .center
            )
        }
        .overlay(alignment: .top) {
            // Light catching the top edge, strongest in the middle.
            LinearGradient(
                colors: [.clear, .white.opacity(0.28), .white.opacity(0.28), .clear],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(height: 0.75)
        }
    }
}

private struct CompactCountdownLeadingView: View {
    let state: ClassActivityAttributes.ContentState
    let isStale: Bool

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            let showCountdown = timeline.date < state.startTime
                && (isStale || state.shouldShowCompactCountdown(now: timeline.date))

            ZStack(alignment: .trailing) {
                if showCountdown {
                    compactTimer(now: timeline.date)
                        .transition(.compactCue)
                } else {
                    compactCourse
                        .transition(.compactCue)
                }
            }
            .frame(width: 50, height: 18, alignment: .trailing)
            .animation(.spring(response: 0.42, dampingFraction: 0.82), value: showCountdown)
        }
    }

    private var compactCourse: some View {
        Text(state.compactCourseCode)
            .font(.system(size: 12.5, weight: .semibold, design: .default))
            .foregroundStyle(ActivityStyle.primary)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
    }

    private func compactTimer(now: Date) -> some View {
        HStack(spacing: 3) {
            Image(systemName: "clock.fill")
                .font(.system(size: 9, weight: .semibold, design: .default))

            if state.startTime > now {
                Text(timerInterval: now...state.startTime, countsDown: true)
                    .font(.system(size: 13, weight: .semibold, design: .default).monospacedDigit())
                    .lineLimit(1)
                    .frame(width: 34, alignment: .leading)
            } else {
                Text("now")
                    .font(.system(size: 13, weight: .semibold, design: .default).monospacedDigit())
                    .lineLimit(1)
                    .frame(width: 34, alignment: .leading)
            }
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
            // Hugs the text so the room sits right beside the camera instead of floating out.
            .frame(maxWidth: 54, minHeight: 18, maxHeight: 18, alignment: .leading)
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
    static let uoftNavy = Color(red: 0.118, green: 0.216, blue: 0.396)
    static let deepNavy = Color(red: 0.055, green: 0.110, blue: 0.225)
    static let periwinkle = Color(red: 0.470, green: 0.580, blue: 0.960)
    static let softNavy = Color(red: 0.010, green: 0.060, blue: 0.12)
    static let blue = Color(red: 0.0, green: 0.42, blue: 0.78)
    static let gold = Color(red: 0.98, green: 0.72, blue: 0.25)
    static let red = Color(red: 0.82, green: 0.16, blue: 0.20)
    static let brightRed = Color(red: 1.0, green: 0.42, blue: 0.40)
    static let primary = Color(red: 0.94, green: 0.96, blue: 0.98)
    static let muted = Color(red: 0.66, green: 0.70, blue: 0.76)
}

/// Same Avenir Next weights as the app's AppFont.
private enum ActivityFont {
    static func regular(_ size: CGFloat) -> Font {
        .custom("AvenirNext-Regular", size: size)
    }

    static func medium(_ size: CGFloat) -> Font {
        .custom("AvenirNext-Medium", size: size)
    }

    static func demiBold(_ size: CGFloat) -> Font {
        .custom("AvenirNext-DemiBold", size: size)
    }
}

private extension ClassActivityAttributes.ContentState {
    /// Same class-type icons as the app's cards.
    var typeSymbolName: String {
        let type = meetingType.lowercased()
        if type.hasPrefix("tut") { return "person.2.fill" }
        if type.hasPrefix("lab") || type.hasPrefix("pra") { return "flask.fill" }
        if type.hasPrefix("sem") { return "bubble.left.and.bubble.right.fill" }
        return "graduationcap.fill"
    }

    /// Short class time, e.g. "9 – 11 AM", "9:30 – 11 AM" or "11 AM – 1 PM".
    var shortTimeRange: String {
        let calendar = Calendar.current
        let formatter = DateFormatter()
        formatter.locale = .current

        func clock(_ date: Date) -> String {
            formatter.dateFormat = calendar.component(.minute, from: date) == 0 ? "h" : "h:mm"
            return formatter.string(from: date)
        }

        func period(_ date: Date) -> String {
            calendar.component(.hour, from: date) < 12 ? formatter.amSymbol : formatter.pmSymbol
        }

        if period(startTime) == period(endTime) {
            return "\(clock(startTime)) – \(clock(endTime)) \(period(endTime))"
        }

        return "\(clock(startTime)) \(period(startTime)) – \(clock(endTime)) \(period(endTime))"
    }

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
