import SwiftUI

struct HouseholdWelcomeView: View {
    @Environment(BackendClient.self) private var backend
    @Environment(HouseholdStore.self) private var store
    @State private var email = ""
    @State private var password = ""
    @State private var code = ""
    @State private var displayName = ""
    @State private var householdName = ""
    @State private var creatingAccount = true
    @State private var useLocal = false
    @State private var recovery = false
    @State private var recoverySent = false
    @State private var busy = false
    @State private var error: String?
    @State private var notice: String?

    var body: some View {
        Form {
            Section {
                Label("A calmer home, together",systemImage:"house.and.flag").font(.title2.bold()).padding(.vertical,8)
                Text("Share groceries, give chores an owner, and keep bills in view.").foregroundStyle(.secondary)
            }
            if useLocal {
                Section("On this device") {
                    TextField("Your name",text:$displayName).textContentType(.givenName)
                    TextField("Household name",text:$householdName)
                    Text("Lists and tasks stay on this device. Sign in later to create a shared household and import them.").font(.footnote).foregroundStyle(.secondary)
                    Button("Create household") { act { try store.createLocal(name:householdName.trimmingCharacters(in:.whitespacesAndNewlines),displayName:displayName.trimmingCharacters(in:.whitespacesAndNewlines)) } }
                        .disabled(busy || displayName.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || householdName.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
                    Button("Back to sign in") { useLocal = false }
                }
            } else if let pendingEmail = backend.confirmationEmail {
                Section("Verify your email") {
                    Text("Enter the code sent to \(pendingEmail).")
                    TextField("6-digit code",text:$code).textContentType(.oneTimeCode).keyboardType(.numberPad)
                    Button("Verify email") { act { try await backend.verify(email:pendingEmail,code:code) } }.disabled(busy || code.count != 6)
                    Button("Send a new code") { act { try await backend.resend(email:pendingEmail); notice = "A new code was requested. Check your inbox." } }.disabled(busy)
                    Button("Use another email") { backend.confirmationEmail = nil; code = "" }
                }
            } else if recovery {
                Section("Reset your password") {
                    emailField
                    if recoverySent {
                        TextField("Recovery code",text:$code).textContentType(.oneTimeCode).keyboardType(.numberPad)
                        SecureField("New password (12+ characters)",text:$password).textContentType(.newPassword)
                        Button("Save new password") { act { try await backend.resetPassword(email:email,code:code,password:password) } }.disabled(busy || password.count<12 || code.isEmpty)
                    } else {
                        Button("Send recovery email") { act { try await backend.requestPasswordReset(email:email); recoverySent = true } }.disabled(busy || email.isEmpty)
                    }
                    Button("Back to sign in") { recovery = false; code = "" }
                }
            } else {
                if backend.configuration.isConfigured {
                    Section {
                        emailField
                        SecureField(creatingAccount ? "Password (12+ characters)" : "Password",text:$password).textContentType(creatingAccount ? .newPassword : .password)
                        Button(creatingAccount ? "Create account" : "Sign in") { act {
                            let address = email.trimmingCharacters(in:.whitespacesAndNewlines).lowercased()
                            if creatingAccount { try await backend.signUp(email:address,password:password) }
                            else { try await backend.signIn(email:address,password:password) }
                        }}.disabled(busy || email.isEmpty || (creatingAccount ? password.count<12 : password.isEmpty))
                        Button(creatingAccount ? "Already have an account? Sign in" : "New here? Create an account") { creatingAccount.toggle(); error = nil }
                        if !creatingAccount { Button("Forgot password?") { recovery = true } }
                    } header: { Text(creatingAccount ? "Create your account" : "Welcome back") } footer: { Text("Verify your email before joining a household. This test build sends email only to the Supabase project's team addresses.") }
                } else {
                    Section { Text("Sharing is not configured in this build yet. You can start an on-device household now.").foregroundStyle(.secondary) }
                }
                Section {
                    Button("Use on this device") { useLocal = true }
                    Button("Open saved on-device household") { if !store.reopenLocal() { useLocal = true } }
                }
            }
            if busy { Section { ProgressView("Please wait…") } }
            if let error { Section { Text(error).foregroundStyle(.red).accessibilityLabel("Error: \(error)") } }
            if let notice { Section { Text(notice).foregroundStyle(.secondary) } }
        }
        .navigationTitle("Household OS").scrollContentBackground(.hidden).background(Color.hhBg)
    }
    private var emailField: some View {
        TextField("Email address",text:$email).textContentType(.emailAddress).keyboardType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled()
    }
    private func act(_ action: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }; busy = true; error = nil; notice = nil
        Task { defer { busy = false }; do { try await action() } catch { self.error = error.localizedDescription } }
    }
}

struct HouseholdSetupView: View {
    @Environment(HouseholdStore.self) private var store
    @Environment(BackendClient.self) private var backend
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var displayName = ""
    @State private var token: String
    @State private var joining: Bool
    @State private var busy = false
    @State private var error: String?
    init(inviteToken: String = "") { _token = State(initialValue:inviteToken); _joining = State(initialValue:!inviteToken.isEmpty) }
    var body: some View {
        Form {
            if !store.households.isEmpty {
                Section("Your households") { ForEach(store.households) { household in Button(household.name) { store.select(household); dismiss() } } }
            }
            Section {
                TextField("Your name",text:$displayName).textContentType(.givenName)
                Picker("Get started",selection:$joining) { Text("Create a household").tag(false); Text("Join with an invitation").tag(true) }
                if joining { TextField("Invitation code",text:$token).textInputAutocapitalization(.never).autocorrectionDisabled() }
                else { TextField("Household name",text:$name) }
                Button(joining ? "Join household" : "Create household") {
                    busy = true; error = nil
                    Task {
                        defer { busy = false }
                        do {
                            if joining { try await store.join(token:token,displayName:displayName) }
                            else { try await store.create(name:name,displayName:displayName) }
                            dismiss()
                        } catch { self.error = error.localizedDescription }
                    }
                }.disabled(busy || displayName.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || (joining ? token.isEmpty : name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty))
            } footer: { Text("Invitation codes only work with the verified email address the owner invited.") }
            if busy { ProgressView() }
            if let error { Text(error).foregroundStyle(.red) }
            if let error = store.error { Text(error).foregroundStyle(.red) }
            Section { Button("Sign out",role:.destructive) { Task { await backend.signOut(); store.reset() } } }
        }.navigationTitle("Your household")
    }
}
