import SwiftUI
import WebKit

@available(iOS 17.0, *)
struct LoginScreen: View {
    @StateObject private var coordinator = LoginCoordinator()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                LoginWebView(coordinator: coordinator)
                if case .verifying = coordinator.state {
                    Color.black.opacity(0.3).ignoresSafeArea()
                    ProgressView("Finishing sign-in…")
                        .padding()
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
            // Google often offers a passkey first, and it can never complete here: WebKit only
            // lets an app's web view use passkeys for the app's own associated domains, or in
            // apps Apple grants the web-browser passkey entitlement. Say so up front instead of
            // leaving the user on "Verifying it's you…".
            .safeAreaInset(edge: .bottom) {
                Label {
                    Text("Passkeys don't work here. If Google asks for one, choose “Try another way” and use your password or your phone.")
                } icon: {
                    Image(systemName: "key")
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
                .padding(.vertical, 10)
                .background(.bar)
            }
            .navigationTitle("Sign in")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onChange(of: coordinator.state) { _, new in
                if case .succeeded = new { dismiss() }
            }
            .alert(
                "Sign-in failed",
                isPresented: failureBinding,
                presenting: failureMessage
            ) { _ in
                Button("OK", role: .cancel) { coordinator.resetState() }
            } message: { message in
                Text(message)
            }
        }
    }

    private var failureMessage: String? {
        if case .failed(let message) = coordinator.state { return message }
        return nil
    }

    private var failureBinding: Binding<Bool> {
        Binding(
            get: {
                if case .failed = coordinator.state { return true }
                return false
            },
            set: { newValue in
                if !newValue { coordinator.resetState() }
            }
        )
    }
}
