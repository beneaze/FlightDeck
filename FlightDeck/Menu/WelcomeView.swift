import SwiftUI

/// The guide shown on first start, before the displays: what the app is,
/// how to get around it (the two swipes), the three modes, how the MCDU
/// takes entries, how a flight and a road route are set up, and last the
/// safety notes the user accepts. It can be opened again from the MCDU
/// MENU page.
///
/// Deliberately not in the displays' colours: the EFIS cyan and amber are
/// made for small symbols on a dark screen, not for reading paragraphs, so
/// the guide uses plain white type on a night-blue ground and keeps the
/// cockpit colours for its small illustrations of the screens.
struct WelcomeView: View {
    /// Set once the guide has been read and its notes accepted.
    static let seenKey = "seenWelcomeGuide1"

    /// Key and page names follow the selected flight deck.
    var isBoeing: Bool
    /// Opened again from the MCDU: the notes were accepted before, so the
    /// guide can be closed from any page.
    var isReplay = false
    var onDone: () -> Void

    @State private var page = 0
    private let pageCount = 7

    var body: some View {
        GeometryReader { geo in
            let landscape = geo.size.width > geo.size.height
            ZStack {
                Guide.background.ignoresSafeArea()
                VStack(spacing: 0) {
                    topBar
                    TabView(selection: $page) {
                        ForEach(0..<pageCount, id: \.self) { i in
                            pageView(i, landscape: landscape).tag(i)
                        }
                    }
                    .tabViewStyle(.page(indexDisplayMode: .never))
                    bottomBar(landscape: landscape)
                }
            }
        }
        .preferredColorScheme(.dark)
        .statusBarHidden(true)
        .interactiveDismissDisabled()
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }

    // MARK: Chrome

    private var isLastPage: Bool { page == pageCount - 1 }

    private var topBar: some View {
        HStack {
            Text("CockpitView")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Guide.secondary)
            Spacer()
            if isReplay {
                Button(action: onDone) {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white.opacity(0.8))
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(Color.white.opacity(0.1)))
                }
                .accessibilityLabel("Close")
            } else if !isLastPage {
                Button("Skip") { withAnimation { page = pageCount - 1 } }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Guide.secondary)
            }
        }
        .frame(height: 32)
        .padding(.horizontal, 20)
        .padding(.top, 10)
    }

    private func bottomBar(landscape: Bool) -> some View {
        HStack(spacing: 20) {
            HStack(spacing: 7) {
                ForEach(0..<pageCount, id: \.self) { i in
                    Capsule()
                        .fill(i == page ? Color.white : Color.white.opacity(0.25))
                        .frame(width: i == page ? 18 : 7, height: 7)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: page)
            .accessibilityElement()
            .accessibilityLabel("Page \(page + 1) of \(pageCount)")

            Spacer(minLength: 0)

            Button {
                if isLastPage { onDone() } else { withAnimation { page += 1 } }
            } label: {
                Text(isLastPage ? (isReplay ? "Done" : "I Understand") : "Continue")
                    .font(.headline)
                    .foregroundStyle(Guide.ink)
                    .padding(.horizontal, 26)
                    .frame(minWidth: 150, minHeight: 50)
                    .background(Capsule().fill(Color.white))
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 8)
        .padding(.bottom, landscape ? 10 : 18)
    }

    // MARK: Names on the selected unit

    private var unit: String { isBoeing ? "CDU" : "MCDU" }
    private var panel: String { isBoeing ? "737 MCP" : "A320 FCU" }
    private var menuKey: String { isBoeing ? "MENU" : "MCDU MENU" }
    private var routeKey: String { isBoeing ? "RTE" : "INIT" }
    private var legsKey: String { isBoeing ? "LEGS" : "F-PLN" }
    private var progressKey: String { isBoeing ? "PROG" : "PROG" }
    private var requestPrompt: String { isBoeing ? "RTE REQUEST" : "INIT REQUEST" }

    /// A key or page name in running text.
    private func key(_ name: String) -> Text {
        Text(name)
            .font(.system(.subheadline, design: .monospaced).weight(.semibold))
            .foregroundStyle(Guide.accent)
    }

    // MARK: Pages

    @ViewBuilder
    private func pageView(_ index: Int, landscape: Bool) -> some View {
        switch index {
        case 0: welcomePage(landscape)
        case 1: swipesPage(landscape)
        case 2: modesPage(landscape)
        case 3: unitPage(landscape)
        case 4: flightPage(landscape)
        case 5: roadPage(landscape)
        default: safetyPage(landscape)
        }
    }

    private func welcomePage(_ landscape: Bool) -> some View {
        GuidePage(landscape: landscape, eyebrow: "Welcome aboard", title: "Your jump seat in the cabin") {
            DeviceSketch()
        } content: {
            Paragraph("CockpitView turns your phone into an airliner's glass cockpit and follows your flight from your seat, the way the pilots see it.")
            VStack(alignment: .leading, spacing: 16) {
                GuideRow(icon: "gauge.with.dots.needle.67percent", title: "Primary flight display",
                         text: Text("Attitude, speed, altitude and vertical speed, in the top half."))
                GuideRow(icon: "location.north.line", title: "Navigation display",
                         text: Text("Your route, the next waypoints and the terrain ahead, below it."))
                GuideRow(icon: "antenna.radiowaves.left.and.right.slash", title: "Works in airplane mode",
                         text: Text("GPS keeps running without a connection. Download your flight before you board."))
            }
            .padding(.top, 4)
        }
    }

    private func swipesPage(_ landscape: Bool) -> some View {
        GuidePage(landscape: landscape, eyebrow: "Getting around", title: "Two swipes") {
            SwipeSketch(unit: unit, panel: isBoeing ? "MCP" : "FCU")
        } content: {
            VStack(alignment: .leading, spacing: 16) {
                GuideRow(icon: "hand.point.right", title: "Swipe right: the \(unit)",
                         text: Text("Plan your flight or route, switch modes and change settings. Swipe left or tap \(key("DISPLAYS")) to return."))
                GuideRow(icon: "hand.point.left", title: "Swipe left: the glareshield",
                         text: Text("The \(panel) and EFIS panel: heading, speed, altitude and vertical speed targets, the approach modes and terrain on the ND. Swipe right to return."))
                GuideRow(icon: "info.circle", tint: Guide.secondary, title: "The displays follow the panel",
                         text: Text("Targets, flight director and modes show up on the PFD and ND as in the real cockpit. Nothing you set flies anything."))
            }
        }
    }

    private func modesPage(_ landscape: Bool) -> some View {
        GuidePage(landscape: landscape, eyebrow: "Three modes", title: "Plane, car or bike") {
            ModesSketch()
        } content: {
            VStack(alignment: .leading, spacing: 16) {
                GuideRow(icon: "airplane", title: "Plane, the default",
                         text: Text("For your seat on board. Attitude from the phone's motion sensors, position, speed and altitude from GPS, the route from your flight plan."))
                GuideRow(icon: "car.fill", title: "Car",
                         text: Text("Turns a road trip into a flight: the route from Apple Maps, the speed limit from OpenStreetMap."))
                GuideRow(icon: "bicycle", title: "Bike",
                         text: Text("The same with cycling routes."))
            }
            Paragraph(Text("Switch modes on the \(key(menuKey)) page of the \(unit)."))
        }
    }

    private func unitPage(_ landscape: Bool) -> some View {
        GuidePage(landscape: landscape, eyebrow: "The \(unit)", title: "Scratchpad and line keys") {
            UnitSketch(page: routeKey)
        } content: {
            Paragraph("The \(unit) works like the real one. Type on its keypad and the text appears on the bottom line, the scratchpad. Then press the key beside the field it belongs in.")
            VStack(alignment: .leading, spacing: 16) {
                GuideRow(icon: "rectangle.dashed", title: "Boxes ask for an entry",
                         text: Text("Prompts with \(key("<")) or \(key(">")) open another page, \(key("*")) carries out an action."))
                GuideRow(icon: "delete.left", title: "CLR",
                         text: Text("Clears the scratchpad. Press \(key("CLR")) with it empty, then a line key, to delete that entry."))
                GuideRow(icon: "exclamationmark.bubble", title: "Messages",
                         text: Text("\(key("NOT IN DATA BASE")) or \(key("FORMAT ERROR")) appear in the scratchpad. \(key("CLR")) and try again."))
            }
        }
    }

    private func flightPage(_ landscape: Bool) -> some View {
        GuidePage(landscape: landscape, eyebrow: "Plane mode", title: "Setting up your flight") {
            RouteSketch(road: false)
        } content: {
            VStack(alignment: .leading, spacing: 14) {
                GuideStep(1, Text("Open the \(unit) and press \(key(routeKey))."))
                GuideStep(2, Text("Type your flight number, like \(key("LH128")), and press the key beside \(key("FLT NBR")). Or enter the airports as ICAO codes beside \(key("FROM/TO")), like \(key("EDDF/KJFK"))."))
                GuideStep(3, Text("For the full route, enter your SimBrief username beside \(key("SIMBRIEF")) and press \(key(requestPrompt)). Or build it on \(key(legsKey)): type a waypoint and press the key beside the fix it goes before."))
                GuideStep(4, isBoeing
                          ? Text("Pick runways, departure and arrival with \(key("DEP ARR")).")
                          : Text("Pick runways, departure and arrival: on \(key("F-PLN")), press the key beside an airport."))
                GuideStep(5, Text("Still on Wi-Fi, press \(key("DOWNLOAD")) for the offline map and terrain, then \(key("ACTIVATE"))."))
                GuideStep(6, Text("On board, turn on airplane mode. A window seat gives the best GPS."))
            }
            Footnote("Departure and arrival procedures come with the app for US airports. For the rest of the world, import X-Plane navigation data on the settings page.")
        }
    }

    private func roadPage(_ landscape: Bool) -> some View {
        GuidePage(landscape: landscape, eyebrow: "Car and bike", title: "Planning a road route") {
            RouteSketch(road: true)
        } content: {
            VStack(alignment: .leading, spacing: 14) {
                GuideStep(1, Text("Choose \(key("CAR")) or \(key("BIKE")) on the \(key(menuKey)) page."))
                GuideStep(2, Text("On \(key(routeKey)), type a destination, like \(key("ZURICH HB")), and press the key beside \(key("DEST"))."))
                GuideStep(3, Text("Pick the place from the results and press \(key("FLY"))."))
                GuideStep(4, Text("Or press \(key("MAP>")) and choose the destination on the map."))
                GuideStep(5, Text("The route appears on the ND, distance and arrival time on \(key(progressKey))."))
            }
            Footnote("Set everything up before you set off. Never use the app while driving or riding.")
        }
    }

    private func safetyPage(_ landscape: Bool) -> some View {
        GuidePage(landscape: landscape, eyebrow: "Before you go", title: "A few things to know", artHeight: 96) {
            SafetySketch()
        } content: {
            Paragraph("CockpitView is for fun. It is not a navigation aid, not a certified instrument and not for flying an aircraft.")
            VStack(alignment: .leading, spacing: 16) {
                GuideRow(icon: "airplane.circle", tint: Guide.warm, title: "On board",
                         text: Text("Keep the phone in airplane mode and follow the crew's instructions on using devices."))
                GuideRow(icon: "location.slash", tint: Guide.warm, title: "GPS can be wrong",
                         text: Text("Speed, altitude and position come from the phone's GPS and can be inaccurate or drop out."))
                GuideRow(icon: "point.topleft.down.to.point.bottomright.curvepath", tint: Guide.warm, title: "The route is the plan",
                         text: Text("The flight path is the planned route you load or enter. The route the crew actually flies can differ."))
                GuideRow(icon: "car.side", tint: Guide.warm, title: "On the road",
                         text: Text("Set the app up before you set off and never use it while driving or riding. Speed limits come from OpenStreetMap and may be wrong: follow the posted signs."))
            }
        }
    }
}

// MARK: - Look

/// The guide's own palette: a night-blue ground, white type, one calm
/// accent for key names and a warm tone for the safety notes.
enum Guide {
    static let top = Color(red: 0.07, green: 0.12, blue: 0.22)       // #121F38
    static let bottom = Color(red: 0.02, green: 0.03, blue: 0.06)    // #05080F
    static let ink = Color(red: 0.05, green: 0.08, blue: 0.15)
    static let accent = Color(red: 0.49, green: 0.74, blue: 1.0)     // #7DBDFF
    static let warm = Color(red: 0.98, green: 0.76, blue: 0.38)      // #FAC261
    static let secondary = Color.white.opacity(0.68)

    static var background: some View {
        ZStack {
            LinearGradient(colors: [top, bottom], startPoint: .top, endPoint: .bottom)
            // A faint glow low on the screen, like the horizon at dusk.
            RadialGradient(colors: [accent.opacity(0.14), .clear], center: .init(x: 0.5, y: 1.05),
                           startRadius: 0, endRadius: 520)
        }
    }
}

/// One page: an illustration and the text, above each other in portrait
/// and side by side in landscape.
private struct GuidePage<Art: View, Content: View>: View {
    let landscape: Bool
    let eyebrow: String
    let title: String
    /// The illustration's height in portrait.
    var artHeight: CGFloat = 210
    @ViewBuilder var art: Art
    @ViewBuilder var content: Content

    var body: some View {
        if landscape {
            HStack(spacing: 36) {
                art
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.vertical, 12)
                ScrollView {
                    text.padding(.top, 16).padding(.bottom, 28)
                }
                .scrollBounceBehavior(.basedOnSize)
                .scrollIndicators(.hidden)
                .mask(fade)
                .frame(maxWidth: 520)
            }
            .padding(.horizontal, 36)
        } else {
            ScrollView {
                VStack(spacing: 26) {
                    art.frame(height: artHeight)
                    text
                }
                .padding(.horizontal, 24)
                .padding(.top, 12)
                .padding(.bottom, 28)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollIndicators(.hidden)
            .mask(fade)
        }
    }

    /// Text fades out above the bottom bar rather than being cut off.
    private var fade: some View {
        VStack(spacing: 0) {
            Color.black
            LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: 28)
        }
    }

    private var text: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(eyebrow.uppercased())
                    .font(.caption.weight(.bold))
                    .tracking(1.4)
                    .foregroundStyle(Guide.accent)
                Text(title)
                    .font(.title.weight(.bold))
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct Paragraph: View {
    let text: Text
    init(_ string: String) { text = Text(string) }
    init(_ text: Text) { self.text = text }

    var body: some View {
        text
            .font(.body)
            .foregroundStyle(.white.opacity(0.88))
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct Footnote: View {
    let string: String
    init(_ string: String) { self.string = string }

    var body: some View {
        Text(string)
            .font(.footnote)
            .foregroundStyle(Guide.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.06)))
    }
}

private struct GuideRow: View {
    let icon: String
    var tint: Color = Guide.accent
    let title: String
    let text: Text

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 36, height: 36)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(tint.opacity(0.14)))
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.white)
                text
                    .font(.subheadline)
                    .foregroundStyle(Guide.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct GuideStep: View {
    let number: Int
    let text: Text
    init(_ number: Int, _ text: Text) {
        self.number = number
        self.text = text
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("\(number)")
                .font(.footnote.weight(.bold).monospacedDigit())
                .foregroundStyle(Guide.ink)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Guide.accent))
                .alignmentGuide(.firstTextBaseline) { $0[.firstTextBaseline] + 1 }
            text
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Illustrations

/// A phone with the two displays, drawn simply.
private struct DeviceSketch: View {
    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            let w = h * 0.5
            ZStack {
                Circle()
                    .fill(RadialGradient(colors: [Guide.accent.opacity(0.18), .clear],
                                         center: .center, startRadius: 0, endRadius: h * 0.55))
                    .frame(width: h * 1.1, height: h * 1.1)
                PhoneFrame { MiniDisplays() }
                    .frame(width: w, height: h)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct PhoneFrame<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        GeometryReader { geo in
            let r = geo.size.width * 0.16
            let inset = geo.size.width * 0.045
            ZStack {
                RoundedRectangle(cornerRadius: r, style: .continuous)
                    .fill(Color.black)
                content
                    .clipShape(RoundedRectangle(cornerRadius: r - inset, style: .continuous))
                    .padding(inset)
                RoundedRectangle(cornerRadius: r, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.22), lineWidth: max(2, geo.size.width * 0.018))
            }
        }
    }
}

/// The PFD over the ND, in muted colours.
private struct MiniDisplays: View {
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            VStack(spacing: 2) {
                // PFD: a tilted horizon between two tapes.
                ZStack {
                    Color(white: 0.03)
                    ZStack {
                        VStack(spacing: 0) {
                            Color(red: 0.16, green: 0.42, blue: 0.70)
                            Color(red: 0.45, green: 0.27, blue: 0.11)
                        }
                        Rectangle().fill(Color.white.opacity(0.9)).frame(height: 1)
                        ForEach([-2, -1, 1, 2], id: \.self) { i in
                            Rectangle().fill(Color.white.opacity(0.7))
                                .frame(width: w * (i % 2 == 0 ? 0.22 : 0.12), height: 1)
                                .offset(y: CGFloat(i) * h * 0.035)
                        }
                    }
                    .frame(width: w * 1.2, height: h)
                    .rotationEffect(.degrees(-12))
                    .frame(width: w * 0.56, height: h * 0.3)
                    .clipped()
                    // The aircraft symbol.
                    HStack(spacing: w * 0.08) {
                        Rectangle().frame(width: w * 0.12, height: 3)
                        Rectangle().frame(width: 4, height: 4)
                        Rectangle().frame(width: w * 0.12, height: 3)
                    }
                    .foregroundStyle(EFIS.yellow)
                    HStack {
                        tape
                        Spacer()
                        tape
                    }
                    .padding(.horizontal, w * 0.04)
                }
                .frame(height: h * 0.44)

                // ND: a compass arc, the route and the aircraft.
                ZStack {
                    Color(white: 0.03)
                    Canvas { context, size in
                        let center = CGPoint(x: size.width / 2, y: size.height * 0.9)
                        let radius = min(size.height * 0.74, size.width * 0.62)
                        var arc = Path()
                        arc.addArc(center: center, radius: radius, startAngle: .degrees(-140),
                                   endAngle: .degrees(-40), clockwise: false)
                        context.stroke(arc, with: .color(.white.opacity(0.7)), lineWidth: 1)
                        for i in 0...10 {
                            let a = Angle.degrees(-140 + Double(i) * 10).radians
                            let p1 = CGPoint(x: center.x + cos(a) * radius, y: center.y + sin(a) * radius)
                            let p2 = CGPoint(x: center.x + cos(a) * (radius - (i % 3 == 0 ? 6 : 3)),
                                             y: center.y + sin(a) * (radius - (i % 3 == 0 ? 6 : 3)))
                            var tick = Path()
                            tick.move(to: p1)
                            tick.addLine(to: p2)
                            context.stroke(tick, with: .color(.white.opacity(0.7)), lineWidth: 1)
                        }
                        var route = Path()
                        route.move(to: center)
                        let fixes = [CGPoint(x: size.width * 0.56, y: size.height * 0.58),
                                     CGPoint(x: size.width * 0.66, y: size.height * 0.3)]
                        fixes.forEach { route.addLine(to: $0) }
                        context.stroke(route, with: .color(EFIS.green.opacity(0.85)), lineWidth: 1.5)
                        for p in fixes {
                            context.stroke(Path(ellipseIn: CGRect(x: p.x - 2.5, y: p.y - 2.5, width: 5, height: 5)),
                                           with: .color(.white), lineWidth: 1)
                        }
                        var plane = Path()
                        plane.move(to: CGPoint(x: center.x, y: center.y - 8))
                        plane.addLine(to: CGPoint(x: center.x - 5, y: center.y + 3))
                        plane.addLine(to: CGPoint(x: center.x + 5, y: center.y + 3))
                        plane.closeSubpath()
                        context.stroke(plane, with: .color(EFIS.yellow), lineWidth: 1.5)
                    }
                }
            }
            .background(Color(white: 0.2))
        }
    }

    private var tape: some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(Color(white: 0.32))
            .frame(width: 10)
            .padding(.vertical, 14)
    }
}

/// The phone between the two swipes, with arrows that drift the way the
/// finger goes.
private struct SwipeSketch: View {
    let unit: String
    let panel: String
    @State private var drift = false

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            HStack(spacing: 14) {
                chip(icon: "arrow.left", text: panel, direction: -1)
                PhoneFrame { MiniDisplays() }
                    .frame(width: h * 0.46, height: h * 0.92)
                chip(icon: "arrow.right", text: unit, direction: 1)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { drift = true }
        }
    }

    private func chip(icon: String, text: String, direction: CGFloat) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(Guide.accent)
                .offset(x: drift ? direction * 6 : -direction * 2)
            Text(text)
                .font(.caption.weight(.bold))
                .foregroundStyle(.white.opacity(0.8))
        }
        .frame(width: 64, height: 64)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.white.opacity(0.07)))
        .accessibilityHidden(true)
    }
}

private struct ModesSketch: View {
    var body: some View {
        HStack(spacing: 12) {
            tile("car.fill", "CAR", isDefault: false)
            tile("airplane", "PLANE", isDefault: true)
            tile("bicycle", "BIKE", isDefault: false)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityHidden(true)
    }

    private func tile(_ icon: String, _ name: String, isDefault: Bool) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: isDefault ? 34 : 26, weight: .semibold))
                .foregroundStyle(isDefault ? Guide.accent : .white.opacity(0.7))
                .frame(height: 40)
            Text(name)
                .font(.system(.caption, design: .monospaced).weight(.bold))
                .foregroundStyle(.white.opacity(isDefault ? 0.95 : 0.6))
            if isDefault {
                Text("DEFAULT")
                    .font(.system(size: 9, weight: .heavy))
                    .tracking(0.8)
                    .foregroundStyle(Guide.ink)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Guide.accent))
            }
        }
        .frame(width: isDefault ? 104 : 84, height: isDefault ? 132 : 108)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.white.opacity(isDefault ? 0.1 : 0.05))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(isDefault ? Guide.accent.opacity(0.6) : .white.opacity(0.08), lineWidth: 1)))
    }
}

/// A slice of the MCDU screen: a field with its line key, and the entry
/// waiting in the scratchpad. The key beside the field pulses.
private struct UnitSketch: View {
    let page: String
    @State private var pulse = false

    private let row: CGFloat = 25
    private let keyColumn: CGFloat = 36

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(white: 0.16))
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.black)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.white.opacity(0.12)))
                .frame(width: 200, height: row * 7 + 16)
                .offset(x: keyColumn + 8, y: 14)
            VStack(alignment: .leading, spacing: 0) {
                line(Text(page).frame(width: 184), key: nil)
                line(Text("FLT NBR").font(mono(11)).foregroundStyle(.white), key: nil)
                line(Text("        ").overlay(MCDUBoxes(count: 8, color: EFIS.amber, fontSize: 15)), key: true)
                line(Text("DATE").font(mono(11)).foregroundStyle(.white), key: nil)
                line(Text("24NOV").foregroundStyle(EFIS.cyan), key: false)
                line(Text(""), key: nil)
                line(Text("LH128").foregroundStyle(.white), key: nil)
            }
            .font(mono(15))
            .foregroundStyle(.white)
            .offset(y: 22)
        }
        .frame(width: keyColumn + 224, height: row * 7 + 44)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityHidden(true)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { pulse = true }
        }
    }

    /// One screen line, with its line-select key beside it when it has one.
    private func line(_ text: some View, key lit: Bool?) -> some View {
        HStack(spacing: 0) {
            ZStack {
                if let lit {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color(white: 0.32))
                        .frame(width: 22, height: 14)
                        .overlay(RoundedRectangle(cornerRadius: 3)
                            .strokeBorder(Guide.accent, lineWidth: 2)
                            .opacity(lit ? (pulse ? 1 : 0.15) : 0))
                }
            }
            .frame(width: keyColumn, alignment: .trailing)
            text
                .padding(.leading, 16)
        }
        .frame(height: row, alignment: .leading)
    }

    private func mono(_ size: CGFloat) -> Font {
        .system(size: size, weight: .semibold, design: .monospaced)
    }
}

/// A route on the ND: a flight's straight legs between waypoints, or a
/// road's winding line to a flag.
private struct RouteSketch: View {
    let road: Bool

    var body: some View {
        Canvas { context, size in
            let s = min(size.width, size.height)
            let center = CGPoint(x: size.width / 2, y: size.height / 2 + s * 0.42)
            let radius = s * 0.78
            // Compass arc.
            var arc = Path()
            arc.addArc(center: center, radius: radius, startAngle: .degrees(-140),
                       endAngle: .degrees(-40), clockwise: false)
            context.stroke(arc, with: .color(.white.opacity(0.35)), lineWidth: 1.5)
            var range = Path()
            range.addArc(center: center, radius: radius / 2, startAngle: .degrees(-140),
                         endAngle: .degrees(-40), clockwise: false)
            context.stroke(range, with: .color(.white.opacity(0.18)),
                           style: StrokeStyle(lineWidth: 1, dash: [4, 4]))

            func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                CGPoint(x: center.x + x * s, y: center.y - y * s)
            }
            let colour = Color(red: 0.95, green: 0.45, blue: 0.95)
            if road {
                var path = Path()
                path.move(to: center)
                path.addCurve(to: point(0.1, 0.36), control1: point(-0.18, 0.1), control2: point(0.26, 0.18))
                path.addCurve(to: point(-0.1, 0.64), control1: point(-0.04, 0.5), control2: point(-0.22, 0.52))
                context.stroke(path, with: .color(colour), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                // The flag at the destination.
                let flag = point(-0.1, 0.64)
                var pole = Path()
                pole.move(to: flag)
                pole.addLine(to: CGPoint(x: flag.x, y: flag.y - 20))
                context.stroke(pole, with: .color(.white), lineWidth: 1.5)
                var cloth = Path()
                cloth.move(to: CGPoint(x: flag.x, y: flag.y - 20))
                cloth.addLine(to: CGPoint(x: flag.x + 13, y: flag.y - 15))
                cloth.addLine(to: CGPoint(x: flag.x, y: flag.y - 10))
                cloth.closeSubpath()
                context.fill(cloth, with: .color(.white))
            } else {
                let fixes = [point(0.14, 0.24), point(0.07, 0.48), point(-0.14, 0.66)]
                var path = Path()
                path.move(to: center)
                fixes.forEach { path.addLine(to: $0) }
                context.stroke(path, with: .color(EFIS.green.opacity(0.9)), lineWidth: 2)
                for (i, fix) in fixes.enumerated() {
                    var diamond = Path()
                    diamond.move(to: CGPoint(x: fix.x, y: fix.y - 5))
                    diamond.addLine(to: CGPoint(x: fix.x + 5, y: fix.y))
                    diamond.addLine(to: CGPoint(x: fix.x, y: fix.y + 5))
                    diamond.addLine(to: CGPoint(x: fix.x - 5, y: fix.y))
                    diamond.closeSubpath()
                    context.stroke(diamond, with: .color(i == 0 ? .white : EFIS.green), lineWidth: 1.5)
                    let name = ["ANEKI", "TOBAK", "KJFK"][i]
                    context.draw(Text(name).font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(i == 0 ? Color.white : EFIS.green),
                                 at: CGPoint(x: fix.x + 10, y: fix.y), anchor: .leading)
                }
            }
            // The aircraft (or car) at the arc's centre.
            var plane = Path()
            plane.move(to: CGPoint(x: center.x, y: center.y - 14))
            plane.addLine(to: CGPoint(x: center.x - 8, y: center.y + 4))
            plane.addLine(to: CGPoint(x: center.x + 8, y: center.y + 4))
            plane.closeSubpath()
            context.stroke(plane, with: .color(EFIS.yellow), lineWidth: 2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .accessibilityHidden(true)
    }
}

private struct SafetySketch: View {
    var body: some View {
        ZStack {
            Circle()
                .fill(RadialGradient(colors: [Guide.warm.opacity(0.22), .clear],
                                     center: .center, startRadius: 0, endRadius: 48))
                .frame(width: 96, height: 96)
            Image(systemName: "checkmark.shield")
                .font(.system(size: 58, weight: .regular))
                .foregroundStyle(Guide.warm)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityHidden(true)
    }
}

#Preview {
    WelcomeView(isBoeing: false) {}
}
