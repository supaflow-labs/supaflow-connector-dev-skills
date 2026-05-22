# Connector Docs And Marketing

Use this reference when a connector task includes customer-facing docs or marketing in `supaflow-www`.

## Goal

Write and review connector docs as product documentation for users configuring a connector, not internal notes for engineers reading implementation details.

## Template First

Before drafting or reviewing, inspect 2-3 clean existing connector docs and use them as the pattern for:

- opener length and tone
- section layout
- table style
- troubleshooting style
- level of detail

Good reference types:

- one simple file-like source, such as `sftp.mdx`
- one API source with broader object coverage, such as `hubspot.mdx`
- one mature operational source, such as `postgres.mdx`

Use connector code and tests only to validate claims after the pattern is established.

## Sources Index Is Required

Every new docs page MUST be paired in the same commit with a matching entry in the human-curated landing page `supaflow-www/docs-src/docs/02-sources/index.md` (or `03-destinations/index.md` for destinations). The Docusaurus sidebar and the `/docs/sitemap.xml` auto-discover MDX files; the index landing page does not. A new connector that ships docs without an index entry is invisible to anyone browsing `/docs/sources` -- it ranks as an incomplete change.

Use existing entries as the voice template:

```
### {Category}

**[{Name}](./{slug})**
{One-sentence summary in the same voice as the docs frontmatter description.}
```

Match the docs frontmatter `description` in tone -- mechanism-forward, no marketing adjectives, end with a scope qualifier where honest (e.g., "Community connector built on dltHub.").

Pre-commit smoke test, run from `supaflow-www`:

```
grep -i '<slug>' docs-src/docs/02-sources/index.md
```

Zero matches = the entry didn't land. Fix before committing.

## Marketing Pages Are Templated

Connector marketing pages in `supaflow-www/data/connectors/marketing/*.ts` fill the
`ConnectorMarketing` template. Treat them as template data, not freeform docs.

- write concise copy for the existing template fields (`hero`, `capabilities`,
  `supportedObjects`, `setupSteps`, `useCases`, `faq`)
- do not invent doc-style sections inside the copy
- keep each capability, setup step, and FAQ answer self-contained and scannable
- remember that `setupSteps.detail` and `faq.answer` are rendered as plain text surfaces;
  do not rely on markdown lists, headings, emphasis, or inline markdown links there
- if a long vendor workflow needs explanation, keep the marketing page brief and put the
  fuller operational guidance in the source doc instead

## Writing Rules

- Keep the opening paragraph broad. Do not list exact objects, sync modes, cursor fields, or internal columns there.
- Put object-by-object coverage in `Supported Objects`.
- Keep `Incremental Sync` short and user-facing:
  - say which objects are incremental
  - say which are full refresh
  - mention only user-visible constraints or gotchas
- Keep authentication focused on what the user needs to create and grant. Avoid protocol mechanics unless the user must act on them.
- For protected scopes, approval-only permissions, or other vendor-controlled access steps:
  - say what needs extra approval
  - say why the user cares
  - point to the official vendor docs
  - do not restate the mutable vendor workflow in our own words
- Keep troubleshooting operational. Tell the user what to check or change, not which internal endpoint/header/namespace the connector uses.
- Keep marketing copy outcome-focused. Do not explain connector internals unless they are user-visible and stable.
- In source-doc configuration sections:
  - use the red asterisk from `FieldLabel ... required` for required fields
  - use `Options:` for enumerated values
  - group advanced settings only when it improves scanning

## Review Order

1. Pattern pass:
   - Does this read like the clean existing docs?
   - Is the tone user-facing?
   - Are sections and tables in the expected places?
2. Factual pass:
   - Are capability claims grounded in connector code/tests or official vendor docs?
   - Are volatile vendor-controlled facts current?
3. Red-flag pass:
   - Does any paragraph drift into implementation detail?
   - Does any claim sound more like connector notes than product docs?
4. Template-surface pass for marketing pages:
   - Does the copy fit the actual `ConnectorMarketing` template shape?
   - Does `setupSteps` and `faq` copy still work as plain text?
   - Did we avoid stuffing long vendor workflows into marketing fields?

## Red Flags

These should usually be findings in review:

- `v1 connector` or similar versioned product wording
- object list, sync mode, or cursor field in the opener
- raw internal identifiers or state namespaces
- internal table names, discriminator columns, primary-key mechanics
- protocol/header details such as `Authorization: Bearer` or `X-RateLimit-*`
- raw endpoint paths
- API version pinning, OpenAPI generation, GraphQL query-shape discussion
- source-specific rate-limit numbers in the docs
- typed-error or retry-layer implementation details
- copied vendor approval workflows for protected scopes or permissions-required access
- markdown or formatting assumptions in plain-text marketing surfaces

## Rate-Limit Pattern

Prefer this pattern unless there is a strong reason not to:

- The source applies API rate limits.
- Supaflow handles transient rate limiting automatically.
- Large syncs may take longer or may need narrower scope or off-peak scheduling.
- Link the official vendor rate-limit docs for current limits.

## Simple Telltale Test

If a sentence could be pasted into connector source-code documentation or an implementation design note without sounding out of place, it is probably too technical for customer-facing docs.
