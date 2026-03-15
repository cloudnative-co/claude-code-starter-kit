# Testing & Deployment

## Backend Testing (pytest)

```bash
poetry run pytest tests/                          # Run all tests
poetry run pytest tests/ --cov=. --cov-report=html # Run with coverage
poetry run pytest tests/test_auth.py -v           # Run specific test file
```

**Test structure:**
```python
import pytest
from httpx import AsyncClient
from main import app

@pytest.fixture
async def client():
    async with AsyncClient(app=app, base_url="http://test") as ac:
        yield ac

@pytest.mark.asyncio
async def test_health_check(client: AsyncClient):
    response = await client.get("/health")
    assert response.status_code == 200
    assert response.json()["status"] == "healthy"
```

## Frontend Testing (React Testing Library)

```bash
npm run test              # Run tests
npm run test -- --coverage # Run with coverage
npm run test:e2e          # Run E2E tests
```

**Test structure:**
```typescript
import { render, screen, fireEvent } from '@testing-library/react'
import { WorkspacePanel } from './WorkspacePanel'

describe('WorkspacePanel', () => {
  it('renders workspace correctly', () => {
    render(<WorkspacePanel />)
    expect(screen.getByRole('main')).toBeInTheDocument()
  })

  it('handles session creation', async () => {
    render(<WorkspacePanel />)
    fireEvent.click(screen.getByText('New Session'))
    expect(await screen.findByText('Session created')).toBeInTheDocument()
  })
})
```

## Pre-Deployment Checklist

- [ ] All tests passing locally
- [ ] `npm run build` succeeds (frontend)
- [ ] `poetry run pytest` passes (backend)
- [ ] No hardcoded secrets
- [ ] Environment variables documented
- [ ] Database migrations ready

## Deployment Commands

```bash
# Build and deploy frontend
cd frontend && npm run build
gcloud run deploy frontend --source .

# Build and deploy backend
cd backend
gcloud run deploy backend --source .
```

## Environment Variables

```bash
# Frontend (.env.local)
NEXT_PUBLIC_API_URL=https://api.example.com
NEXT_PUBLIC_SUPABASE_URL=https://xxx.supabase.co
NEXT_PUBLIC_SUPABASE_ANON_KEY=eyJ...

# Backend (.env)
DATABASE_URL=postgresql://...
ANTHROPIC_API_KEY=sk-ant-...
SUPABASE_URL=https://xxx.supabase.co
SUPABASE_KEY=eyJ...
```
