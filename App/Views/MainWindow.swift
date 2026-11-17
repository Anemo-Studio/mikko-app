import MikkoCore
import SwiftUI

struct MainWindow: View {
    @Environment(AppModel.self) private var model
    @AppStorage("onboardingDone") private var onboardingDone = false

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(get: { model.section }, set: { if let s = $0 { model.select(s) } })) {
                // Three groups instead of eight equal items: what is happening, what it costs in space, what happened.
                ForEach(AppSection.groups, id: \.title) { group in
                    let sections = group.sections.filter(model.visibleSections.contains)
                    if !sections.isEmpty {
                        Section(group.title) {
                            ForEach(sections) { s in Label(s.title, systemImage: s.symbol).tag(s) }
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190)
        } detail: {
            detail
                .navigationTitle(model.section.title)
        }
        .sheet(isPresented: Binding(get: { !onboardingDone }, set: { onboardingDone = !$0 })) {
            OnboardingView { onboardingDone = true }
                .environment(model)
        }
    }

    @ViewBuilder private var detail: some View {
        switch model.section {
        case .overview: OverviewView()
        case .disk: DiskView()
        case .running: RunningView()
        case .simulators: SimulatorsView()
        case .containers: ContainersView()
        case .sessions: SessionsView()
        case .usage: UsageView()
        }
    }
}
