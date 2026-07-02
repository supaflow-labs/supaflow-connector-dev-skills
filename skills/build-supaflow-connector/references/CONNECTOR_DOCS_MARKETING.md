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
- one API source, such as `github.mdx` (the cleanest current exemplar -- zero findings in the 2026-07-01 audit)
- one database source, such as `mariadb.mdx` (canonical member of the What Gets Synced / Sync Modes / Schema Discovery family)

Do not template off `hubspot.mdx`, `salesforce/index.mdx`, `salesforce-marketing-cloud.mdx`, or `postgres.mdx` -- each carries known drift from the current rules (destination-in-prerequisites, cursor-field column, missing sections, family-outlier structure). An existing doc that conflicts with these rules is technical debt, not a template.

Use connector code and tests only to validate claims after the pattern is established.

## Docs Index Is Required

Every new docs page MUST be paired in the same commit with a matching entry in the role-specific human-curated landing page: `supaflow-www/docs-src/docs/02-sources/index.md` for sources, or `supaflow-www/docs-src/docs/03-destinations/index.md` for destinations. The Docusaurus sidebar and the `/docs/sitemap.xml` auto-discover MDX files; the index landing pages do not. A new connector that ships docs without a role-index entry is invisible to anyone browsing `/docs/sources` or `/docs/destinations` -- it ranks as an incomplete change.

Use existing entries as the voice template:

```
### {Category}

**[{Name}](./{slug})**
{One-sentence summary in the same voice as the docs frontmatter description.}
```

Match the docs frontmatter `description` in tone -- mechanism-forward, no marketing adjectives, end with a scope qualifier where honest (e.g., "Community connector." or a concrete scope statement like "Syncs nine core billing objects."). Never name internal frameworks in the qualifier -- "built on dltHub" is a banned architecture leak.

Pre-commit smoke test, run from `supaflow-www` with the path for the role you are shipping:

```
grep -i '<slug>' docs-src/docs/02-sources/index.md        # source docs
grep -i '<slug>' docs-src/docs/03-destinations/index.md   # destination docs
```

Zero matches in the relevant index = the entry didn't land. Fix before committing.

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

Exception: exact error strings the user will actually see -- whether emitted by the vendor or by Supaflow (Job Details / sync error messages) -- are fine and encouraged in Troubleshooting, even when they contain internal-sounding identifiers (e.g., "CT incremental read requires custom_state"). Quoted searchable error text is not a red flag; the same identifier in narrative prose is.

Destination-page exception: user-visible `_supa_*` system columns may be documented in destination docs, including how users query or dedupe with them. Source docs should not expose `_supa_*` columns, and destination docs should still avoid internal computation mechanics such as hashing algorithms, staging filenames, and loader internals.

## Rate-Limit Pattern

Prefer this pattern unless there is a strong reason not to:

- The source applies API rate limits.
- Supaflow handles transient rate limiting automatically -- include this sentence ONLY when retry/backoff is verifiable in code Supaflow ships and on the connector's actual request path (explicit retry in connector code, or requests genuinely flowing through the dlt requests helper). Vendor-SDK-only retry does not qualify; a vendored source that calls the vendor SDK directly bypasses the dlt helper. If nothing qualifies, say the connector does not add a vendor-specific retry layer.
- Large syncs may take longer or may need narrower scope or off-peak scheduling.
- Link the official vendor rate-limit docs for current limits.

## Simple Telltale Test

If a sentence could be pasted into connector source-code documentation or an implementation design note without sounding out of place, it is probably too technical for customer-facing docs.
