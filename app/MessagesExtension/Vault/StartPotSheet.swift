import SwiftUI

/// Dead-simple "start a pot in this chat" over iMessage: name it, pick an emoji,
/// tap Start. People count and member slots come from the chat itself, so
/// there's nothing else to configure.
struct StartPotSheet: View {
    let onStart: (_ name: String, _ emoji: String) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var emoji = "🍯"
    private let choices = ["🍯", "🐷", "🎉", "✈️", "🏠", "🎁", "🍕", "⚽️", "🌮", "🏖️", "🎄", "🍻", "💰", "🚗", "🐶"]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Text(emoji).font(.system(size: 30))
                        TextField("Name your pot (e.g. Ski Trip)", text: $name)
                            .font(.system(.body, design: .rounded))
                    }
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(choices, id: \.self) { e in
                                Text(e).font(.system(size: 26))
                                    .frame(width: 40, height: 40)
                                    .background(Circle().fill(emoji == e ? Brand.orange.opacity(0.2) : Color(.tertiarySystemFill)))
                                    .overlay(Circle().strokeBorder(Brand.orange, lineWidth: emoji == e ? 2 : 0))
                                    .onTapGesture { emoji = e; Haptics.tap() }
                            }
                        }.padding(.vertical, 2)
                    }
                } footer: {
                    Text("Everyone in this chat shares the pot. Approving a spend takes any 2 of you.")
                }

                Section {
                    Button {
                        onStart(name.trimmingCharacters(in: .whitespaces), emoji)
                        dismiss()
                    } label: {
                        Label("Start pot", systemImage: "sparkles").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(ProminentButtonStyle())
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                    .listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
                }
            }
            .navigationTitle("New Pot").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}
