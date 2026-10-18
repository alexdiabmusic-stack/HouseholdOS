import SwiftUI

// MARK: - Service Marketplace View

struct ServiceMarketplaceView: View {
    @Environment(ServiceMarketplaceStore.self) private var store
    @State private var selectedProvider: ServiceProvider? = nil

    private static let categories: [(id: String, label: String, icon: String)] = [
        ("all",         "All",        "square.grid.2x2.fill"),
        ("cleaning",    "Cleaning",   "sparkles"),
        ("plumbing",    "Plumbing",   "drop.fill"),
        ("electrical",  "Electrical", "bolt.fill"),
        ("hvac",        "HVAC",       "thermometer.medium"),
        ("handyman",    "Handyman",   "hammer.fill"),
        ("lawn",        "Lawn",       "leaf.fill"),
        ("moving",      "Moving",     "shippingbox.fill"),
        ("pest",        "Pest",       "ant.fill"),
    ]

    var body: some View {
        ZStack {
            Color.hhBg.ignoresSafeArea()
            VStack(spacing: 0) {
                categoryRow
                Divider()
                providerContent
            }
        }
        .navigationTitle("Services")
        .hhNavTitleStyle(.large)
        .sheet(item: $selectedProvider) { sp in
            ProviderDetailSheet(provider: sp)
                .environment(store)
        }
        .task { await store.search(category: "all") }
    }

    // MARK: - Category Chips

    private var categoryRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(Self.categories, id: \.id) { cat in
                    MarketplaceCategoryChip(
                        label: cat.label,
                        icon: cat.icon,
                        isSelected: store.selectedCategory == cat.id
                    ) {
                        Task { await store.search(category: cat.id) }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .background(Color.hhCard)
    }

    // MARK: - Provider List

    @ViewBuilder
    private var providerContent: some View {
        if store.isSearching {
            Spacer()
            ProgressView().scaleEffect(1.2).tint(.hhAccent)
            Spacer()
        } else if store.searchResults.isEmpty {
            Spacer()
            VStack(spacing: 14) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 40))
                    .foregroundColor(.hhFaint)
                Text("No providers found")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(.hhSub)
            }
            Spacer()
        } else {
            ScrollView(showsIndicators: false) {
                LazyVStack(spacing: 12) {
                    if FeatureFlags.sandboxBannerVisible {
                        sandboxBanner
                    }
                    if !store.upcomingBookings.isEmpty {
                        upcomingBookingsRow
                    }
                    ForEach(store.searchResults) { sp in
                        ServiceProviderCard(provider: sp) { selectedProvider = sp }
                    }
                    Spacer(minLength: 80)
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
            }
        }
    }

    private var sandboxBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "flask.fill").font(.system(size: 12))
            Text("Sandbox — real providers powered by Google Places in production")
                .font(.system(size: 12, weight: .medium))
        }
        .foregroundColor(.hhAccent)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.hhAccent.opacity(0.08))
        .cornerRadius(10)
    }

    private var upcomingBookingsRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "calendar.badge.checkmark")
                .font(.system(size: 18))
                .foregroundColor(.hhGreen)
                .frame(width: 40, height: 40)
                .background(Color.hhGreen.opacity(0.1))
                .clipShape(Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text("Upcoming Bookings")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.hhInk)
                Text(store.upcomingBookings.first.map { "\($0.providerName) · \($0.scheduledDate.formatted(date: .abbreviated, time: .omitted))" } ?? "")
                    .font(.system(size: 12))
                    .foregroundColor(.hhSub)
                    .lineLimit(1)
            }
            Spacer()
            if store.upcomingBookings.count > 1 {
                Text("+\(store.upcomingBookings.count - 1)")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.hhGreen)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.hhGreen.opacity(0.12))
                    .cornerRadius(8)
            }
        }
        .padding(14)
        .background(Color.hhCard)
        .cornerRadius(14)
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.hhGreen.opacity(0.2), lineWidth: 1))
    }
}

// MARK: - Category Chip

struct MarketplaceCategoryChip: View {
    let label: String
    let icon: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 11, weight: .semibold))
                Text(label).font(.system(size: 13, weight: .semibold))
            }
            .foregroundColor(isSelected ? .white : .hhSub)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(isSelected ? Color.hhAccent : Color.hhShell)
            .cornerRadius(20)
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.25), value: isSelected)
    }
}

// MARK: - Provider Card

struct ServiceProviderCard: View {
    let provider: ServiceProvider
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 14) {
                Text(String(provider.name.prefix(1)))
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 50, height: 50)
                    .background(categoryColor)
                    .clipShape(Circle())

                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Text(provider.name)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(.hhInk)
                            .lineLimit(1)
                        if provider.isMarketplaceMember {
                            Image(systemName: "checkmark.seal.fill")
                                .font(.system(size: 12))
                                .foregroundColor(.hhAccent)
                        }
                    }
                    if let rating = provider.googleRating {
                        starRow(rating: rating)
                    }
                    if let address = provider.address {
                        Text(address)
                            .font(.system(size: 12))
                            .foregroundColor(.hhFaint)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 0)

                VStack(alignment: .trailing, spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.hhFaint)
                    if provider.isMarketplaceMember {
                        Text("Book")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.hhAccent)
                    }
                }
            }
            .padding(16)
            .background(Color.hhCard)
            .cornerRadius(18)
            .shadow(color: Color.hhInk.opacity(0.05), radius: 8, x: 0, y: 2)
        }
        .buttonStyle(.plain)
    }

    private func starRow(rating: Double) -> some View {
        HStack(spacing: 3) {
            let filled = Int(rating.rounded())
            ForEach(0..<5) { i in
                Image(systemName: i < filled ? "star.fill" : "star")
                    .font(.system(size: 10))
                    .foregroundColor(.yellow)
            }
            Text(String(format: "%.1f", rating))
                .font(.system(size: 12))
                .foregroundColor(.hhSub)
        }
    }

    var categoryColor: Color { providerCategoryColor(provider.category) }
}

// MARK: - Provider Detail Sheet

struct ProviderDetailSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(ServiceMarketplaceStore.self) private var store
    let provider: ServiceProvider
    @State private var showBooking = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color.hhBg.ignoresSafeArea()
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 24) {
                        // Avatar + name
                        VStack(spacing: 12) {
                            Text(String(provider.name.prefix(1)))
                                .font(.system(size: 36, weight: .bold))
                                .foregroundColor(.white)
                                .frame(width: 84, height: 84)
                                .background(providerCategoryColor(provider.category))
                                .clipShape(Circle())

                            VStack(spacing: 4) {
                                HStack(spacing: 6) {
                                    Text(provider.name)
                                        .font(.system(size: 22, weight: .bold))
                                        .foregroundColor(.hhInk)
                                        .multilineTextAlignment(.center)
                                    if provider.isMarketplaceMember {
                                        Image(systemName: "checkmark.seal.fill")
                                            .font(.system(size: 18))
                                            .foregroundColor(.hhAccent)
                                    }
                                }
                                Text(provider.category.capitalized)
                                    .font(.system(size: 14))
                                    .foregroundColor(.hhSub)
                            }

                            if let rating = provider.googleRating {
                                HStack(spacing: 4) {
                                    let filled = Int(rating.rounded())
                                    ForEach(0..<5) { i in
                                        Image(systemName: i < filled ? "star.fill" : "star")
                                            .font(.system(size: 14))
                                            .foregroundColor(.yellow)
                                    }
                                    Text(String(format: "%.1f on Google", rating))
                                        .font(.system(size: 13))
                                        .foregroundColor(.hhSub)
                                }
                            }
                        }
                        .padding(.top, 8)

                        // Contact info
                        VStack(spacing: 8) {
                            if let address = provider.address {
                                detailInfoRow(icon: "mappin.circle.fill", text: address, color: .red)
                            }
                            if let phone = provider.phone {
                                detailInfoRow(icon: "phone.circle.fill", text: phone, color: .hhGreen)
                            }
                        }
                        .padding(.horizontal, 20)

                        // Household OS badge
                        if provider.isMarketplaceMember {
                            VStack(alignment: .leading, spacing: 10) {
                                HStack(spacing: 8) {
                                    Image(systemName: "checkmark.seal.fill")
                                        .foregroundColor(.hhAccent)
                                    Text("Household OS Verified")
                                        .font(.system(size: 15, weight: .semibold))
                                        .foregroundColor(.hhInk)
                                }
                                Text("This provider has completed background screening, holds valid insurance, and is eligible for in-app booking and payment.")
                                    .font(.system(size: 13))
                                    .foregroundColor(.hhSub)
                            }
                            .padding(16)
                            .background(Color.hhAccent.opacity(0.07))
                            .cornerRadius(14)
                            .padding(.horizontal, 20)
                        }

                        // CTA or fallback
                        if provider.isMarketplaceMember {
                            VStack(spacing: 12) {
                                Text("Payments processed securely by Stripe. Household OS charges an 8% platform fee, calculated server-side. Your banking credentials are never stored by us.")
                                    .font(.system(size: 12))
                                    .foregroundColor(.hhFaint)
                                    .multilineTextAlignment(.center)
                                    .padding(.horizontal, 8)

                                Button { showBooking = true } label: {
                                    Text("Book This Provider")
                                        .font(.system(size: 17, weight: .semibold))
                                        .foregroundColor(.white)
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 16)
                                        .background(Color.hhAccent)
                                        .cornerRadius(14)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.horizontal, 20)
                        } else {
                            Text("This provider isn't on the Household OS marketplace yet. Call them directly to book.")
                                .font(.system(size: 14))
                                .foregroundColor(.hhSub)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 32)
                        }

                        Spacer(minLength: 40)
                    }
                }
            }
            .navigationTitle(provider.name)
            .hhNavTitleStyle(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }.foregroundColor(.hhAccent)
                }
            }
            .sheet(isPresented: $showBooking) {
                ServiceBookingSheet(provider: provider)
                    .environment(store)
            }
        }
    }

    private func detailInfoRow(icon: String, text: String, color: Color) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 22))
                .foregroundColor(color)
                .frame(width: 36)
            Text(text)
                .font(.system(size: 14))
                .foregroundColor(.hhInk)
            Spacer()
        }
        .padding(14)
        .background(Color.hhCard)
        .cornerRadius(12)
    }
}

// MARK: - Booking Sheet

struct ServiceBookingSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(ServiceMarketplaceStore.self) private var store
    let provider: ServiceProvider

    @State private var scheduledDate = Calendar.current.date(byAdding: .day, value: 3, to: Date()) ?? Date()
    @State private var notes = ""
    @State private var costText = ""
    @State private var bookedRecord: ServiceBookingRecord? = nil
    @State private var errorMessage: String? = nil
    @FocusState private var notesFocused: Bool

    private var estimatedCost: Double? { Double(costText.replacingOccurrences(of: ",", with: ".")) }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.hhBg.ignoresSafeArea()
                if let record = bookedRecord {
                    BookingSuccessView(record: record) { dismiss() }
                } else {
                    bookingForm
                }
            }
            .navigationTitle("Book Service")
            .hhNavTitleStyle(.inline)
            .toolbar {
                if bookedRecord == nil {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }.foregroundColor(.hhAccent)
                    }
                }
            }
        }
    }

    private var bookingForm: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 22) {
                // Provider summary
                HStack(spacing: 14) {
                    Text(String(provider.name.prefix(1)))
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(.white)
                        .frame(width: 46, height: 46)
                        .background(providerCategoryColor(provider.category))
                        .clipShape(Circle())
                    VStack(alignment: .leading, spacing: 2) {
                        Text(provider.name)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(.hhInk)
                        Text(provider.category.capitalized)
                            .font(.system(size: 13))
                            .foregroundColor(.hhSub)
                    }
                    Spacer()
                }
                .padding(16)
                .background(Color.hhCard)
                .cornerRadius(14)

                bookingFieldGroup(title: "DATE & TIME") {
                    DatePicker("", selection: $scheduledDate, in: Date()..., displayedComponents: [.date, .hourAndMinute])
                        .datePickerStyle(.graphical)
                        .tint(.hhAccent)
                        .labelsHidden()
                }

                bookingFieldGroup(title: "ESTIMATED COST (OPTIONAL)") {
                    HStack {
                        Text("$")
                            .font(.system(size: 16))
                            .foregroundColor(.hhSub)
                        TextField("e.g. 150", text: $costText)
                            .keyboardType(.decimalPad)
                            .font(.system(size: 16))
                            .foregroundColor(.hhInk)
                    }
                    .padding(14)
                    .background(Color.hhCard)
                    .cornerRadius(12)
                }

                bookingFieldGroup(title: "NOTES") {
                    TextField("Describe what you need (optional)", text: $notes, axis: .vertical)
                        .lineLimit(3...6)
                        .font(.system(size: 15))
                        .foregroundColor(.hhInk)
                        .padding(14)
                        .background(Color.hhCard)
                        .cornerRadius(12)
                        .focused($notesFocused)
                }

                // Security notice
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "lock.shield.fill")
                        .font(.system(size: 16))
                        .foregroundColor(.hhAccent)
                        .padding(.top, 1)
                    Text("Payments are processed by Stripe. No payment is charged now — the provider will confirm the booking and send a quote. The 8% platform fee is calculated server-side.")
                        .font(.system(size: 12))
                        .foregroundColor(.hhSub)
                }
                .padding(14)
                .background(Color.hhCard)
                .cornerRadius(12)

                if FeatureFlags.sandboxBannerVisible {
                    HStack(spacing: 8) {
                        Image(systemName: "flask.fill").font(.system(size: 12))
                        Text("Sandbox — no real booking will be made")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundColor(.hhAccent)
                    .frame(maxWidth: .infinity)
                    .padding(10)
                    .background(Color.hhAccent.opacity(0.08))
                    .cornerRadius(10)
                }

                if let err = errorMessage {
                    Text(err)
                        .font(.system(size: 13))
                        .foregroundColor(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Button {
                    Task { await confirmBooking() }
                } label: {
                    Group {
                        if store.isBooking {
                            ProgressView().progressViewStyle(.circular).tint(.white)
                        } else {
                            Text("Confirm Request")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundColor(.white)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(Color.hhAccent)
                    .cornerRadius(14)
                }
                .buttonStyle(.plain)
                .disabled(store.isBooking)

                Spacer(minLength: 20)
            }
            .padding(20)
        }
    }

    private func confirmBooking() async {
        errorMessage = nil
        do {
            let record = try await store.book(
                provider: provider,
                date: scheduledDate,
                notes: notes,
                estimatedCost: estimatedCost
            )
            withAnimation(.spring(response: 0.4)) { bookedRecord = record }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @ViewBuilder
    private func bookingFieldGroup<C: View>(title: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundColor(.hhFaint)
            content()
        }
    }
}

// MARK: - Booking Success View

struct BookingSuccessView: View {
    let record: ServiceBookingRecord
    let onDone: () -> Void

    var body: some View {
        VStack(spacing: 28) {
            Spacer()

            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 72))
                .foregroundColor(.hhGreen)

            VStack(spacing: 8) {
                Text("Booking Requested!")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundColor(.hhInk)
                Text("Your request has been sent to \(record.providerName).\nThey'll confirm and contact you.")
                    .font(.system(size: 15))
                    .foregroundColor(.hhSub)
                    .multilineTextAlignment(.center)
            }

            VStack(spacing: 0) {
                successRow(label: "Provider", value: record.providerName)
                Divider().padding(.leading, 16)
                successRow(label: "Date", value: record.scheduledDate.formatted(date: .long, time: .shortened))
                if let cost = record.estimatedCost {
                    Divider().padding(.leading, 16)
                    successRow(label: "Estimated", value: cost.formatted(.currency(code: "CAD")))
                    Divider().padding(.leading, 16)
                    successRow(label: "Platform fee (8%)", value: (cost * 0.08).formatted(.currency(code: "CAD")))
                }
                Divider().padding(.leading, 16)
                successRow(label: "Status", value: record.status.capitalized)
                if record.isSandbox {
                    Divider().padding(.leading, 16)
                    successRow(label: "Mode", value: "Sandbox")
                }
            }
            .background(Color.hhCard)
            .cornerRadius(18)
            .padding(.horizontal, 20)

            Spacer()

            Button(action: onDone) {
                Text("Done")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(Color.hhAccent)
                    .cornerRadius(14)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 20)
            .padding(.bottom, 30)
        }
    }

    private func successRow(label: String, value: String) -> some View {
        HStack {
            Text(label).font(.system(size: 14)).foregroundColor(.hhSub)
            Spacer()
            Text(value).font(.system(size: 14, weight: .semibold)).foregroundColor(.hhInk)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

// MARK: - Shared Helpers

func providerCategoryColor(_ category: String) -> Color {
    switch category {
    case "cleaning":   return Color(red: 0.24, green: 0.58, blue: 0.95)
    case "plumbing":   return Color(red: 0.20, green: 0.40, blue: 0.82)
    case "electrical": return Color(red: 0.82, green: 0.53, blue: 0.0)
    case "hvac":       return Color(red: 0.58, green: 0.28, blue: 0.80)
    case "handyman":   return Color(red: 0.88, green: 0.48, blue: 0.10)
    case "lawn":       return Color(red: 0.18, green: 0.64, blue: 0.28)
    case "moving":     return Color(red: 0.50, green: 0.34, blue: 0.18)
    case "pest":       return Color(red: 0.78, green: 0.18, blue: 0.18)
    default:           return Color(red: 0.38, green: 0.38, blue: 0.88)
    }
}

#Preview {
    NavigationStack {
        ServiceMarketplaceView()
            .environment(ServiceMarketplaceStore(provider: GooglePlacesSandboxProvider()))
    }
}
