import SwiftUI

/// Shown once, before the displays: what the app is and is not, and how to
/// use it on the road. The app is meant to ride along in a moving vehicle,
/// so this has to be said before the first drive, not buried in a menu.
struct SafetyNoticeView: View {
    static let acceptedKey = "acceptedSafetyNotice"

    var onAccept: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("BEFORE YOU GO")
                    .font(EFIS.label(20))
                    .foregroundStyle(EFIS.amber)

                Text("FlightDeck shows your car's, bike's or flight's motion in the style of an airliner's displays. It is for fun: not a navigation aid, not a certified instrument, and not for flying an aircraft.")
                    .font(.system(size: 16))
                    .foregroundStyle(.white)

                VStack(alignment: .leading, spacing: 12) {
                    point("Mount the device securely and set it up before you set off. Don't look at or operate the app while driving or riding.")
                    point("Speed limits come from OpenStreetMap and may be missing or wrong. Always follow the posted signs.")
                    point("Speed, altitude and attitude come from the phone's GPS and motion sensors and can be inaccurate.")
                    point("Obey traffic laws and keep your eyes on the road.")
                    point("As a passenger, keep the phone in airplane mode and follow the crew's instructions.")
                }

                Button(action: onAccept) {
                    Text("I UNDERSTAND")
                        .font(EFIS.digits(15, .bold))
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(EFIS.cyan, in: RoundedRectangle(cornerRadius: 8))
                }
                .padding(.top, 6)
            }
            .padding(24)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .background(EFIS.background.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled()
    }

    private func point(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("•").foregroundStyle(EFIS.amber)
            Text(text)
                .foregroundStyle(.white.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 15))
    }
}

#Preview {
    SafetyNoticeView {}
}
