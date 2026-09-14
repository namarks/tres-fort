import Foundation

/// Pure recovery decisions. Persistence, network delivery and artifact ownership
/// remain with their existing owners; cached rows never acknowledge an intent.
enum RunnerRecovery {
    enum Decision {
        case mounted(bind: SessionRow?)
        case waitingForFirstSet(bind: SessionRow?)
        case resume(session: SessionRow?)
        case waitingForValidation
        case discard
    }

    static func canResumeOffline(_ checkpoint: WorkoutRunnerCheckpoint, session: SessionRow?) -> Bool {
        guard let session else { return checkpoint.sessionID == nil && checkpoint.sessionAttempt == nil }
        guard session.date == checkpoint.date,
              session.attempt != nil,
              checkpoint.sessionID == nil || checkpoint.sessionID == session.id,
              attemptMatches(checkpoint, serverSession: session) else { return false }
        if session.status == "discarded" {
            return checkpoint.sessionID == nil && checkpoint.restartDiscardedAttempt != nil
                && checkpoint.restartDiscardedAttempt == session.attempt
        }
        return session.status == "planned" || session.status == "in_progress"
    }

    static func decision(
        _ checkpoint: WorkoutRunnerCheckpoint,
        session: SessionRow?, today: String, mounted: Bool,
        hasTerminalIntent: Bool, hasPendingFirstSet: Bool, offline: Bool
    ) -> Decision {
        if let session, !attemptMatches(checkpoint, serverSession: session) {
            return offline ? .waitingForValidation : .discard
        }
        if mounted {
            if let session {
                if session.status == "discarded" {
                    return checkpoint.sessionID == nil && checkpoint.restartDiscardedAttempt != nil
                        && checkpoint.restartDiscardedAttempt == session.attempt
                        ? .mounted(bind: nil) : .discard
                }
                guard session.status == "planned" || session.status == "in_progress" else { return .discard }
            }
            return .mounted(bind: checkpoint.sessionID == nil ? session : nil)
        }
        guard checkpoint.date == today, !hasTerminalIntent else {
            return offline ? .waitingForValidation : .discard
        }
        if offline {
            return canResumeOffline(checkpoint, session: session)
                ? .resume(session: session?.status == "discarded" ? nil : session)
                : .waitingForValidation
        }
        let restarting = checkpoint.sessionID == nil && checkpoint.restartDiscardedAttempt != nil
            && checkpoint.restartDiscardedAttempt == session?.attempt && session?.status == "discarded"
        if hasPendingFirstSet && (session == nil || session?.status == "planned" || restarting) {
            return .waitingForFirstSet(bind: session?.status == "discarded" ? nil : session)
        }
        guard session?.status == "in_progress" || canResumeUnstartedFeedback(checkpoint, session: session)
        else { return .discard }
        return .resume(session: session?.status == "discarded" ? nil : session)
    }

    /// Migration 0032 assigns generation zero to legacy rows. A checkpoint
    /// missing its local attempt therefore means attempt 0, not "adopt
    /// whichever generation is current." The sole exception is an explicit
    /// restart, whose marker names the discarded generation and therefore
    /// expects the next one once the server revives the date.
    static func attemptMatches(
        _ checkpoint: WorkoutRunnerCheckpoint,
        serverSession: SessionRow
    ) -> Bool {
        if checkpoint.sessionID == nil,
           serverSession.status == "discarded",
           checkpoint.restartDiscardedAttempt == serverSession.attempt
        {
            return true
        }
        guard let serverAttempt = serverSession.attempt else { return true }
        let expectedAttempt = checkpoint.sessionAttempt
            ?? checkpoint.restartDiscardedAttempt.map { $0 + 1 }
            ?? 0
        return expectedAttempt == serverAttempt
    }

    static func canResumeUnstartedFeedback(_ checkpoint: WorkoutRunnerCheckpoint, session: SessionRow?) -> Bool {
        guard checkpoint.feedback != nil || !(session?.exerciseSwaps.entries.isEmpty ?? true) else { return false }
        guard let session else { return checkpoint.sessionID == nil }
        guard attemptMatches(checkpoint, serverSession: session) else { return false }
        return session.status == "planned" || (checkpoint.sessionID == nil
            && session.status == "discarded" && checkpoint.restartDiscardedAttempt == session.attempt
            && checkpoint.restartDiscardedAttempt != nil)
    }

    static func normalized(
        _ checkpoint: WorkoutRunnerCheckpoint,
        day: Workout,
        serverSession: SessionRow?,
        setIDs: [String: Set<String>],
        preservingFocusIn groups: Set<String> = []
    ) -> WorkoutRunnerCheckpoint? {
        guard !day.exercises.isEmpty, checkpoint.workoutStartedAtMS > 0,
              let currentSlotID = checkpoint.currentSlotID,
              let currentIndex = day.exercises.firstIndex(where: { $0.id == currentSlotID })
        else { return nil }
        let liveSlotIDs = Set(day.exercises.map(\.id))
        let normalizedSkipped = checkpoint.skippedSlotIDs
            .filter { liveSlotIDs.contains($0) }
            .sorted()
        let skippedIDs = Set(normalizedSkipped)
        func checkpointSetIDs(_ slot: TemplateExercise) -> Set<String> {
            setIDs[slot.id] ?? []
        }
        func checkpointGroup(_ slot: TemplateExercise) -> GroupRunnerProgress? {
            guard let id = slot.group_id else { return nil }
            return GroupRunnerProgress(id: id, members: day.exercises.filter { $0.group_id == id }.map {
                .init(id: $0.id, target: $0.target_sets, completedIDs: checkpointSetIDs($0), skipped: skippedIDs.contains($0.id))
            })
        }
        let unresolvedIndices = Set(day.exercises.indices.filter { index in
            let slot = day.exercises[index]
            return !skippedIDs.contains(slot.id) && checkpointSetIDs(slot).count < slot.target_sets
        })
        let normalizedFinished = unresolvedIndices.isEmpty
        let normalizedCurrentSlotID: String
        let currentGroup = checkpointGroup(day.exercises[currentIndex])
        let preserveFocus = currentGroup.map { groups.contains($0.id) } ?? false
        let deferredProgress = checkpoint.deferredGroupRepair.flatMap { repair -> GroupRunnerProgress? in
            guard RunnerGroupRepair(groupID: repair.groupID, day: day) == repair,
                  let slot = day.exercises.first(where: { $0.group_id == repair.groupID }) else { return nil }
            return checkpointGroup(slot)
        }
        if let nextID = deferredProgress?.nextMemberID {
            normalizedCurrentSlotID = nextID
        } else if !normalizedFinished, let group = currentGroup,
           !preserveFocus, group != checkpoint.groupProgress, let nextID = group.nextMemberID {
            normalizedCurrentSlotID = nextID
        } else if preserveFocus || normalizedFinished || unresolvedIndices.contains(currentIndex)
                    || (currentGroup != nil && currentGroup == checkpoint.groupProgress) {
            normalizedCurrentSlotID = currentSlotID
        } else {
            // Mirror the mounted runner's wrapped next-unresolved rule. This
            // advances a checkpoint left behind while its set request awaited
            // the network and lands an all-resolved workout on FinishedView.
            let nextIndex = (1...day.exercises.count)
                .map { (currentIndex + $0) % day.exercises.count }
                .first(where: unresolvedIndices.contains)!
            normalizedCurrentSlotID = checkpointGroup(day.exercises[nextIndex])?.nextMemberID ?? day.exercises[nextIndex].id
        }
        var normalizedFocus = checkpoint.focus
        if normalizedCurrentSlotID != currentSlotID
            || (normalizedFinished && !checkpoint.finished) || deferredProgress != nil {
            normalizedFocus?.isExplicit = false
        }
        return WorkoutRunnerCheckpoint(
            date: checkpoint.date,
            sessionID: serverSession?.id,
            selectedDayID: checkpoint.selectedDayID,
            currentSlotID: normalizedCurrentSlotID,
            skippedSlotIDs: normalizedSkipped,
            workoutStartedAtMS: checkpoint.workoutStartedAtMS,
            finished: normalizedFinished,
            sessionAttempt: serverSession?.attempt ?? checkpoint.sessionAttempt,
            restartDiscardedAttempt: serverSession == nil ? checkpoint.restartDiscardedAttempt : nil,
            input: checkpoint.input, inputsBySlot: checkpoint.inputsBySlot, groupProgress: day.exercises.first(where: { $0.id == normalizedCurrentSlotID }).flatMap(checkpointGroup),
            focus: normalizedFocus, feedback: checkpoint.feedback)
    }
}
