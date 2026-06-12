# Custom Hooks Patterns

## State Management Hook

```typescript
export function useToggle(initialValue = false): [boolean, () => void] {
  const [value, setValue] = useState(initialValue)
  const toggle = useCallback(() => setValue(v => !v), [])
  return [value, toggle]
}
```

## Server State (Data Fetching)

Do not hand-roll data-fetching hooks. Use a dedicated server-state library — TanStack Query or SWR — which handles caching, deduplication, retries, and revalidation correctly.

```typescript
// TanStack Query (v5: isPending; v4 used isLoading)
import { useQuery } from '@tanstack/react-query'

export function UserProfile({ userId }: { userId: string }) {
  const { data, error, isPending } = useQuery({
    queryKey: ['user', userId],
    queryFn: () => fetchUser(userId),
  })

  if (isPending) return <Spinner />
  if (error) return <ErrorMessage error={error} />
  return <Profile user={data} />
}
```

```typescript
// SWR (2.x: isLoading)
import useSWR from 'swr'

const { data, error, isLoading } = useSWR(`/api/users/${userId}`, fetcher)
```

## Debounce Hook

```typescript
export function useDebounce<T>(value: T, delay: number): T {
  const [debouncedValue, setDebouncedValue] = useState<T>(value)

  useEffect(() => {
    const handler = setTimeout(() => setDebouncedValue(value), delay)
    return () => clearTimeout(handler)
  }, [value, delay])

  return debouncedValue
}
```
