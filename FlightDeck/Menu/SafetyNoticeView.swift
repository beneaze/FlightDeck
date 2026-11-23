import SwiftUI

/// Shown once, before the displays: what the app is and is not, and how to
/// use it on board. The app is meant to ride along on a flight (and, while
/// the road modes remain, in a car or on a bike), so this has to be said
/// before the first use, not buried in a menu.
struct SafetyNoticeView: View {
    static let acceptedKey = "acceptedSafetyNotice"

    var onAccept: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("BEFORE YOU GO")
                    .font(EFIS.label(20))
                    .foregroundStyle(EFIS.amber)

                Text("CockpitView follows your flight from your seat in the cabin and shows it the way the pilots see it, on airliner-style displays. It is for fun: not a navigation aid, not a certified instrument, and not for flying an aircraft.")
                    .font(.system(size: 16))
                    .foregroundStyle(.white)

                VStack(alignment: .leading, spacing: 12) {
                    point("On board, keep the phone in airplane mode and follow the crew's instructions on using devices.")
                    point("Speed, altitude and position come from the phone's GPS and can be inaccurate or drop out. A window seat gives the best reception.")
                    point("The flight path is the planned route you load or enter. The route the crew actually flies can differ.")
                    point("In a car or on a bike, set the app up before you set off and never use it while driving or riding. Speed limits come from OpenStreetMap and may be wrong: follow the posted signs.")
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
