import AppKit
import SwiftUI
import tcKit

/// Non-blocking SwiftUI banner rendered above the main content when the
/// `SkillVersionBanner` reports a lagging install. Dismiss is sticky per bundle
/// version via `UserDefaults`.
///
/// The banner offers a "Copy command" affordance that writes the exact
/// `tc skill install --<agent>` string to the pasteboard, so users don't need to
/// re-type it even if `tc` isn't on their `$PATH` yet.
struct SkillVersionBannerView: View {
  let banner: SkillVersionBanner

  var body: some View {
    if case .needsUpgrade(let agent, let installed, let bundled) = banner.status {
      let command = "tc skill install --\(agent.rawValue)"
      HStack(alignment: .top, spacing: 12) {
        Image(systemName: "arrow.up.circle")
          .foregroundStyle(.orange)
          .accessibilityHidden(true) // decorative; adjacent text conveys meaning
        VStack(alignment: .leading, spacing: 2) {
          Text("touch-code skill \(bundled) is available")
            .font(.headline)
          Text("Installed for \(agent.rawValue): \(installed). Run `\(command)` to upgrade.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
        }
        Spacer(minLength: 8)
        VStack(alignment: .trailing, spacing: 4) {
          Button("Copy command") { Self.copyToPasteboard(command) }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help("Copies `\(command)` to the clipboard.")
          Button("Dismiss") { banner.dismiss() }
            .buttonStyle(.borderless)
            .controlSize(.small)
        }
      }
      .padding(10)
      .background(.yellow.opacity(0.12))
      .overlay(
        RoundedRectangle(cornerRadius: 6)
          .stroke(.orange.opacity(0.35), lineWidth: 1)
      )
      .clipShape(RoundedRectangle(cornerRadius: 6))
      .padding(.horizontal, 16)
      .padding(.top, 12)
      .transition(.opacity)
    }
  }

  private static func copyToPasteboard(_ text: String) {
    let pb = NSPasteboard.general
    pb.clearContents()
    pb.setString(text, forType: .string)
  }
}
