## Web Fetch / URL Analysis Standard Rule (permanent, all projects)

When reading a web page, URL, official documentation, blog post, news article, or OSS page, **extract the main content with Defuddle first, as a rule, every time** (Skill: `web-content-extraction`).

Claude Code **must not summarize, analyze, compare, or review raw HTML directly**. Convert the body to Markdown/JSON first, then read it:

```bash
node ~/.claude/skills/web-content-extraction/scripts/defuddle-url.mjs <url>   # public URL
node ~/.claude/skills/web-content-extraction/scripts/defuddle-file.mjs <file> # local HTML (no network)
```

Related commands: `/web-article` (article summary) / `/oss-analyze` (OSS investigation) / `/web-source-review` (source credibility).

### Required Rules
- Use Defuddle first when fetching the web, and prefer the extracted Markdown/JSON.
- If extraction fails (`success:false`), state **"Defuddle extraction failed"** explicitly.
- Only on failure, consider alternatives (raw fetch / GitHub raw / official API / Playwright / dedicated PDF extraction); if used, say so explicitly.
- Do not silently read full raw HTML or noise on failure.

### Security Rules
- No external fallback, no sub-resource external fetch, no in-page script execution (guaranteed by a synchronous core + a non-fetching DOM; `useAsync` does not exist in defuddle 0.6.x–0.18.x, so the intent is enforced structurally).
- Never send internal / customer / authenticated / confidential pages externally. `localhost`, private IPs, `.local`/`.internal`, single-label internal hostnames, non-http(s), and credential-bearing URLs are rejected by default. IPs are matched byte-wise (IPv4-mapped IPv6 compressed forms are rejected too). The connection IP is pinned (DNS-rebinding/TOCTOU defense), each redirect hop is re-validated, and the body is size-capped via streaming.
- Set `ALLOW_PRIVATE_URLS=true` only when explicitly permitted for development.

### Handling Extraction Results
- Always keep the URL and fetch time (`fetchedAt`/`parsedAt`) in results.
- Do not treat the extraction result as the sole source of truth. Re-confirm important facts, dates, numbers, laws, standards, and security information against primary sources.

### GitHub Repository Analysis
- Extract regular pages/official docs with Defuddle, but for repository investigation prioritize: raw README → package.json and other metadata → docs → examples → releases → issues/PRs → license.

> Note: linkedom is incompatible with `defuddle/node` (jsdom-only), so jsdom is used (verified).
