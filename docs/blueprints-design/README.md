# Blueprints: the form and the list (8 Nov 2026)

Benjamin's design for Blueprints is in `../blueprints-design.md`. These
mockups draw what it leaves open. The form can stack its rounds, newest at
the bottom, or show one at a time, and the header has a switch for it. We
need to see which reads better with a few rounds in. Continue sits under
the last question of the open round, with a muted "Write it now" beside
it, and the composer below takes a note that rides along. We need to see
whether that is one submit too many next to the composer's send arrow.

The other thing to settle is the header once the spec is written. A Ready
blueprint has three ways to start and a quiet "Check the spec", and the
edited-by-hand and spec-stale banners sit under the same header. Render
with `./render.sh` (headless Chromium, no install). The look follows
`../options-review-design/review.css`, in dark mode.

1. `1-form-stacked` The detail column: round 1 folded, round 2 open with
   five questions (single with a recommendation, multi, needs-you text with
   an answer from a side chat, number, repo files), Assumptions strip,
   Continue and Write it now, the composer below.
2. `2-form-one-at-a-time` The same thread with the switch on "One at a
   time": only round 2, with a back arrow and "Round 2 of 2".
3. `3-ready` The spec is written: "Ready", "Checked, nothing found", the
   three start buttons (the last disabled), the rounds folded and the
   spec's steps as a checklist. Below it, two header variants: edited by
   hand, and "The spec is older than your answers".
4. `4-list` The activity bar with the Blueprints button selected and the
   list grouped by project, then by state, with "New blueprint" on top.
5. `5-too-small` The too-small card in place of the form.
6. `6-side-chat` The form narrower on the left and a side chat about
   question 3 on the right, ending in a "Proposed answer" card with Use.

## Picks

Benjamin's picks, 8 Nov 2026:

- The form as drawn, stacked by default, with the One at a time switch.
- Continue under the last question, and the composer's send arrow does
  the same as Continue while a round is open. "Fine."
- The per-question buttons ("Ask about this", "You decide") stay
  visible, not on hover ("discoverability"), but smaller and quieter
  than drawn, since they won't be used often. Text, not icons: "You
  decide" has no obvious picture.
- The Ready state: the start buttons go inside the Steps card, not in a
  row under the header. The banners (edited by hand, spec older than
  answers) stay in the header as drawn.
- The recommendation line's "Use" is a plain, link-style control, not
  a button: the button looked too big against the text beside it.
- The copy as drawn.
