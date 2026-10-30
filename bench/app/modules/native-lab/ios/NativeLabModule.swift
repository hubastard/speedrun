import ExpoModulesCore
import SwiftUI
import UIKit

public class NativeLabModule: Module {
  public func definition() -> ModuleDefinition {
    Name("NativeLab")
    View(NativeLabView.self) {}
  }
}

// The lab's native screen in SwiftUI (NativeLabModule.kt: the same in Jetpack Compose, with the
// same texts and identifiers). SwiftUI draws its views itself, not as UIViews: its animations
// run on its own clock, and what takes a touch is decided by SwiftUI's own hit testing.
final class NativeLabView: ExpoView {
  private let host = UIHostingController(rootView: LabScreen())

  required init(appContext: AppContext? = nil) {
    super.init(appContext: appContext)
    host.view.backgroundColor = .clear
    if #available(iOS 16.4, *) { host.safeAreaRegions = [] }
    addSubview(host.view)
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    host.view.frame = bounds
  }
}

private struct LabScreen: View {
  @State private var loads = 0
  @State private var loading = false
  @State private var count = 0
  @State private var details = false
  @State private var locked = false
  @State private var card = false
  @State private var cardTaps = 0
  @State private var list = false
  @State private var picked = "none"

  var body: some View {
    if list {
      // A lazy list: rows exist only once scrolled to.
      VStack(alignment: .leading, spacing: 0) {
        Button("Close list") { list = false }
          .buttonStyle(.bordered)
          .accessibilityIdentifier("native-close-list")
          .padding(16)
        List(1...100, id: \.self) { k in
          Button("Item \(k)") {
            picked = "Item \(k)"
            list = false
          }
          .accessibilityIdentifier("native-item-\(k)")
        }
        .listStyle(.plain)
      }
    } else {
      main
        .overlay {
          // A loading overlay for 1.5 s: it takes the taps, with a spinner.
          if locked {
            ZStack {
              Color.black.opacity(0.25)
              ProgressView()
            }
            .contentShape(Rectangle())
            .onTapGesture {}
            .accessibilityIdentifier("native-overlay")
          }
        }
    }
  }

  private var main: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 8) {
        button("Load", "native-load") {
          loads += 1
          loading = true
          DispatchQueue.main.asyncAfter(deadline: .now() + 2) { loading = false }
        }
        button("Add", "native-add") { count += 1 }
        button("Details", "native-toggle") { details.toggle() }
      }
      HStack(spacing: 8) {
        button("Lock", "native-lock") {
          locked = true
          DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { locked = false }
        }
        // A card that springs in from the side, slow and bouncy: a SwiftUI animation, on
        // SwiftUI's clock.
        button("Card", "native-card") {
          withAnimation(.spring(response: 1.2, dampingFraction: 0.5)) { card = true }
        }
        button("List", "native-list") { list = true }
      }
      ForEach(0..<12, id: \.self) { row in
        HStack(spacing: 0) {
          ForEach(0..<10, id: \.self) { k in Text("\(row * 10 + k) ").font(.system(size: 12)) }
        }
      }
      line("Loads finished: \(loading ? loads - 1 : loads)", "native-loads")
      line("Count: \(count)", "native-count")
      line("Card taps: \(cardTaps)", "native-card-taps")
      line("Picked: \(picked)", "native-picked")
      ZStack(alignment: .leading) {
        if loading { ProgressView().accessibilityIdentifier("native-bar") }
      }
      .frame(maxWidth: .infinity, minHeight: 28, maxHeight: 28, alignment: .leading)
      ZStack(alignment: .leading) {
        if details { Text("Details shown").accessibilityIdentifier("native-details") }
      }
      .frame(maxWidth: .infinity, minHeight: 28, maxHeight: 28, alignment: .leading)
      ZStack(alignment: .leading) {
        Button("Card button") { cardTaps += 1 }
          .buttonStyle(.borderedProminent)
          .accessibilityIdentifier("native-card-button")
          .offset(x: card ? 0 : 600)
      }
      .frame(maxWidth: .infinity, minHeight: 56, maxHeight: 56, alignment: .leading)
      .clipped()
      Spacer(minLength: 0)
    }
    .padding(16)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }

  private func button(_ title: String, _ id: String, action: @escaping () -> Void) -> some View {
    Button(title, action: action)
      .buttonStyle(.bordered)
      .accessibilityIdentifier(id)
  }

  private func line(_ text: String, _ id: String) -> some View {
    Text(text)
      .accessibilityIdentifier(id)
      .frame(width: 240, height: 28, alignment: .leading)
  }
}
