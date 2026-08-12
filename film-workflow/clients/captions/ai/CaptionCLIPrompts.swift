#if os(macOS)
import Foundation

/// Instructions for the whole-transcript tasks a CLI agent runs.
///
/// Different in kind from `CaptionAIPrompts`, which describes one caption to a
/// model that answers in one shot. These describe a *job*: the agent is told how
/// to find its own work through MCP, how big a batch to propose, and when to
/// stop. Model-facing English, deliberately unlocalized.
nonisolated enum CaptionCLIPrompts {

    /// Cap on how many edits go in one `caption_propose_edits` call.
    ///
    /// Small enough that a rejected call costs little and the arguments stay
    /// well inside any request limit; large enough that a long transcript
    /// doesn't turn into dozens of round trips.
    static let batchSize = 25

    static func splitInstruction(
        maxRunes: Int,
        minRunes: Int,
        overlong: Int,
        total: Int,
        terms: [CaptionTerm]
    ) -> String {
        var parts = [
            """
            Break the over-long captions in this project into shorter lines.

            The transcript has \(total) captions, of which \(overlong) are longer \
            than \(maxRunes) characters. Read them with \
            caption_list_segments — page through in chunks of 50 — and work on \
            the long ones only.

            For each caption longer than \(maxRunes) characters, decide where it \
            should break and propose a `split` edit whose `pieces` are the parts \
            in order.

            Rules, in order of importance:
            1. Never change, add or remove a spoken word. The pieces joined back \
            together must be the original caption. You may add or correct \
            sentence punctuation, and nothing else.
            2. Two pieces is the usual answer. Only use three when the caption is \
            more than twice \(maxRunes) characters. Never one piece per word or \
            per phrase — a caption that becomes a list of words is a failure, not \
            a split.
            3. Break at a clause or breath boundary, so each piece reads as a \
            complete thought — after a comma, or before a linking word such as \
            "because", "and" or "but". Never break inside a name, a number, or a \
            fixed expression.
            4. No piece may be shorter than about \(minRunes) characters. If the \
            only available break would leave a stub, leave the caption alone.
            5. Captions of \(maxRunes) characters or fewer are already fine. Do \
            not propose anything for them.

            Give each edit a short `reason` naming the boundary you chose.
            """
        ]

        let glossary = CaptionTermMatching.promptBlock(terms)
        if !glossary.isEmpty {
            parts.append(glossary)
            parts.append("Never break inside a glossary term.")
        }

        parts.append(closing(verb: "split"))
        return parts.joined(separator: "\n\n")
    }

    static func termInstruction(total: Int, terms: [CaptionTerm]) -> String {
        [
            """
            Proofread this project's captions against its glossary.

            The transcript has \(total) captions. Find the ones that mention a \
            glossary term — caption_search_segments, once per term and once per \
            known wrong spelling, is far cheaper than reading everything.

            Propose a `replace_text` edit for every caption where a glossary term \
            is misspelled or was misheard, with the whole caption as `text` and \
            only the term corrected.

            Change nothing else. Do not rephrase, do not fix grammar, and do not \
            touch punctuation or capitalisation away from the term itself. A \
            caption whose only problem is that you would have worded it \
            differently is not a problem.
            """,
            CaptionTermMatching.promptBlock(terms),
            closing(verb: "corrected"),
        ]
        .filter { !$0.isEmpty }
        .joined(separator: "\n\n")
    }

    /// Shared tail: how to hand the work back.
    ///
    /// Spelled out because a coding agent's instinct at the end of a task is to
    /// summarise what it *would* do; here the tool call is the deliverable, and
    /// a turn that ends without one has produced nothing.
    private static func closing(verb: String) -> String {
        """
        Send your edits with caption_propose_edits, at most \(batchSize) per \
        call, as you go. Do not describe the changes in your reply instead of \
        proposing them — a reply with no tool call means no work was done. The \
        user reviews and approves every edit, so nothing you propose takes \
        effect on its own.

        Finish with one sentence saying how many captions you \(verb).
        """
    }
}
#endif
