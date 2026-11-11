import SwiftUI

/// Title row shared by the custom sheets: large title, quiet subtitle and a round close or back button.
struct SheetHeader: View {
    let title: String
    var subtitle: String? = nil
    var showsBack = false
    let onClose: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            if showsBack {
                roundButton(systemImage: "chevron.left", label: "Back")
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(AppFont.medium(26))
                    .tracking(-0.4)
                    .foregroundStyle(AppTheme.navy)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                if let subtitle {
                    Text(subtitle)
                        .font(AppFont.regular(14))
                        .foregroundStyle(AppTheme.secondaryText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
            }

            Spacer(minLength: 0)

            if !showsBack {
                roundButton(systemImage: "xmark", label: "Close")
            }
        }
        .padding(.top, 28)
        .padding(.bottom, 8)
    }

    private func roundButton(systemImage: String, label: String) -> some View {
        Button(action: onClose) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .semibold, design: .default))
                .foregroundStyle(AppTheme.navy)
                .frame(width: 40, height: 40)
                .background { CardSurface(cornerRadius: 20) }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// Small uppercase label above a group, matching the program picker sections.
struct SheetSectionLabel: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title.uppercased())
            .font(AppFont.semibold(12))
            .tracking(1)
            .foregroundStyle(AppTheme.secondaryText)
            .padding(.horizontal, 4)
    }
}

/// Quiet helper text under a group.
struct SheetFootnote: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(AppFont.regular(13))
            .foregroundStyle(AppTheme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 4)
    }
}

/// Hairline between rows inside a card.
struct SheetDivider: View {
    var leading: CGFloat = 16

    var body: some View {
        Rectangle()
            .fill(AppTheme.border.opacity(0.8))
            .frame(height: 0.75)
            .padding(.leading, leading)
    }
}

/// Icon and text field row used inside sheet cards.
struct SheetTextFieldRow: View {
    let placeholder: String
    @Binding var text: String
    let systemImage: String
    var capitalization: TextInputAutocapitalization = .sentences

    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .semibold, design: .default))
                .foregroundStyle(isFocused ? AppTheme.blue : AppTheme.secondaryText)
                .frame(width: 20)

            TextField(placeholder, text: $text)
                .font(AppFont.medium(16))
                .foregroundStyle(AppTheme.primaryText)
                .textInputAutocapitalization(capitalization)
                .autocorrectionDisabled()
                .focused($isFocused)
        }
        .padding(.horizontal, 16)
        .frame(height: 54)
        .contentShape(Rectangle())
        .onTapGesture { isFocused = true }
        .animation(.smooth(duration: 0.2), value: isFocused)
    }
}

/// Pill used for single choices such as meeting type and day.
struct SheetChip: View {
    let title: String
    let isSelected: Bool
    var height: CGFloat = 38
    let action: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)

        Button(action: action) {
            Text(title)
                .font(isSelected ? AppFont.semibold(14) : AppFont.medium(14))
                .foregroundStyle(isSelected ? Color.white : AppTheme.primaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .frame(maxWidth: .infinity)
                .frame(height: height)
                .background {
                    shape.fill(isSelected ? AppTheme.blue : AppTheme.field)
                        .overlay {
                            if !isSelected {
                                shape.strokeBorder(AppTheme.border.opacity(0.8), lineWidth: 0.75)
                            }
                        }
                }
                .contentShape(shape)
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .animation(.smooth(duration: 0.2), value: isSelected)
    }
}

/// Main capsule button for the bottom of a sheet.
struct SheetPrimaryButton: View {
    let title: String
    var systemImage: String? = nil
    var isEnabled = true
    var isLoading = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if isLoading {
                    ProgressView()
                        .tint(.white)
                        .controlSize(.small)
                }

                Text(title)
                    .font(AppFont.semibold(17))

                if let systemImage, !isLoading {
                    Image(systemName: systemImage)
                        .font(.system(size: 15, weight: .semibold, design: .default))
                }
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .background(AppTheme.blue, in: Capsule())
            .shadow(color: isEnabled ? AppTheme.blue.opacity(0.22) : .clear, radius: 14, y: 7)
        }
        .buttonStyle(PressableButtonStyle())
        .opacity(isEnabled ? 1 : 0.4)
        .disabled(!isEnabled || isLoading)
        .animation(.smooth(duration: 0.2), value: isEnabled)
    }
}

extension View {
    /// Pins content to the bottom of a sheet over a soft fade of the page background.
    func sheetBottomBar<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 12) {
                content()
            }
            .padding(.horizontal, 22)
            .padding(.top, 12)
            .padding(.bottom, 8)
            .background {
                // Solid behind the controls so nothing shows through; the fade sits above the bar.
                AppTheme.background
                    .ignoresSafeArea()
                    .overlay(alignment: .top) {
                        LinearGradient(
                            colors: [AppTheme.background.opacity(0), AppTheme.background],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .frame(height: 28)
                        .offset(y: -28)
                        .allowsHitTesting(false)
                    }
            }
        }
    }

    /// Shared presentation for the custom sheets.
    func customSheetPresentation() -> some View {
        background { AppBackground() }
            .presentationDragIndicator(.visible)
            .presentationCornerRadius(32)
    }
}
