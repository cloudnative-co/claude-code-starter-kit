---
name: backend-patterns
description: Backend architecture patterns, API design, database optimization, and server-side best practices for Node.js, Express, and Next.js API routes.
when_to_use: Use when the user is designing or refactoring APIs, service layers, database access, or backend architecture in Node.js or Next.js projects.
---

# Backend Development Patterns

Backend architecture patterns and best practices for scalable server-side applications.

## Pattern Categories

### API Design
RESTful structure, Repository pattern, Service layer, Middleware pattern.
See [references/api-patterns.md](references/api-patterns.md) for implementations.

### Database & Caching
Query optimization, N+1 prevention, transactions, Redis cache-aside pattern.
See [references/database-caching.md](references/database-caching.md) for implementations.

### Error Handling, Auth & Infrastructure
Centralized error handler, retry with backoff, JWT/RBAC, rate limiting, job queues, structured logging.
See [references/error-auth-infra.md](references/error-auth-infra.md) for implementations.

## Quick Decision Guide

| Need | Pattern |
|------|---------|
| Data access abstraction | Repository pattern |
| Business logic isolation | Service layer |
| Auth/logging/validation | Middleware pattern |
| Expensive DB queries | Cache-aside (Redis) |
| N+1 query problem | Batch fetch with Map |
| Atomic multi-table writes | Database transactions |
| Unreliable external APIs | Retry with exponential backoff |
| Abuse prevention | Rate limiter (in-memory or Redis) |
| Non-blocking operations | Job queue |

**Remember**: Choose patterns that fit your complexity level. Not every project needs every pattern.
