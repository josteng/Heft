import HeftCore
import SwiftUI
import UIKit

/// The daily notes, with the day's note right under its calendar.
///
/// The month sits on top and the selected day's note below it, rendered
/// and editable in place. Reading down into the note folds the month to a
/// single week, title and all, so the note gets the screen without the
/// calendar leaving it; scrolling back to the top, or tapping the selected
/// day, opens it again. Swiping pages the month, or the week while folded.
/// A dot marks a day that has a note.
struct CalendarView: View {
    @Environment(MobileVault.self) private var vault
    @State private var month = Calendar.current.dateInterval(of: .month, for: Date())!.start
    /// The first day of the week the folded calendar shows. Starts on the
    /// selected day's week and moves when the folded row is swiped.
    @State private var shownWeek = Calendar.current.dateInterval(of: .weekOfYear, for: Date())!.start
    @State private var selected = Calendar.current.startOfDay(for: Date())
    @State private var document: NoteDocument?
    @State private var folded = false
    /// How far the grid sits off to the side: following a finger, or
    /// sliding out and back in as a page turns.
    @State private var slide: CGFloat = 0
    /// Once folded and settled, the week row gives way to a strip of days
    /// that scrolls freely; `bandDay` is the leftmost day showing in it.
    @State private var bandShown = false
    @State private var bandDay: Date?
    /// Where the strip's half-year either side is counted from: fixed while
    /// it shows, so scrolling does not rebuild the days under the finger.
    @State private var bandOrigin = Date()
    @State private var problem: String?
    @State private var action: ItemAction?
    /// When the last swipe ended. A finger lifting off a swipe lands on a
    /// day, and a day button takes that lift for a tap: paging a month
    /// opened whatever day was under the thumb.
    @State private var swipedAt = Date.distantPast

    private let calendar = Calendar.current
    private var dayRequest = CalendarDayRequest.shared
    private static let fold = Animation.smooth(duration: 0.35)
    private static let rowHeight: CGFloat = 40

    var body: some View {
        // The note runs under the month, as a list runs under a bar, and
        // ends at its edge rather than at a rule.
        note
            .safeAreaBar(edge: .top) {
                grid.padding(.bottom, 8)
            }
        .navigationTitle(month.formatted(.dateTime.month(.wide).year()))
        .navigationBarTitleDisplayMode(.inline)
        // Shown on the left instead; the bar's own centred title stays as
        // the screen's name for VoiceOver.
        .toolbar(removing: .title)
        .toolbar {
            // The month on the left, as Calendar has it, and the only title:
            // a day's name above a month row said nearly the same thing
            // twice. The day is marked in the grid, and a daily note's own
            // heading names it. Tapping it folds or opens the calendar, and
            // its digits roll as the months page.
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    if folded { unfold() } else { fold() }
                } label: {
                    Text(month.formatted(.dateTime.month(.wide).year()))
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.primary)
                        .contentTransition(.numericText(value: month.timeIntervalSinceReferenceDate))
                        .fixedSize()
                }
                .tint(.primary)
                .accessibilityHint(folded ? "Shows the whole month" : "Folds the month to one week")
            }
            .sharedBackgroundVisibility(.hidden)
            // Today first, so the group grows to the left when it appears,
            // and only away from today and not while typing. Capture is
            // placed here rather than by the tab so it can come after it.
            if document?.editing != true {
                if !showsToday {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { goToToday() } label: {
                            Image(systemName: Self.todaySymbol)
                        }
                        .tint(.primary)
                        .accessibilityLabel("Today")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) { CaptureButton() }
            }
        }
        .onAppear {
            openSelected()
            #if DEBUG
            if let shift = ProcessInfo.processInfo.environment["HEFT_IOS_DAY"].flatMap(Int.init) {
                select(calendar.date(byAdding: .day, value: shift, to: Date()) ?? Date())
            }
            if ProcessInfo.processInfo.environment["HEFT_IOS_FOLDED"] != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { fold() }
                if ProcessInfo.processInfo.environment["HEFT_IOS_UNFOLD"] != nil {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { unfold() }
                }
            }
            #endif
        }
        .onChange(of: collapsed) { _, now in
            if now {
                // Folding shows the selected day's week, whatever was
                // browsed to, and the strip takes over once the fold has
                // settled, starting on exactly that week so the swap is
                // invisible.
                show(week: weekStart(of: selected))
                bandDay = shownWeek
                bandOrigin = shownWeek
                // `fold()` hands over when its animation has settled; this
                // covers folding for the keyboard, which is not animated.
                Task {
                    try? await Task.sleep(for: .milliseconds(700))
                    if collapsed { bandShown = true }
                }
            } else {
                // Opening on the week the strip was scrolled to.
                if bandShown, let bandDay { show(week: weekStart(of: bandDay)) }
                bandShown = false
            }
        }
        .onChange(of: dayRequest.day, initial: true) { _, day in
            guard let day else { return }
            dayRequest.day = nil
            select(day)
        }
        .onChange(of: vault.generation) { _, _ in
            // A note made from the template, or one that arrived from
            // iCloud, replaces the empty-day prompt once it is indexed.
            if document == nil { openSelected() }
        }
        .itemActionHost($action)
        .alert("Can't Create Daily Note", isPresented: .constant(problem != nil)) {
            Button("OK") { problem = nil }
        } message: {
            Text(problem ?? "")
        }
    }

    // MARK: Calendar

    /// Folded while the note is read further down or edited.
    private var collapsed: Bool { folded || document?.editing == true }

    /// The month's name, which tapping folds, between arrows that page it;
    /// gone while folded, when the selected day is what opens it again.
    /// A calendar with one day marked, which iOS 27 has; the plain calendar
    /// before that, where the newer symbol would draw nothing.
    private static let todaySymbol = UIImage(systemName: "calendar.day") == nil ? "calendar" : "calendar.day"

    /// Today is selected and on show: in the month, or in the folded
    /// strip's seven days, which scroll away from it on their own.
    private var showsToday: Bool {
        guard calendar.isDateInToday(selected) else { return false }
        if bandShown, let bandDay {
            let end = calendar.date(byAdding: .day, value: 7, to: bandDay) ?? bandDay
            return (bandDay..<end).contains(calendar.startOfDay(for: Date()))
        }
        return calendar.isDate(month, equalTo: Date(), toGranularity: .month)
    }

    /// Back to today, scrolling a folded strip to its week.
    private func goToToday() {
        select(Date())
        guard bandShown else { return }
        let week = weekStart(of: selected)
        if abs(calendar.dateComponents([.day], from: bandOrigin, to: week).day ?? 0) > 170 {
            bandOrigin = week
        }
        withAnimation(.smooth) { bandDay = week }
    }

    private func weekStart(of date: Date) -> Date {
        calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? calendar.startOfDay(for: date)
    }

    /// Every week touching the month, each a full seven days: the days of
    /// the neighbouring months fill the first and last rows, dimmed, so a
    /// folded week is never cut short at a month's edge.
    private var weeks: [[Date]] {
        let start = weekStart(of: month)
        let end = calendar.date(byAdding: .month, value: 1, to: month) ?? month
        var weeks: [[Date]] = []
        var day = start
        while day < end {
            weeks.append((0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: day) })
            day = calendar.date(byAdding: .day, value: 7, to: day) ?? end
        }
        return weeks
    }

    /// One grid for both states: folding closes every week but the shown
    /// one to nothing, so that week slides into place rather than one view
    /// fading into another.
    private var grid: some View {
        Group {
            if bandShown {
                band
            } else {
                weeksGrid
            }
        }
        .contentShape(.rect)
        .simultaneousGesture(swipes)
        // Swiping is the only paging on screen; VoiceOver pages by adjusting.
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: page(1)
            case .decrement: page(-1)
            @unknown default: break
            }
        }
    }

    private var weeksGrid: some View {
        // No stack spacing: a closed week has to take up nothing at all, or
        // the folded grid stands taller than the strip that replaces it and
        // the note jumps at the handover. Rows carry their own gap instead.
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                ForEach(WeekLayout.symbols(firstWeekday: calendar.firstWeekday), id: \.self) {
                    Text($0)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.bottom, 6)
            VStack(spacing: 0) {
                ForEach(weeks, id: \.first) { week in
                    let kept = !collapsed || week.first.map { calendar.isDate($0, inSameDayAs: shownWeek) } == true
                    HStack(spacing: 4) {
                        ForEach(week, id: \.self) { dayCell($0) }
                    }
                    .frame(height: kept ? Self.rowHeight + 2 : 0, alignment: .top)
                    .opacity(kept ? 1 : 0)
                    .clipped()
                }
            }
            .animation(nil, value: month)
            .offset(y: slide)
            .opacity(1 - min(abs(slide) / 240, 0.7))
            // A month sliding out stays inside the calendar rather than over
            // the month's name or the note.
            .clipped()
        }
        .padding(.horizontal)
        .padding(.top, 4)
    }

    /// The folded calendar: days in one row that scrolls on and back as
    /// far as wanted, settling on a whole day, each with its weekday over
    /// it since no header could line up with a strip that moves.
    private var band: some View {
        let symbols = WeekLayout.symbols(firstWeekday: 1)
        let days = (-180...180).compactMap { calendar.date(byAdding: .day, value: $0, to: bandOrigin) }
        return ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 4) {
                ForEach(days, id: \.self) { day in
                    VStack(spacing: 0) {
                        Text(symbols[calendar.component(.weekday, from: day) - 1])
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.bottom, 6)
                        dayCell(day)
                            .frame(height: Self.rowHeight + 2, alignment: .top)
                    }
                    .containerRelativeFrame(.horizontal, count: 7, spacing: 4)
                }
            }
            .scrollTargetLayout()
        }
        .contentMargins(.horizontal, 16, for: .scrollContent)
        .scrollTargetBehavior(.viewAligned)
        .scrollPosition(id: $bandDay, anchor: .leading)
        // A sideways scroll view takes all the height it is offered; this
        // one is exactly the folded week row it stands in for.
        .fixedSize(horizontal: false, vertical: true)
        .padding(.top, 4)
    }

    /// Up and down page the month, as Calendar on iOS does: the weeks
    /// follow the finger and a short flick turns the page. Folding is left
    /// to the note's scrolling and to the month's name, and the folded strip
    /// scrolls sideways by itself.
    private var swipes: some Gesture {
        DragGesture(minimumDistance: 15)
            .onChanged { drag in
                guard !collapsed, abs(drag.translation.height) > abs(drag.translation.width) else { return }
                slide = drag.translation.height
            }
            .onEnded { drag in
                swipedAt = Date()
                let along = drag.predictedEndTranslation.height
                if !collapsed, abs(drag.translation.height) > abs(drag.translation.width), abs(along) > 60 {
                    page(along < 0 ? 1 : -1)
                } else {
                    withAnimation(.snappy) { slide = 0 }
                }
            }
    }

    /// Slides the weeks out the way the finger went and the next month in
    /// from the other side.
    private func page(_ direction: Int) {
        let distance: CGFloat = 220
        withAnimation(.easeIn(duration: 0.12)) {
            slide = -CGFloat(direction) * distance
        } completion: {
            var still = Transaction()
            still.disablesAnimations = true
            withTransaction(still) {
                slide = CGFloat(direction) * distance
            }
            // Animated for the title, which rolls to the new month; the
            // weeks keep out of it and simply slide in.
            withAnimation(.snappy(duration: 0.18)) {
                month = calendar.date(byAdding: .month, value: direction, to: month) ?? month
            }
            withAnimation(.easeOut(duration: 0.2)) { slide = 0 }
        }
    }

    /// Folds to the selected week, and hands over to the strip only once
    /// the animation has settled. The spring keeps moving a point or two
    /// past its nominal duration, and a strip arriving on a timer met the
    /// row before it had, which showed as a small hop.
    private func fold() {
        guard !folded else { return }
        withAnimation(Self.fold) {
            folded = true
        } completion: {
            if collapsed { bandShown = true }
        }
    }

    /// Opens a folded calendar the way it folded, in reverse.
    ///
    /// The strip goes first, giving way to the grid still folded on the
    /// week it was scrolled to; only on the next pass does the grid open.
    /// Swapping and opening in one step drew the grid already open, which
    /// was a jump where folding was an animation.
    private func unfold() {
        guard folded else { return }
        if bandShown {
            if let bandDay { show(week: weekStart(of: bandDay)) }
            bandShown = false
            DispatchQueue.main.async {
                withAnimation(Self.fold) { folded = false }
            }
        } else {
            withAnimation(Self.fold) { folded = false }
        }
    }

    /// Folded on `week`, with the month on show the one most of it is in.
    private func show(week: Date) {
        shownWeek = week
        let middle = calendar.date(byAdding: .day, value: 3, to: week) ?? week
        let owner = calendar.dateInterval(of: .month, for: middle)?.start ?? month
        if owner != month { month = owner }
    }

    private func dayCell(_ date: Date) -> some View {
        let today = calendar.isDateInToday(date)
        let chosen = calendar.isDate(date, inSameDayAs: selected)
        let inMonth = calendar.isDate(date, equalTo: month, toGranularity: .month)
        let exists = existing(date) != nil
        return Button {
            guard Date().timeIntervalSince(swipedAt) > 0.3, slide == 0 else { return }
            if chosen, collapsed {
                unfold()
            } else {
                select(date)
            }
        } label: {
            VStack(spacing: 2) {
                Text("\(calendar.component(.day, from: date))")
                    .font(.callout.weight(today || chosen ? .bold : .regular))
                    .foregroundStyle(chosen ? Color.white
                                     : today ? Color.accentColor
                                     : inMonth || collapsed ? Color.primary : Color.secondary.opacity(0.6))
                    .frame(width: 32, height: 32)
                    .background(chosen ? Color.accentColor : .clear, in: .circle)
                Circle()
                    .fill(exists ? Color.accentColor : .clear)
                    .frame(width: 4, height: 4)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(date.formatted(date: .complete, time: .omitted))
        .contextMenu { DayMenu(date: date) { action = $0 } }
        .accessibilityValue(exists ? "Has a note" : "")
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }

    // MARK: The note

    @ViewBuilder
    private var note: some View {
        if let document {
            NoteContent(document: document, scrolledDown: { down in
                guard down != folded else { return }
                if down {
                    fold()
                } else {
                    unfold()
                }
            }, findInMenu: true, topInset: 20)
            .id(document.path)
        } else {
            ContentUnavailableView {
                Label("No Note", systemImage: "calendar.badge.plus")
            } description: {
                Text(selected.formatted(date: .complete, time: .omitted))
            } actions: {
                Button("Create Note", action: create)
                    .buttonStyle(.borderedProminent)
            }
            .frame(maxHeight: .infinity)
        }
    }

    private func existing(_ date: Date) -> NoteRef? {
        guard let dailyNotes = vault.dailyNotes else { return nil }
        return vault.index.note(atRelativePath: dailyNotes.relativePath(for: date))
    }

    private func select(_ date: Date) {
        // Another day while typing: the keyboard goes, and the note being
        // left saves as it disappears.
        document?.editing = false
        withAnimation(.snappy(duration: 0.18)) {
            selected = calendar.startOfDay(for: date)
        }
        if collapsed {
            if !bandShown { show(week: weekStart(of: selected)) }
        } else if !calendar.isDate(selected, equalTo: month, toGranularity: .month) {
            month = calendar.dateInterval(of: .month, for: selected)?.start ?? month
        }
        openSelected()
    }

    private func openSelected() {
        let path = existing(selected)?.relativePath
        guard path != document?.path else { return }
        // A folded calendar stays folded: the next day's note, or its
        // prompt, opens under the same strip.
        document = path.map(NoteDocument.init(path:))
    }

    /// From the daily template; `ensureNote` never overwrites, so a note
    /// that appeared meanwhile is simply opened.
    private func create() {
        do {
            let note = try vault.dailyNote(for: selected)
            document = NoteDocument(path: note.relativePath)
        } catch {
            problem = error.localizedDescription
        }
    }
}

/// A day to show, from outside the calendar: a daily note handed over from
/// the Mac or asked for by an intent opens on its day here.
@MainActor @Observable
final class CalendarDayRequest {
    static let shared = CalendarDayRequest()
    var day: Date?
}
