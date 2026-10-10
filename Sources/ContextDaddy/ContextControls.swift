import SwiftUI

struct ContextChoice<Value: Hashable> {
    let value: Value
    let title: String

    init(_ value: Value, _ title: String) {
        self.value = value
        self.title = title
    }
}

struct ContextModeToggle<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let choices: [ContextChoice<Value>]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(choices.indices, id: \.self) { index in
                let choice = choices[index]
                Button { selection = choice.value } label: {
                    Text(choice.title.lowercased())
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 12)
                        .frame(height: 30)
                        .foregroundStyle(selection == choice.value ? Color.black : DaddyTheme.muted)
                        .background(selection == choice.value ? DaddyTheme.mint : .clear, in: RoundedRectangle(cornerRadius: 7))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(title): \(choice.title)")
                .accessibilityValue(selection == choice.value ? "Selected" : "Not selected")
            }
        }
        .padding(3)
        .background(DaddyTheme.raised, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(DaddyTheme.line))
    }
}

struct ContextChoiceMenu<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let choices: [ContextChoice<Value>]
    var width: CGFloat = 160

    private var selectedTitle: String {
        choices.first { $0.value == selection }?.title ?? "Choose"
    }

    var body: some View {
        Menu {
            ForEach(choices.indices, id: \.self) { index in
                let choice = choices[index]
                Button { selection = choice.value } label: {
                    if selection == choice.value {
                        Label(choice.title, systemImage: "checkmark")
                    } else {
                        Text(choice.title)
                    }
                }
            }
        } label: {
            HStack(spacing: 7) {
                Text(title.lowercased())
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .tracking(0.5)
                    .foregroundStyle(DaddyTheme.muted)
                Text(selectedTitle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(DaddyTheme.mint)
                    .lineLimit(1)
                Spacer(minLength: 2)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(DaddyTheme.muted)
            }
            .padding(.horizontal, 10)
            .frame(width: width, height: 32)
            .background(DaddyTheme.raised, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(DaddyTheme.line))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(selectedTitle)
    }
}
