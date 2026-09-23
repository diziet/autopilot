# Writing style — clear English

This guide governs English prose in a repository: documentation, code comments, doc comments,
test names and failure messages, UI copy, pull-request descriptions, and agent instructions.

The rule is:

> **Use the simplest concrete sentence that states the exact fact.**

A reader should understand a sentence on the first pass without translating an image or guessing
an unnamed subject. Use the project's defined terms where they apply and ordinary English
everywhere else.

A project may add stricter guides for specific surfaces, such as user-facing copy or translated
text. Where one applies, follow both, and the stricter guide wins where it is more specific.
Quotations stay verbatim. Historical records get the same treatment as everything else: fix the
wording, keep the facts and the chronology.

Code identifiers are not prose. Do not rename a field, function, type, or ID to satisfy a writing
preference. Use its exact name and then explain its behavior.

## The voice

Write as a smart person speaking plainly to another smart person. Use short sentences, ordinary
words, and concrete reasoning. Cut preamble and filler.

The model is the prose of Paul Graham's essays: conversational, compressed, concrete, and willing
to say the plain thing. Apply those qualities. Do not imitate his phrases or habits.

In technical, instructional, and rules text, avoid corporate, academic, literary, and marketing
voices. Do not sound grand, cute, or mysterious. Such text follows the principles of ASD-STE100
Simplified Technical English: one topic per sentence, one meaning per word, active voice, and short
sentences. It does not adopt the STE controlled dictionary.

Text written for character or atmosphere may use a different voice. It must not obscure
instructions, contradict the rules, or imply behavior that does not exist.

## The rules

### 1. Say the fact directly

Lead with the subject and the change, rule, reason, or result. Do not warm up, dramatize the
problem, or narrate how you discovered it. The first sentence carries the most important fact.
Supporting detail follows only when the reader needs it.

- Prefer: “`apply_discount` sets the order total to 0 when the customer redeems a full-value
  voucher.”
- Avoid: “Redeeming the voucher wipes the bill clean.”

### 2. Name the actual thing

Use the noun the code or interface uses. Name the state, value, action, and time. Avoid “it,”
“this,” “the flow,” and “the system” when more than one subject is possible.

- `Account.balance`, not “the purse”
- item quantity, not “stock depth”
- calls `resolve_retry_delay`, not “uses the retry plumbing”

An exact identifier is usually the shortest unambiguous noun.

### 3. Use literal language

Do not use metaphor, imagery, or personification to carry technical meaning. Code does not
swallow, promise, or decide unless that word names a real operation.

A familiar metaphor can still be unclear. “Cash out,” “thread through,” and “wire up” make the
reader reconstruct the real operation. State the operation instead.

Established technical terms are fine when they are exact: a Git branch, a process thread, a hook.
Proper names are fine. The test is whether the term names a recognized thing or only makes the
sentence vivid.

### 4. Use established vocabulary

Do not invent a synonym when the project already has a term. A new term must name a new concept.
Use the same word for the same operation across nearby files. If one comment says “store” and
another says “bank” for the same transition, pick the literal established term and align both.

### 5. Keep the structure simple

Put one main claim in each sentence. Split independent changes, causes, and exceptions. Prefer a short
paragraph to a sentence with nested clauses.

Use a list when the reader must compare or verify separate facts. Do not use one to make a
simple sentence look substantial.

Use parentheses for brief precision. If a parenthetical carries a rule, give it a sentence or
remove it.

### 6. Cut before rewording

Delete a sentence that repeats the code, the previous sentence, a visible UI result, or a rule
documented elsewhere. Keep a detail when it changes what the reader should implement, verify, or
expect. Cut it when it only reassures or restates a consequence already given.

### 7. Prefer ordinary verbs

Use `set`, `add`, `remove`, `increase`, `decrease`, `store`, `call`, `return`, `reject`, and
`skip` when they are accurate. Do not replace a plain verb to avoid repetition.

Check `hold`, `handle`, `support`, `work`, and `keep`. They can be correct, but they often hide
the state or operation. Ask what is held, what behavior is supported, or what value changes.

### 8. Do not coach the reader

Do not add “simply,” “obviously,” “of course,” “as you can see,” or “note that.” Do not call a
design elegant, robust, clean, or intuitive. Show the property.

Do not use rhetorical questions, jokes, or scene-setting in technical prose.

### 9. Preserve meaning when simplifying

Plain is not vague. Keep exact conditions, timing, quantities, exceptions, and subjects. Do not
drop a technical distinction because the shorter sentence sounds smoother. When the behavior is
unclear, read the code or ask. Do not fill a gap with a plausible story.

## Surface-specific guidance

### Comments and doc comments

A comment explains a reason, invariant, boundary, ordering requirement, or surprising
consequence. It does not translate the code line by line.

- Prefer: “Clear `pending_jobs` after dispatch so a restarted worker cannot run the same job
  twice.”
- Avoid: “The dispatcher consumes what it was holding so nothing leaks into the next cycle.”

Delete a comment that adds nothing beyond the code. Update a comment in the same change that
alters its invariant.

### Engineering documentation

Start with the rule or decision. Then name the implementation and the test evidence. Keep cause
and effect explicit. A heading states what the section contains.

### Tests and failure messages

A test name states the condition and the expected result. A failure message states what should
be true at that assertion.

- Prefer: `full_value_voucher_sets_order_total_to_zero`
- Avoid: `voucher_wipes_the_bill`

Humor and narrative make failures harder to search for.

### Pull requests and commits

Lead with the outcome. The body explains why the change was needed, the main implementation
choice, and how it was verified. Do not tell the story of the debugging session. Commit subjects
stay short and use the repository's conventional prefix.

## Before and after

| Avoid | Prefer |
|---|---|
| “The premium tier deepens the quota.” | “The premium tier increases the request quota.” |
| “The resolver pours the same value.” | “Both paths call `resolve_retry_delay`.” |
| “The retry was swallowed.” | “The retry had no effect.” |
| “The credit is banked.” | “The customer receives the credit when the invoice closes.” |
| “This threads through the plumbing.” | Name the functions or data path involved. |
| “The system holds up to 10 workers.” | “The pool can run up to 10 workers.” |
| “Strict mode holds you to 1 attempt.” | “Strict mode sets the maximum attempts to 1.” |

The right rewrite depends on the actual behavior.

## Words to check

`bank`, `cash out`, `deepen`, `feed`, `flow`, `hold`, `plumbing`, `pour`, `swallow`, `thread through`,
`wire up`.

These are review prompts, not bans. Keep a proper name, an identifier, or a literal technical use.
Otherwise replace the word with the exact state or operation. Do not swap in a different metaphor.

## Review checklist

Before committing prose, read the changed paragraph in context and ask:

1. What exact fact does each sentence add?
2. Does every noun have one clear referent?
3. Does every verb describe the real operation?
4. Can any sentence, clause, or parenthetical be deleted?
5. Are the exact condition, timing, quantity, and exception preserved?
6. Are the project's established terms used?
7. Would a reader understand it once, without translating a metaphor?

If a sentence is hard to simplify, check the underlying behavior. A complicated sentence often
means the design or implementation is not settled.
