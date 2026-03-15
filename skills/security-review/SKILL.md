---
name: security-review
description: Use this skill when adding authentication, handling user input, working with secrets, creating API endpoints, or implementing payment/sensitive features. Provides comprehensive security checklist and patterns.
---

# Security Review Skill

Ensures all code follows security best practices and identifies potential vulnerabilities.

## When to Activate

- Implementing authentication or authorization
- Handling user input or file uploads
- Creating new API endpoints
- Working with secrets or credentials
- Implementing payment features
- Storing or transmitting sensitive data
- Integrating third-party APIs

## Security Checklist Categories

Review each category. See `references/vulnerability-patterns.md` for WRONG/CORRECT code examples.

1. **Secrets Management** -- No hardcoded secrets; all in env vars; `.env*` gitignored
2. **Input Validation** -- Schema validation (zod); file upload size/type/extension checks
3. **SQL Injection** -- Parameterized queries only; no string concatenation
4. **Auth & Authorization** -- httpOnly cookies; RBAC; Supabase RLS enabled
5. **XSS Prevention** -- DOMPurify for user HTML; CSP headers configured
6. **CSRF Protection** -- CSRF tokens on state-changing ops; SameSite=Strict cookies
7. **Rate Limiting** -- All endpoints rate-limited; stricter on expensive operations
8. **Data Exposure** -- No secrets in logs; generic error messages to users
9. **Blockchain** -- Wallet signatures verified; transaction validation; balance checks
10. **Dependencies** -- `npm audit` clean; lock files committed; Dependabot enabled

Full checkbox checklist: `assets/security-checklist.md`

## Pre-Deployment Checklist

Before ANY production deployment, confirm ALL of the following:

- [ ] No hardcoded secrets, all in env vars
- [ ] All user inputs validated
- [ ] All queries parameterized
- [ ] User content sanitized (XSS)
- [ ] CSRF protection enabled
- [ ] Proper token handling (httpOnly cookies)
- [ ] Authorization role checks in place
- [ ] Rate limiting on all endpoints
- [ ] HTTPS enforced
- [ ] Security headers configured (CSP, X-Frame-Options)
- [ ] No sensitive data in error messages or logs
- [ ] Dependencies up to date, no vulnerabilities
- [ ] CORS properly configured
- [ ] File uploads validated (size, type)

## References

- `references/vulnerability-patterns.md` -- All WRONG/CORRECT code examples by vulnerability type
- `assets/security-checklist.md` -- Full security review checklist (markdown checkboxes)
- [OWASP Top 10](https://owasp.org/www-project-top-ten/)
- [Next.js Security](https://nextjs.org/docs/security)
- [Supabase Security](https://supabase.com/docs/guides/auth)
- [Web Security Academy](https://portswigger.net/web-security)

---

**Security is not optional.** One vulnerability can compromise the entire platform. When in doubt, err on the side of caution.
