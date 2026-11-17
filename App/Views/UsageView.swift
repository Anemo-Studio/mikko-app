import Charts
import MikkoCore
import SwiftUI

struct UsageView: View {
    @Environment(AppModel.self) private var app
    @AppStorage("usageShowBreakdown") private var showBreakdown = false
    @AppStorage("usageShowBudgets") private var showBudgets = false
    @State private var newBudget = ""
    @State private var newBudgetPeriod = Budget.Period.month
    @State private var newBudgetProject: String?

    private var model: UsageModel { app.usageModel }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Headline(title: "\(money(model.today.cost)) today",
                         subtitle: "What your tokens would cost at API list prices — not a bill. \(money(model.week.cost)) in 7 days, \(money(model.month.cost)) in 30.")
                chart
                limits
                DisclosureGroup("Where it went", isExpanded: $showBreakdown) {
                    VStack(alignment: .leading, spacing: 20) {
                        HStack(alignment: .top, spacing: 24) {
                            breakdown("By model — 30 days", model.byModel)
                            breakdown("By project — 30 days", model.byProject)
                        }
                        topSessions
                    }
                    .padding(.top, 12)
                }
                DisclosureGroup("Budgets\(model.overBudget.isEmpty ? "" : " — \(model.overBudget.count) over")", isExpanded: $showBudgets) {
                    budgets.padding(.top, 12)
                }
            }
            .padding(Calm.pad)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .toolbar { Button { app.sessionsModel.index(force: true) } label: { Label("Refresh", systemImage: "arrow.clockwise") }.disabled(app.sessionsModel.isIndexing) }
        .onAppear { app.sessionsModel.index(); model.reload() }
        .onChange(of: app.sessionsModel.isIndexing) { _, indexing in if !indexing { model.reload() } }
    }

    private func money(_ v: Double) -> String { String(format: "$%.2f", v) }
    private func count(_ v: Int64) -> String { v.formatted(.number.notation(.compactName)) }

    // U-1
    private var limits: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Limits").font(.headline)
            if model.limits.isEmpty {
                Text("No limit data yet. Codex reports its limits in every session; they appear here after your next Codex run.")
                    .foregroundStyle(.secondary)
            }
            // A reading from before its window reset says nothing about now: one quiet line, not a bar.
            let stale = model.limits.filter { ($0.resetsAt ?? .distantFuture) < .now }
            if let s = stale.max(by: { $0.observedAt < $1.observedAt }) {
                Text("\(s.provider): no current reading. It last reported \(s.observedAt.formatted(.relative(presentation: .named))); limits appear again after your next \(s.provider) run.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(model.limits.filter { ($0.resetsAt ?? .distantFuture) >= .now }, id: \.rowID) { l in
                let expired = false
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("\(l.provider) · \(l.window == "5h" ? "5-hour window" : "Weekly window")").font(.body.weight(.medium))
                        if !expired { Tag(l.isExact ? "Exact" : "Estimate", color: l.isExact ? .green : .orange) }
                        Spacer()
                        // A figure from before the window reset says nothing about now.
                        Text(expired ? "Not known since reset" : "\(Int(l.usedPercent.rounded()))% used").monospacedDigit()
                            .foregroundStyle(expired ? .secondary : .primary)
                    }
                    ProgressView(value: expired ? 0 : min(l.usedPercent, 100), total: 100)
                        .tint(l.usedPercent >= 90 ? .red : l.usedPercent >= 80 ? .orange : .accentColor)
                        .accessibilityLabel("\(l.provider) \(l.window) limit").accessibilityValue(expired ? "not known since the window reset" : "\(Int(l.usedPercent)) percent used")
                    Text(limitCaption(l)).font(.caption).foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Claude · last 7 days").font(.body.weight(.medium))
                    Spacer()
                    Text("\(count(model.claudeWeek.usage.input + model.claudeWeek.usage.output)) tokens in and out · \(count(model.claudeWeek.usage.cacheRead + model.claudeWeek.usage.cacheWrite5m + model.claudeWeek.usage.cacheWrite1h)) cached").monospacedDigit()
                }
                Text("Claude Code does not record how much of your plan's limit is used, and the limits themselves are not published — so mikko shows what you used, not a percentage of a limit.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func limitCaption(_ l: RateLimitWindow) -> String {
        let seen = "Reported by \(l.provider) \(l.observedAt.formatted(.relative(presentation: .named)))"
        guard let r = l.resetsAt else { return seen }
        return r < .now ? "Last \(seen.prefix(1).lowercased() + seen.dropFirst()) at \(Int(l.usedPercent.rounded()))%. The window has reset since then." : "\(seen) · resets \(r.formatted(date: .omitted, time: .shortened)) \(r.formatted(.relative(presentation: .named)))"
    }

    // U-3
    private var spend: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("API-equivalent value").font(.title3.weight(.semibold))
                Text("What your tokens would cost at list prices (\(Pricing.asOf)). Not a bill.").font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 16) {
                card("Today", model.today)
                card("7 days", model.week)
                card("30 days", model.month)
            }
        }
    }

    private func card(_ title: String, _ t: UsageTotals) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(money(t.cost) + (t.unpricedTokens > 0 ? "+" : "")).font(.title2.weight(.semibold)).monospacedDigit()
            Text("In \(count(t.usage.input)) · Out \(count(t.usage.output)) · Cache \(count(t.usage.cacheRead + t.usage.cacheWrite5m + t.usage.cacheWrite1h))")
                .font(.caption).foregroundStyle(.secondary)
            if t.unpricedTokens > 0 {
                Text("\(count(t.unpricedTokens)) tokens on unpriced models not included").font(.caption2).foregroundStyle(.orange)
            }
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
    }

    private var chart: some View {
        VStack(alignment: .leading, spacing: 8) {
            Chart(model.byDay) { d in
                BarMark(x: .value("Day", String(d.key.suffix(2))), y: .value("USD", d.cost))
                    .cornerRadius(3)
                    .accessibilityLabel(d.key).accessibilityValue(money(d.cost))
            }
            .chartXAxis { AxisMarks(values: .automatic(desiredCount: 10)) { _ in AxisValueLabel() } }
            .chartYAxis { AxisMarks(values: .automatic(desiredCount: 3)) }
            .frame(height: 140)
            Text("Last 30 days, by day of the month").font(.caption).foregroundStyle(.tertiary)
        }
    }

    private func breakdown(_ title: String, _ slices: [UsageSlice]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            ForEach(slices.prefix(8)) { s in
                HStack {
                    Text(s.key).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text(count(s.tokens)).foregroundStyle(.secondary).monospacedDigit()
                    Text(s.unpricedTokens == s.tokens && s.tokens > 0 ? "unpriced" : money(s.cost)).monospacedDigit().frame(width: 76, alignment: .trailing)
                }
                .font(.callout)
            }
            if slices.isEmpty { Text("No usage recorded.").foregroundStyle(.secondary) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // U-5
    private var topSessions: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Most expensive sessions — spend in the last 7 days").font(.headline)
            ForEach(model.top.filter { $0.cost > 0 }) { row in
                Button {
                    app.sessionsModel.selection = row.path
                    app.select(.sessions)
                } label: {
                    HStack {
                        Text(row.title).lineLimit(1)
                        Spacer()
                        Text(row.project).foregroundStyle(.secondary).lineLimit(1)
                        Text(costText(row)).monospacedDigit().frame(width: 76, alignment: .trailing)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .font(.callout)
            }
        }
    }

    // U-4
    private var budgets: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(model.budgets) { b in
                let spent = model.budgetSpend[b.id] ?? 0
                HStack {
                    Image(systemName: spent > b.limitUSD ? "exclamationmark.triangle.fill" : "checkmark.circle")
                        .foregroundStyle(spent > b.limitUSD ? .orange : .secondary)
                    Text("\(b.project ?? "All projects") · per \(b.period.rawValue)")
                    Spacer()
                    Text("\(money(spent)) of \(money(b.limitUSD))\(spent > b.limitUSD ? " — over budget" : "")").monospacedDigit()
                    Button { model.budgets.removeAll { $0.id == b.id } } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless).accessibilityLabel("Remove budget")
                }
                .font(.callout)
            }
            HStack {
                Picker("Project", selection: $newBudgetProject) {
                    Text("All projects").tag(String?.none)
                    ForEach(app.sessionsModel.projects, id: \.self) { Text($0).tag(String?.some($0)) }
                }
                .frame(width: 180)
                Picker("Period", selection: $newBudgetPeriod) {
                    Text("Per day").tag(Budget.Period.day)
                    Text("Per month").tag(Budget.Period.month)
                }
                .frame(width: 120)
                TextField("USD", text: $newBudget).frame(width: 80).textFieldStyle(.roundedBorder)
                Button("Add Budget") {
                    guard let v = Double(newBudget.replacingOccurrences(of: ",", with: ".")), v > 0 else { return }
                    let b = Budget(project: newBudgetProject, period: newBudgetPeriod, limitUSD: v)
                    model.budgets.removeAll { $0.id == b.id }
                    model.budgets.append(b)
                    newBudget = ""
                }
            }
            .labelsHidden()
        }
    }
}
