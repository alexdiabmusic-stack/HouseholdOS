import SwiftUI
import Charts

// MARK: - Smart Insights View (Phase 8)

struct InsightsView: View {
    @Environment(FinancialStore.self) private var store

    private var anomalies: [SpendingAnomaly] {
        FeatureFlags.anomalyDetection ? store.spendingAnomalies : []
    }
    private var breakdown: [CategorySpend] { Array(store.categoryBreakdown.prefix(7)) }
    private var forecast: [ForecastPoint]  { store.cashFlowForecast }

    private var totalThisMonth: Double { breakdown.reduce(0) { $0 + $1.amountThisMonth } }

    var body: some View {
        ZStack {
            Color.hhBg.ignoresSafeArea()
            if store.transactions.isEmpty {
                loadingState
            } else {
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 20) {
                        if !anomalies.isEmpty {
                            anomalySection
                        }
                        if FeatureFlags.cashFlowForecasting && !forecast.isEmpty {
                            forecastSection
                        }
                        if !breakdown.isEmpty {
                            categorySection
                        }
                        Spacer(minLength: 80)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                }
            }
        }
        .navigationTitle("Smart Insights")
        .hhNavTitleStyle(.large)
    }

    // MARK: - Anomaly Section

    private var anomalySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(
                title: "Anomalies Detected",
                subtitle: "\(anomalies.count) alert\(anomalies.count == 1 ? "" : "s")"
            )
            VStack(spacing: 10) {
                ForEach(anomalies) { anomaly in
                    AnomalyCard(anomaly: anomaly)
                }
            }
        }
    }

    // MARK: - Forecast Section

    private var forecastSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "30-Day Forecast")
            VStack(spacing: 0) {
                // Current balance headline
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(forecast.first?.projectedBalance ?? 0,
                         format: .currency(code: "CAD"))
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .foregroundColor(.hhInk)
                    Text("available today")
                        .font(.system(size: 13))
                        .foregroundColor(.hhFaint)
                        .padding(.bottom, 2)
                    Spacer()
                    let lowest = forecast.map { $0.projectedBalance }.min() ?? 0
                    VStack(alignment: .trailing, spacing: 1) {
                        Text("Lowest projected")
                            .font(.system(size: 10))
                            .foregroundColor(.hhFaint)
                        Text(lowest, format: .currency(code: "CAD"))
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(lowest < 500 ? .orange : .hhSub)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 10)

                // Line chart
                Chart {
                    ForEach(forecast) { pt in
                        AreaMark(
                            x: .value("Date", pt.date),
                            y: .value("Balance", pt.projectedBalance)
                        )
                        .foregroundStyle(
                            LinearGradient(
                                colors: [Color.hhAccent.opacity(0.12), .clear],
                                startPoint: .top, endPoint: .bottom
                            )
                        )

                        LineMark(
                            x: .value("Date", pt.date),
                            y: .value("Balance", pt.projectedBalance)
                        )
                        .foregroundStyle(by: .value("Kind", pt.isProjected ? "Forecast" : "Current"))
                        .lineStyle(StrokeStyle(lineWidth: 2.5))
                        .interpolationMethod(.monotone)
                    }

                    // Today marker
                    RuleMark(x: .value("Today", Date()))
                        .foregroundStyle(Color.hhFaint.opacity(0.5))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                        .annotation(position: .top, alignment: .leading) {
                            Text("Today")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundColor(.hhFaint)
                        }
                }
                .chartForegroundStyleScale([
                    "Current": Color.hhGreen,
                    "Forecast": Color.hhAccent
                ])
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day, count: 7)) { _ in
                        AxisGridLine().foregroundStyle(Color.hhFaint.opacity(0.2))
                        AxisValueLabel(format: .dateTime.day().month(.abbreviated),
                                       centered: false)
                            .font(.system(size: 9))
                            .foregroundStyle(Color.hhFaint)
                    }
                }
                .chartYAxis {
                    AxisMarks(values: .automatic(desiredCount: 3)) { value in
                        AxisGridLine().foregroundStyle(Color.hhFaint.opacity(0.2))
                        AxisValueLabel {
                            if let v = value.as(Double.self) {
                                Text(v.formatted(.currency(code: "CAD")
                                    .precision(.fractionLength(0))))
                                    .font(.system(size: 9))
                                    .foregroundStyle(Color.hhFaint)
                            }
                        }
                    }
                }
                .chartLegend(.hidden)
                .frame(height: 170)
                .padding(.horizontal, 12)
                .padding(.bottom, 14)

                // Legend row
                HStack(spacing: 16) {
                    legendChip(color: .hhGreen,  label: "Today's balance")
                    legendChip(color: .hhAccent, label: "Projected (income & bills)")
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 14)
            }
            .background(Color.hhCard)
            .cornerRadius(18)
            .shadow(color: Color.hhInk.opacity(0.05), radius: 8, x: 0, y: 2)
        }
    }

    private func legendChip(color: Color, label: String) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.hhFaint)
        }
    }

    // MARK: - Category Section

    private var categorySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(
                title: "This Month",
                subtitle: totalThisMonth.formatted(.currency(code: "CAD"))
            )
            VStack(spacing: 0) {
                Chart(breakdown) { cat in
                    BarMark(
                        x: .value("Amount", cat.amountThisMonth),
                        y: .value("Category", cat.displayName)
                    )
                    .foregroundStyle(insightCategoryColor(cat.category))
                    .cornerRadius(5)
                    .annotation(position: .trailing, alignment: .leading) {
                        Text(cat.amountThisMonth.formatted(.currency(code: "CAD")
                            .precision(.fractionLength(0))))
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.hhSub)
                    }
                }
                .chartXAxis(.hidden)
                .chartYAxis {
                    AxisMarks { value in
                        AxisValueLabel {
                            if let name = value.as(String.self) {
                                Text(name)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(Color.hhInk)
                            }
                        }
                    }
                }
                .frame(height: CGFloat(breakdown.count) * 38 + 20)
                .padding(.horizontal, 12)
                .padding(.vertical, 14)

                // Month-over-month summary
                if breakdown.contains(where: { $0.changePercent != nil }) {
                    Divider()
                    momSummary
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                }
            }
            .background(Color.hhCard)
            .cornerRadius(18)
            .shadow(color: Color.hhInk.opacity(0.05), radius: 8, x: 0, y: 2)
        }
    }

    private var momSummary: some View {
        let ups   = breakdown.filter { $0.isUp }
        let downs = breakdown.filter { $0.isDown }
        return HStack(spacing: 4) {
            Image(systemName: ups.isEmpty ? "checkmark.circle.fill" : "arrow.up.circle.fill")
                .font(.system(size: 13))
                .foregroundColor(ups.isEmpty ? .hhGreen : .orange)
            if ups.isEmpty && downs.isEmpty {
                Text("Spending in line with last month")
            } else if ups.isEmpty {
                Text("\(downs.map { $0.displayName }.joined(separator: ", ")) down vs last month")
            } else {
                Text("\(ups.map { $0.displayName }.joined(separator: ", ")) up vs last month")
                    .foregroundColor(.orange)
            }
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundColor(.hhSub)
    }

    // MARK: - Loading State

    private var loadingState: some View {
        VStack(spacing: 16) {
            ProgressView().scaleEffect(1.3).tint(.hhAccent)
            Text("Analysing your finances…")
                .font(.system(size: 14))
                .foregroundColor(.hhFaint)
        }
    }
}

// MARK: - Anomaly Card

private struct AnomalyCard: View {
    let anomaly: SpendingAnomaly

    private var accentColor: Color {
        anomaly.severity == .alert ? .red.opacity(0.8) : .orange
    }

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: anomaly.severity == .alert ? "exclamationmark.triangle.fill" : "exclamationmark.circle.fill")
                .font(.system(size: 20))
                .foregroundColor(accentColor)
                .frame(width: 42, height: 42)
                .background(accentColor.opacity(0.1))
                .cornerRadius(12)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(anomaly.merchantName)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.hhInk)
                    Text(anomaly.kind == .unusuallyLarge ? "UNUSUAL" : "POSSIBLE DUPLICATE")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(accentColor)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(accentColor.opacity(0.1))
                        .cornerRadius(4)
                }
                Text(anomaly.message)
                    .font(.system(size: 12))
                    .foregroundColor(.hhSub)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            Text(anomaly.amount, format: .currency(code: "CAD"))
                .font(.system(size: 15, weight: .bold))
                .foregroundColor(accentColor)
        }
        .padding(14)
        .background(Color.hhCard)
        .cornerRadius(16)
        .shadow(color: accentColor.opacity(0.12), radius: 6, x: 0, y: 2)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(accentColor.opacity(0.2), lineWidth: 1)
        )
    }
}

// MARK: - Color Helper

private func insightCategoryColor(_ category: String) -> Color {
    switch category.uppercased() {
    case "GROCERIES":           return Color.hhGreen
    case "FOOD_AND_DRINK":      return Color.orange
    case "SHOPPING":            return Color.hhAccent
    case "ENTERTAINMENT":       return Color.hhPurple
    case "TRANSPORTATION":      return Color.hhSub
    case "HEALTH":              return Color(red: 0.90, green: 0.35, blue: 0.40)
    case "ELECTRIC", "HYDRO":   return Color.yellow
    case "INTERNET", "PHONE":   return Color.hhBlue
    default:                    return Color.hhFaint
    }
}

#Preview {
    NavigationStack { InsightsView() }
        .environment(FinancialStore(provider: PlaidSandboxProvider()))
}
