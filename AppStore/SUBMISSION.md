# App Store submission checklist

## Done in the project

- [x] `ITSAppUsesNonExemptEncryption = NO`, so no export-compliance question per build
- [x] App category (Navigation), display name, scene manifest in the generated Info.plist
- [x] Location usage string says the position goes to OpenStreetMap when speed limits are on
- [x] `PrivacyInfo.xcprivacy`: UserDefaults reason `CA92.1`, precise location declared (not linked, no tracking)
- [x] Shared `FlightDeck` scheme (for Xcode Cloud and command-line archiving)
- [x] One-time safety notice before first use (not a navigation aid, don't operate while driving)
- [x] Screen stays awake while the app is open
- [x] Banner with a Settings button when location access is denied
- [x] Data attributions in the menu and flight picker: OpenStreetMap (ODbL), adsb.lol flight tracks (ODbL), AWS terrain tiles, OurAirports
- [x] App icon 1024×1024, no alpha
- [x] Release archive builds with no warnings and exports with App Store signing (team NY26DHXVSR)

## Before you submit

0. **Flight-number lookup** uses adsbdb.com (free, no key), so nothing needs setting up. The flight-track archive in `Tools/FlightArchive/` is optional and off by default.

1. **Decide on the legal points below.** These are the most likely reasons for rejection or later trouble.
2. **Host the privacy policy** (`AppStore/PRIVACY.md`), add a contact address, and put the URL in App Store Connect.
3. **Support URL**: any page with a way to contact you.
4. **Create the app in App Store Connect**: bundle ID `com.flightdeck.efis`, SKU of your choice, name (check availability).
5. **Screenshots** (required):
   - iPhone 6.9": 1320 × 2868 (portrait) or 2868 × 1320. Use an iPhone 17/18 Pro Max simulator.
   - iPad 13": 2064 × 2752 or 2752 × 2064 (needed because the app supports iPad). Use the iPad Pro 13-inch simulator.
   - The Simulator runs the demo flight, so displays are live. Tap through the safety notice first; `Cmd+S` in Simulator saves a screenshot.
6. **Upload**: Xcode → Product → Archive → Distribute App → App Store Connect. Or Xcode Cloud using the shared scheme.
7. **Fill in the metadata** from `AppStore/METADATA.md`, then answer the App Privacy questions as listed there.
8. **TestFlight** on a real phone in a car, and on one real flight (download the pack at the gate, then use airplane mode), before submitting. In particular, check the stationary magnetic heading, which the README notes is unverified on hardware.
9. Submit for review.

For every later upload, raise `CURRENT_PROJECT_VERSION` (build number). Also raise `MARKETING_VERSION` for each new public release.

## Legal points to settle (your call)

- **SimBrief INIT REQUEST.** The app fetches the user's own latest SimBrief plan through SimBrief's public OFP fetcher. Navigraph's Developer Terms (which cover the SimBrief API) limit use to flight simulation, exclude real-world navigation, and require a Navigraph client ID and account check for distributed apps. Ask Navigraph for permission or remove the feature before App Store submission.

- **FlyByWire A32NX (GPL-3.0): addressed in the code.** The Airbus PFD, ND and VD are now our own parametric layout (100- and 1000-unit canvases), built from a few design parameters and geometric primitives. The display smoothing is our own exponential smoother and slew limiter. No FlyByWire coordinates, path data, formulas or file references remain. Still open: (1) the proportions intentionally match the real A320 displays, so they match FlyByWire's drawing of them too; (2) the rewrite was done by someone who had seen the earlier version, so it is not a strict clean-room rewrite; (3) git history before this change still contains the GPL-derived version, so don't publish the repository with that history. If you want certainty, ask FlyByWire for permission or get legal advice.
- **Zibo 737-800X (X-Plane mod): addressed in the code.** The 737 PFD, ND and VSD are now our own parametric layout: a 100 × 102-unit PFD, a 1000-unit ND and a 1000 × 210 VSD. They are built from design parameters and geometric primitives. No coordinates from `b738.acf` and no shapes measured off the mod's textures remain, and no texture or image from the mod is in the app. The same caveats as for FlyByWire apply: the proportions intentionally match the real 737 displays, the rewrite was not a strict clean-room rewrite, and git history still holds the earlier version. The colour values are unchanged; colours as such aren't protectable.
- **Airbus / Boeing trademarks.** The in-app labels "A320" and "B737", and the model names in the profiles, are manufacturers' marks. Guideline 5.2.1 lets Apple reject apps that use others' trademarks without permission. The draft metadata deliberately leaves these names out. Consider neutral labels in the app as well (e.g. "STYLE A / STYLE B", or "EURO / US").
- **Overpass API usage policy.** The public `overpass-api.de` instance is meant for light use. One request per ~350 m per active user is fine at small scale. If the app becomes popular, use a dedicated instance or a commercial provider.
